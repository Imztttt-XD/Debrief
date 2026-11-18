import Foundation

/// Everything the app stores lives under ~/Library/Application Support/Debrief/.
/// (SwiftData isn't usable here: its @Model macro needs Xcode's macro plugins, and this project
/// builds with Command Line Tools only. JSON files are plenty for this data size.)
enum AppPaths {
    static let root: URL = {
        // DEBRIEF_DATA_DIR redirects all data (used by tests so they never touch real data;
        // $HOME doesn't work for this, FileManager resolves the home folder from the account).
        let url = ProcessInfo.processInfo.environment["DEBRIEF_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Debrief", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// One JSON file per review: reviews/<recordingID>.json (they can be large).
    static let reviews: URL = {
        let url = root.appendingPathComponent("Reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// One JSON file per mock interview: MockInterviews/<id>.json.
    static let mocks: URL = {
        let url = root.appendingPathComponent("MockInterviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Copies of imported resume files.
    static let resumes: URL = {
        let url = root.appendingPathComponent("Resumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// One Codable value stored in one JSON file, written atomically.
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ fileName: String) {
        url = AppPaths.root.appendingPathComponent(fileName)
    }

    init(reviewsSubpath fileName: String) {
        url = AppPaths.reviews.appendingPathComponent(fileName)
    }

    init(url: URL) {
        self.url = url
    }

    /// nil when the file doesn't exist yet. If it exists but can't be decoded, a copy is kept
    /// next to it (`*.unreadable-<time>.json`) before returning nil, so data is never silently lost.
    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("Debrief: could not decode \(url.lastPathComponent): \(error). Kept a copy at \(backup.lastPathComponent)")
            return nil
        }
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
