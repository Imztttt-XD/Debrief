import Foundation
import Testing
@testable import Debrief

private func critique(_ a: Int, _ s: Int, _ d: Int, corrections: Int = 0, better: String = "") -> Critique {
    Critique(accuracy: a, structure: s, depth: d,
             corrections: (0..<corrections).map { _ in .init(claim: "c", issue: "i", correct: "x") },
             strengths: [], improvements: [], betterAnswer: better)
}

private func question(_ text: String, category: String = "fundamentals", answer: String = "",
                      followUps: [String] = [], critique: Critique? = nil) -> ReviewQuestion {
    ReviewQuestion(question: text, category: category, resumeItem: nil, start: nil, answer: answer, answerStart: nil,
                   followUps: followUps.map { .init(question: $0, answer: "", start: nil) }, critique: critique)
}

private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
private let day2 = day1.addingTimeInterval(86_400)

@Suite("QuestionBank.merge")
struct QuestionBankMergeTests {
    @Test func newQuestionIsAddedWithApplicationInfo() {
        var bank = QuestionBank()
        let appID = UUID()
        bank.merge([question("Redis 的持久化机制有哪些？")], source: .interview, applicationID: appID,
                   company: "字节跳动", role: "后端开发", at: day1)
        #expect(bank.items.count == 1)
        let item = bank.items[0]
        #expect(item.company == "字节跳动")
        #expect(item.role == "后端开发")
        #expect(item.applicationID == appID)
        #expect(item.timesAsked == 1)
        #expect(item.mastery == .new)
        #expect(item.lastScore == nil)
    }

    @Test func blankQuestionsAreSkipped() {
        var bank = QuestionBank()
        bank.merge([question("   "), question("")], source: .mock, applicationID: nil, company: "", role: "", at: day1)
        #expect(bank.items.isEmpty)
    }

    @Test func similarQuestionIsMergedAndCounted() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？", followUps: ["RDB 和 AOF 的区别？"])],
                   source: .mock, applicationID: nil, company: "", role: "", at: day2)
        bank.merge([question("redis持久化机制有哪些", followUps: ["RDB和AOF的区别", "AOF 重写是怎么做的？"])],
                   source: .mock, applicationID: nil, company: "", role: "", at: day1)
        #expect(bank.items.count == 1)
        let item = bank.items[0]
        #expect(item.timesAsked == 2)
        // An older interview ingested later must not move lastAskedAt backwards.
        #expect(item.lastAskedAt == day2)
        // The duplicate follow-up is dropped, the new one kept.
        #expect(item.followUps == ["RDB 和 AOF 的区别？", "AOF 重写是怎么做的？"])
    }

    @Test func differentQuestionsStaySeparate() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？"), question("讲一下你在实习中遇到的最大挑战")],
                   source: .interview, applicationID: nil, company: "", role: "", at: day1)
        #expect(bank.items.count == 2)
    }

    @Test(arguments: [
        (critique(4, 4, 4), BankQuestion.Mastery.mastered),
        (critique(5, 4, 3), .mastered),             // average exactly 4
        (critique(5, 5, 5, corrections: 1), .review), // any factual correction → review
        (critique(4, 4, 3), .review),
    ])
    func masteryFromCritique(_ c: Critique, _ expected: BankQuestion.Mastery) {
        #expect(QuestionBank.mastery(for: c) == expected)
    }

    @Test func mergeWithoutCritiqueKeepsPreviousScore() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？", critique: critique(5, 5, 5, better: "参考答案"))],
                   source: .interview, applicationID: nil, company: "", role: "", at: day1)
        bank.merge([question("Redis 的持久化机制有哪些", answer: "新的回答")],
                   source: .mock, applicationID: nil, company: "", role: "", at: day2)
        let item = bank.items[0]
        #expect(item.mastery == .mastered)
        #expect(item.lastScore == 5)
        #expect(item.betterAnswer == "参考答案")
        #expect(item.myAnswer == "新的回答")
    }

    @Test func latestCritiqueOverridesMastery() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？", critique: critique(5, 5, 5))],
                   source: .interview, applicationID: nil, company: "", role: "", at: day1)
        bank.merge([question("Redis 的持久化机制有哪些？", critique: critique(2, 2, 2))],
                   source: .mock, applicationID: nil, company: "", role: "", at: day2)
        #expect(bank.items[0].mastery == .review)
        #expect(bank.items[0].lastScore == 2)
    }

    @Test func realInterviewOutranksMockAsSource() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？")], source: .mock, applicationID: nil, company: "", role: "", at: day1)
        bank.merge([question("Redis 的持久化机制有哪些？")], source: .interview, applicationID: nil, company: "", role: "", at: day2)
        #expect(bank.items[0].source == .interview)
        bank.merge([question("Redis 的持久化机制有哪些？")], source: .mock, applicationID: nil, company: "", role: "", at: day2)
        #expect(bank.items[0].source == .interview)
    }

    @Test func otherCategoryIsUpgradedButRealCategoryIsKept() {
        var bank = QuestionBank()
        bank.merge([question("Redis 的持久化机制有哪些？", category: "other")],
                   source: .mock, applicationID: nil, company: "", role: "", at: day1)
        bank.merge([question("Redis 的持久化机制有哪些？", category: "fundamentals")],
                   source: .mock, applicationID: nil, company: "", role: "", at: day1)
        #expect(bank.items[0].category == "fundamentals")
        bank.merge([question("Redis 的持久化机制有哪些？", category: "project")],
                   source: .mock, applicationID: nil, company: "", role: "", at: day1)
        #expect(bank.items[0].category == "fundamentals")
    }
}

@Suite("Transcriber.similarity")
struct SimilarityTests {
    @Test func ignoresCasePunctuationAndSpaces() {
        #expect(Transcriber.similarity("Redis 的持久化？", "redis的持久化") == 1)
    }

    @Test func identicalEmptyStringsAreSame() {
        #expect(Transcriber.similarity("", "") == 1)
    }

    @Test func unrelatedTextScoresLow() {
        #expect(Transcriber.similarity("Redis 的持久化机制", "讲讲你的职业规划") < QuestionBank.sameQuestionThreshold)
    }
}
