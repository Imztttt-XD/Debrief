// Headless check of the RecorderCore write → recover → mixdown path, using synthetic audio.
//   swift run RecorderSelfTest [output-dir]
// Doesn't use ScreenCaptureKit, so it needs no permissions.
import AVFoundation
import Foundation
import RecorderCore

let sampleRate = 48_000.0
let chunkFrames = 1024

func makeBuffer(channels: Int, startFrame: Int, frequency: Double, hostStart: CMTime) -> CMSampleBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames))!
    pcm.frameLength = AVAudioFrameCount(chunkFrames)
    for c in 0..<channels {
        let p = pcm.floatChannelData![c]
        for i in 0..<chunkFrames {
            p[i] = Float(0.25 * sin(2 * .pi * frequency * Double(startFrame + i) / sampleRate))
        }
    }
    let pts = CMTimeAdd(hostStart, CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)))
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                    presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                         makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                         sampleCount: chunkFrames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                         sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
    CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: kCFAllocatorDefault,
                                                   blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                   flags: 0, bufferList: pcm.audioBufferList)
    return sb!
}

/// Feeds `seconds` of system (stereo 440 Hz) and mic (mono 660 Hz) audio, interleaved like the real stream.
/// The mic starts 0.5 s late, as it would in practice.
func feed(_ writer: TrackWriter, seconds: Double) {
    let host = CMClockGetTime(CMClockGetHostTimeClock())
    let total = Int(seconds * sampleRate)
    let micOffset = Int(0.5 * sampleRate)
    var frame = 0
    while frame < total {
        while !writer.isReady(for: .system) { usleep(500) }
        writer.append(makeBuffer(channels: 2, startFrame: frame, frequency: 440, hostStart: host), from: .system)
        if frame >= micOffset {
            while !writer.isReady(for: .microphone) { usleep(500) }
            writer.append(makeBuffer(channels: 1, startFrame: frame, frequency: 660, hostStart: host), from: .microphone)
        }
        frame += chunkFrames
    }
}

func describe(_ url: URL) async throws -> (duration: Double, tracks: Int, channels: Int) {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    var channels = 0
    if let t = tracks.first, let desc = try await t.load(.formatDescriptions).first {
        channels = Int(desc.audioStreamBasicDescription?.mChannelsPerFrame ?? 0)
    }
    return (duration, tracks.count, channels)
}

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments

// Child-process mode: write, then die without finishing (a simulated crash).
if args.count == 3, args[1] == "--crash-writer" {
    let writer = try TrackWriter(url: URL(fileURLWithPath: args[2]), captureSystem: true, captureMicrophone: true)
    feed(writer, seconds: 5)
    sleep(1)       // give the writer time to flush the last fragment, like a recording that keeps running
    exit(0)        // no finish(): the moov never gets finalized
}

