import Foundation
import Speech
@preconcurrency import AVFoundation
import NaturalLanguage
import os

/// A take's audio into timed words, on device: `SpeechTranscriber` where
/// the device has it for the language, `DictationTranscriber` (all four of
/// the app's languages, with word timing) otherwise. The script's words go
/// in as contextual strings, which steers recognition towards them.
@available(iOS 26.0, *)
nonisolated enum SubtitleTranscriber {

    enum TranscribeError: Error {
        case noLocale
        case noAudioTrack
    }

    static func transcribe(videoURL: URL, script: String?) async throws -> [TimedWord] {
        let hint = locale(for: script)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitles-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await StudioSoundAudio.extractAudio(from: videoURL, to: audioURL)
        // The extracted audio starts at zero; in the movie it starts here.
        let audioStart = try await audioTrackStart(of: videoURL)
        let file = try AVAudioFile(forReading: audioURL)

        let context = AnalysisContext()
        if let script {
            context.contextualStrings[.general] = contextualWords(script)
        }

        let started = Date()
        let words: [TimedWord]
        let engine: String
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: hint),
           await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
            )
            engine = "speech:\(locale.identifier(.bcp47))"
            words = try await run(transcriber, locale: locale, file: file, context: context) {
                transcriber.results.map { result in result.text }
            }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: hint) {
            let transcriber = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
            )
            engine = "dictation:\(locale.identifier(.bcp47))"
            words = try await run(transcriber, locale: locale, file: file, context: context) {
                transcriber.results.map { result in result.text }
            }
        } else {
            throw TranscribeError.noLocale
        }

        log.notice("event=subtitles_transcribed engine=\(engine, privacy: .public) hint=\(hint.identifier(.bcp47), privacy: .public) words=\(words.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return words.map { TimedWord(text: $0.text, start: $0.start + audioStart, end: $0.end + audioStart) }
    }

    /// Runs one module over the whole file and collects its timed words.
    private static func run<Texts: AsyncSequence & Sendable>(
        _ module: any SpeechModule,
        locale: Locale,
        file: AVAudioFile,
        context: AnalysisContext,
        texts: () -> Texts
    ) async throws -> [TimedWord] where Texts.Element == AttributedString {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let reserved = (try? await AssetInventory.reserve(locale: locale)) != nil
        defer {
            if reserved { Task { await AssetInventory.release(reservedLocale: locale) } }
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(context)
        let stream = texts()
        let collector = Task { () throws -> [TimedWord] in
            var words: [TimedWord] = []
            for try await text in stream {
                words += timedWords(in: text)
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// A result's runs into words. A run carrying several words shares its
    /// time among them by length.
    static func timedWords(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let pieces = String(text[run.range].characters)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            guard !pieces.isEmpty else { continue }
            let start = range.start.seconds
            let duration = max(0, range.duration.seconds)
            let total = Double(pieces.reduce(0) { $0 + $1.count })
            var cursor = start
            for piece in pieces {
                let share = total > 0 ? duration * Double(piece.count) / total : duration / Double(pieces.count)
                words.append(TimedWord(text: piece, start: cursor, end: cursor + share))
                cursor += share
            }
        }
        return words
    }

    /// The script's language, mapped to the app's own locales; the device's
    /// language when there is no script or no telling.
    static func locale(for script: String?) -> Locale {
        let recognizer = NLLanguageRecognizer()
        if let script { recognizer.processString(script) }
        switch recognizer.dominantLanguage {
        case .english?: return Locale(identifier: "en-US")
        case .spanish?: return Locale(identifier: "es-MX")
        case .portuguese?: return Locale(identifier: "pt-BR")
        case .russian?: return Locale(identifier: "ru-RU")
        case let language?: return Locale(identifier: language.rawValue)
        case nil: return Locale.current
        }
    }

    /// Distinct script words, cleaned, at most a few hundred.
    private static func contextualWords(_ script: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in SubtitleAligner.scriptWords(script) {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            guard cleaned.count > 2, seen.insert(cleaned.lowercased()).inserted else { continue }
            out.append(cleaned)
            if out.count >= 300 { break }
        }
        return out
    }

    private static func audioTrackStart(of videoURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscribeError.noAudioTrack
        }
        return try await track.load(.timeRange).start.seconds
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "Subtitles"
    )
}
