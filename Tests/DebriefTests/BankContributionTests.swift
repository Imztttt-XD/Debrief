import Foundation
import Testing
@testable import Debrief

private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
private let day2 = day1.addingTimeInterval(86_400 * 3)

private func critique(_ s: Int) -> Critique {
    Critique(accuracy: s, structure: s, depth: s, corrections: [], strengths: [], improvements: [], betterAnswer: "")
}

private func q(_ text: String, score: Int? = nil) -> ReviewQuestion {
    ReviewQuestion(question: text, category: "fundamentals", resumeItem: nil, start: nil, answer: "答", answerStart: nil,
                   followUps: [], critique: score.map(critique))
}

private let redis = "Redis 的持久化机制有哪些？"
private let kafka = "Kafka 如何保证消息不丢失？"

@Suite("QuestionBank.removeContributions")
struct BankContributionTests {
    @Test func removesOnlyWhatThatReviewAdded() {
        let reviewA = UUID(), reviewB = UUID()
        var bank = QuestionBank()
        bank.merge([q(redis, score: 2), q(kafka, score: 3)], source: .interview, applicationID: nil,
                   company: "", role: "", at: day1, sourceID: reviewA)
        bank.merge([q(redis, score: 5)], source: .interview, applicationID: nil, company: "", role: "", at: day2, sourceID: reviewB)
        #expect(bank.items.first { $0.question == redis }?.timesAsked == 2)

        bank.removeContributions(of: reviewB, questions: [q(redis, score: 5)], kind: .interview, date: day2)

        // Kafka only came from A: untouched. Redis: back to A's single answer and its score.
        #expect(bank.items.count == 2)
        let r = bank.items.first { $0.question == redis }!
        #expect(r.timesAsked == 1)
        #expect(r.history.count == 1 && r.history[0].sourceID == reviewA)
        #expect(r.lastScore == 2)
        #expect(r.mastery == .review)

        bank.removeContributions(of: reviewA, questions: [q(redis), q(kafka)], kind: .interview, date: day1)
        #expect(bank.items.isEmpty)
    }

    @Test func manualQuestionsStay() {
        let review = UUID()
        var bank = QuestionBank(items: [BankQuestion(question: redis, category: "fundamentals", source: .manual)])
        bank.merge([q(redis, score: 4)], source: .mock, applicationID: nil, company: "", role: "", at: day1, sourceID: review)
        bank.removeContributions(of: review, questions: [q(redis)], kind: .mock, date: day1)
        #expect(bank.items.count == 1)
        #expect(bank.items[0].timesAsked == 1)
        #expect(bank.items[0].history.isEmpty)
        #expect(bank.items[0].dueAt == nil)
    }

    @Test func legacyEntriesAreMatchedByTextAndDate() {
        // As saved before sources were tracked: no `sources`, attempts without sourceID.
        var old = BankQuestion(question: redis, category: "fundamentals", source: .interview, timesAsked: 2)
        old.attempts = [PracticeAttempt(date: day1, kind: .interview, score: 2, corrections: 0),
                        PracticeAttempt(date: day2, kind: .interview, score: 5, corrections: 0)]
        let lonely = BankQuestion(question: kafka, category: "fundamentals", source: .interview)
        var bank = QuestionBank(items: [old, lonely])

        bank.removeContributions(of: UUID(), questions: [q(redis), q(kafka)], kind: .interview, date: day2)

        #expect(bank.items.map(\.question) == [redis])
        #expect(bank.items[0].timesAsked == 1)
        #expect(bank.items[0].history.map(\.date) == [day1])
        #expect(bank.items[0].lastScore == 2)
    }

    @Test func questionAskedTwiceInOneReviewIsFullyUndone() {
        let review = UUID()
        var bank = QuestionBank()
        bank.merge([q(redis), q("redis持久化机制有哪些")], source: .interview, applicationID: nil,
                   company: "", role: "", at: day1, sourceID: review)
        #expect(bank.items.count == 1 && bank.items[0].timesAsked == 2)
        bank.removeContributions(of: review, questions: [], kind: .interview, date: day1)
        #expect(bank.items.isEmpty)
    }

    @Test func mergingAgainAfterRemovalCountsOnce() {
        let review = UUID()
        var bank = QuestionBank()
        bank.merge([q(redis, score: 3)], source: .interview, applicationID: nil, company: "", role: "", at: day1, sourceID: review)
        bank.removeContributions(of: review, questions: [q(redis)], kind: .interview, date: day1)
        bank.merge([q(redis, score: 3)], source: .interview, applicationID: nil, company: "", role: "", at: day1, sourceID: review)
        #expect(bank.items.count == 1 && bank.items[0].timesAsked == 1 && bank.items[0].history.count == 1)
    }
}
