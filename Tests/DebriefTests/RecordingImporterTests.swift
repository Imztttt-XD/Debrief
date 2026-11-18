import AVFoundation
import Foundation
import Testing
@testable import Debrief

@Suite("RecordingImporter")
struct RecordingImporterTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1 s of tone as a WAV file.
    private func wav(in dir: URL, name: String = "phone recording.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ConnectionCheck.testTone().write(to: url)
        return url
    }

    private func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    @Test func convertsToM4AInTheRecordingsFolderAndLeavesTheOriginal() async throws {
        let dir = try scratch(), folder = dir.appendingPathComponent("Recordings")
        let source = try wav(in: dir)
        let created = try #require(try source.resourceValues(forKeys: [.creationDateKey]).creationDate)

        let record = try await RecordingImporter.importFile(source, into: folder)

        #expect(record.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(record.fileURL.lastPathComponent == "Imported-phone recording.m4a")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(abs(record.duration - 1) < 0.1)
        #expect(abs(try await duration(record.fileURL) - 1) < 0.15)   // a real, playable M4A
        #expect(record.startedAt == created)
        #expect(record.tracksFileURL == nil && record.tracks.isEmpty)     // speakers unknown
    }

    @Test func m4aIsCopiedAndNamesDontCollide() async throws {
        let dir = try scratch(), folder = dir.appendingPathComponent("Recordings")
        let first = try await RecordingImporter.importFile(try wav(in: dir, name: "a.wav"), into: dir)
        let m4a = dir.appendingPathComponent("a.m4a")
        try FileManager.default.moveItem(at: first.fileURL, to: m4a)

        let one = try await RecordingImporter.importFile(m4a, into: folder)
        let two = try await RecordingImporter.importFile(m4a, into: folder)

        #expect(one.fileURL.lastPathComponent == "Imported-a.m4a")
        #expect(two.fileURL.lastPathComponent == "Imported-a 2.m4a")
        #expect(try Data(contentsOf: one.fileURL) == Data(contentsOf: m4a))   // copied as is
    }

    @Test func mp4AudioIsConverted() async throws {
        let dir = try scratch()
        let source = try wav(in: dir, name: "meeting.wav")
        let mp4 = dir.appendingPathComponent("meeting.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "mp4f", "-d", "aac", source.path, mp4.path]
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)

        let record = try await RecordingImporter.importFile(mp4, into: dir.appendingPathComponent("Recordings"))
        #expect(record.fileURL.pathExtension == "m4a")
        #expect(abs(try await duration(record.fileURL) - 1) < 0.15)
    }

    @Test func fileWithoutAudioIsRejected() async throws {
        let dir = try scratch()
        let text = dir.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: text)
        await #expect(throws: (any Error).self) {
            _ = try await RecordingImporter.importFile(text, into: dir.appendingPathComponent("Recordings"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Recordings/Imported-notes.m4a").path))
    }
}
