import Foundation
import Testing
@testable import Debrief

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2023-11-14 22:13:20 UTC: late evening, so "start of day" rounding is visible.
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func day(_ n: Int) -> Date { utc.startOfDay(for: utc.date(byAdding: .day, value: n, to: t0)!) }

private let good = Critique(accuracy: 4, structure: 4, depth: 4, corrections: [], strengths: [], improvements: [], betterAnswer: "")
private let weak = Critique(accuracy: 3, structure: 3, depth: 3, corrections: [], strengths: [], improvements: [], betterAnswer: "")
private let wrong = Critique(accuracy: 5, structure: 5, depth: 5,
                             corrections: [.init(claim: "c", issue: "i", correct: "x")],
                             strengths: [], improvements: [], betterAnswer: "")

private func item(_ text: String = "Redis 的持久化机制有哪些？") -> BankQuestion {
    BankQuestion(question: text, category: "fundamentals", source: .interview)
}

@Suite("ReviewSchedule")
struct ReviewScheduleTests {
    @Test func goodAnswersSpreadOut() {
        var stage = 0
        var dueDays: [Int] = []
        for _ in 0..<7 {
            let next = ReviewSchedule.next(stage: stage, passed: true, from: t0, calendar: utc)
            stage = next.stage
            dueDays.append(utc.dateComponents([.day], from: day(0), to: next.due).day!)
        }
        // Capped at the last interval.
        #expect(dueDays == [3, 7, 14, 30, 60, 60, 60])
    }

    @Test func weakAnswerComesBackTomorrowAndResetsStage() {
        let next = ReviewSchedule.next(stage: 4, passed: false, from: t0, calendar: utc)
        #expect(next.stage == 0)
        #expect(next.due == day(1))
    }

    @Test func recordSchedulesFromTheCritique() {
        var q = item()
        q.record(good, kind: .practice, at: t0, calendar: utc)
        #expect(q.mastery == .mastered)
        #expect(q.lastScore == 4)
        #expect(q.reviewStage == 1)
        #expect(q.dueAt == day(3))

        q.record(wrong, kind: .practice, at: day(3), calendar: utc)
        #expect(q.mastery == .review)   // a factual correction is never "mastered"
        #expect(q.reviewStage == 0)
        #expect(q.dueAt == day(4))
        #expect(q.history.map(\.corrections) == [0, 1])
    }

    @Test func olderAttemptGoesIntoHistoryWithoutOverriding() {
        var q = item()
        q.record(good, kind: .practice, at: day(5), calendar: utc)
        let due = q.dueAt
        // A review of an interview from two days earlier finishes later.
        q.record(weak, kind: .interview, at: day(3), calendar: utc)
        #expect(q.history.map(\.kind) == [.interview, .practice])   // sorted by date
        #expect(q.mastery == .mastered)
        #expect(q.lastScore == 4)
        #expect(q.dueAt == due)
    }

    @Test func dueness() {
        var q = item()
        #expect(!q.isDue(at: t0))                 // never scored
        q.mastery = .review
        #expect(q.isDue(at: t0))                  // scored before scheduling existed
        q.mastery = .mastered
        #expect(!q.isDue(at: t0))
        q.dueAt = day(2)
        #expect(!q.isDue(at: day(1)))
        #expect(q.isDue(at: day(2)))
        #expect(!item("  ").isDue(at: day(9)))    // blank manual entry
    }

    @Test func manualMasteryChanges() {
        var q = item()
        q.setMastery(.review, now: t0, calendar: utc)
        #expect(q.isDue(at: t0))
        q.setMastery(.mastered, now: t0, calendar: utc)
        #expect(q.dueAt == day(3))
        #expect(!q.isDue(at: day(2)))
        q.setMastery(.new, now: t0, calendar: utc)
        #expect(q.dueAt == nil)
        #expect(!q.isDue(at: day(30)))
    }

    @Test func dueListIsMostOverdueFirst() {
        var a = item("A 题目内容"), b = item("B 题目内容"), c = item("C 题目内容")
        a.dueAt = day(2); b.dueAt = day(1); c.mastery = .mastered; c.dueAt = day(9)
        var legacy = item("D 题目内容"); legacy.mastery = .review
        let bank = QuestionBank(items: [a, b, c, legacy])
        #expect(bank.due(at: day(5)).map(\.question) == ["D 题目内容", "B 题目内容", "A 题目内容"])
    }

    @Test func mergeSchedulesNewAndExistingQuestions() {
        var bank = QuestionBank()
        let q = ReviewQuestion(question: "Redis 的持久化机制有哪些？", category: "fundamentals", resumeItem: nil, start: nil,
                               answer: "RDB 和 AOF", answerStart: nil, followUps: [], critique: weak)
        bank.merge([q], source: .interview, applicationID: nil, company: "", role: "", at: t0)
        #expect(bank.items[0].history.map(\.kind) == [.interview])
        #expect(bank.items[0].dueAt != nil)
        bank.merge([q], source: .mock, applicationID: nil, company: "", role: "", at: day(2))
        #expect(bank.items[0].history.map(\.kind) == [.interview, .mock])
    }

    /// question-bank.json from before scheduling existed must still load.
    @Test func decodesBankWithoutSchedulingFields() throws {
        let json = """
        {"items":[{"id":"9C8B1E39-2F86-4F3E-9D2B-6E0F5C1A7B11","question":"Q","category":"hr","followUps":[],
        "company":"","role":"","source":"interview","timesAsked":1,"firstAskedAt":"2026-01-01T00:00:00Z",
        "lastAskedAt":"2026-01-01T00:00:00Z","mastery":"review","myAnswer":"","betterAnswer":"","notes":"","lastScore":3}],
        "ingestedReviews":[],"ingestedMocks":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bank = try decoder.decode(QuestionBank.self, from: Data(json.utf8))
        #expect(bank.items[0].attempts == nil)
        #expect(bank.items[0].isDue(at: Date()))
    }
}
