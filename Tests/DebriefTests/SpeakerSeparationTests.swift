import Foundation
import RecorderCore
import Testing
@testable import Debrief

private func line(_ start: Double, _ end: Double, _ text: String = "…") -> Utterance {
    Utterance(speaker: .unknown, start: start, end: end, text: text)
}
private typealias T = SpeakerSeparation.Turn

@Suite("SpeakerSeparation.assign")
struct SpeakerAssignTests {
    @Test func whoeverTalksMostIsMe() {
        // Voice 7 asks short questions, voice 3 gives long answers.
        let turns = [T(start: 0, end: 3, speaker: 7), T(start: 3.5, end: 15, speaker: 3),
                     T(start: 16, end: 18, speaker: 7), T(start: 18.5, end: 30, speaker: 3)]
        let out = SpeakerSeparation.assign([line(0, 3), line(3.6, 14), line(16, 18), line(19, 29)], turns: turns)
        #expect(out.map(\.speaker) == [.interviewer, .me, .interviewer, .me])
    }

    @Test func lineGoesToTheVoiceItOverlapsMost() {
        let turns = [T(start: 0, end: 10, speaker: 0), T(start: 10, end: 11, speaker: 1), T(start: 11, end: 30, speaker: 1)]
        // 8–12 overlaps voice 0 for 2 s and voice 1 for 2 s… then 8–13: voice 1 wins with 3 s.
        #expect(SpeakerSeparation.assign([line(8, 13)], turns: turns)[0].speaker == .me)
        #expect(SpeakerSeparation.assign([line(2, 9)], turns: turns)[0].speaker == .interviewer)
    }

    @Test func lineInAGapTakesTheNearestTurn() {
        let turns = [T(start: 0, end: 5, speaker: 0), T(start: 20, end: 40, speaker: 1)]
        let out = SpeakerSeparation.assign([line(6, 7), line(18, 19)], turns: turns)
        #expect(out.map(\.speaker) == [.interviewer, .me])
    }

    @Test func oneVoiceLeavesLinesUnknown() {
        let turns = [T(start: 0, end: 5, speaker: 0), T(start: 6, end: 9, speaker: 0)]
        let lines = [line(0, 5), line(6, 9)]
        #expect(SpeakerSeparation.assign(lines, turns: turns) == lines)
        #expect(SpeakerSeparation.assign(lines, turns: []) == lines)
    }

    @Test func panelInterviewersAllMapToInterviewer() {
        let turns = [T(start: 0, end: 2, speaker: 0), T(start: 2, end: 20, speaker: 1), T(start: 20, end: 23, speaker: 2)]
        let out = SpeakerSeparation.assign([line(0, 2), line(3, 19), line(20, 23)], turns: turns)
        #expect(out.map(\.speaker) == [.interviewer, .me, .interviewer])
    }

    @Test func tinyClustersAreIgnored() {
        // Two real voices plus a 1-second blip (2%): the blip doesn't become a third speaker,
        // and a line inside it goes to the nearest real voice.
        let turns = [T(start: 0, end: 10, speaker: 0), T(start: 10, end: 11, speaker: 9), T(start: 12, end: 50, speaker: 1)]
        let out = SpeakerSeparation.assign([line(10, 11), line(13, 40)], turns: turns)
        #expect(out.map(\.speaker) == [.interviewer, .me])
        #expect(SpeakerSeparation.majorVoices(turns).voices == [1, 0])
    }

    @Test func fragmentedResultsTryTheNextThreshold() {
        // Like the real phone recording at threshold 0.5: many small clusters, top voices < 90%.
        var fragmented: [T] = []
        for i in 0..<30 { fragmented.append(T(start: Double(i * 10), end: Double(i * 10 + 4), speaker: i % 15)) }
        let settled = [T(start: 0, end: 60, speaker: 0), T(start: 60, end: 80, speaker: 1), T(start: 80, end: 81, speaker: 2)]
        #expect(!SpeakerSeparation.isSettled(fragmented))
        #expect(SpeakerSeparation.isSettled(settled))
        #expect(SpeakerSeparation.choose([fragmented, settled]) == settled)
        // Nothing settles: two clear voices plus 12 one-second blips (13% of speech, so coverage
        // < 90%) still beat 15 equal "voices", which is fragmentation rather than a crowd.
        let twoPlusBlips = [T(start: 0, end: 60, speaker: 0), T(start: 60, end: 80, speaker: 1)]
            + (0..<12).map { T(start: 100 + Double($0) * 2, end: 101 + Double($0) * 2, speaker: 10 + $0) }
        #expect(!SpeakerSeparation.isSettled(twoPlusBlips))
        #expect(SpeakerSeparation.choose([fragmented, twoPlusBlips]) == twoPlusBlips)
    }

