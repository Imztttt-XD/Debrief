import Foundation
import RecorderCore

/// Recording → speaker-labelled, time-stamped transcript.
///
/// Each track of the `.tracks.mov` is one speaker (system = interviewer, mic = me). Tracks are
/// split into speech segments, each segment is sent to the ASR model on its own (≤ 4 at a
/// time, retried on rate limits / server errors), and the results are merged by start time.
struct Transcriber {
    let client: OpenAICompatibleClient
    let model: String
    /// Background text for the recognizer: company, role and technical terms from the JD/resume.
    let context: String

    static let concurrency = 4
    static let maxAttempts = 3

    private struct Job: Sendable {
        let speaker: Utterance.Speaker
        let start: Double
        let end: Double
        let wav: Data
    }

    /// `progress(done, total)` is called as segments finish.
    func transcribe(_ record: RecordingRecord,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Utterance] {
        // Prefer the per-speaker track file; fall back to the mixed .m4a (speaker unknown).
        let tracksFile = record.tracksFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let file = tracksFile ?? record.fileURL
        let usingTracks = tracksFile != nil
        let trackCount = try await SpeechSegmenter.audioTrackCount(url: file)

        var jobs: [Job] = []
        for index in 0..<trackCount {
            let speaker: Utterance.Speaker
            if usingTracks, record.tracks.indices.contains(index) {
                speaker = record.tracks[index] == .system ? .interviewer : .me
            } else {
                speaker = .unknown
            }
            let track = try await SpeechSegmenter.readTrack(url: file, index: index)
            for seg in SpeechSegmenter.segments(track.samples) {
                jobs.append(Job(speaker: speaker, start: track.startOffset + seg.start,
                                end: track.startOffset + seg.end, wav: SpeechSegmenter.wav(track.samples, seg)))
            }
            try Task.checkCancellation()
        }
        guard !jobs.isEmpty else { return [] }
        progress(0, jobs.count)

        let client = client, model = model, context = context
        var results: [Utterance] = []
        var done = 0
        try await withThrowingTaskGroup(of: Utterance?.self) { group in
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    let text = try await Self.withRetry {
                        try await client.transcribe(wav: job.wav, model: model, context: context)
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : Utterance(speaker: job.speaker, start: job.start, end: job.end, text: trimmed)
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let result = try await group.next() {
                if let result { results.append(result) }
                done += 1
                progress(done, jobs.count)
                addNext()
            }
        }
        return Self.removeEcho(results).sorted { $0.start < $1.start }
    }

    static func withRetry<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await work()
            } catch let error as AIError where error.retryable && attempt < maxAttempts {
                try await Task.sleep(for: .seconds(Double(attempt * attempt) * 2))   // 2 s, 8 s
                attempt += 1
            }
        }
    }

    /// Without headphones the mic also picks up the interviewer from the speakers, so the same
    /// sentence shows up on both tracks. Drop "me" lines that overlap an interviewer line in
    /// time and say nearly the same thing.
    static func removeEcho(_ utterances: [Utterance]) -> [Utterance] {
        let interviewer = utterances.filter { $0.speaker == .interviewer }
        return utterances.filter { u in
            guard u.speaker == .me else { return true }
            return !interviewer.contains { s in
                let overlap = min(u.end, s.end) - max(u.start, s.start)
                return overlap > 0.5 * (u.end - u.start) && similarity(u.text, s.text) > 0.6
            }
        }
    }

    /// Character-bigram Jaccard similarity, ignoring spaces and punctuation.
    static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
            guard chars.count > 1 else { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let x = bigrams(a), y = bigrams(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Context for the recognizer: who/what the interview is about plus technical terms
    /// (Latin-script words like Redis, Kafka, B+Tree) found in the JD and resume, most frequent first.
    static func context(company: String, role: String, jd: String, resume: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+#./-]{1,30}")
        let text = jd + "\n" + resume
        var counts: [String: Int] = [:]
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { counts[String(text[r]), default: 0] += 1 }
        }
        let terms = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(80).map(\.key)
        var parts: [String] = []
        if !company.isEmpty || !role.isEmpty { parts.append("面试：\(company) \(role)") }
        if !terms.isEmpty { parts.append("术语：" + terms.joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }
}
