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
    /// `company` / `role` are only used for new entries. `sourceID` (the review's recording ID or
    /// the mock session ID) is remembered so `removeContributions` can undo it.
    mutating func merge(_ questions: [ReviewQuestion], source: BankQuestion.Source, applicationID: UUID?,
                        company: String, role: String, at date: Date, sourceID: UUID? = nil) {
        let kind: PracticeAttempt.Kind = switch source {
        case .interview: .interview
        case .mock: .mock
        case .manual: .practice
        }
        for q in questions where !q.question.trimmingCharacters(in: .whitespaces).isEmpty {
            let followUps = q.followUps.map(\.question)
            if let i = items.firstIndex(where: { Transcriber.similarity($0.question, q.question) >= Self.sameQuestionThreshold }) {
                items[i].timesAsked += 1
                items[i].lastAskedAt = max(items[i].lastAskedAt, date)
                if let sourceID { items[i].sources = (items[i].sources ?? []) + [sourceID] }
                for f in followUps where !items[i].followUps.contains(where: { Transcriber.similarity($0, f) >= Self.sameQuestionThreshold }) {
                    items[i].followUps.append(f)
                }
                if !q.answer.isEmpty { items[i].myAnswer = q.answer }
                if let c = q.critique, !c.betterAnswer.isEmpty { items[i].betterAnswer = c.betterAnswer }
                // Score, mastery and the next review date come from the attempt history.
                if let c = q.critique { items[i].record(c, kind: kind, at: date, sourceID: sourceID) }
                if items[i].resumeItem == nil { items[i].resumeItem = q.resumeItem }
                if items[i].category == "other" { items[i].category = q.category }
                // A real interview outranks a mock or manual entry as the source.
                if source == .interview { items[i].source = .interview }
            } else {
                var item = BankQuestion(question: q.question, category: q.category, resumeItem: q.resumeItem,
                                        followUps: followUps, applicationID: applicationID,
                                        company: company, role: role, source: source,
                                        firstAskedAt: date, lastAskedAt: date, mastery: .new,
                                        myAnswer: q.answer, betterAnswer: q.critique?.betterAnswer ?? "",
                                        sources: sourceID.map { [$0] })
                if let c = q.critique { item.record(c, kind: kind, at: date, sourceID: sourceID) }
                items.append(item)
            }
        }
    }
}

extension QuestionBank {
    /// Undoes what one review or mock session added (when it's deleted): each question it added
    /// is asked one time fewer and loses that answer from its history; a question nothing else
    /// asked (times asked reaches 0) is removed. Questions added by hand always stay.
    ///
    /// Entries from before sources were tracked are matched by question text (`questions` are
    /// the deleted review's questions) and their answers by kind + date.
    mutating func removeContributions(of sourceID: UUID, questions: [ReviewQuestion],
                                      kind: PracticeAttempt.Kind, date: Date, calendar: Calendar = .current) {
        var touched = Set<UUID>()
        for i in items.indices {
            // A review can add to the same entry more than once (the question asked twice).
            guard let sources = items[i].sources, case let n = sources.filter({ $0 == sourceID }).count, n > 0 else { continue }
            items[i].sources = sources.filter { $0 != sourceID }
            items[i].timesAsked -= n
            items[i].attempts = items[i].history.filter { $0.sourceID != sourceID }
            touched.insert(items[i].id)
        }
        for q in questions where !q.question.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let i = items.firstIndex(where: {
                $0.sources == nil && !touched.contains($0.id)
                    && Transcriber.similarity($0.question, q.question) >= Self.sameQuestionThreshold
            }) else { continue }
            items[i].timesAsked -= 1
            var history = items[i].history
            if let k = history.firstIndex(where: { $0.sourceID == nil && $0.kind == kind && $0.date == date }) {
                history.remove(at: k)
            }
            items[i].attempts = history
            touched.insert(items[i].id)
        }
        items.removeAll { touched.contains($0.id) && $0.timesAsked <= 0 && $0.source != .manual }
        for i in items.indices where touched.contains(items[i].id) {
            items[i].timesAsked = max(1, items[i].timesAsked)
            items[i].rebuildFromHistory(calendar: calendar)
        }
    }
}

extension Interview {
    /// How far around an interview a recording still counts as "that interview".
    static let matchMargin: TimeInterval = 30 * 60

    /// How many interviews on `day` are still to come and how many have ended (by planned end),
    /// for the calendar's markers.
    struct DayMarks: Equatable {
        var upcoming = 0
        var ended = 0
        var total: Int { upcoming + ended }
    }

    static func marks(_ interviews: [Interview], on day: Date, now: Date, calendar: Calendar = .current) -> DayMarks {
        var m = DayMarks()
        for iv in interviews where calendar.isDate(iv.start, inSameDayAs: day) {
            if iv.end <= now { m.ended += 1 } else { m.upcoming += 1 }
        }
        return m
    }

    /// Interviews a recording starting at `date` could belong to: from 30 min before the start
    /// to 30 min after the planned end, closest start first.
    static func candidates(in interviews: [Interview], forRecordingAt date: Date) -> [Interview] {
        interviews
            .filter { date >= $0.start.addingTimeInterval(-matchMargin) && date <= $0.end.addingTimeInterval(matchMargin) }
            .sorted { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
}
