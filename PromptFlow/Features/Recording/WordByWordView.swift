import SwiftUI

// MARK: - Placeholder demo loop (mode-aware)

struct PlaceholderLoopView: View {
    let fontSize: CGFloat
    let isClassicMode: Bool

    @AppStorage("orpAlignmentEnabled") private var orpAlignmentEnabled: Bool = true
    @AppStorage("orpHighlightAnchor") private var orpHighlightAnchor: Bool = true
    @AppStorage("speedSliderValue") private var sliderValue: Double = 0.5
    @Environment(\.locale) private var locale

    @State private var chunks: [String] = [""]
    @State private var strategy: any LanguageStrategy = LatinLanguageStrategy()
    @State private var supportsORP: Bool = true
    @State private var currentIndex = 0
    @State private var opacity: Double = 1
    @State private var scrollOffset: CGFloat = 0
    @State private var loopTask: Task<Void, Never>?

    private let lineHeight: CGFloat = 28

    private var useORP: Bool { orpAlignmentEnabled && supportsORP }
    private var currentChunk: String {
        guard !chunks.isEmpty else { return "" }
        return chunks[currentIndex % chunks.count]
    }

    var body: some View {
        Group {
            if isClassicMode {
                classicPlaceholder
            } else {
                wbwPlaceholder
            }
        }
        .onAppear {
            recomputeChunks()
            startLoop()
        }
        .onDisappear { loopTask?.cancel() }
        .onChange(of: isClassicMode) { _, _ in
            // Restart loop after container animation settles
            loopTask?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                startLoop()
            }
        }
        .onChange(of: orpAlignmentEnabled) { _, _ in
            recomputeChunks()
            restartLoop()
        }
        .onChange(of: locale) { _, _ in
            recomputeChunks()
            restartLoop()
        }
    }

    // MARK: - WbW placeholder

    private var wbwPlaceholder: some View {
        Group {
            if useORP {
                ORPWord(
                    word: currentChunk,
                    fontSize: fontSize,
                    highlightAnchor: orpHighlightAnchor,
                    textColor: .white.opacity(0.5)
                )
                .opacity(opacity)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, -4)
                .padding(.horizontal, 16)
            } else {
                Text(currentChunk)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .opacity(opacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .padding(.top, -4)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Classic placeholder

    private var classicPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { slot in
                let idx = currentIndex - 1 + slot
                let count = max(chunks.count, 1)
                let wrapped = ((idx % count) + count) % count
                let text = (idx < 0 || chunks.isEmpty) ? "" : chunks[wrapped]
                Text(text)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(classicSlotOpacity(slot) * 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: lineHeight)
            }
        }
        .offset(y: -scrollOffset)
        .frame(height: lineHeight * 3, alignment: .top)
        .clipped()
        .padding(.horizontal, 16)
    }

    private func classicSlotOpacity(_ slot: Int) -> Double {
        switch slot {
        case 0: return 0.3
        case 1: return 1.0
        case 2: return 0.6
        default: return 0.0
        }
    }

    // MARK: - Chunking

    private func recomputeChunks() {
        let phrase = String(
            localized: "recording.placeholder.phrase",
            defaultValue: "Your script will appear here when you hit record",
            comment: "Placeholder phrase shown in the recording screen when no script is loaded. Cycled word-by-word as a demo of the teleprompter. Should read naturally when split on spaces and hint that the user needs to tap record to start."
        )
        let detected = LanguageDetector.detect(phrase)
        let baseMs = ChunkTimingCalculator.orpBaseSpeedMs(sliderValue: sliderValue)
        let newChunks: [String]
        if orpAlignmentEnabled && detected.supportsORP {
            newChunks = detected.chunksPerWord(text: phrase, baseSpeedMs: baseMs)
        } else {
            newChunks = detected.chunks(from: phrase)
        }
        strategy = detected
        supportsORP = detected.supportsORP
        chunks = newChunks.isEmpty ? [phrase] : newChunks
        currentIndex = 0
    }

    // MARK: - Loop

    private func chunkDelay() -> UInt64 {
        // Read slider live from UserDefaults each tick. The @AppStorage wrapper
        // stops seeing fresh writes once captured into a long-lived Task closure,
        // so reading from UserDefaults directly is the only way to pick up
        // mid-loop slider changes without restarting the loop.
        let liveSlider = (UserDefaults.standard.object(forKey: "speedSliderValue") as? Double) ?? 0.5
        let chunk = currentChunk
        let duration: TimeInterval
        if useORP {
            duration = strategy.durationPerWord(
                chunk: chunk,
                baseSpeedMs: ChunkTimingCalculator.orpBaseSpeedMs(sliderValue: liveSlider)
            )
        } else {
            duration = ChunkTimingCalculator.calculateDuration(
                for: chunk,
                sliderValue: liveSlider,
                strategy: strategy
            )
        }
        return UInt64(duration * 1_000_000_000)
    }

    private func restartLoop() {
        loopTask?.cancel()
        startLoop()
    }

    private func startLoop() {
        loopTask?.cancel()
        currentIndex = 0
        opacity = 1
        scrollOffset = 0

        loopTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: chunkDelay())
                guard !Task.isCancelled else { return }

                if isClassicMode {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) { scrollOffset = lineHeight }
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        scrollOffset = 0
                        currentIndex = chunks.isEmpty ? 0 : (currentIndex + 1) % chunks.count
                    }
                } else {
                    await MainActor.run { withAnimation(.easeOut(duration: 0.08)) { opacity = 0 } }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        currentIndex = chunks.isEmpty ? 0 : (currentIndex + 1) % chunks.count
                    }
                    await MainActor.run { withAnimation(.easeIn(duration: 0.08)) { opacity = 1 } }
                }
            }
        }
    }
}

