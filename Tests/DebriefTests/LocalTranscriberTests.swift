import Foundation
import Testing
@testable import Debrief

private typealias P = LocalTranscriber.Piece
private typealias S = LocalTranscriber.Sentence

@Suite("LocalTranscriber.sentences")
struct SentenceSplitTests {
    @Test func splitsAtSentenceEndsWithPieceTimes() {
        let pieces = [P(text: "我负责", start: 1.0, end: 1.6), P(text: "红包模块。", start: 1.6, end: 2.4),
                      P(text: "用 Redis", start: 3.0, end: 3.5), P(text: " 预扣库存？", start: 3.5, end: 4.2)]
        #expect(LocalTranscriber.sentences(from: pieces, fallback: (1, 4.2)) == [
            S(start: 1.0, end: 2.4, text: "我负责红包模块。"),
            S(start: 3.0, end: 4.2, text: "用 Redis 预扣库存？"),
        ])
    }

    @Test func trailingTextWithoutPunctuationIsKept() {
        let pieces = [P(text: "好的。", start: 0, end: 0.5), P(text: "那我们开始吧", start: 0.8, end: 1.9)]
        #expect(LocalTranscriber.sentences(from: pieces, fallback: (0, 1.9)).map(\.text) == ["好的。", "那我们开始吧"])
    }

    @Test func missingTimesFallBackToResultRange() {
        let pieces = [P(text: "嗯，", start: nil, end: nil), P(text: "可以。", start: nil, end: nil)]
        #expect(LocalTranscriber.sentences(from: pieces, fallback: (10, 12)) == [S(start: 10, end: 12, text: "嗯，可以。")])
    }

    @Test func longRunWithoutPunctuationIsCut() {
        let pieces = (0..<10).map { P(text: String(repeating: "字", count: 20), start: Double($0), end: Double($0) + 1) }
        let out = LocalTranscriber.sentences(from: pieces, fallback: (0, 10), maxLength: 60)
        #expect(out.count == 4)                       // 60 + 60 + 60 + 20 characters
        #expect(out.allSatisfy { $0.text.count <= 60 })
        #expect(out.first?.end == 3)
    }

    /// What the recognizer really returns: one character per piece, no punctuation, and a pause
    /// folded into the next character's range ("是" 3.90–4.56 after a pause at ~3.9–4.3).
    @Test func splitsAtSpeechSegmentsWhenUnpunctuated() {
        let pieces = [P(text: "张", start: 3.42, end: 3.66), P(text: "三", start: 3.66, end: 3.90),
                      P(text: "是", start: 3.90, end: 4.56), P(text: "硕", start: 4.56, end: 4.80),
                      P(text: "士", start: 4.80, end: 5.00)]
        let out = LocalTranscriber.sentences(from: pieces, fallback: (3.42, 5.0), segmentStarts: [0, 4.3])
        #expect(out == [S(start: 3.42, end: 3.90, text: "张三"), S(start: 4.3, end: 5.0, text: "是硕士")])
    }

    @Test func blankPiecesProduceNothing() {
        #expect(LocalTranscriber.sentences(from: [P(text: "  ", start: 0, end: 1)], fallback: (0, 1)).isEmpty)
    }

    @Test func oldSettingsWithoutLocalFlagDecode() throws {
        let json = #"{"accounts":[],"assignments":{}}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(settings.localTranscription == nil)
    }
}

/// Runs the real on-device recognizer (macOS 26+). Opt-in because it needs the language model
/// (downloaded on first run) and real audio:
///   DEBRIEF_LOCAL_ASR_AUDIO=/path/to/speech.m4a ./scripts/test.sh --filter LocalRecognition
@Suite("LocalRecognition", .enabled(if: ProcessInfo.processInfo.environment["DEBRIEF_LOCAL_ASR_AUDIO"] != nil))
struct LocalRecognitionTests {
    @Test func transcribesARecording() async throws {
        guard #available(macOS 26, *) else { return }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEBRIEF_LOCAL_ASR_AUDIO"]!)
        let record = RecordingRecord(fileURL: url, tracksFileURL: nil, startedAt: Date(), duration: 30, tracks: [])
        let (lines, locale) = try await LocalTranscriber.transcribe(record, terms: ["Redis", "Kafka"]) { _ in }
        for line in lines { print(String(format: "[%6.2f–%6.2f] %@", line.start, line.end, line.text)) }
        print("locale:", locale.identifier, "lines:", lines.count)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.speaker == .unknown && $0.end >= $0.start })
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}