    @Test func swapFlipsOnlyKnownSpeakers() {
        var lines = [line(0, 1), line(1, 2), line(2, 3)]
        lines[0].speaker = .interviewer; lines[1].speaker = .me
        #expect(SpeakerSeparation.swapped(lines).map(\.speaker) == [.me, .interviewer, .unknown])
    }

    @Test func oldReviewsWithoutTheFlagDecode() throws {
        let id = UUID()
        let json = #"{"recordingID":"\#(id.uuidString)","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","transcript":[],"transcriptEdited":false,"questions":[],"myNotes":""}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Review.self, from: Data(json.utf8)).speakersEstimated == nil)
    }
}

/// The real library and models on a two-speaker recording. Opt-in:
///   DEBRIEF_SHERPA_LIB_DIR=Vendor/sherpa-onnx/lib DEBRIEF_SHERPA_MODELS=<dir with segmentation.onnx, embedding.onnx> \
///   DEBRIEF_DIARIZATION_AUDIO=<dialog.wav> DEBRIEF_DIARIZATION_TRUTH=<truth.json> ./scripts/test.sh --filter Diarization
@Suite("Diarization", .enabled(if: ProcessInfo.processInfo.environment["DEBRIEF_DIARIZATION_AUDIO"] != nil))
struct DiarizationIntegrationTests {
    struct Truth: Decodable { let speaker: String; let start: Double; let end: Double }

    /// Without DEBRIEF_DIARIZATION_TRUTH it only prints the voices found (for real recordings).
    @Test func labelsATwoSpeakerDialog() async throws {
        let env = ProcessInfo.processInfo.environment
        #expect(SpeakerSeparation.isReady, "library or models not found")
        let audio = URL(fileURLWithPath: env["DEBRIEF_DIARIZATION_AUDIO"]!)
        let track = try await SpeechSegmenter.readTrack(url: audio, index: 0)
        let start = Date()
        let turns = try await SpeakerSeparation.diarize(track)
        let (voices, coverage) = SpeakerSeparation.majorVoices(turns)
        var total: [Int: Double] = [:]
        for t in turns { total[t.speaker, default: 0] += t.end - t.start }
        print(String(format: "diarized in %.0f s: %d major voices covering %.0f%%: ", Date().timeIntervalSince(start), voices.count, coverage * 100)
              + voices.map { String(format: "%.1f min", (total[$0] ?? 0) / 60) }.joined(separator: ", "))
        guard let truthPath = env["DEBRIEF_DIARIZATION_TRUTH"] else { return }
        let truth = try JSONDecoder().decode([Truth].self, from: Data(contentsOf: URL(fileURLWithPath: truthPath)))
        #expect(voices.count == 2)
        // The dialog's lines, unlabeled, as a single-track transcript would be.
        let lines = truth.map { line($0.start, $0.end) }
        let labeled = SpeakerSeparation.assign(lines, turns: turns)
        // In the test dialog A asks (interviewer) and B answers at length (me).
        #expect(labeled.map(\.speaker) == truth.map { $0.speaker == "A" ? .interviewer : .me })
    }
}

/// Real model download into a scratch folder (≈ 33 MB). Opt-in:
///   DEBRIEF_TEST_MODEL_DOWNLOAD=1 DEBRIEF_SHERPA_MODELS=<empty dir> ./scripts/test.sh --filter ModelDownload
@Suite("ModelDownload", .enabled(if: ProcessInfo.processInfo.environment["DEBRIEF_TEST_MODEL_DOWNLOAD"] == "1"))
@MainActor
struct ModelDownloadTests {
    @Test(.timeLimit(.minutes(15))) func downloadsAndVerifiesBothModels() async throws {
        let downloader = SpeakerModelDownloader()
        var sawProgress = false
        downloader.start()
        while true {
            try await Task.sleep(for: .milliseconds(500))
            if case .downloading(let f) = downloader.state, f > 0 { sawProgress = true }
            if case .failed(let message) = downloader.state { Issue.record("download failed: \(message)"); return }
            if downloader.state == .idle { break }
        }
        #expect(sawProgress)
        #expect(SpeakerSeparation.Models.areDownloaded)
        for f in SpeakerSeparation.Models.files {
            #expect(try SpeakerSeparation.Models.sha256(of: SpeakerSeparation.Models.path(f.name)) == f.sha256)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: SpeakerSeparation.Models.directory.path)
        #expect(!leftovers.contains { $0.hasSuffix(".download") })
    }
}
