import Foundation

/// One scored answer to a bank question: from a real interview, a mock interview or practice.
struct PracticeAttempt: Codable, Hashable {
    enum Kind: String, Codable {
        case interview, mock, practice
        var title: String { L10n.tr("practice.kind.\(rawValue)") }
    }

    var date: Date
    var kind: Kind
    /// Average of the critique's three scores (1–5).
    var score: Double
    var corrections: Int
    /// The review (recording ID) or mock session this answer came from; nil for practice and
    /// for attempts recorded before this was tracked.
    var sourceID: UUID?
}

/// Spaced review. A good answer (same rule as 已掌握: average ≥ 4, no corrections) pushes the next
/// review further out, 3 → 7 → 14 → 30 → 60 days; a weak one brings the question back tomorrow.
enum ReviewSchedule {
    static let passIntervals = [3, 7, 14, 30, 60]
    static let failInterval = 1

    /// Due dates fall at the start of a day, so "due today" is everything up to tonight.
    static func next(stage: Int, passed: Bool, from date: Date, calendar: Calendar = .current) -> (stage: Int, due: Date) {
        let newStage = passed ? min(max(stage, 0) + 1, passIntervals.count) : 0
        let days = passed ? passIntervals[newStage - 1] : failInterval
        let later = calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
        return (newStage, calendar.startOfDay(for: later))
    }
}

extension BankQuestion {
    var history: [PracticeAttempt] { attempts ?? [] }

    /// Adds a scored answer. Only the newest answer sets the score, mastery and next review: a
    /// review of an older interview that finishes later still goes into the history, but doesn't
    /// override a more recent result.
    mutating func record(_ critique: Critique, kind: PracticeAttempt.Kind, at date: Date, sourceID: UUID? = nil,
                         calendar: Calendar = .current) {
        let score = Double(critique.accuracy + critique.structure + critique.depth) / 3
        let isNewest = history.allSatisfy { $0.date <= date }
        var all = history
        all.append(PracticeAttempt(date: date, kind: kind, score: score, corrections: critique.corrections.count,
                                   sourceID: sourceID))
        attempts = all.sorted { $0.date < $1.date }
        guard isNewest else { return }
        let passed = QuestionBank.mastery(for: critique) == .mastered
        lastScore = score
        mastery = passed ? .mastered : .review
        let next = ReviewSchedule.next(stage: reviewStage ?? 0, passed: passed, from: date, calendar: calendar)
        reviewStage = next.stage
        dueAt = next.due
    }

    /// Recomputes score, mastery and schedule by replaying the history (after attempts were
    /// removed). No scored attempts left → not rated, not scheduled.
    mutating func rebuildFromHistory(calendar: Calendar = .current) {
        lastScore = nil
        mastery = .new
        reviewStage = nil
        dueAt = nil
        var stage = 0
        for a in history.sorted(by: { $0.date < $1.date }) {
            let passed = a.score >= 4 && a.corrections == 0
            let next = ReviewSchedule.next(stage: stage, passed: passed, from: a.date, calendar: calendar)
            stage = next.stage
            reviewStage = next.stage
            dueAt = next.due
            lastScore = a.score
            mastery = passed ? .mastered : .review
        }
    }

    /// The user changed mastery by hand: 已掌握 counts as a good answer today, 需复习 makes it
    /// due now, 未评估 takes it off the schedule.
    mutating func setMastery(_ value: Mastery, now: Date = Date(), calendar: Calendar = .current) {
        guard value != mastery else { return }
        mastery = value
        switch value {
        case .mastered:
            let next = ReviewSchedule.next(stage: reviewStage ?? 0, passed: true, from: now, calendar: calendar)
            reviewStage = next.stage
            dueAt = next.due
        case .review:
            reviewStage = 0
            dueAt = calendar.startOfDay(for: now)
        case .new:
            reviewStage = nil
            dueAt = nil
        }
    }

    /// Questions scored before scheduling existed have no due date: they're due if they still
    /// need review.
    func isDue(at now: Date) -> Bool {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let dueAt { return dueAt <= now }
        return mastery == .review
    }
}

extension QuestionBank {
    /// Due questions, longest overdue first (unscheduled legacy ones first of all).
    func due(at now: Date) -> [BankQuestion] {
        items.filter { $0.isDue(at: now) }
            .sorted { ($0.dueAt ?? .distantPast, $0.lastScore ?? 0) < ($1.dueAt ?? .distantPast, $1.lastScore ?? 0) }
    }
}
