import Foundation
import RecorderCore

/// Runs the review pipeline for a recording: transcribe → extract questions → critique →
/// summarize. Each finished step is saved immediately, so a failure (or quitting) part-way
/// keeps what's done and "继续" picks up from there.
@MainActor
final class ReviewEngine: ObservableObject {
    enum Phase: Equatable {
        case reading
        case transcribing(Int, Int)
        /// On-device transcription, percent done.
        case transcribingLocally(Int)
        case separatingSpeakers
        case extracting
        case critiquing(Int, Int)
        case summarizing

        var text: String {
            switch self {
            case .reading: L10n.tr("review.phase.reading")
            case .transcribing(let d, let t): L10n.tr("review.phase.transcribing", [String(d), String(t)])
            case .transcribingLocally(let p): L10n.tr("review.phase.transcribingLocal", [String(p)])
            case .separatingSpeakers: L10n.tr("review.phase.separatingSpeakers")
            case .extracting: L10n.tr("review.phase.extracting")
            case .critiquing(let d, let t): L10n.tr("review.phase.critiquing", [String(d), String(t)])
            case .summarizing: L10n.tr("review.phase.summarizing")
            }
        }

        var fraction: Double? {
            switch self {
            case .transcribing(let d, let t), .critiquing(let d, let t): t > 0 ? Double(d) / Double(t) : nil
            case .transcribingLocally(let p): Double(p) / 100
            default: nil
            }
        }
    }

    @Published private(set) var running: [UUID: Phase] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    /// Does whatever is missing: transcribes if there's no transcript, then analyzes.
    func start(_ recordingID: UUID) {
        let hasTranscript = store.review(for: recordingID)?.isTranscribed ?? false
        launch(recordingID, transcribe: !hasTranscript, analyze: true)
    }

    func retranscribe(_ recordingID: UUID) {
        // Starting over: don't reuse segments from an earlier run.
        store.updateReview(recordingID) { $0.transcriptCache = nil }
        launch(recordingID, transcribe: true, analyze: true)
    }
    func reanalyze(_ recordingID: UUID) { launch(recordingID, transcribe: false, analyze: true) }

    func cancel(_ recordingID: UUID) {
        tasks[recordingID]?.cancel()
    }

    private func launch(_ id: UUID, transcribe: Bool, analyze: Bool) {
        guard tasks[id] == nil else { return }
        running[id] = .reading
        tasks[id] = Task { [weak self] in
            await self?.run(id, transcribe: transcribe, analyze: analyze)
        }
    }

    private func run(_ id: UUID, transcribe: Bool, analyze: Bool) async {
        defer {
            running[id] = nil
            tasks[id] = nil
        }
        guard let record = store.recordings.first(where: { $0.id == id }) else { return }
        store.ensureReview(for: id)
        let settings = store.ai
        let context = interviewContext(for: record)

        do {
            if transcribe {
                var (utterances, model) = try await transcribeRecording(record, id: id, settings: settings, context: context)
                try Task.checkCancellation()
                let estimated = await separateSpeakers(&utterances, record: record, id: id)
                try Task.checkCancellation()
                store.updateReview(id) {
                    $0.transcript = utterances
                    $0.transcriptModel = model
                    $0.speakersEstimated = estimated ? true : nil
                    $0.transcriptCache = nil
                    $0.transcriptEdited = false
                    $0.questions = []
                    $0.summary = nil
                    $0.lastError = nil
                }
                guard !utterances.isEmpty else { throw AIError(message: L10n.tr("error.review.noSpeech")) }
            }

            guard analyze, let transcript = store.review(for: id)?.transcript, !transcript.isEmpty else { return }
            let (client, model) = try settings.client(for: .review)
            let analyzer = ReviewAnalyzer(client: client, model: model, outputLanguage: Self.outputLanguage)

            running[id] = .extracting
            var questions = try await analyzer.extractQuestions(transcript: transcript, context: context)
            try Task.checkCancellation()
            store.updateReview(id) {
                $0.questions = questions
                $0.summary = nil
                $0.analysisModel = model
                $0.lastError = nil
            }
            guard !questions.isEmpty else { throw AIError(message: L10n.tr("error.review.noQuestions")) }

            let batches = (questions.count + ReviewAnalyzer.critiqueBatch - 1) / ReviewAnalyzer.critiqueBatch
            running[id] = .critiquing(0, batches)
            let critiques = try await analyzer.critique(questions, context: context) { [weak self] done, total in
                Task { @MainActor in self?.running[id] = .critiquing(done, total) }
            }
            try Task.checkCancellation()
            for i in questions.indices { questions[i].critique = critiques[i] }
            store.updateReview(id) { $0.questions = questions }

            running[id] = .summarizing
            let summary = try await analyzer.summarize(questions, transcript: transcript, context: context)
            try Task.checkCancellation()
            store.updateReview(id) {
                $0.summary = summary
                $0.transcriptEdited = false
                $0.lastError = nil
            }
            store.ingestReview(id)
        } catch {
            // Cancelling also surfaces as a URLSession error; don't report it as a failure.
            if Task.isCancelled || error is CancellationError { return }
            // Rate limited even after waiting: say what was kept and what to do.
            let message = (error as? AIError)?.isRateLimit == true ? L10n.tr("review.error.rateLimited") : error.localizedDescription
            store.updateReview(id) { $0.lastError = message }
        }
    }

