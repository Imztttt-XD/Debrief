import AVFoundation

/// Mixes the per-source tracks of a `.inprogress.mov` down to one stereo AAC `.m4a`.
/// Steps: AVMutableComposition → AVMutableAudioMix (per-track volume) → AVAssetExportSession (AppleM4A).
/// This works on finished files and on crash-truncated fragmented files.
public enum AudioMixer {
    public static func mixdown(
        source: URL,
        to destination: URL,
        systemVolume: Float = 1.0,
        microphoneVolume: Float = 1.0
    ) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
            .sorted { $0.trackID < $1.trackID }
        guard !tracks.isEmpty else { throw RecorderError.noAudioTracks }

        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []

        for (index, track) in tracks.enumerated() {
            let range = try await track.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero,
                  let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            // Insert at the track's own start time so system and mic stay aligned.
            try compTrack.insertTimeRange(range, of: track, at: range.start)

            // TrackWriter order: [system, mic] when both are present.
            let isMic = tracks.count == 2 && index == 1
            let p = AVMutableAudioMixInputParameters(track: compTrack)
            p.setVolume(tracks.count == 2 ? (isMic ? microphoneVolume : systemVolume) : 1.0, at: .zero)
            parameters.append(p)
        }
        guard !parameters.isEmpty else { throw RecorderError.noAudioTracks }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed(nil)
        }
        export.audioMix = mix
        try? FileManager.default.removeItem(at: destination)
        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            throw RecorderError.exportFailed(error)
        }
    }
}
