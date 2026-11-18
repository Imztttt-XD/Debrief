import Foundation

/// Runs the review pipeline for a recording: transcribe → extract questions → critique →
/// summarize. Each finished step is saved immediately, so a failure (or quitting) part-way
/// keeps what's done and "继续" picks up from there.
@MainActor
final class ReviewEngine: ObservableObject {
    enum Phase: Equatable {
        case reading
        case transcribing(Int, Int)
        case extracting
        case critiquing(Int, Int)
        case summarizing

        var text: String {
            switch self {
            case .reading: L10n.tr("review.phase.reading")
            case .transcribing(let d, let t): L10n.tr("review.phase.transcribing", [String(d), String(t)])
            case .extracting: L10n.tr("review.phase.extracting")
            case .critiquing(let d, let t): L10n.tr("review.phase.critiquing", [String(d), String(t)])
            case .summarizing: L10n.tr("review.phase.summarizing")
            }
        }

        var fraction: Double? {
            switch self {
            case .transcribing(let d, let t), .critiquing(let d, let t): t > 0 ? Double(d) / Double(t) : nil
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

    func retranscribe(_ recordingID: UUID) { launch(recordingID, transcribe: true, analyze: true) }
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
                let (client, model) = try settings.client(for: .transcription)
                let transcriber = Transcriber(client: client, model: model,
                                              context: Transcriber.context(company: context.company, role: context.role,
                                                                           jd: context.jobDescription, resume: context.resume))
                let utterances = try await transcriber.transcribe(record) { [weak self] done, total in
                    Task { @MainActor in self?.running[id] = .transcribing(done, total) }
                }
                try Task.checkCancellation()
                store.updateReview(id) {
                    $0.transcript = utterances
                    $0.transcriptModel = model
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
            store.updateReview(id) { $0.lastError = error.localizedDescription }
        }
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
