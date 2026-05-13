import Foundation

/// Per-chunk timing metadata produced by `MarkerPreprocessor`. Held in
/// a parallel array next to `ChunkPlayerEngine.chunks` (Option C in the
/// design) so non-engine readers (`WordByWordView`, `ClassicThreeLineView`,
/// etc.) keep their `[String]` interface unchanged.
///
/// All fields default to "no effect" so an array of `ChunkMetadata()`
/// preserves pre-marker behavior exactly.
struct ChunkMetadata: Sendable, Equatable {
    /// Per-chunk speed multiplier from `{N}` markers. 1.0 = no effect.
    /// Composes multiplicatively with `engine.externalSpeedMultiplier`
    /// (which is itself driven by FMV2) and the slider-derived
    /// baseline. Stack: `effectiveDuration = base / (markerMul × extMul)`.
    var speedMultiplier: Double = 1.0
    /// Flat extra pause inserted BEFORE this chunk plays. Driven by the
    /// `///` marker. NOT divided by any multiplier — long pauses are
    /// honest seconds regardless of pace.
    var extraPauseSec: Double = 0.0
    /// True iff this chunk's text ends with `.`, `!`, or `?`. Currently
    /// informational; future logic might use it for pacing decisions.
    var endsSentence: Bool = false
}

/// Parses inline timing markers from raw script text and produces
/// chunked output with parallel `ChunkMetadata`. Handled markers:
///
/// - `{N}` (e.g. `{0.5}`, `{1.5}`, `{2}`) — relative speed multiplier
///   that composes with FMV2/slider, applies until the end of the
///   current sentence (`.`, `!`, `?`), then auto-resets to 1.0.
/// - `///` — adds 1.0 s of extra pause before the next chunk. Intended
///   placement is between sentences; placed mid-sentence works but is
///   visually awkward.
///
/// Existing `//` short-pause behavior is unchanged: that marker is
/// handled inside the strategy implementations (250 ms ORP, 500 ms /
/// 200 ms non-ORP). MarkerPreprocessor never touches `//`.
///
/// Non-Latin strategies (Arabic, CJK) skip preprocessing entirely in
/// the engine; markers in those scripts are treated as ordinary tokens
/// per the v1 acceptance criteria. They won't crash, just won't apply.
enum MarkerPreprocessor {

    /// Long-pause duration for a single `///` marker. Multiple `///`
    /// in a row stack additively (`/// ///` = 2 s).
    static let longPauseSec: Double = 1.0

    /// Sentence terminators recognized for the auto-reset of `{N}`.
    /// Matches `LatinLanguageStrategy.endsSentence`'s detection set.
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// One contiguous span of script text that shares a single speed
    /// multiplier. Each segment is fed to the strategy's chunker as a
    /// unit; segment boundaries are at `{N}` activations and at
    /// sentence-ending punctuation.
    struct Segment {
        let text: String
        let speedMultiplier: Double
        /// Extra pause to attach to the segment's FIRST chunk only.
        let extraPauseBefore: Double
    }

    // MARK: - Public

    /// Run the full preprocessing pipeline. The caller supplies the
    /// per-segment chunker (typically `strategy.chunks(from:)` or
    /// `strategy.chunksPerWord(text:baseSpeedMs:)`); we run it once
    /// per speed-segment and stitch the results into final parallel
    /// arrays.
    static func process(
        rawText: String,
        chunker: (String) -> [String]
    ) -> (chunks: [String], metadata: [ChunkMetadata]) {
        let segments = splitIntoSegments(rawText)
        var chunks: [String] = []
        var metadata: [ChunkMetadata] = []

        for segment in segments {
            let segChunks = chunker(segment.text)
            guard !segChunks.isEmpty else { continue }

            let segmentEndsSentence: Bool = {
                guard let last = segment.text.unicodeScalars.last else { return false }
                return sentenceEnders.contains(Character(last))
            }()

            for (i, chunk) in segChunks.enumerated() {
                var meta = ChunkMetadata()
                meta.speedMultiplier = segment.speedMultiplier
                if i == 0 {
                    meta.extraPauseSec = segment.extraPauseBefore
                }
                if i == segChunks.count - 1, segmentEndsSentence {
                    meta.endsSentence = true
                }
                chunks.append(chunk)
                metadata.append(meta)
            }
        }

        return (chunks, metadata)
    }

