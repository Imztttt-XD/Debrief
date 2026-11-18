import AppKit
import AVFoundation
import CoreGraphics
import RecorderCore

struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum StopReason {
    case user, sleep, interrupted, quitting
    var noticeKey: String {
        switch self {
        case .user, .quitting: "notice.saved"
        case .sleep: "notice.sleepSaved"
        case .interrupted: "notice.interruptedSaved"
        }
    }
}

enum PermissionError: Error { case microphone, screenCapture }

@MainActor
final class Recorder: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording(since: Date), finalizing }

    private enum Key {
        static let system = "captureSystemAudio", mic = "captureMicrophone", micID = "microphoneID"
        static let micVolume = "microphoneVolume", folder = "outputFolder", consent = "acknowledgedConsent"
    }
    private let defaults = UserDefaults.standard

    @Published private(set) var phase: Phase = .idle
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Key.system) } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: Key.mic) } }
    /// "" means the system default input.
    @Published var microphoneID: String { didSet { defaults.set(microphoneID, forKey: Key.micID) } }
    @Published var microphoneVolume: Double { didSet { defaults.set(microphoneVolume, forKey: Key.micVolume) } }
    @Published private(set) var outputDirectory: URL
    @Published private(set) var microphones: [Microphone] = []
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published var notice: Notice?
    /// Called when something needs the user's eyes (e.g. a start failure triggered from the
    /// floating button while the main window is closed). Set by AppDelegate.
    var onNeedsAttention: (() -> Void)?

    /// Interview this recording belongs to. Picked automatically when recording starts (the
    /// scheduled interview closest to now, see Interview.candidates) and changeable
    /// while recording; saved with the recording.
    @Published var linkedInterviewID: UUID?
    /// Set by AppDelegate: finds the interview for a point in time.
    var interviewMatcher: ((Date) -> UUID?)?
    /// Set by AppDelegate: "字节跳动 · 后端开发 · 一面" for notices.
    var interviewLabel: ((UUID) -> String?)?
    /// Set by AppDelegate: stores the saved recording in the recordings index.
    var onRecordingSaved: ((RecordingRecord) -> Void)?
    private var activeStart: Date?
    private var activeTracks: [RecordingRecord.Track] = []

    private let engine = CaptureEngine()
    private var activeTempURL: URL?
    private var observers: [NSObjectProtocol] = []

    var isRecording: Bool { if case .recording = phase { true } else { false } }

    /// Only for DevSnapshots: show a state without actually recording.
    func setPhaseForSnapshot(_ phase: Phase) { self.phase = phase }
    var isBusy: Bool { phase == .starting || phase == .finalizing }

    init() {
        defaults.register(defaults: [Key.system: true, Key.mic: true, Key.micVolume: 1.0])
        captureSystemAudio = defaults.bool(forKey: Key.system)
        captureMicrophone = defaults.bool(forKey: Key.mic)
        microphoneID = defaults.string(forKey: Key.micID) ?? ""
        microphoneVolume = defaults.double(forKey: Key.micVolume)
        outputDirectory = defaults.url(forKey: Key.folder) ?? Self.defaultOutputDirectory()

        engine.onLevel = { [weak self] source, level in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if source == .system { self.systemLevel = level } else { self.micLevel = level }
            }
        }
        engine.onInterrupted = { [weak self] _ in
            Task { @MainActor in await self?.stop(reason: .interrupted) }
        }

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.stop(reason: .sleep) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMicrophones() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMicrophones() }
        })

        refreshMicrophones()
        // Crash recovery is started by AppDelegate once the closures above are wired up,
        // so recovered recordings get indexed and linked like normal ones.
    }

    /// ~/Movies/Debrief, unless recordings from before the rename are in ~/Movies/InterviewRecorder:
    /// then keep using that folder so they stay where the app looks.
    private static func defaultOutputDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let legacy = movies.appendingPathComponent("InterviewRecorder", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return movies.appendingPathComponent("Debrief", isDirectory: true)
    }

    func refreshMicrophones() {
        microphones = Microphone.available()
        if !microphoneID.isEmpty && !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "" }
    }

    // MARK: Start / stop

    func toggle() {
        if isRecording { Task { await stop(reason: .user) } } else { requestStart() }
    }

    /// `interviewID`: link to this interview instead of auto-matching (used by the
    /// "Start Recording" action on an interview reminder).
    func requestStart(linkTo interviewID: UUID? = nil) {
        guard phase == .idle else { return }
        guard captureSystemAudio || captureMicrophone else {
            notice = Notice("error.noSources")
            onNeedsAttention?()
            return
        }
        if !defaults.bool(forKey: Key.consent) {
            // NSAlert instead of a SwiftUI .alert so it works when started from the floating
            // button or menu bar while the main window is closed.
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L10n.tr("consent.title")
            alert.informativeText = L10n.tr("consent.message")
            alert.addButton(withTitle: L10n.tr("action.start"))
            alert.addButton(withTitle: L10n.tr("action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            defaults.set(true, forKey: Key.consent)
        }
        Task { await start(linkTo: interviewID) }
    }

    private func start(linkTo explicitInterview: UUID?) async {
        guard phase == .idle else { return }
        phase = .starting
        notice = nil
        do {
            if captureMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                throw PermissionError.microphone
            }
            // SCStream needs this even when it only captures audio.
            if !CGPreflightScreenCaptureAccess() {
                // Shows the system prompt the first time. After a denial (or a stale grant from an
                // older build) it does nothing, so also open the right Settings pane.
                if !CGRequestScreenCaptureAccess(),
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                throw PermissionError.screenCapture
            }
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let temp = RecordingFiles.newTemporaryURL(in: outputDirectory)
            try await engine.start(
                options: .init(captureSystemAudio: captureSystemAudio,
                               captureMicrophone: captureMicrophone,
                               microphoneDeviceID: microphoneID.isEmpty ? nil : microphoneID),
                writingTo: temp)
            activeTempURL = temp
            let now = Date()
            activeStart = now
            activeTracks = [captureSystemAudio ? .system : nil, captureMicrophone ? .microphone : nil].compactMap { $0 }
            linkedInterviewID = explicitInterview ?? interviewMatcher?(now)
            phase = .recording(since: now)
        } catch {
            phase = .idle
            notice = Notice(error: error)
            onNeedsAttention?()
        }
    }

    func stop(reason: StopReason) async {
        guard isRecording, let temp = activeTempURL else { return }
        phase = .finalizing
        activeTempURL = nil
        systemLevel = 0
        micLevel = 0
        do {
            try await engine.stop()
        } catch RecorderError.noAudioCaptured {
            try? FileManager.default.removeItem(at: temp)
            notice = Notice("error.noAudio")
            linkedInterviewID = nil
            phase = .idle
            return
        } catch {
            // The writer failed to finalize, but the fragmented file usually still opens. Try the mixdown anyway.
        }
        let linked = linkedInterviewID
        await finalize(temp, startedAt: activeStart ?? Date(), tracks: activeTracks, interviewID: linked)
        if let record = lastSavedRecord, record.interviewID == linked {
            notice = Notice(reason.noticeKey, detail: linked.flatMap { interviewLabel?($0) }
                .map { L10n.tr("notice.linkedTo", [$0]) })
        }
        linkedInterviewID = nil
        phase = .idle
    }

    private var lastSavedRecord: RecordingRecord?

    /// Mixes the temp file down to .m4a, keeps the per-source tracks next to it as
    /// `.tracks.mov` (needed for per-speaker transcription) and reports the recording.
    /// If the mixdown fails, the temp file stays as a checkpoint. Returns success.
    @discardableResult
    private func finalize(_ temp: URL, startedAt: Date, tracks: [RecordingRecord.Track], interviewID: UUID?) async -> Bool {
        let dest = RecordingFiles.finalURL(forTemporary: temp)
        lastSavedRecord = nil
        do {
            try await AudioMixer.mixdown(source: temp, to: dest, microphoneVolume: Float(microphoneVolume))
        } catch {
            notice = Notice("notice.checkpointKept", [temp.lastPathComponent], detail: error.localizedDescription)
            return false
        }
        let tracksURL = RecordingFiles.tracksURL(forFinal: dest)
        let keptTracks = (try? FileManager.default.moveItem(at: temp, to: tracksURL)) != nil
        if !keptTracks { try? FileManager.default.removeItem(at: temp) }
        let duration = (try? await AVURLAsset(url: dest).load(.duration).seconds) ?? 0
        let record = RecordingRecord(fileURL: dest, tracksFileURL: keptTracks ? tracksURL : nil,
                                     startedAt: startedAt, duration: duration, tracks: tracks,
                                     interviewID: interviewID)
        lastSavedRecord = record
        lastRecordingURL = dest
        onRecordingSaved?(record)
        return true
    }

    /// Turns any leftover `.inprogress.mov` (from a crash or force-quit) into an .m4a.
    func recoverInterruptedRecordings() async {
        let leftovers = RecordingFiles.leftoverTemporaryFiles(in: outputDirectory).filter { $0 != activeTempURL }
        guard !leftovers.isEmpty else { return }
        var recovered = 0
        for temp in leftovers {
            let startedAt = RecordingFiles.startDate(fromFileName: temp.lastPathComponent) ?? Date()
            // Which sources were on isn't known after a crash; two tracks can only be [system, mic].
            let trackCount = (try? await AVURLAsset(url: temp).loadTracks(withMediaType: .audio).count) ?? 0
            let tracks: [RecordingRecord.Track] = trackCount == 2 ? [.system, .microphone] : []
            if await finalize(temp, startedAt: startedAt, tracks: tracks, interviewID: interviewMatcher?(startedAt)) {
                recovered += 1
            }
        }
        if recovered > 0 {
            notice = recovered == 1 ? Notice("notice.recoveredOne")
                                    : Notice("notice.recoveredMany", [String(recovered)])
        }
    }

    // MARK: Output folder

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = L10n.tr("action.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        defaults.set(url, forKey: Key.folder)
        Task { await recoverInterruptedRecordings() }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }
}