let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory())
    .appendingPathComponent("recorder-selftest-\(getpid())", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
print("Working in \(dir.path)\n")

// 1. Normal path: two tracks → finish → mixdown.
do {
    let temp = RecordingFiles.newTemporaryURL(in: dir)
    let writer = try TrackWriter(url: temp, captureSystem: true, captureMicrophone: true)
    feed(writer, seconds: 3)
    try await writer.finish()
    let raw = try await describe(temp)
    check(raw.tracks == 2, "finished .mov has 2 separate tracks (got \(raw.tracks))")

    let final = RecordingFiles.finalURL(forTemporary: temp)
    try await AudioMixer.mixdown(source: temp, to: final, microphoneVolume: 0.8)
    let out = try await describe(final)
    check(final.pathExtension == "m4a" && final.lastPathComponent.hasPrefix("Interview-"), "final name \(final.lastPathComponent)")
    check(out.tracks == 1, "mixdown has 1 track (got \(out.tracks))")
    check(out.channels == 2, "mixdown is stereo (got \(out.channels) ch)")
    check(abs(out.duration - 3) < 0.15, String(format: "mixdown duration ≈ 3 s (got %.2f s)", out.duration))
}

// 2. Crash path: a child process writes 5 s and exits without finalizing → recover.
do {
    let temp = RecordingFiles.newTemporaryURL(in: dir, date: Date().addingTimeInterval(1))
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
    if !FileManager.default.isExecutableFile(atPath: child.executableURL!.path) {
        child.executableURL = Bundle.main.executableURL
    }
    child.arguments = ["--crash-writer", temp.path]
    try child.run()
    child.waitUntilExit()

    let leftovers = RecordingFiles.leftoverTemporaryFiles(in: dir)
    check(leftovers.contains(temp), "crashed recording left \(temp.lastPathComponent)")

    let recovered = RecordingFiles.finalURL(forTemporary: temp)
    do {
        try await AudioMixer.mixdown(source: temp, to: recovered)
        let out = try await describe(recovered)
        check(out.duration >= 3.0, String(format: "recovered %.2f s of the 5 s written before the crash", out.duration))
    } catch {
        check(false, "recovery mixdown: \(error.localizedDescription)")
    }
}

// 3. Writer with no audio fails cleanly instead of producing an empty file.
do {
    let writer = try TrackWriter(url: dir.appendingPathComponent("empty.inprogress.mov"),
                                 captureSystem: true, captureMicrophone: false)
    do { try await writer.finish(); check(false, "empty recording should throw") }
    catch RecorderError.noAudioCaptured { check(true, "empty recording throws noAudioCaptured") }
}

// 4. Speech segmentation on synthetic audio.
do {
    let rate = SpeechSegmenter.sampleRate
    var samples: [Int16] = []
    func silence(_ s: Double) { for i in 0..<Int(s * Double(rate)) { samples.append(Int16((i * 7919) % 61) - 30) } } // faint noise
    func tone(_ s: Double) { let n = samples.count; for i in 0..<Int(s * Double(rate)) { samples.append(Int16(6000 * sin(2 * .pi * 220 * Double(n + i) / Double(rate)))) } }
    silence(1); tone(2); silence(0.4); tone(2); silence(3); tone(70); silence(1)
    let segs = SpeechSegmenter.segments(samples)
    check(segs.count >= 4, "found \(segs.count) segments")
    if let first = segs.first {
        check(abs(first.start - 0.85) < 0.1 && abs(first.end - 5.55) < 0.1,
              String(format: "short pause merged: first segment %.2f–%.2f s (expect ≈0.85–5.55)", first.start, first.end))
    }
    let long = segs.dropFirst()
    check(long.allSatisfy { $0.duration <= 30.4 }, "long speech split into ≤ 30 s pieces: " + long.map { String(format: "%.1f", $0.duration) }.joined(separator: ", "))
    let covered = long.reduce(0) { $0 + $1.duration }
    check(abs(covered - 70.3) < 1, String(format: "split pieces cover the 70 s run (%.1f s)", covered))
    let silent = [Int16](repeating: 0, count: rate * 5)
    check(SpeechSegmenter.segments(silent).isEmpty, "pure silence → no segments")
    let wav = SpeechSegmenter.wav(samples, segs[0])
    check(wav.count == 44 + (segs[0].endSample - segs[0].startSample) * 2, "segment WAV size")
}

// 5. Decoding tracks from a real .tracks file (from check 1): mic starts 0.5 s late.
do {
    var twoTrackFile: URL?
    for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
        where url.lastPathComponent.hasSuffix(RecordingFiles.inProgressSuffix) {
        if ((try? await SpeechSegmenter.audioTrackCount(url: url)) ?? 0) == 2 { twoTrackFile = url; break }
    }
    if let file = twoTrackFile {
        let system = try await SpeechSegmenter.readTrack(url: file, index: 0)
        let mic = try await SpeechSegmenter.readTrack(url: file, index: 1)
        check(abs(Double(system.samples.count) / 16000 - 3) < 0.15, String(format: "system track decodes to %.2f s at 16 kHz", Double(system.samples.count) / 16000))
        // The reader fills the mic track's leading empty edit with silence, so both tracks share
        // one timeline from sample 0: the mic's speech must show up ≈0.5 s in.
        let micStart = SpeechSegmenter.segments(mic.samples).first.map { $0.start + 0.15 } ?? -1  // undo padding
        check(system.startOffset < 0.05 && mic.startOffset < 0.05 && abs(micStart - 0.51) < 0.06,
              String(format: "tracks aligned: mic speech starts at %.3f s on the shared timeline (expect ≈0.51)", micStart))
        check(!SpeechSegmenter.segments(system.samples).isEmpty, "tone in decoded track is detected as speech")
    } else {
        check(false, "two-track file from check 1 not found")
    }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
