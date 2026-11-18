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
    /// Server errors and network failures: a few quick retries.
    static let maxAttempts = 3
    /// Rate limits (429) are per minute, so they get more and longer waits: 4, 8, 16, 32, 60 s.
    static let rateLimitAttempts = 6

    private struct Job: Sendable {
        let key: String
        let speaker: Utterance.Speaker
        let start: Double
        let end: Double
        let wav: Data
    }

    /// Identifies a speech segment across runs (same audio → same segments), for resuming.
    static func segmentKey(_ speaker: Utterance.Speaker, start: Double) -> String {
        "\(speaker.rawValue)@\(Int((start * 1000).rounded()))"
    }

    /// After a rate limit, the rest of the run sends one request at a time.
    private actor Throttle {
        private(set) var limit: Int
        init(_ limit: Int) { self.limit = limit }
        func rateLimited() { limit = 1 }
    }

    /// `cached`: segment results from an earlier, interrupted run (segmentKey → text; "" for
    /// silence), used instead of sending those segments again. `onSegment` gets each new result
    /// as it arrives, so the caller can save it. `progress(done, total)` as segments finish.
    func transcribe(_ record: RecordingRecord, cached: [String: String] = [:],
                    onSegment: @escaping @Sendable (String, String) -> Void = { _, _ in },
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Utterance] {
        let (file, speakers) = try await Self.sources(for: record)
        var jobs: [Job] = []
        for (index, speaker) in speakers.enumerated() {
            let track = try await SpeechSegmenter.readTrack(url: file, index: index)
            for seg in SpeechSegmenter.segments(track.samples) {
                let start = track.startOffset + seg.start
                jobs.append(Job(key: Self.segmentKey(speaker, start: start), speaker: speaker, start: start,
                                end: track.startOffset + seg.end, wav: SpeechSegmenter.wav(track.samples, seg)))
            }
            try Task.checkCancellation()
        }
        guard !jobs.isEmpty else { return [] }

        func utterance(_ job: Job, _ text: String) -> Utterance? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Utterance(speaker: job.speaker, start: job.start, end: job.end, text: trimmed)
        }
        var results: [Utterance] = jobs.compactMap { job in cached[job.key].flatMap { utterance(job, $0) } }
        let pending = jobs.filter { cached[$0.key] == nil }
        var done = jobs.count - pending.count
        progress(done, jobs.count)

        let client = client, model = model, context = context
        let throttle = Throttle(Self.concurrency)
        try await withThrowingTaskGroup(of: Utterance?.self) { group in
            var next = 0, inFlight = 0
            func addNext() {
                guard next < pending.count else { return }
                let job = pending[next]
                next += 1
                inFlight += 1
                group.addTask {
                    let text = try await Self.withRetry(onRateLimit: { await throttle.rateLimited() }) {
                        try await client.transcribe(wav: job.wav, model: model, context: context)
                    }
                    onSegment(job.key, text)
                    return utterance(job, text)
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let result = try await group.next() {
                inFlight -= 1
                if let result { results.append(result) }
                done += 1
                progress(done, jobs.count)
                let limit = await throttle.limit
                while inFlight < limit && next < pending.count { addNext() }
            }
        }
        return Self.removeEcho(results).sorted { $0.start < $1.start }
    }

    /// Seconds to wait before attempt `attempt + 1`. Rate limits: the server's Retry-After if it
    /// sent one (capped at 2 minutes), else 4, 8, 16, 32, 60 s. Other errors: 2, 8 s.
    static func retryDelay(attempt: Int, error: AIError) -> Double {
        if error.isRateLimit {
            if let after = error.retryAfter, after > 0 { return min(after, 120) }
            return min(60, 4 * pow(2, Double(attempt - 1)))
        }
        return Double(attempt * attempt) * 2
    }

    /// Retries retryable AIErrors (see retryDelay). `onRateLimit` is told about each 429 so the
    /// caller can slow down; `delay` is replaceable for tests.
    static func withRetry<T: Sendable>(onRateLimit: (@Sendable () async -> Void)? = nil,
                                       delay: @Sendable (Int, AIError) -> Double = { retryDelay(attempt: $0, error: $1) },
                                       _ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await work()
            } catch let error as AIError where error.retryable
                        && attempt < (error.isRateLimit ? rateLimitAttempts : maxAttempts) {
                if error.isRateLimit { await onRateLimit?() }
                // ±20% jitter so parallel requests don't all retry at the same moment.
                let wait = delay(attempt, error) * Double.random(in: 0.8...1.2)
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    /// The file to read and the speaker of each of its audio tracks. Prefers the per-speaker
    /// track file (system = interviewer, mic = me); falls back to the mixed .m4a (speaker unknown).
    static func sources(for record: RecordingRecord) async throws -> (URL, [Utterance.Speaker]) {
        let tracksFile = record.tracksFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let file = tracksFile ?? record.fileURL
        let count = try await SpeechSegmenter.audioTrackCount(url: file)
        let speakers = (0..<count).map { index -> Utterance.Speaker in
            guard tracksFile != nil, record.tracks.indices.contains(index) else { return .unknown }
            return record.tracks[index] == .system ? .interviewer : .me
        }
        return (file, speakers)
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
        let terms = terms(jd: jd, resume: resume)
        var parts: [String] = []
        if !company.isEmpty || !role.isEmpty { parts.append("面试：\(company) \(role)") }
        if !terms.isEmpty { parts.append("术语：" + terms.joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }

    /// Latin-script technical terms in the JD and resume, most frequent first (at most 80).
    static func terms(jd: String, resume: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+#./-]{1,30}")
        let text = jd + "\n" + resume
        var counts: [String: Int] = [:]
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { counts[String(text[r]), default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(80).map(\.key)
    }
}
