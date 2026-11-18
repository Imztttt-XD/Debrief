import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Brings an existing audio or video file (a phone recording, a meeting app's export) into the
/// app as a recording so it can be reviewed.
///
/// The file is copied into the recordings folder, never referenced in place: deleting a
/// recording moves its files to the Trash, which must not hit the user's original. M4A files are
/// copied as they are; everything else (mp3, wav, mp4, mov…) is converted to M4A, keeping only
/// the audio. Imported files have one mixed track, so speakers are unknown (`tracks` empty) and
/// the review tells them apart from content.
enum RecordingImporter {
    static let allowedTypes: [UTType] = [.audio, .movie]

    enum ImportError: LocalizedError {
        case noAudio(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio(let name): L10n.tr("import.noAudio", [name])
            case .exportFailed(let name): L10n.tr("import.failed", [name])
            }
        }
    }

    /// The recording starts when the file was created (falling back to its modification date).
    static func importFile(_ source: URL, into folder: URL) async throws -> RecordingRecord {
        let asset = AVURLAsset(url: source)
        let name = source.lastPathComponent
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ImportError.noAudio(name) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ImportError.noAudio(name) }
        let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let startedAt = values?.creationDate ?? values?.contentModificationDate ?? Date()

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, for: source)
        if source.pathExtension.lowercased() == "m4a" {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw ImportError.exportFailed(name)
            }
            do {
                try await export.export(to: destination, as: .m4a)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw ImportError.exportFailed(name)
            }
        }
        return RecordingRecord(fileURL: destination, tracksFileURL: nil, startedAt: startedAt, duration: duration,
                               tracks: [], interviewID: nil)
    }

    /// "Imported-<original name>.m4a", with " 2", " 3"… if that's taken.
    static func uniqueURL(in folder: URL, for source: URL) -> URL {
        let base = "Imported-" + source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("m4a")
            n += 1
        }
        return candidate
    }
}
