import CryptoKit
import CSherpaOnnx
import Foundation
import RecorderCore

/// Experimental: tells speakers apart in single-track recordings (imported files, in-person
/// interviews), which otherwise leave every line as 未知.
///
/// sherpa-onnx (Apache-2.0) does the work on this Mac: pyannote segmentation 3.0 finds who-speaks-
/// when, a CAM++ voiceprint model groups the turns by voice. The library is loaded at runtime from
/// the app bundle's Frameworks folder (copied there by build-app.sh when Vendor/sherpa-onnx exists;
/// see scripts/fetch-sherpa.sh), so the app builds and runs without it. The two models (≈ 33 MB)
/// are downloaded on first use and checked against pinned SHA-256s.
///
/// The voices are then mapped to 面试官 / 我 by speaking time: the candidate usually talks most.
/// That's a guess, so the review marks the speakers as estimated and offers a one-click swap.
enum SpeakerSeparation {
    /// One stretch of speech by one voice, in seconds on the track's own timeline.
    struct Turn: Equatable, Sendable {
        var start: Double
        var end: Double
        var speaker: Int
    }

    enum Failure: LocalizedError {
        case libraryMissing, modelsMissing, createFailed, processFailed
        var errorDescription: String? {
            switch self {
            case .libraryMissing: L10n.tr("speakers.error.library")
            case .modelsMissing: L10n.tr("speakers.error.models")
            case .createFailed, .processFailed: L10n.tr("speakers.error.failed")
            }
        }
    }

    // MARK: Choosing a clustering (pure)

    /// A voice needs this share of all speech to count as a speaker. Real recordings scatter a
    /// few seconds of noise, laughter or crosstalk into tiny clusters of their own.
    static let majorShare = 0.05
    /// Clustering thresholds tried in order (sherpa-onnx: larger → fewer, larger clusters).
    /// Clean audio separates at the default 0.5; a noisy phone recording of two people came out
    /// as 60+ "speakers" there and as two clear voices covering 97% of speech at 0.9–1.0.
    static let thresholds: [Float] = [0.5, 0.9, 1.0]

    /// Voices with at least `majorShare` of the speech, most speech first, and the share they cover.
    static func majorVoices(_ turns: [Turn]) -> (voices: [Int], coverage: Double) {
        var total: [Int: Double] = [:]
        for t in turns { total[t.speaker, default: 0] += t.end - t.start }
        let all = total.values.reduce(0, +)
        guard all > 0 else { return ([], 0) }
        let majors = total.filter { $0.value / all >= majorShare }.sorted { $0.value > $1.value }
        return (majors.map(\.key), majors.reduce(0) { $0 + $1.value } / all)
    }

    /// More major voices than this is treated as fragmentation, not a crowd: interviews rarely
    /// have more, and separation that fine wouldn't be trustworthy anyway.
    static let maxVoices = 4

    /// A clustering is usable when a few voices (1 to `maxVoices`) hold ≥ 90% of the speech; a
    /// single voice holding it all means one speaker. Otherwise it's fragmented: try the next threshold.
    static func isSettled(_ turns: [Turn]) -> Bool {
        let (voices, coverage) = majorVoices(turns)
        return coverage >= 0.9 && (1...maxVoices).contains(voices.count)
    }

    /// The first settled result in threshold order; else, preferring results with at most
    /// `maxVoices` major voices, the one whose major voices cover the most speech.
    static func choose(_ results: [[Turn]]) -> [Turn] {
        if let settled = results.first(where: isSettled) { return settled }
        func rank(_ turns: [Turn]) -> (Int, Double) {
            let (voices, coverage) = majorVoices(turns)
            return (voices.count <= maxVoices ? 1 : 0, coverage)
        }
        return results.max { rank($0) < rank($1) } ?? []
    }

    // MARK: Assigning speakers (pure)

    /// Labels each line with the major voice that overlaps it most (or the nearest major turn if
    /// none does); tiny clusters are ignored. The voice with the most speaking time is 我, every
    /// other major voice 面试官. Fewer than two major voices: unchanged, nothing to tell apart.
    static func assign(_ utterances: [Utterance], turns allTurns: [Turn]) -> [Utterance] {
        let majors = Set(majorVoices(allTurns).voices)
        let turns = allTurns.filter { majors.contains($0.speaker) }
        var total: [Int: Double] = [:]
        for t in turns { total[t.speaker, default: 0] += t.end - t.start }
        guard total.count >= 2 else { return utterances }
        let firstStart = Dictionary(turns.map { ($0.speaker, $0.start) }, uniquingKeysWith: min)
        // Most speech; on a tie, the voice that started later (the interviewer usually opens).
        let me = total.max { a, b in
            a.value != b.value ? a.value < b.value : (firstStart[a.key] ?? 0) > (firstStart[b.key] ?? 0)
        }!.key

        return utterances.map { u in
            var overlap: [Int: Double] = [:]
            for t in turns {
                let o = min(u.end, t.end) - max(u.start, t.start)
                if o > 0 { overlap[t.speaker, default: 0] += o }
            }
            let speaker = overlap.max { $0.value < $1.value }?.key
                ?? turns.min { distance(u, $0) < distance(u, $1) }!.speaker
            var labeled = u
            labeled.speaker = speaker == me ? .me : .interviewer
            return labeled
        }
    }

