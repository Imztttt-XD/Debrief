import Foundation

/// One question in the question bank. Similar questions from different interviews are merged
/// into one entry, counting how often it was asked.
struct BankQuestion: Codable, Identifiable, Hashable {
    enum Mastery: String, Codable, CaseIterable, Identifiable {
        case new, review, mastered
        var id: String { rawValue }
        var title: String { L10n.tr("bank.mastery.\(rawValue)") }
    }

    enum Source: String, Codable {
        case interview, mock, manual
        var title: String { L10n.tr("bank.source.\(rawValue)") }
    }

    var id = UUID()
    var question: String
    /// Same values as ReviewQuestion.category.
    var category: String
    var resumeItem: String?
    var followUps: [String] = []
    var applicationID: UUID?
    var company = ""
    var role = ""
    var source: Source
    var timesAsked = 1
    var firstAskedAt = Date()
    var lastAskedAt = Date()
    var mastery: Mastery = .new
    /// Latest answer given (interview transcript or mock interview).
    var myAnswer = ""
    /// Reference answer from the latest critique; editable.
    var betterAnswer = ""
    var notes = ""
    /// Average of the latest critique's three scores (1–5).
    var lastScore: Double?

    var categoryTitle: String {
        L10n.tr("review.category.\(ReviewQuestion.categories.contains(category) ? category : "other")")
    }
}

struct QuestionBank: Codable {
    var items: [BankQuestion] = []
    /// Reviews / mock sessions already added, so they're never added twice.
    var ingestedReviews: [UUID] = []
    var ingestedMocks: [UUID] = []
}

// MARK: - Mock interview

struct MockMessage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case question, followUp, end, answer }

    var id = UUID()
    var kind: Kind
    var text: String
    var createdAt = Date()
    /// For main questions: the interviewer's own classification (ReviewQuestion.categories).
    var category: String?
    var resumeItem: String?

    var isInterviewer: Bool { kind != .answer }
}

struct MockSession: Codable, Identifiable, Hashable {
    enum Focus: String, Codable, CaseIterable, Identifiable {
        case mixed, project, fundamentals, behavioral, hr
        var id: String { rawValue }
        var title: String { L10n.tr("mock.focus.\(rawValue)") }
        /// How the interviewer prompt describes the interview type.
        var promptText: String {
            switch self {
            case .mixed: "综合技术面（以简历项目深挖为主，穿插专业基础）"
            case .project: "项目深挖面（围绕简历中的项目，追问实现细节、数据、取舍和个人贡献）"
            case .fundamentals: "专业基础面（结合岗位要求考察基础知识与原理）"
            case .behavioral: "行为面（经历、协作、冲突、失败与成长，用 STAR 追问细节）"
            case .hr: "HR 面（求职动机、职业规划、稳定性、期望与到岗时间）"
            }
        }
    }

    static let questionCountChoices = [3, 5, 8, 10]

    var id = UUID()
    var applicationID: UUID?
    var focus: Focus = .mixed
    var questionCount = 5
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [MockMessage] = []
    /// The interviewer said the interview is over (or the user ended it).
    var finished = false
    /// Filled by "结束并点评".
    var questions: [ReviewQuestion] = []
    var summary: ReviewSummary?
    var lastError: String?

    var mainQuestionsAsked: Int { messages.filter { $0.kind == .question }.count }
    var awaitingAnswer: Bool {
        guard !finished, let last = messages.last else { return false }
        return last.kind == .question || last.kind == .followUp
    }

    /// Questions with their follow-ups and my answers, in order: the input for critique and export.
    var asReviewQuestions: [ReviewQuestion] {
        var result: [ReviewQuestion] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            let answer = i + 1 < messages.count && messages[i + 1].kind == .answer ? messages[i + 1].text : ""
            switch m.kind {
            case .question:
                let category = m.category.flatMap { ReviewQuestion.categories.contains($0) ? $0 : nil } ?? "other"
                result.append(ReviewQuestion(question: m.text, category: category, resumeItem: m.resumeItem, start: nil,
                                             answer: answer, answerStart: nil, followUps: [], critique: nil))
            case .followUp:
                if result.isEmpty {
                    result.append(ReviewQuestion(question: m.text, category: "other", resumeItem: nil, start: nil,
                                                 answer: answer, answerStart: nil, followUps: [], critique: nil))
                } else {
                    result[result.count - 1].followUps.append(.init(question: m.text, answer: answer, start: nil))
                }
            default: break
            }
            i += 1
        }
        return result
    }
}