    /// UserDefaults key of the 实验功能 switch in 设置 → 通用.
    static let speakerSeparationKey = "experimentalSpeakerSeparation"

    /// Experimental: a single-track recording (every line 未知) gets its speakers from
    /// SpeakerSeparation. Any failure leaves the lines as they were: the review still works,
    /// just without speakers. Returns whether speakers were assigned.
    private func separateSpeakers(_ utterances: inout [Utterance], record: RecordingRecord, id: UUID) async -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.speakerSeparationKey), SpeakerSeparation.isReady,
              !utterances.isEmpty, utterances.allSatisfy({ $0.speaker == .unknown }) else { return false }
        running[id] = .separatingSpeakers
        do {
            let (file, _) = try await Transcriber.sources(for: record)
            let track = try await SpeechSegmenter.readTrack(url: file, index: 0)
            let turns = try await SpeakerSeparation.diarize(track)
            let labeled = SpeakerSeparation.assign(utterances, turns: turns)
            guard labeled != utterances else { return false }
            utterances = labeled
            return true
        } catch {
            NSLog("Debrief: speaker separation failed: \(error)")
            return false
        }
    }

    /// On this Mac (macOS 26+, no key) or with the cloud model, per the settings.
    private func transcribeRecording(_ record: RecordingRecord, id: UUID, settings: AISettings,
                                     context: InterviewContext) async throws -> ([Utterance], String) {
        if settings.usesLocalTranscription, #available(macOS 26, *) {
            let terms = [context.company, context.role].filter { !$0.isEmpty }
                + Transcriber.terms(jd: context.jobDescription, resume: context.resume)
            running[id] = .transcribingLocally(0)
            let (utterances, locale) = try await LocalTranscriber.transcribe(record, terms: terms) { [weak self] fraction in
                Task { @MainActor in self?.running[id] = .transcribingLocally(Int(fraction * 100)) }
            }
            return (utterances, LocalTranscriber.modelName(locale))
        }
        let (client, model) = try settings.client(for: .transcription)
        let transcriber = Transcriber(client: client, model: model,
                                      context: Transcriber.context(company: context.company, role: context.role,
                                                                   jd: context.jobDescription, resume: context.resume))
        let cached = store.review(for: id)?.transcriptCache ?? [:]
        let utterances = try await transcriber.transcribe(record, cached: cached, onSegment: { [weak self] key, text in
            Task { @MainActor in self?.store.updateReview(id) { $0.transcriptCache = ($0.transcriptCache ?? [:]).merging([key: text]) { $1 } } }
        }, progress: { [weak self] done, total in
            Task { @MainActor in self?.running[id] = .transcribing(done, total) }
        })
        return (utterances, model)
    }

    private func interviewContext(for record: RecordingRecord) -> InterviewContext {
        var c = InterviewContext()
        c.targetDirection = store.profile.targetDirection
        if let iv = store.interview(record.interviewID) {
            c.round = iv.round
            if let app = store.application(iv.applicationID) {
                c.company = app.company
                c.role = app.role
                c.jobDescription = app.jobDescription
                c.resume = store.resumes.first { $0.id == app.resumeID }?.text ?? ""
            }
        }
        // No resume chosen for this application: use the only one, if there is exactly one.
        if c.resume.isEmpty, store.resumes.count == 1 { c.resume = store.resumes[0].text }
        return c
    }

    /// The review is written in the app's UI language.
    static var outputLanguage: String {
        switch AppLanguage.current.resolvedCode {
        case "zh-Hant": "繁體中文"
        case "en": "English"
        case "ja": "日本語"
        default: "简体中文"
        }
    }
}
