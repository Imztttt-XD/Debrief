import Foundation

/// Naming scheme for recordings.
///
/// While recording, audio goes to `Interview-<timestamp>.inprogress.mov` (a fragmented
/// QuickTime file with one track per source). After the mixdown it becomes
/// `Interview-<timestamp>.m4a` and the `.inprogress.mov` is deleted. Any
/// `.inprogress.mov` still around at launch means the app crashed or was killed,
/// so it gets recovered.
public enum RecordingFiles {
    public static let inProgressSuffix = ".inprogress.mov"
    public static let filePrefix = "Interview-"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    public static func newTemporaryURL(in directory: URL, date: Date = Date()) -> URL {
        directory.appendingPathComponent(filePrefix + formatter.string(from: date) + inProgressSuffix)
    }

    /// `Interview-X.inprogress.mov` → `Interview-X.m4a`. If that name is taken, appends `-2`, `-3`, and so on.
    public static func finalURL(forTemporary temp: URL) -> URL {
        let name = temp.lastPathComponent
        let base = name.hasSuffix(inProgressSuffix) ? String(name.dropLast(inProgressSuffix.count)) : temp.deletingPathExtension().lastPathComponent
        let dir = temp.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(base + ".m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).m4a")
            n += 1
        }
        return candidate
    }

    public static let tracksSuffix = ".tracks.mov"

    /// `Interview-X.m4a` → `Interview-X.tracks.mov`: the per-source (system / mic) track file kept
    /// after the mixdown, because transcription works on each speaker's track separately.
    public static func tracksURL(forFinal final: URL) -> URL {
        final.deletingPathExtension().appendingPathExtension("tracks.mov")
    }

    /// Recording start time from `Interview-yyyy-MM-dd-HHmmss…`, or nil.
    public static func startDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix(filePrefix) else { return nil }
        let stamp = name.dropFirst(filePrefix.count).prefix("yyyy-MM-dd-HHmmss".count)
        return formatter.date(from: String(stamp))
    }

    public static func leftoverTemporaryFiles(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasSuffix(inProgressSuffix) }.sorted { $0.path < $1.path }
    }
}
