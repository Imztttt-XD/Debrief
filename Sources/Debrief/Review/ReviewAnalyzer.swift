import Foundation

/// What the analyzer knows about the interview besides the transcript.
struct InterviewContext: Sendable {
    var company = ""
    var role = ""
    var round = ""
    var targetDirection = ""
    var jobDescription = ""
    var resume = ""
}

/// Transcript → questions → per-question critique → summary, in three kinds of LLM calls.
/// Every call asks for JSON only, and the code never trusts it blindly: line numbers are
/// validated against the transcript, scores are clamped, missing fields get defaults.
struct ReviewAnalyzer {
    let client: OpenAICompatibleClient
    let model: String
    /// e.g. "简体中文" — the language the output should be in.
    let outputLanguage: String

    /// Questions per critique call; keeps each response well under output limits.
    static let critiqueBatch = 4

    // MARK: 1. Extract questions

    private struct ExtractDTO: Decodable {
        struct Item: Decodable {
            var question: String?
            var category: String?
            var resumeItem: String?
            var questionLines: [Int]?
            var answerLines: [Int]?
            var followUps: [Item]?
        }
        var questions: [Item]?
    }

    func extractQuestions(transcript: [Utterance], context: InterviewContext) async throws -> [ReviewQuestion] {
        let system = """
        你是资深的面试复盘助手。下面是一场求职面试的逐字转写，每行格式为 `L<行号> [时间] 说话人: 内容`。\
        “面试官”来自会议音频，“我”是求职者的麦克风，“未知”表示无法区分说话人。转写可能有识别错误，请结合上下文理解。

        任务：找出面试官提出的每一个主要问题、围绕它的追问，以及求职者对应的回答。
        规则：
        - “请做个自我介绍”这类请求也算问题；寒暄、闲聊、网络/设备沟通、面试官介绍公司不算。
        - 面试官在同一话题上的进一步提问放进对应主问题的 followUps，不要单独列为主问题。
        - questionLines 和 answerLines 是 [起始行号, 结束行号]（闭区间），行号必须来自原文；没有回答时 answerLines 为 null。
        - question 用简洁的书面语重述问题，可以修正明显的识别错误，但不能加入原文没有的内容。
        - category 只能是：project（项目深挖）、internship（实习/工作经历）、fundamentals（专业基础知识）、\
        algorithm（算法/编程题）、behavioral（行为题）、hr（动机/薪资/职业规划等）、other。
        - resumeItem：如果问题针对简历里的某段经历，填这段经历的简短名称，否则为 null。
        - question 字段使用\(outputLanguage)。

        只输出 JSON，格式：
        {"questions":[{"question":"…","category":"project","resumeItem":null,"questionLines":[3,4],"answerLines":[5,12],\
        "followUps":[{"question":"…","questionLines":[13,13],"answerLines":[14,18]}]}]}
        """
        // No interviewer lines at all means the meeting audio wasn't captured (silent system
        // track, e.g. an in-person interview or a self-run mock), so everything came through the
        // mic. Then "我" would be wrong for the questions: mark every line unknown and let the
        // model tell speakers apart from content.
        let speakersKnown = transcript.contains { $0.speaker == .interviewer }
        let lines = transcript.enumerated().map { i, u in
            "L\(i + 1) [\(Self.clock(u.start))] \(Self.speakerName(speakersKnown ? u.speaker : .unknown)): \(u.text)"
        }.joined(separator: "\n")
        let note = speakersKnown ? "" : "\n注意：这段录音只有麦克风音频，面试官和求职者的话混在一起，所有行都标为“未知”。请根据内容判断哪些是面试官的提问、哪些是求职者的回答。\n"
        let user = """
        \(Self.contextBlock(context, jdLimit: 1500, resumeLimit: 0))
        \(note)
        转写：
        \(lines)
        """
        let dto: ExtractDTO = try await requestJSON(system: system, user: user)

        func text(_ range: [Int]?) -> (String, Double?) {
            guard let r = range, r.count == 2 else { return ("", nil) }
            let lo = max(1, min(r[0], r[1])), hi = min(transcript.count, max(r[0], r[1]))
            guard lo <= hi else { return ("", nil) }
            let slice = transcript[(lo - 1)...(hi - 1)]
            // The answer is the candidate's lines only (or unknown-speaker lines).
            let answerLines = speakersKnown ? slice.filter { $0.speaker != .interviewer } : Array(slice)
            return (answerLines.map(\.text).joined(separator: " "), slice.first?.start)
        }
        func start(_ range: [Int]?) -> Double? {
            guard let r = range, let first = r.first, transcript.indices.contains(first - 1) else { return nil }
            return transcript[first - 1].start
        }

        return (dto.questions ?? []).compactMap { item in
            guard let q = item.question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return nil }
            let (answer, answerStart) = text(item.answerLines)
            let followUps = (item.followUps ?? []).compactMap { f -> ReviewQuestion.FollowUp? in
                guard let fq = f.question?.trimmingCharacters(in: .whitespacesAndNewlines), !fq.isEmpty else { return nil }
                return ReviewQuestion.FollowUp(question: fq, answer: text(f.answerLines).0, start: start(f.questionLines))
            }
            return ReviewQuestion(question: q,
                                  category: ReviewQuestion.categories.contains(item.category ?? "") ? item.category! : "other",
                                  resumeItem: item.resumeItem.flatMap { $0.isEmpty ? nil : $0 },
                                  start: start(item.questionLines), answer: answer, answerStart: answerStart,
                                  followUps: followUps, critique: nil)
        }
    }

    // MARK: 2. Critique

    private struct CritiqueDTO: Decodable {
        struct Item: Decodable {
            struct Scores: Decodable { var accuracy: Int?; var structure: Int?; var depth: Int? }
            struct Correction: Decodable { var claim: String?; var issue: String?; var correct: String? }
            var index: Int?
            var scores: Scores?
            var corrections: [Correction]?
            var strengths: [String]?
            var improvements: [String]?
            var betterAnswer: String?
        }
        var items: [Item]?
    }

    /// Critiques `questions` in batches; `progress(done, total)` after each batch.
    func critique(_ questions: [ReviewQuestion], context: InterviewContext,
                  progress: (Int, Int) -> Void) async throws -> [Critique?] {
        let system = """
        你是严格但建设性的面试教练，帮助求职者复盘一场真实的面试。逐题评估求职者的回答。
        要求：
        - corrections：只列出回答中确定存在的事实或技术错误（概念错误、原理错误、数据前后矛盾）。\
        每条给出原话要点 claim、问题 issue、正确说法 correct。没有把握的不要列，没有就给空数组。\
        转写可能有错别字或同音字，不要把识别错误当成回答错误。
        - strengths、improvements：各 1–3 条，要具体到这道题（例如“没有量化项目成果”“缺少方案取舍的分析”），不要空话。
        - betterAnswer：写一个更好的回答。只能使用简历和回答里出现过的真实经历、数据和项目，\
        不得编造经历、数字或公司名；可以补充通用的专业知识。300 字以内，可以用要点。
        - scores：accuracy（内容准确性）、structure（结构与表达）、depth（深度与细节），1–5 的整数。
        - 所有文字使用\(outputLanguage)。
        只输出 JSON，items 按题目编号对应：
        {"items":[{"index":0,"scores":{"accuracy":4,"structure":3,"depth":3},\
        "corrections":[{"claim":"…","issue":"…","correct":"…"}],"strengths":["…"],"improvements":["…"],"betterAnswer":"…"}]}
        """
        var results = [Critique?](repeating: nil, count: questions.count)
        let batches = stride(from: 0, to: questions.count, by: Self.critiqueBatch).map {
            Array($0..<min($0 + Self.critiqueBatch, questions.count))
        }
        for (b, indices) in batches.enumerated() {
            let items = indices.map { i -> String in
                let q = questions[i]
                var s = "### 题目 \(i)\n问题：\(q.question)\n回答：\(q.answer.isEmpty ? "（没有回答）" : q.answer)"
                for f in q.followUps { s += "\n追问：\(f.question)\n回答：\(f.answer.isEmpty ? "（没有回答）" : f.answer)" }
                return s
            }.joined(separator: "\n\n")
            let user = "\(Self.contextBlock(context, jdLimit: 3000, resumeLimit: 4000))\n\n\(items)"
            let dto: CritiqueDTO = try await requestJSON(system: system, user: user)
            for item in dto.items ?? [] {
                guard let i = item.index, indices.contains(i) else { continue }
                func clamp(_ v: Int?) -> Int { min(5, max(1, v ?? 3)) }
                results[i] = Critique(
                    accuracy: clamp(item.scores?.accuracy), structure: clamp(item.scores?.structure), depth: clamp(item.scores?.depth),
                    corrections: (item.corrections ?? []).compactMap { c in
                        guard let claim = c.claim, let issue = c.issue, !issue.isEmpty else { return nil }
                        return Critique.Correction(claim: claim, issue: issue, correct: c.correct ?? "")
                    },
                    strengths: item.strengths ?? [], improvements: item.improvements ?? [],
                    betterAnswer: item.betterAnswer ?? "")
            }
            progress(b + 1, batches.count)
        }
        return results
    }

    // MARK: 3. Summary

    private struct SummaryDTO: Decodable {
        var overall: String?
        var strengths: [String]?
        var improvements: [String]?
        var actionItems: [String]?
        var interviewerStyle: String?
    }

    func summarize(_ questions: [ReviewQuestion], transcript: [Utterance], context: InterviewContext) async throws -> ReviewSummary {
        let system = """
        你是面试教练。根据下面这场面试的逐题评估，写一份整场复盘报告。
        - overall：整体表现，3–5 句，直接、具体。
        - strengths：最多 3 条做得好的地方。
        - improvements：最多 3 条最需要改进的地方，按重要性排序。
        - actionItems：下次面试前可以执行的具体行动，最多 5 条（例如“把推荐系统项目的 QPS、延迟数据整理成一页”）。
        - interviewerStyle：这位面试官的提问风格和关注点，1–2 句。
        - 所有文字使用\(outputLanguage)。
        只输出 JSON：{"overall":"…","strengths":["…"],"improvements":["…"],"actionItems":["…"],"interviewerStyle":"…"}
        """
        let items = questions.enumerated().map { i, q in
            var s = "\(i + 1). [\(q.category)] \(q.question)"
            if let c = q.critique {
                s += "（准确 \(c.accuracy)，结构 \(c.structure)，深度 \(c.depth)）"
                if !c.corrections.isEmpty { s += "\n   错误：" + c.corrections.map(\.issue).joined(separator: "；") }
                if !c.improvements.isEmpty { s += "\n   改进：" + c.improvements.joined(separator: "；") }
            }
            return s
        }.joined(separator: "\n")
        let speakingShare = Self.speakingShare(transcript)
        let user = """
        \(Self.contextBlock(context, jdLimit: 1500, resumeLimit: 0))
        求职者说话时长占比：\(speakingShare)

        逐题评估：
        \(items)
        """
        let dto: SummaryDTO = try await requestJSON(system: system, user: user)
        return ReviewSummary(overall: dto.overall ?? "", strengths: dto.strengths ?? [], improvements: dto.improvements ?? [],
                             actionItems: dto.actionItems ?? [], interviewerStyle: dto.interviewerStyle ?? "")
    }

    // MARK: Helpers

    /// Calls the model in JSON mode and decodes; on a parse failure it retries once.
    /// No max_tokens: on reasoning models it also caps the thinking, and an 8000 cap made
    /// deepseek-v4-pro run out while still thinking ("output truncated" on a short transcript).
    private func requestJSON<T: Decodable>(system: String, user: String) async throws -> T {
        var lastError: Error = AIError(message: L10n.tr("error.ai.badResponse"))
        for _ in 0..<2 {
            let raw = try await Transcriber.withRetry {
                try await client.chat(model: model, messages: [("system", system), ("user", user)], jsonOutput: true)
            }
            do {
                return try JSONDecoder().decode(T.self, from: Data(Self.stripFences(raw).utf8))
            } catch {
                lastError = AIError(message: L10n.tr("error.review.badJSON", [String(raw.prefix(200))]))
            }
        }
        throw lastError
    }

    /// Removes ```json … ``` fences some models add even in JSON mode.
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = String(t.drop { $0 != "\n" }.dropFirst())
            if let end = t.range(of: "```", options: .backwards) { t = String(t[..<end.lowerBound]) }
        }
        return t
    }

    static func contextBlock(_ c: InterviewContext, jdLimit: Int, resumeLimit: Int) -> String {
        var parts: [String] = []
        let header = [c.company, c.role, c.round].filter { !$0.isEmpty }.joined(separator: " · ")
        if !header.isEmpty { parts.append("面试：\(header)") }
        if !c.targetDirection.isEmpty { parts.append("求职方向：\(c.targetDirection)") }
        if jdLimit > 0, !c.jobDescription.isEmpty { parts.append("岗位描述：\n\(c.jobDescription.prefix(jdLimit))") }
        if resumeLimit > 0, !c.resume.isEmpty { parts.append("求职者简历：\n\(c.resume.prefix(resumeLimit))") }
        return parts.joined(separator: "\n\n")
    }

    static func speakerName(_ s: Utterance.Speaker) -> String {
        switch s {
        case .interviewer: "面试官"
        case .me: "我"
        case .unknown: "未知"
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func speakingShare(_ t: [Utterance]) -> String {
        let me = t.filter { $0.speaker == .me }.reduce(0) { $0 + ($1.end - $1.start) }
        let all = t.reduce(0) { $0 + ($1.end - $1.start) }
        return all > 0 ? "\(Int(me / all * 100))%" : "未知"
    }
}