    // MARK: - Internal pipeline

    /// Pre-tokenization pass: insert whitespace around `///` and `{N}`
    /// so the downstream whitespace tokenizer sees them as standalone
    /// regardless of whether the user wrote them flush against words.
    /// `///(?!/)` (negative lookahead) prevents partial matches inside
    /// 4+ slash runs — those are user typos that we leave as-is.
    /// `//` (the existing short-pause marker) is intentionally NOT
    /// padded here; the strategy still finds it via its own
    /// whitespace-keyed detector.
    static func normalizeMarkers(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: "///(?!/)", with: " /// ", options: .regularExpression)
        out = out.replacingOccurrences(of: "(\\{\\d+(?:\\.\\d+)?\\})", with: " $1 ", options: .regularExpression)
        return out
    }

    /// Walk normalized whitespace tokens, building speed-segments via a
    /// small state machine.
    ///
    /// State:
    /// - `activeSpeed` — current speed multiplier. Reset to 1.0 after
    ///   any sentence-ending word.
    /// - `pendingPause` — pause carried by `///` markers until the
    ///   next real-word segment opens.
    /// - `bufferWords` / `bufferSpeed` / `bufferPauseBefore` — words
    ///   accumulating into the current segment.
    ///
    /// Token handling:
    /// - `///` → `pendingPause += longPauseSec`. No emission.
    /// - `{N}` → close current segment if any words are queued, then
    ///   set `activeSpeed = N`. Pending pause carries to next segment.
    /// - real word → start a new segment if buffer is empty, append to
    ///   buffer, and if the word ends in `.`/`!`/`?`, close the segment
    ///   and reset `activeSpeed = 1.0`.
    static func splitIntoSegments(_ raw: String) -> [Segment] {
        let normalized = normalizeMarkers(raw)
        let tokens = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var segments: [Segment] = []
        var activeSpeed: Double = 1.0
        var pendingPause: Double = 0.0
        var bufferWords: [String] = []
        var bufferSpeed: Double = 1.0
        var bufferPauseBefore: Double = 0.0

        func flushBuffer() {
            guard !bufferWords.isEmpty else { return }
            segments.append(Segment(
                text: bufferWords.joined(separator: " "),
                speedMultiplier: bufferSpeed,
                extraPauseBefore: bufferPauseBefore
            ))
            bufferWords.removeAll()
            bufferPauseBefore = 0
        }

        for token in tokens {
            if token == "///" {
                pendingPause += longPauseSec
                continue
            }
            if let speed = parseSpeedMarker(token) {
                if !bufferWords.isEmpty {
                    flushBuffer()
                }
                activeSpeed = speed
                continue
            }
            if bufferWords.isEmpty {
                bufferSpeed = activeSpeed
                bufferPauseBefore = pendingPause
                pendingPause = 0
            }
            bufferWords.append(token)
            if let last = token.unicodeScalars.last,
               sentenceEnders.contains(Character(last)) {
                flushBuffer()
                activeSpeed = 1.0
            }
        }
        flushBuffer()
        return segments
    }

    /// Parse a `{N}` token into its Double value. Returns nil for
    /// non-marker tokens or invalid contents (`{abc}`, `{}`, `{-1}`,
    /// `{0}`). Zero/negative speeds are rejected so they can't divide
    /// by zero downstream.
    private static func parseSpeedMarker(_ token: String) -> Double? {
        guard token.hasPrefix("{") && token.hasSuffix("}") else { return nil }
        let inner = String(token.dropFirst().dropLast())
        guard let value = Double(inner), value > 0 else { return nil }
        return value
    }
}
