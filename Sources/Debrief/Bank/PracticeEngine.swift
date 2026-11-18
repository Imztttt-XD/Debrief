import Foundation

/// Practice from the question bank: answer one question at a time, the review model critiques
/// that single answer, and the result goes into the question's history and schedule
/// (Bank/ReviewSchedule.swift). Used for "今天待复习" and for practising one question.
@MainActor
final class PracticeEngine: ObservableObject {
    enum Phase: Equatable { case answering, grading, graded, failed(String) }

    struct Session {
        var queue: [UUID]
        var index = 0
        var phase = Phase.answering
        var answer = ""
        /// The critique of the current answer once it's graded.
        var critique: Critique?
        var finishedCount = 0
        var isDone: Bool { index >= queue.count }
    }

    @Published var session: Session?
    private var task: Task<Void, Never>?
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    var current: BankQuestion? {
        guard let s = session, !s.isDone else { return nil }
        return store.bank.items.first { $0.id == s.queue[s.index] }
    }

    func start(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        task?.cancel()
        session = Session(queue: ids)
    }

    func submit() {
        guard let s = session, let item = current, s.phase != .grading else { return }
        let answer = s.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        session?.phase = .grading
        let id = item.id
        task = Task { [weak self] in await self?.grade(id, answer: answer) }
    }

    /// Next question (after grading, or to skip this one).
    func next() {
        task?.cancel()
        guard var s = session else { return }
        s.index += 1
        s.phase = .answering
        s.answer = ""
        s.critique = nil
        session = s
        // A question deleted while practising: move past it.
        if !s.isDone && current == nil { next() }
    }

    func end() {
        task?.cancel()
        session = nil
    }

    private func grade(_ id: UUID, answer: String) async {
        guard let item = store.bank.items.first(where: { $0.id == id }) else { return }
        do {
            let (client, model) = try store.ai.client(for: .review)
            let analyzer = ReviewAnalyzer(client: client, model: model, outputLanguage: ReviewEngine.outputLanguage)
            let question = ReviewQuestion(question: item.question, category: item.category, resumeItem: item.resumeItem,
                                          start: nil, answer: answer, answerStart: nil, followUps: [], critique: nil)
            let result = try await analyzer.critique([question], context: context(for: item)) { _, _ in }
            try Task.checkCancellation()
            guard let critique = result.first ?? nil else { throw AIError(message: L10n.tr("error.ai.badResponse")) }
            if let i = store.bank.items.firstIndex(where: { $0.id == id }) {
                var updated = store.bank.items[i]
                updated.record(critique, kind: .practice, at: Date())
                updated.myAnswer = answer
                if !critique.betterAnswer.isEmpty { updated.betterAnswer = critique.betterAnswer }
                store.bank.items[i] = updated
            }
            guard session.map({ !$0.isDone && $0.queue[$0.index] == id }) == true else { return }
            session?.critique = critique
            session?.phase = .graded
            session?.finishedCount += 1
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard session.map({ !$0.isDone && $0.queue[$0.index] == id }) == true else { return }
            session?.phase = .failed(error.localizedDescription)
        }
    }

    /// The application the question came from (JD, resume), else the only/first resume, so the
    /// better answer can still be built from real experience.
    private func context(for item: BankQuestion) -> InterviewContext {
        var c = InterviewContext()
        c.targetDirection = store.profile.targetDirection
        if let app = store.application(item.applicationID) {
            c.company = app.company
            c.role = app.role
            c.jobDescription = app.jobDescription
            c.resume = store.resumes.first { $0.id == app.resumeID }?.text ?? ""
        } else {
            c.company = item.company
            c.role = item.role
        }
        if c.resume.isEmpty, let first = store.resumes.first { c.resume = first.text }
        return c
    }
}
