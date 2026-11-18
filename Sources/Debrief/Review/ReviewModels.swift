import Foundation

/// One transcribed utterance. Times are seconds on the recording's timeline.
struct Utterance: Codable, Identifiable, Hashable {
    enum Speaker: String, Codable, CaseIterable, Identifiable {
        case interviewer, me, unknown
        var id: String { rawValue }
        var title: String { L10n.tr("speaker.\(rawValue)") }
    }

    var id = UUID()
    var speaker: Speaker
    var start: Double
    var end: Double
    var text: String
}

/// A main interview question with its follow-ups, the candidate's answer, and the critique.
struct ReviewQuestion: Codable, Identifiable, Hashable {
    struct FollowUp: Codable, Hashable, Identifiable {
        var id = UUID()
        var question: String
        var answer: String
        var start: Double?
    }

    var id = UUID()
    var question: String
    /// project / internship / fundamentals / algorithm / behavioral / hr / other
    var category: String
    var resumeItem: String?
    /// When the question was asked (for click-to-play).
    var start: Double?
    var answer: String
    var answerStart: Double?
    var followUps: [FollowUp]
    var critique: Critique?

    static let categories = ["project", "internship", "fundamentals", "algorithm", "behavioral", "hr", "other"]
    var categoryTitle: String {
        L10n.tr("review.category.\(Self.categories.contains(category) ? category : "other")")
    }
}

struct Critique: Codable, Hashable {
    struct Correction: Codable, Hashable, Identifiable {
        var id = UUID()
        var claim: String
        var issue: String
        var correct: String
        /// The user marked this as "I think I was right".
        var disputed = false
    }

    /// 1–5 each.
    var accuracy: Int
    var structure: Int
    var depth: Int
    var corrections: [Correction]
    var strengths: [String]
    var improvements: [String]
    var betterAnswer: String
}

struct ReviewSummary: Codable, Hashable {
    var overall: String
    var strengths: [String]
    var improvements: [String]
    var actionItems: [String]
    var interviewerStyle: String
}

/// Everything derived from one recording. Saved as reviews/<recordingID>.json.
struct Review: Codable, Identifiable, Hashable {
    var id: UUID { recordingID }
    var recordingID: UUID
    var createdAt = Date()
    var updatedAt = Date()

    var transcript: [Utterance] = []
    var transcriptModel: String?
    /// Speakers were told apart automatically (SpeakerSeparation) and may be wrong; the review
    /// page says so and offers to swap 面试官 / 我. Optional so older review files decode.
    var speakersEstimated: Bool?
    /// Cloud transcription results saved segment by segment (Transcriber.segmentKey → text), so an
    /// interrupted run (e.g. rate limited) resumes instead of paying for the same segments again.
    /// Cleared once the transcript is complete. Optional so older review files decode.
    var transcriptCache: [String: String]?
    /// True after the user edits the transcript, until the next analysis.
    var transcriptEdited = false

    var questions: [ReviewQuestion] = []
    var summary: ReviewSummary?
    var analysisModel: String?

    /// The user's own notes: how it felt, the outcome.
    var myNotes = ""
    /// Last failure, shown on the review page; cleared by the next successful step.
    var lastError: String?

    var isTranscribed: Bool { !transcript.isEmpty }
    var isAnalyzed: Bool { summary != nil }
}
