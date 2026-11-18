import Foundation
import Testing
@testable import Debrief

private let base = Date(timeIntervalSince1970: 1_700_000_000)
private func at(minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

private func interview(startMinutes: Double, duration: Int = 60) -> Interview {
    Interview(applicationID: UUID(), start: at(minutes: startMinutes), durationMinutes: duration)
}

/// Rule: a recording belongs to an interview if it starts between 30 min before the interview's
/// start and 30 min after its planned end; the closest start wins.
@Suite("Interview.candidates")
struct InterviewMatchingTests {
    @Test func noInterviewsNoMatch() {
        #expect(Interview.candidates(in: [], forRecordingAt: base).isEmpty)
    }

    @Test(arguments: [
        (-30.0, true),  // exactly 30 min early: included
        (-31.0, false),
        (0.0, true),
        (59.0, true),   // during the interview
        (90.0, true),   // 60 min interview + 30 min margin: included
        (91.0, false),
    ])
    func windowBoundaries(_ recordingMinutes: Double, _ matches: Bool) {
        let iv = interview(startMinutes: 0)
        let result = Interview.candidates(in: [iv], forRecordingAt: at(minutes: recordingMinutes))
        #expect(result.map(\.id) == (matches ? [iv.id] : []))
    }

    @Test func longerInterviewHasLongerWindow() {
        let iv = interview(startMinutes: 0, duration: 120)
        #expect(Interview.candidates(in: [iv], forRecordingAt: at(minutes: 150)).count == 1)
        #expect(Interview.candidates(in: [iv], forRecordingAt: at(minutes: 151)).isEmpty)
    }

    @Test func closestStartComesFirst() {
        // Back-to-back rounds: a recording started at 10:55 belongs to the 11:00 round,
        // even though it's still inside the 10:00 round's window.
        let first = interview(startMinutes: 0)
        let second = interview(startMinutes: 60)
        let result = Interview.candidates(in: [first, second], forRecordingAt: at(minutes: 55))
        #expect(result.map(\.id) == [second.id, first.id])
    }
}
