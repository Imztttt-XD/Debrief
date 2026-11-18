import AVFoundation
import ScreenCaptureKit

/// Captures system audio and the microphone with a single SCStream (macOS 15+ `captureMicrophone`).
///
/// SCStream always needs a content filter and a video config, even when only audio is wanted.
/// We attach it to the main display at 2×2 px and 1 fps, and ignore the frames.
public final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var captureSystemAudio: Bool
        public var captureMicrophone: Bool
        /// `AVCaptureDevice.uniqueID`, or nil for the system default input.
        public var microphoneDeviceID: String?
        public init(captureSystemAudio: Bool, captureMicrophone: Bool, microphoneDeviceID: String?) {
            self.captureSystemAudio = captureSystemAudio
            self.captureMicrophone = captureMicrophone
            self.microphoneDeviceID = microphoneDeviceID
        }
    }

    /// Called on the capture queue, throttled to about 15 Hz per source.
    public var onLevel: (@Sendable (AudioSource, Float) -> Void)?
    /// The stream stopped on its own: display gone, permission revoked, and so on.
    public var onInterrupted: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "Debrief.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: TrackWriter?          // only touched on `queue`
    private var lastLevelAt: [AudioSource: CFAbsoluteTime] = [:]

    public func start(options: Options, writingTo url: URL) async throws {
        guard options.captureSystemAudio || options.captureMicrophone else { throw RecorderError.noSourcesEnabled }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.captureMicrophone
        if let id = options.microphoneDeviceID { config.microphoneCaptureDeviceID = id }
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let writer = try TrackWriter(url: url,
                                     captureSystem: options.captureSystemAudio,
                                     captureMicrophone: options.captureMicrophone)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // A screen output stops SCStream from logging "dropping frame" for every video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.captureSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if options.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }

        queue.sync { self.writer = writer; self.lastLevelAt = [:] }
        do {
            try await stream.startCapture()
        } catch {
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.stream = stream
    }

    /// Stops capture and finalizes the `.inprogress.mov`. Safe to call more than once.
    public func stop() async throws {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let writer: TrackWriter? = queue.sync { defer { self.writer = nil }; return self.writer }
        try await writer?.finish()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: AudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        writer?.append(sampleBuffer, from: source)

        let now = CFAbsoluteTimeGetCurrent()
        if now - (lastLevelAt[source] ?? 0) >= 1.0 / 15 {
            lastLevelAt[source] = now
            onLevel?(source, AudioLevel.normalizedRMS(sampleBuffer))
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }
}