// MARK: - Word-by-word display (rendering only)

struct WordByWordView: View {
    @ObservedObject var player: ChunkPlayerEngine
    let fontSize: CGFloat

    @AppStorage("orpAlignmentEnabled") private var orpAlignmentEnabled: Bool = true
    @AppStorage("orpHighlightAnchor") private var orpHighlightAnchor: Bool = true

    @State private var displayedText: String = ""
    @State private var textOpacity: Double = 1
    @State private var lastIndex: Int = -1

    private var useORP: Bool {
        orpAlignmentEnabled
            && player.supportsORP
            && displayedText != "..."
            && displayedText != "✓"
    }

    var body: some View {
        Group {
            if useORP {
                if displayedText.isEmpty {
                    // Pause chunk in ORP mode — transparent spacer keeps layout stable
                    Text(" ")
                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.clear)
                        .padding(.top, -4)
                        .padding(.horizontal, 16)
                } else {
                    ORPWord(
                        word: displayedText,
                        fontSize: fontSize,
                        highlightAnchor: orpHighlightAnchor
                    )
                    .opacity(textOpacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, -4)
                    .padding(.horizontal, 16)
                }
            } else {
                Text(displayedText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(textOpacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .padding(.top, -4)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear {
            player.orpEnabled = orpAlignmentEnabled
            syncToPlayer()
        }
        .onChange(of: player.currentChunkIndex) { _, _ in
            crossfadeToCurrentChunk()
        }
        .onChange(of: orpAlignmentEnabled) { _, newValue in
            player.orpEnabled = newValue
            player.reloadChunks()
        }
    }

    /// CJK sentence-ending punctuation to strip from display (but keep for timing)
    private static let cjkStripPunctuation: Set<Character> = ["。", "！", "？"]

    private func displayText(for chunk: String) -> String {
        if ChunkTimingCalculator.isPause(chunk) { return "..." }
        // Strip CJK sentence-ending punctuation from display
        if CJKTokenizer.containsCJK(chunk) {
            let stripped = String(chunk.filter { !Self.cjkStripPunctuation.contains($0) })
            return stripped.isEmpty ? chunk : stripped
        }
        return chunk
    }

    private func displayOpacity(for chunk: String) -> Double {
        ChunkTimingCalculator.isPause(chunk) ? 0.2 : 1
    }

    private func syncToPlayer() {
        let idx = player.currentChunkIndex
        if idx >= 0, idx < player.chunks.count {
            let chunk = player.chunks[idx]
            displayedText = displayText(for: chunk)
            textOpacity = displayOpacity(for: chunk)
        }
        lastIndex = idx
    }

    private func crossfadeToCurrentChunk() {
        let idx = player.currentChunkIndex
        guard idx != lastIndex else { return }
        lastIndex = idx

        guard idx < player.chunks.count else {
            displayedText = "✓"
            textOpacity = 1
            return
        }

        let chunk = player.chunks[idx]
        withAnimation(.easeInOut(duration: 0.08)) { textOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            displayedText = displayText(for: chunk)
            withAnimation(.easeInOut(duration: 0.08)) { textOpacity = displayOpacity(for: chunk) }
        }
    }
}

// MARK: - Classic 3-line display (rendering only)

struct ClassicThreeLineView: View {
    @ObservedObject var player: ChunkPlayerEngine

    @State private var displayIndex: Int = 0
    @State private var scrollOffset: CGFloat = 0

    private let lineFontSize: CGFloat = 22
    private let lineHeight: CGFloat = 28

    private static let cjkStripPunctuation: Set<Character> = ["。", "！", "？"]

    private func chunkText(at i: Int) -> String {
        guard i >= 0, i < player.chunks.count else { return "" }
        let chunk = player.chunks[i]
        if ChunkTimingCalculator.isPause(chunk) { return "" }
        if CJKTokenizer.containsCJK(chunk) {
            let stripped = String(chunk.filter { !Self.cjkStripPunctuation.contains($0) })
            return stripped.isEmpty ? chunk : stripped
        }
        return chunk
    }

    private func lineOpacity(_ slot: Int) -> Double {
        switch slot {
        case 0: return 0.3
        case 1: return 1.0
        case 2: return 0.6
        default: return 0.0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { slot in
                let chunkIdx = displayIndex - 1 + slot
                Text(chunkText(at: chunkIdx))
                    .font(.system(size: lineFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(lineOpacity(slot))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: lineHeight)
            }
        }
        .offset(y: -scrollOffset)
        .frame(height: lineHeight * 3, alignment: .top)
        .clipped()
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .onAppear {
            displayIndex = player.currentChunkIndex
            scrollOffset = 0
        }
        .onChange(of: player.currentChunkIndex) { _, newIdx in
            guard newIdx != displayIndex else { return }
            animateScrollTo(newIdx)
        }
    }

    private func animateScrollTo(_ newIdx: Int) {
        // Scroll up one slot
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollOffset = lineHeight
        }
        // After animation, snap to new position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollOffset = 0
            displayIndex = newIdx
        }
    }
}
