import Foundation
import Testing
@testable import Debrief

/// AppStore reads and writes AppPaths.root, which is resolved once from DEBRIEF_DATA_DIR. These
/// tests point it at a scratch folder and refuse to run if that didn't take, so real data is
/// never touched. Files moved to the Trash are deleted from it at the end of each test.
@Suite("Deleting recordings and reviews", .serialized)
@MainActor
struct RecordingDeletionTests {
    static let dataDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("DEBRIEF_DATA_DIR", dir.path, 1)
        return dir
    }()

    private func makeStore() throws -> AppStore {
        let dir = Self.dataDir
        try #require(AppPaths.root.standardizedFileURL.path == dir.standardizedFileURL.path,
                     "AppPaths.root isn't the scratch folder; not creating an AppStore")
        return AppStore()
    }

    private func file(_ name: String) throws -> URL {
        let url = Self.dataDir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("test".utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func reviewFile(_ id: UUID) -> URL { AppPaths.reviews.appendingPathComponent("\(id.uuidString).json") }

    @Test func deleteRecordingTrashesAudioAndRemovesReview() throws {
        let store = try makeStore()
        let audio = try file("Interview.m4a"), tracks = try file("Interview.tracks.mov")
        let record = RecordingRecord(fileURL: audio, tracksFileURL: tracks, startedAt: Date(), duration: 60,
                                     tracks: [.system, .microphone])
        store.add(record)
        store.updateReview(record.id) { $0.transcript = [Utterance(speaker: .me, start: 0, end: 1, text: "你好")] }
        store.flush()
        #expect(exists(reviewFile(record.id)))

        let trashed = try store.deleteRecording(record.id)
        defer { trashed.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(trashed.count == 2)
        #expect(trashed.allSatisfy(exists))           // recoverable from the Trash
        #expect(!exists(audio) && !exists(tracks))
        #expect(!store.recordings.contains { $0.id == record.id })
        #expect(store.review(for: record.id) == nil)
        #expect(!exists(reviewFile(record.id)))
    }

    @Test func filesAlreadyGoneAreSkipped() throws {
        let store = try makeStore()
        let missing = Self.dataDir.appendingPathComponent("\(UUID().uuidString).m4a")
        let record = RecordingRecord(fileURL: missing, tracksFileURL: nil, startedAt: Date(), duration: 5, tracks: [])
        store.add(record)
        let trashed = try store.deleteRecording(record.id)
        #expect(trashed.isEmpty)
        #expect(!store.recordings.contains { $0.id == record.id })
    }

    @Test func deleteReviewKeepsRecordingButTakesItsQuestionsOutOfTheBank() throws {
        let store = try makeStore()
        store.bank = QuestionBank()
        let audio = try file("Interview.m4a")
        let record = RecordingRecord(fileURL: audio, tracksFileURL: nil, startedAt: Date(), duration: 5, tracks: [])
        store.add(record)
        let question = ReviewQuestion(question: "Redis 的持久化机制有哪些？", category: "fundamentals", resumeItem: nil,
                                      start: nil, answer: "RDB 和 AOF", answerStart: nil, followUps: [], critique: nil)
        store.updateReview(record.id) {
            $0.transcript = [Utterance(speaker: .me, start: 0, end: 1, text: "你好")]
            $0.questions = [question]
        }
        // As ingestReview does once a review is analyzed.
        store.ingest([question], source: .interview, applicationID: nil, at: record.startedAt, sourceID: record.id)
        store.bank.ingestedReviews.append(record.id)
        store.flush()

        store.deleteReview(record.id)

        #expect(store.review(for: record.id) == nil)
        #expect(!exists(reviewFile(record.id)))
        #expect(exists(audio))
        #expect(store.recordings.contains { $0.id == record.id })
        #expect(store.bank.items.isEmpty)
        // Reviewing it again later adds the questions again.
        #expect(!store.bank.ingestedReviews.contains(record.id))
    }
}