    private static func distance(_ u: Utterance, _ t: Turn) -> Double {
        max(0, max(t.start - u.end, u.start - t.end))
    }

    /// Swaps 面试官 and 我 (when the speaking-time guess got them the wrong way round).
    static func swapped(_ utterances: [Utterance]) -> [Utterance] {
        utterances.map { u in
            var s = u
            switch u.speaker {
            case .interviewer: s.speaker = .me
            case .me: s.speaker = .interviewer
            case .unknown: break
            }
            return s
        }
    }

    // MARK: Library

    private typealias CreateFn = @convention(c) (UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>?) -> OpaquePointer?
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    private typealias ProcessFn = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, Int32) -> OpaquePointer?
    private typealias CountFn = @convention(c) (OpaquePointer?) -> Int32
    private typealias SortFn = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationSegment>?
    private typealias DestroySegmentsFn = @convention(c) (UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationSegment>?) -> Void
    private typealias SetConfigFn = @convention(c) (OpaquePointer?, UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>?) -> Void

    private struct Library: @unchecked Sendable {
        let create: CreateFn, destroy: DestroyFn, process: ProcessFn, count: CountFn
        let sorted: SortFn, destroySegments: DestroySegmentsFn, destroyResult: DestroyFn, setConfig: SetConfigFn
    }

    /// Where the dylibs are looked for: DEBRIEF_SHERPA_LIB_DIR (tests, `swift run`), then the
    /// app bundle's Frameworks folder.
    static var libraryDirectories: [URL] {
        var dirs: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["DEBRIEF_SHERPA_LIB_DIR"] {
            dirs.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        if let frameworks = Bundle.main.privateFrameworksURL { dirs.append(frameworks) }
        return dirs
    }

    private static let library: Library? = {
        for dir in libraryDirectories {
            let path = dir.appendingPathComponent("libsherpa-onnx-c-api.dylib").path
            // Its @loader_path rpath finds libonnxruntime.dylib in the same folder.
            guard FileManager.default.fileExists(atPath: path), let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
            if let create = sym("SherpaOnnxCreateOfflineSpeakerDiarization", CreateFn.self),
               let destroy = sym("SherpaOnnxDestroyOfflineSpeakerDiarization", DestroyFn.self),
               let process = sym("SherpaOnnxOfflineSpeakerDiarizationProcess", ProcessFn.self),
               let count = sym("SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments", CountFn.self),
               let sorted = sym("SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime", SortFn.self),
               let destroySegments = sym("SherpaOnnxOfflineSpeakerDiarizationDestroySegment", DestroySegmentsFn.self),
               let destroyResult = sym("SherpaOnnxOfflineSpeakerDiarizationDestroyResult", DestroyFn.self),
               let setConfig = sym("SherpaOnnxOfflineSpeakerDiarizationSetConfig", SetConfigFn.self) {
                return Library(create: create, destroy: destroy, process: process, count: count, sorted: sorted,
                               destroySegments: destroySegments, destroyResult: destroyResult, setConfig: setConfig)
            }
            dlclose(h)
        }
        return nil
    }()

    /// The library is part of this build of the app.
    static var isLibraryAvailable: Bool { library != nil }
    /// Library present and models downloaded.
    static var isReady: Bool { isLibraryAvailable && Models.areDownloaded }

    // MARK: Models

    enum Models {
        struct File: Sendable {
            let name: String
            let url: URL
            let size: Int64
            let sha256: String
        }

        /// Hugging Face mirrors of the sherpa-onnx release files (much faster than GitHub here).
        static let files = [
            File(name: "segmentation.onnx",
                 url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx")!,
                 size: 5_992_913, sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"),
            File(name: "embedding.onnx",
                 url: URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
                 size: 28_281_138, sha256: "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"),
        ]
        static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

        /// DEBRIEF_SHERPA_MODELS (tests) or Application Support/Debrief/Models/speaker-separation.
        static var directory: URL {
            if let dir = ProcessInfo.processInfo.environment["DEBRIEF_SHERPA_MODELS"] {
                return URL(fileURLWithPath: dir, isDirectory: true)
            }
            return AppPaths.root.appendingPathComponent("Models/speaker-separation", isDirectory: true)
        }

        static func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

        static var areDownloaded: Bool {
            files.allSatisfy { f in
                (try? FileManager.default.attributesOfItem(atPath: path(f.name).path)[.size] as? Int64) == f.size
            }
        }

        static func sha256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Running

    /// Turns for a track, on the recording's timeline (the track's start offset added).
    /// Runs off the main thread. Tries the thresholds in order until the result settles, so a
    /// noisy recording runs two or three times (a 25-minute interview: about 2 minutes a run).
    static func diarize(_ track: SpeechSegmenter.Track) async throws -> [Turn] {
        guard let lib = library else { throw Failure.libraryMissing }
        guard Models.areDownloaded else { throw Failure.modelsMissing }
        let samples = track.samples.map { Float($0) / 32768 }
        let segmentation = Models.path("segmentation.onnx").path, embedding = Models.path("embedding.onnx").path
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        let offset = track.startOffset
        return try await Task.detached(priority: .userInitiated) {
            try run(lib, samples: samples, segmentation: segmentation, embedding: embedding, threads: threads)
                .map { Turn(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker) }
        }.value
    }

    private static func run(_ lib: Library, samples: [Float], segmentation: String, embedding: String,
                            threads: Int32) throws -> [Turn] {
        // The library copies the strings while creating the diarizer.
        let seg = strdup(segmentation), emb = strdup(embedding), cpu = strdup("cpu")
        defer { free(seg); free(emb); free(cpu) }
        var c = SherpaOnnxOfflineSpeakerDiarizationConfig()
        c.segmentation.pyannote.model = UnsafePointer(seg)
        c.segmentation.num_threads = threads
        c.segmentation.provider = UnsafePointer(cpu)
        c.embedding.model = UnsafePointer(emb)
        c.embedding.num_threads = threads
        c.embedding.provider = UnsafePointer(cpu)
        // Unknown number of speakers (panel interviews happen): cluster by voice distance. Fixing
        // the count at 2 put 99% of a real two-person interview into one cluster.
        c.clustering.num_clusters = -1
        c.clustering.threshold = thresholds[0]
        c.min_duration_on = 0.3
        c.min_duration_off = 0.5
        guard let sd = lib.create(&c) else { throw Failure.createFailed }
        defer { lib.destroy(sd) }
        var results: [[Turn]] = []
        for threshold in thresholds {
            c.clustering.threshold = threshold
            lib.setConfig(sd, &c)
            guard let result = samples.withUnsafeBufferPointer({ lib.process(sd, $0.baseAddress, Int32($0.count)) }) else {
                throw Failure.processFailed
            }
            defer { lib.destroyResult(result) }
            let n = Int(lib.count(result))
            var turns: [Turn] = []
            if n > 0, let segments = lib.sorted(result) {
                defer { lib.destroySegments(segments) }
                turns = (0..<n).map { Turn(start: Double(segments[$0].start), end: Double(segments[$0].end), speaker: Int(segments[$0].speaker)) }
            }
            results.append(turns)
            if isSettled(turns) || Task.isCancelled { break }
        }
        return choose(results)
    }
}

/// Downloads the speaker-separation models, with progress. One app-wide instance (`shared`):
/// the settings page comes and goes, the download mustn't (and must never run twice at once).
@MainActor
final class SpeakerModelDownloader: ObservableObject {
    enum State: Equatable { case idle, downloading(Double), failed(String) }
    static let shared = SpeakerModelDownloader()
    @Published private(set) var state = State.idle
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try await Self.download { fraction in self?.state = .downloading(fraction) }
                self?.state = .idle
            } catch {
                if !(error is CancellationError) { self?.state = .failed(error.localizedDescription) }
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// A plain download task (written straight to disk by the system); progress is read from the
    /// task's Progress. Cancelling the Swift task cancels the download.
    private nonisolated static func fetch(_ url: URL, resumeData: Data?, to destination: URL,
                                          onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        final class Box: @unchecked Sendable { var task: URLSessionDownloadTask?; var observation: NSKeyValueObservation? }
        let box = Box()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let done: @Sendable (URL?, URLResponse?, Error?) -> Void = { temp, response, error in
                    box.observation?.invalidate()
                    if let error { continuation.resume(throwing: error); return }
                    guard let temp, [200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                        continuation.resume(throwing: AIError(message: L10n.tr("speakers.error.download")))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temp, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let task = resumeData.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: done) }
                    ?? URLSession.shared.downloadTask(with: url, completionHandler: done)
                box.task = task
                box.observation = task.progress.observe(\.completedUnitCount) { p, _ in onBytes(p.completedUnitCount) }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Each file goes to a temporary name, is checked against its SHA-256, then moved into place.
    private static func download(progress: @escaping @MainActor (Double) -> Void) async throws {
        typealias M = SpeakerSeparation.Models
        try FileManager.default.createDirectory(at: M.directory, withIntermediateDirectories: true)
        var done: Int64 = 0
        for file in M.files {
            let target = M.path(file.name)
            if (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) == file.size {
                done += file.size
                continue
            }
            let partial = target.appendingPathExtension("download")
            let base = done
            // Connections drop on slow networks: resume from where it stopped, a few times.
            var resumeData: Data?
            for attempt in 1...5 {
                do {
                    try await fetch(file.url, resumeData: resumeData, to: partial) { received in
                        Task { @MainActor in progress(Double(base + received) / Double(M.totalSize)) }
                    }
                    break
                } catch let error as URLError where error.code != .cancelled && attempt < 5 {
                    resumeData = error.downloadTaskResumeData
                    try await Task.sleep(for: .seconds(Double(attempt)))
                }
            }
            guard try M.sha256(of: partial) == file.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw AIError(message: L10n.tr("speakers.error.checksum"))
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            done += file.size
            await progress(Double(done) / Double(M.totalSize))
        }
    }
}
