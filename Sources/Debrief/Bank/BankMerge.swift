import Foundation

/// Pure merge logic for the question bank: no disk, no UI, so it can be unit tested.
/// AppStore.ingest calls this and then saves.
extension QuestionBank {
    /// Questions this similar (character-bigram Jaccard) are treated as the same question.
    static let sameQuestionThreshold = 0.55

    /// Mastery from the latest critique: average ≥ 4 with no corrections → mastered,
    /// otherwise review. No critique → new.
    static func mastery(for critique: Critique?) -> BankQuestion.Mastery {
        guard let c = critique else { return .new }
        let score = Double(c.accuracy + c.structure + c.depth) / 3
        return score >= 4 && c.corrections.isEmpty ? .mastered : .review
    }

    /// Adds critiqued questions, merging each into an existing entry when it's the same question
    /// (counting it as asked again) and otherwise creating a new one.
    /// `company` / `role` are only used for new entries.
    mutating func merge(_ questions: [ReviewQuestion], source: BankQuestion.Source, applicationID: UUID?,
                        company: String, role: String, at date: Date) {
        for q in questions where !q.question.trimmingCharacters(in: .whitespaces).isEmpty {
            let score = q.critique.map { Double($0.accuracy + $0.structure + $0.depth) / 3 }
            let mastery = Self.mastery(for: q.critique)
            let followUps = q.followUps.map(\.question)
            if let i = items.firstIndex(where: { Transcriber.similarity($0.question, q.question) >= Self.sameQuestionThreshold }) {
                items[i].timesAsked += 1
                items[i].lastAskedAt = max(items[i].lastAskedAt, date)
                for f in followUps where !items[i].followUps.contains(where: { Transcriber.similarity($0, f) >= Self.sameQuestionThreshold }) {
                    items[i].followUps.append(f)
                }
                if !q.answer.isEmpty { items[i].myAnswer = q.answer }
                if let c = q.critique, !c.betterAnswer.isEmpty { items[i].betterAnswer = c.betterAnswer }
                if let score { items[i].lastScore = score; items[i].mastery = mastery }
                if items[i].resumeItem == nil { items[i].resumeItem = q.resumeItem }
                if items[i].category == "other" { items[i].category = q.category }
                // A real interview outranks a mock or manual entry as the source.
                if source == .interview { items[i].source = .interview }
            } else {
                items.append(BankQuestion(question: q.question, category: q.category, resumeItem: q.resumeItem,
                                          followUps: followUps, applicationID: applicationID,
                                          company: company, role: role, source: source,
                                          firstAskedAt: date, lastAskedAt: date, mastery: mastery,
                                          myAnswer: q.answer, betterAnswer: q.critique?.betterAnswer ?? "",
                                          lastScore: score))
            }
        }
    }
}

extension Interview {
    /// How far around an interview a recording still counts as "that interview".
    static let matchMargin: TimeInterval = 30 * 60

    /// Interviews a recording starting at `date` could belong to: from 30 min before the start
    /// to 30 min after the planned end, closest start first.
    static func candidates(in interviews: [Interview], forRecordingAt date: Date) -> [Interview] {
        interviews
            .filter { date >= $0.start.addingTimeInterval(-matchMargin) && date <= $0.end.addingTimeInterval(matchMargin) }
            .sorted { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
}
