import AVFoundation
import CoreMedia

public enum AudioSource: Sendable { case system, microphone }

public enum RecorderError: LocalizedError {
    case noSourcesEnabled
    case noDisplay
    case writerSetupFailed(Error?)
    case noAudioCaptured
    case writeFailed(Error?)
    case noAudioTracks
    case exportFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noSourcesEnabled: "Turn on System Audio or Microphone before recording."
        case .noDisplay: "No display available to attach the capture stream to."
        case .writerSetupFailed(let e): "Could not prepare the audio file. \(e?.localizedDescription ?? "")"
        case .noAudioCaptured: "No audio was captured."
        case .writeFailed(let e): "Writing audio failed. \(e?.localizedDescription ?? "")"
        case .noAudioTracks: "The recording contains no audio."
        case .exportFailed(let e): "Could not create the final M4A file. \(e?.localizedDescription ?? "")"
        }
    }
}

/// Writes each source to its own AAC track in a **fragmented** QuickTime movie.
///
/// With `movieFragmentInterval` set, AVAssetWriter flushes a readable fragment every few
/// seconds. If the process dies before `finish()`, the file can still be opened up to the
/// last fragment, which is what makes crash recovery possible.
///
/// Track order is fixed: system audio comes first (if enabled), then the microphone.
/// `AudioMixer` relies on that order.
///
/// Not thread-safe: call it from a single serial queue (the capture queue).
public final class TrackWriter: @unchecked Sendable {
    public static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    public private(set) var droppedBuffers = 0

    public init(url: URL, captureSystem: Bool, captureMicrophone: Bool) throws {
        guard captureSystem || captureMicrophone else { throw RecorderError.noSourcesEnabled }
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.writerSetupFailed(error)
        }
        writer.movieFragmentInterval = Self.fragmentInterval
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        func makeInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }

        systemInput = captureSystem ? makeInput(channels: 2, bitRate: 192_000) : nil
        micInput = captureMicrophone ? makeInput(channels: 1, bitRate: 96_000) : nil
        for input in [systemInput, micInput].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw RecorderError.writerSetupFailed(nil) }
            writer.add(input)
        }
        guard writer.startWriting() else { throw RecorderError.writerSetupFailed(writer.error) }
    }

    public func isReady(for source: AudioSource) -> Bool {
        input(for: source)?.isReadyForMoreMediaData ?? false
    }

    /// Appends one buffer. Both sources share ScreenCaptureKit's host-time clock, so their
    /// timestamps can go straight onto the same timeline.
    public func append(_ buffer: CMSampleBuffer, from source: AudioSource) {
        guard writer.status == .writing, CMSampleBufferDataIsReady(buffer),
              let input = input(for: source) else { return }
        let pts = buffer.presentationTimeStamp
        guard pts.isValid else { return }

        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        // Drop buffers from before the session start, and buffers that arrive while the encoder
        // is still busy. Blocking here would stall the capture queue for both sources.
        guard let start = sessionStart, pts >= start, input.isReadyForMoreMediaData else {
            droppedBuffers += 1
            return
        }
        if !input.append(buffer) { droppedBuffers += 1 }
    }

    public func finish() async throws {
        guard sessionStart != nil else {
            writer.cancelWriting()
            throw RecorderError.noAudioCaptured
        }
        systemInput?.markAsFinished()
        micInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw RecorderError.writeFailed(writer.error) }
    }

    private func input(for source: AudioSource) -> AVAssetWriterInput? {
        source == .system ? systemInput : micInput
    }
}
