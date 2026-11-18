import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import Speech

/// On-device transcription with Apple's SpeechTranscriber (macOS 26+): no API key, no cost, and
/// the recording never leaves the Mac. Each track is one speaker, as with the cloud transcriber
/// (Review/Transcriber.swift). The recognizer returns long, mostly unpunctuated results, so they
/// are cut into lines at the same pauses the cloud path uses (SpeechSegmenter), plus at
/// sentence-ending punctuation, so the review can point at individual lines.
enum LocalTranscriber {
    static var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Interviews are assumed to be in the app's UI language.
    static var preferredLocale: Locale {
        switch AppLanguage.current.resolvedCode {
        case "zh-Hant": Locale(identifier: "zh-TW")
        case "en": Locale(identifier: "en-US")
        case "ja": Locale(identifier: "ja-JP")
        default: Locale(identifier: "zh-CN")
        }
    }

    /// Shown as the transcript's model, e.g. "Apple 本机识别 (zh_CN)".
    static func modelName(_ locale: Locale) -> String {
        L10n.tr("local.modelName", [locale.identifier])
    }

    /// Checks the language is supported and downloads its speech model the first time.
    @available(macOS 26, *)
    static func prepare() async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            throw AIError(message: L10n.tr("local.unsupportedLanguage", [preferredLocale.identifier]))
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return locale
    }

    /// `progress` gets 0…1. `terms` (JD / resume vocabulary) go to the recognizer as contextual
    /// strings. Tested on macOS 27 / zh_CN they made no visible difference ("Redis" still came out
    /// as "readis"); the review step's prompt allows fixing obvious recognition errors from context.
    @available(macOS 26, *)
    static func transcribe(_ record: RecordingRecord, terms: [String],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> (utterances: [Utterance], locale: Locale) {
        let locale = try await prepare()
        let (file, speakers) = try await Transcriber.sources(for: record)
        let total = max(1, record.duration * Double(speakers.count))
        var finished = 0.0
        var utterances: [Utterance] = []
        progress(0)
        for (index, speaker) in speakers.enumerated() {
            let track = try await SpeechSegmenter.readTrack(url: file, index: index)
            let duration = Double(track.samples.count) / Double(SpeechSegmenter.sampleRate)
            let segments = SpeechSegmenter.segments(track.samples)
            // A silent track (e.g. no meeting audio in an in-person interview): nothing to do.
            if segments.isEmpty {
                finished += duration
                progress(min(1, finished / total))
                continue
            }
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let pcm = track.samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try WAV.encode(pcm16Mono: pcm, sampleRate: SpeechSegmenter.sampleRate).write(to: wav)

            let base = finished
            let lines = try await run(wav, locale: locale, terms: terms, pauses: segments.map(\.start)) { seconds in
                progress(min(1, (base + seconds) / total))
            }
            utterances += lines.map {
                Utterance(speaker: speaker, start: track.startOffset + $0.start, end: track.startOffset + $0.end, text: $0.text)
            }
            finished += duration
            try Task.checkCancellation()
        }
        return (Transcriber.removeEcho(utterances).sorted { $0.start < $1.start }, locale)
    }

    @available(macOS 26, *)
    private static func run(_ url: URL, locale: Locale, terms: [String], pauses: [Double],
                            progress: @escaping @Sendable (Double) -> Void) async throws -> [Sentence] {
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        async let sentences = collect(module, pauses: pauses, progress: progress)
        let audio = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await sentences
    }

    @available(macOS 26, *)
    private static func collect(_ module: SpeechTranscriber, pauses: [Double],
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [Sentence] {
        var out: [Sentence] = []
        for try await result in module.results {
            let pieces = result.text.runs.map { run -> Piece in
                let range = run.audioTimeRange
                return Piece(text: String(result.text[run.range].characters),
                             start: range.map { $0.start.seconds }, end: range.map { $0.end.seconds })
            }
            let whole = (result.range.start.seconds, result.range.end.seconds)
            out += sentences(from: pieces, fallback: whole, segmentStarts: pauses)
            if whole.1.isFinite { progress(whole.1) }
        }
        return out
    }

    // MARK: Sentences

    struct Piece: Equatable { var text: String; var start: Double?; var end: Double? }
    struct Sentence: Equatable { var start: Double; var end: Double; var text: String }

    /// Cuts recognized text into lines and times each line by the pieces it contains.
    /// - A new line starts where a speech segment starts (`segmentStarts`, ascending: the
    ///   segmenter's pauses). The recognizer folds a pause into the next piece's time range, so a
    ///   piece belongs to the segment its *end* falls in, and a line starts no earlier than its segment.
    /// - Also after sentence-ending punctuation, or after `maxLength` characters with neither.
    /// - Pieces without times use the result's overall range (`fallback`).
    static func sentences(from pieces: [Piece], fallback: (Double, Double), segmentStarts: [Double] = [],
                          maxLength: Int = 120) -> [Sentence] {
        let enders: Set<Character> = ["。", "？", "！", "?", "!", "；", ";"]
        func segment(_ t: Double) -> Int { segmentStarts.lastIndex { $0 <= t - 0.05 } ?? -1 }
        var out: [Sentence] = []
        var text = "", start: Double?, end: Double?, current: Int?
        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                let s = start ?? fallback.0, e = end ?? fallback.1
                out.append(Sentence(start: s.isFinite ? s : 0, end: max(e.isFinite ? e : s, s), text: t))
            }
            text = ""; start = nil; end = nil
        }
        for piece in pieces {
            if let e = piece.end, e.isFinite {
                let index = segment(e)
                if let current, index != current { flush() }
                current = index
                if start == nil, index >= 0, let s = piece.start, s.isFinite { start = max(s, segmentStarts[index]) }
            }
            text += piece.text
            if let s = piece.start, s.isFinite, start == nil { start = s }
            if let e = piece.end, e.isFinite { end = e }
            let trimmed = piece.text.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, enders.contains(last) { flush() } else if text.count >= maxLength { flush() }
        }
        flush()
        return out
    }
}
