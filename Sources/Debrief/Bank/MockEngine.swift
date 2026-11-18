import Foundation

/// Runs text mock interviews: asks the next question / follow-up after each answer, and at the
/// end critiques the whole session (same critique and summary as a real interview review) and
/// adds the questions to the bank.
@MainActor
final class MockEngine: ObservableObject {
    enum Activity: Equatable { case thinking, critiquing(Int, Int), summarizing }

    @Published private(set) var activity: [UUID: Activity] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func isBusy(_ id: UUID) -> Bool { activity[id] != nil }

    /// Creates a session and asks the first question.
    func start(applicationID: UUID?, focus: MockSession.Focus, questionCount: Int) -> UUID {
        let session = MockSession(applicationID: applicationID, focus: focus, questionCount: questionCount)
        store.addMock(session)
        askNext(session.id)
        return session.id
    }

    func submit(_ answer: String, to id: UUID) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.mocks[id]?.awaitingAnswer == true else { return }
        store.updateMock(id) { $0.messages.append(MockMessage(kind: .answer, text: text)) }
        askNext(id)
    }

    /// Ask again after a failed request.
    func retry(_ id: UUID) {
        guard let s = store.mocks[id], !s.finished, !s.awaitingAnswer else { return }
        askNext(id)
    }

    /// Ends the interview (if still running) and critiques it.
    func finish(_ id: UUID) {
        store.updateMock(id) { $0.finished = true }
        launch(id) { [weak self] in await self?.critique(id) }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    // MARK: Interviewer

    private struct TurnDTO: Decodable {
        var kind: String?
        var text: String?
        var category: String?
        var resumeItem: String?
    }

    private func askNext(_ id: UUID) {
        launch(id) { [weak self] in await self?.interviewerTurn(id) }
    }

    private func launch(_ id: UUID, _ work: @escaping () async -> Void) {
        guard tasks[id] == nil else { return }
        activity[id] = .thinking
        tasks[id] = Task { [weak self] in
            await work()
            self?.tasks[id] = nil
            self?.activity[id] = nil
        }
    }

    private func interviewerTurn(_ id: UUID) async {
        guard let session = store.mocks[id] else { return }
        do {
            let (client, model) = try store.ai.client(for: .mockInterview)
            let context = interviewContext(for: session)
            let seeds = store.seedQuestions(for: session.applicationID, resumeText: context.resume)
            var messages: [(role: String, content: String)] = [("system", systemPrompt(session, context: context, seeds: seeds))]
            for m in session.messages {
                if m.isInterviewer {
                    messages.append(("assistant", #"{"kind":"\#(m.kind.rawValue)","text":\#(Self.jsonString(m.text))}"#))
                } else {
                    messages.append(("user", m.text))
                }
            }
            // The interviewer prompt is Chinese, so the progress note is too (not the UI language).
            let progress = "［进度：已问 \(session.mainQuestionsAsked)/\(session.questionCount) 道主问题］"
            if session.messages.isEmpty {
                messages.append(("user", "开始面试。" + progress))
            } else {
                messages[messages.count - 1].content += "\n\n" + progress
            }

            let request = messages
            let raw = try await Transcriber.withRetry {
                try await client.chat(model: model, messages: request, jsonOutput: true)
            }
            try Task.checkCancellation()
            let dto = try? JSONDecoder().decode(TurnDTO.self, from: Data(ReviewAnalyzer.stripFences(raw).utf8))
            let text = (dto?.text ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIError(message: L10n.tr("error.ai.badResponse")) }

            var kind: MockMessage.Kind = switch dto?.kind {
            case "followUp": .followUp
            case "end": .end
            default: .question
            }
            // Keep the interview to the planned length even if the model loses count.
            if kind == .question && session.mainQuestionsAsked >= session.questionCount { kind = .end }
            if kind == .followUp && session.mainQuestionsAsked == 0 { kind = .question }
            let message = MockMessage(kind: kind, text: text,
                                      category: kind == .question ? dto?.category : nil,
                                      resumeItem: kind == .question ? dto?.resumeItem.flatMap { $0.isEmpty ? nil : $0 } : nil)
            store.updateMock(id) {
                $0.messages.append(message)
                $0.lastError = nil
                if kind == .end { $0.finished = true }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            store.updateMock(id) { $0.lastError = error.localizedDescription }
        }
    }

    private func systemPrompt(_ s: MockSession, context: InterviewContext, seeds: [BankQuestion]) -> String {
        let who = [context.company, context.role].filter { !$0.isEmpty }.joined(separator: " 的 ")
        var prompt = """
        你是\(who.isEmpty ? "一家科技公司" : who)岗位的面试官，正在对求职者进行一场文字模拟面试。
        面试类型：\(s.focus.promptText)。
        规则：
        - 每次只说一句话：提出一个问题，或针对上一个回答追问。不要一次问多个问题，不要点评回答，不要给出答案。
        - 一共问 \(s.questionCount) 道主问题。每道主问题之后，根据回答追问 0–2 次：回答含糊、缺少数据、技术细节不清楚、\
        只说了“我们”没说“我”时追问；回答已经充分就进入下一道主问题。
        - 出题优先级：1) 下面“真实面试题”中的题（可以换一种问法）；2) 简历中的项目经历，深挖实现细节、数据、方案取舍和本人贡献；\
        3) 岗位描述要求的技能；4) 通用基础知识。
        - 像真实面试官一样口语化、具体，第一道题可以是简短的开场加问题。
        - \(s.questionCount) 道主问题都问完、最后的追问也结束后，返回 kind 为 end，text 写一句简短的结束语。
        - kind 为 question 时，category 取 project / internship / fundamentals / algorithm / behavioral / hr / other 之一，\
        resumeItem 填所针对的简历经历名称（没有则为 null）。
        - 所有文字使用\(ReviewEngine.outputLanguage)。
        只输出 JSON：{"kind":"question 或 followUp 或 end","text":"…","category":"project","resumeItem":null}
        """
        let ctx = ReviewAnalyzer.contextBlock(context, jdLimit: 3000, resumeLimit: 5000)
        if !ctx.isEmpty { prompt += "\n\n" + ctx }
        if !seeds.isEmpty {
            prompt += "\n\n真实面试题（求职者以前被问过的）：\n" + seeds.enumerated().map { i, q in
                var line = "\(i + 1). \(q.question)"
                if !q.company.isEmpty { line += "（\(q.company)）" }
                if q.timesAsked > 1 { line += "［被问过 \(q.timesAsked) 次］" }
                return line
            }.joined(separator: "\n")
        }
        return prompt
    }

    // MARK: Critique

    private func critique(_ id: UUID) async {
        guard let session = store.mocks[id] else { return }
        var questions = session.asReviewQuestions
        guard !questions.isEmpty else { return }
        do {
            let (client, model) = try store.ai.client(for: .review)
            let analyzer = ReviewAnalyzer(client: client, model: model, outputLanguage: ReviewEngine.outputLanguage)
            let context = interviewContext(for: session)
            let batches = (questions.count + ReviewAnalyzer.critiqueBatch - 1) / ReviewAnalyzer.critiqueBatch
            activity[id] = .critiquing(0, batches)
            let critiques = try await analyzer.critique(questions, context: context) { [weak self] done, total in
                Task { @MainActor in self?.activity[id] = .critiquing(done, total) }
            }
            try Task.checkCancellation()
            for i in questions.indices { questions[i].critique = critiques[i] }
            store.updateMock(id) { $0.questions = questions; $0.lastError = nil }
            activity[id] = .summarizing
            let summary = try await analyzer.summarize(questions, transcript: [], context: context)
            try Task.checkCancellation()
            store.updateMock(id) { $0.summary = summary }
            store.ingestMock(id)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            store.updateMock(id) { $0.lastError = error.localizedDescription }
        }
    }

    private func interviewContext(for session: MockSession) -> InterviewContext {
        var c = InterviewContext()
        c.targetDirection = store.profile.targetDirection
        if let app = store.application(session.applicationID) {
            c.company = app.company
            c.role = app.role
            c.jobDescription = app.jobDescription
            c.resume = store.resumes.first { $0.id == app.resumeID }?.text ?? ""
        }
        if c.resume.isEmpty, let first = store.resumes.first { c.resume = first.text }
        return c
    }

    static func jsonString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}
