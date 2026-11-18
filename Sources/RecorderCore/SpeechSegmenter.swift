import AVFoundation

/// Splits one speaker's track into speech segments for transcription.
///
/// Why: Qwen-ASR's synchronous API takes ≤ 5 min / ≤ 10 MB per request and returns no
/// timestamps. Sending each utterance separately gives every line its own start time, and
/// skipping silence roughly halves what gets sent (and billed).
///
/// Method: 20 ms frames → RMS in dBFS → adaptive threshold above the track's noise floor →
/// speech runs. Runs separated by short pauses are merged (more context per request = better
/// recognition), long ones are cut at their quietest point.
public enum SpeechSegmenter {
    public static let sampleRate = 16_000

    public struct Options: Sendable {
        /// Pauses shorter than this stay inside one segment.
        public var mergeGap: Double = 0.8
        /// Segments longer than this are split (at the quietest frame in their second half).
        public var maxLength: Double = 30
        /// Speech shorter than this is dropped (clicks, coughs).
        public var minSpeech: Double = 0.3
        /// Added before/after each segment so word edges aren't clipped.
        public var padding: Double = 0.15
        public init() {}
    }

    /// A segment as sample offsets into the track's 16 kHz samples.
    public struct Segment: Equatable, Sendable {
        public let startSample: Int
        public let endSample: Int
        public var start: Double { Double(startSample) / Double(SpeechSegmenter.sampleRate) }
        public var end: Double { Double(endSample) / Double(SpeechSegmenter.sampleRate) }
        public var duration: Double { end - start }
    }

    /// One decoded track: 16 kHz mono Int16 samples, plus where it starts on the recording's
    /// timeline (the mic track usually starts a little after the system track).
    public struct Track: Sendable {
        public let samples: [Int16]
        public let startOffset: Double
    }

    // MARK: Decoding

    /// Number of audio tracks in a file, in trackID order.
    public static func audioTrackCount(url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
    }

    /// Decodes audio track `index` (trackID order) to 16 kHz mono 16-bit PCM.
    public static func readTrack(url: URL, index: Int) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard tracks.indices.contains(index) else { throw RecorderError.noAudioTracks }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw RecorderError.writeFailed(reader.error) }

        var samples: [Int16] = []
        var offset: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if offset == nil, buffer.presentationTimeStamp.isNumeric {
                offset = buffer.presentationTimeStamp.seconds
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw RecorderError.writeFailed(reader.error) }
        return Track(samples: samples, startOffset: max(0, offset ?? 0))
    }

    // MARK: Segmenting

    public static func segments(_ samples: [Int16], options: Options = Options()) -> [Segment] {
        let frame = sampleRate / 50                       // 20 ms
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return [] }

        // Frame loudness in dBFS (digital silence clamps to -100).
        var db = [Double](repeating: -100, count: frameCount)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frameCount {
                var sum = 0.0
                for i in (f * frame)..<((f + 1) * frame) {
                    let s = Double(p[i]) / 32768
                    sum += s * s
                }
                db[f] = max(-100, 10 * log10(max(sum / Double(frame), 1e-10)))
            }
        }

        // Threshold: 12 dB above the noise floor (10th percentile), kept within [-50, -28] dBFS
        // so near-silent tracks don't call noise speech and noisy rooms don't hide quiet speech.
        let floor = db.sorted()[frameCount / 10]
        let threshold = min(max(floor + 12, -50), -28)
        let framesPerSecond = 50.0

        // Speech runs, merged across short pauses.
        var runs: [(Int, Int)] = []                       // [start, end) in frames
        var f = 0
        while f < frameCount {
            guard db[f] >= threshold else { f += 1; continue }
            var end = f
            while end < frameCount && db[end] >= threshold { end += 1 }
            if let last = runs.last, Double(f - last.1) / framesPerSecond < options.mergeGap {
                runs[runs.count - 1].1 = end
            } else {
                runs.append((f, end))
            }
            f = end
        }
        runs.removeAll { Double($0.1 - $0.0) / framesPerSecond < options.minSpeech }

        // Split runs that are too long, cutting at the quietest frame in the second half of the window.
        let maxFrames = Int(options.maxLength * framesPerSecond)
        var split: [(Int, Int)] = []
        for var run in runs {
            while run.1 - run.0 > maxFrames {
                let lo = run.0 + maxFrames / 2, hi = run.0 + maxFrames
                // Quietest frame; on ties the latest one, so steady speech is cut near maxLength.
                var cut = hi - 1
                for i in lo..<hi where db[i] <= db[cut] { cut = i }
                split.append((run.0, cut))
                run.0 = cut
            }
            split.append(run)
        }

        // Pad, without overlapping neighbours or running past the ends.
        let pad = Int(options.padding * Double(sampleRate))
        var result: [Segment] = []
        for (i, run) in split.enumerated() {
            var start = max(0, run.0 * frame - pad)
            var end = min(samples.count, run.1 * frame + pad)
            if let prev = result.last { start = max(start, prev.endSample) }
            if i + 1 < split.count { end = min(end, split[i + 1].0 * frame) }
            if end > start { result.append(Segment(startSample: start, endSample: end)) }
        }
        return result
    }

    /// WAV (16 kHz mono 16-bit) for one segment.
    public static func wav(_ samples: [Int16], _ segment: Segment) -> Data {
        var pcm = Data(capacity: (segment.endSample - segment.startSample) * 2)
        samples[segment.startSample..<segment.endSample].withUnsafeBytes { pcm.append(contentsOf: $0) }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
