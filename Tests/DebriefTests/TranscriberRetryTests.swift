import Foundation
import RecorderCore
import Testing
@testable import Debrief

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("Transcriber retries and resume")
struct TranscriberRetryTests {
    private let rateLimit = AIError.http(429, "slow down")

    @Test func rateLimitWaitsGrowAndHonourRetryAfter() {
        #expect((1...5).map { Transcriber.retryDelay(attempt: $0, error: rateLimit) } == [4, 8, 16, 32, 60])
        #expect(Transcriber.retryDelay(attempt: 1, error: .http(429, "", retryAfter: 30)) == 30)
        #expect(Transcriber.retryDelay(attempt: 1, error: .http(429, "", retryAfter: 900)) == 120)   // capped
        #expect(Transcriber.retryDelay(attempt: 2, error: .http(503, "")) == 8)
    }

    @Test func rateLimitsRetrySixTimesAndSlowDown() async {
        let calls = Counter(), slowDowns = Counter()
        let error = rateLimit
        await #expect(throws: AIError.self) {
            _ = try await Transcriber.withRetry(onRateLimit: { slowDowns.bump() }, delay: { _, _ in 0 }) {
                calls.bump(); throw error
            } as String
        }
        #expect(calls.value == Transcriber.rateLimitAttempts)
        #expect(slowDowns.value == Transcriber.rateLimitAttempts - 1)
    }

    @Test func serverErrorsRetryThreeTimesAndBadKeysNotAtAll() async {
        let five = Counter(), four = Counter()
        await #expect(throws: AIError.self) {
            _ = try await Transcriber.withRetry(delay: { _, _ in 0 }) { five.bump(); throw AIError.http(503, "") } as String
        }
        await #expect(throws: AIError.self) {
            _ = try await Transcriber.withRetry(delay: { _, _ in 0 }) { four.bump(); throw AIError.http(401, "bad key") } as String
        }
        #expect(five.value == Transcriber.maxAttempts)
        #expect(four.value == 1)
    }

    @Test func succeedsOnceTheLimitLifts() async throws {
        let calls = Counter()
        let error = rateLimit
        let text = try await Transcriber.withRetry(delay: { _, _ in 0 }) {
            calls.bump()
            if calls.value < 3 { throw error }
            return "ok"
        }
        #expect(text == "ok" && calls.value == 3)
    }

    @Test func readsRetryAfterHeader() {
        let r = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil,
                                headerFields: ["Retry-After": "17"])!
        #expect(AIError.retryAfter(r) == 17)
    }

    /// Everything already transcribed: nothing is sent (the client points nowhere, so any request
    /// would fail), and the cached text comes back as the transcript.
    @Test func resumesFromCachedSegmentsWithoutCallingTheService() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("tone.wav")
        try ConnectionCheck.testTone().write(to: wav)
        let track = try await SpeechSegmenter.readTrack(url: wav, index: 0)
        let keys = SpeechSegmenter.segments(track.samples).map { Transcriber.segmentKey(.unknown, start: track.startOffset + $0.start) }
        try #require(!keys.isEmpty)
        let cached = Dictionary(uniqueKeysWithValues: keys.map { ($0, "已转写") })

        let client = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:9/v1")!, apiKey: "none")
        let record = RecordingRecord(fileURL: wav, tracksFileURL: nil, startedAt: Date(), duration: 1, tracks: [])
        let sent = Counter()
        let lines = try await Transcriber(client: client, model: "m", context: "")
            .transcribe(record, cached: cached, onSegment: { _, _ in sent.bump() }) { _, _ in }
        #expect(lines.map(\.text) == Array(repeating: "已转写", count: keys.count))
        #expect(sent.value == 0)
    }

    @Test func oldReviewsWithoutTheCacheDecode() throws {
        let json = #"{"recordingID":"\#(UUID().uuidString)","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","transcript":[],"transcriptEdited":false,"questions":[],"myNotes":""}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Review.self, from: Data(json.utf8)).transcriptCache == nil)
    }
}
