import SwiftUI
import AVFoundation

// MARK: - Text width presets

enum TextWidthPreset: String, CaseIterable, Identifiable {
    case narrow = "Narrow"
    case medium = "Medium"
    case wide = "Wide"

    var id: String { rawValue }

    /// Fraction of screen width the container occupies
    var fraction: CGFloat {
        switch self {
        case .narrow: return 0.50
        case .medium: return 0.65
        case .wide:   return 0.80
        }
    }
}

struct RecordingView: View {
    let script: Script

    @Environment(\.dismiss) private var dismiss
    @State private var cameraManager = CameraManager()

    // Word-by-word teleprompter state
    @State private var chunks: [String] = []
    @State private var isPlaying = false
    @State private var currentChunkIndex = 0
    @State private var wbwResetToken = UUID()

    // Display settings
    private let fontSize: CGFloat = 32
    @State private var readingSpeed: WordChunkEngine.ReadingSpeed = .medium

    // Container positioning — persisted
    @AppStorage("textContainerOffsetX") private var savedOffsetX: Double = 20
    @AppStorage("textWidthPreset") private var textWidthRaw: String = TextWidthPreset.medium.rawValue
    private var textWidth: TextWidthPreset {
        TextWidthPreset(rawValue: textWidthRaw) ?? .medium
    }

    // Drag state
    @State private var dragOffsetX: CGFloat = 0
    @State private var isDragging = false

    // Recording countdown
    @State private var countdownValue: Int = 0
    @State private var isCountingDown = false
    @State private var countdownTimer: Timer?
    private let countdownSeconds = 3

    // UI
    @State private var showControls = true
    @State private var controlsHideTask: Task<Void, Never>?
    /// Container expand state — expands on appear, only collapses when leaving screen
    @State private var isExpanded = false
    /// Text fades in after the container expand animation finishes
    @State private var showTextContent = false
    /// Smooth progress value animated continuously within each chunk
    @State private var smoothProgress: Double = 0
    /// Scrubbing state
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false

    var body: some View {
        ZStack {
            // 1. Camera preview — full screen
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            // 2. Black container expanding from Dynamic Island — narrower & draggable
            // Hardcoded DI dimensions: top=11pt, width=126pt, height=37.33pt, radius≈19pt
            GeometryReader { geo in
                let diTop: CGFloat = 11
                let diHeight: CGFloat = 37.33
                let cornerRadius: CGFloat = 28
                let diWidth: CGFloat = 126

                let contentHeight: CGFloat = fontSize + 4 + 10
                let expandedContentHeight = diHeight + contentHeight
                let expandedWidth = geo.size.width * textWidth.fraction

                // Clamp: container must always cover the Dynamic Island AND stay 16pt from edges
                let diCoverLimit = (expandedWidth - diWidth) / 2 - 16
                let edgeLimit = (geo.size.width - expandedWidth) / 2 - 16
                let maxOffset = max(0, min(diCoverLimit, edgeLimit))
                let currentX = CGFloat(savedOffsetX) + dragOffsetX
                let clampedX = min(max(currentX, -maxOffset), maxOffset)

                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(
                            width: isExpanded ? expandedWidth : diWidth,
                            height: isExpanded ? expandedContentHeight : diHeight
                        )
                        .overlay(alignment: .top) {
                            if showTextContent {
                                wordDisplay
                                    .frame(width: expandedWidth - 32)
                                    .padding(.top, diHeight)
                                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
                            }
                        }
                        .scaleEffect(isDragging ? 1.02 : 1.0)
                        .offset(x: isExpanded ? clampedX : 0)
                        .gesture(
                            isExpanded ?
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    isDragging = true
                                    // Clamp live so it hard-stops at limits
                                    let proposed = CGFloat(savedOffsetX) + value.translation.width
                                    let clamped = min(max(proposed, -maxOffset), maxOffset)
                                    dragOffsetX = clamped - CGFloat(savedOffsetX)
                                }
                                .onEnded { value in
                                    let newOffset = CGFloat(savedOffsetX) + value.translation.width
                                    let clamped = min(max(newOffset, -maxOffset), maxOffset)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        savedOffsetX = Double(clamped)
                                        dragOffsetX = 0
                                        isDragging = false
                                    }
                                }
                            : nil
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, diTop)
                .ignoresSafeArea(edges: .top)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
                .animation(.interactiveSpring(), value: isDragging)
            }

            // 3. Controls pinned to bottom
            if showControls {
                VStack {
                    Spacer()
                    controlsOverlay
                }
                .transition(.opacity)
            }

            // 3. Countdown overlay
            if isCountingDown {
                countdownOverlay
            }

            // 4. Recording indicator
            if cameraManager.isRecording {
                recordingIndicator
            }
        }
        .onAppear {
            chunks = WordChunkEngine.chunks(from: script.content)
            cameraManager.configure(position: .front)
            scheduleControlsHide()
            // Auto-expand container after a short delay so user sees text position
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeIn(duration: 0.15)) {
                        showTextContent = true
                    }
                }
            }
        }
        .onChange(of: currentChunkIndex) { _, newIndex in
            guard newIndex < chunks.count, isPlaying else { return }
            animateProgressForChunk(at: newIndex)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing && currentChunkIndex < chunks.count {
                // Kick off smooth progress for current chunk (handles first chunk
                // and resume, since onChange(of: currentChunkIndex) won't fire)
                animateProgressForChunk(at: currentChunkIndex)
            }
        }
        .onDisappear {
            cameraManager.stopRecording()
            cameraManager.stopSession()
            isPlaying = false
            showTextContent = false
            isExpanded = false
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
            if showControls { scheduleControlsHide() }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .alert("Camera Error", isPresented: .constant(cameraManager.errorMessage != nil)) {
            Button("OK") { cameraManager.errorMessage = nil }
        } message: {
            Text(cameraManager.errorMessage ?? "")
        }
    }

    // MARK: - Word display area

    /// Shows placeholder loop before playback, real script during playback
    @State private var hasStartedPlayback = false

    private var wordDisplay: some View {
        Group {
            if hasStartedPlayback {
                WordByWordView(
                    chunks: chunks,
                    fontSize: fontSize,
                    speed: readingSpeed,
                    isPlaying: $isPlaying,
                    resetToken: $wbwResetToken,
                    onFinished: { isPlaying = false },
                    currentIndex: $currentChunkIndex
                )
            } else {
                PlaceholderLoopView(fontSize: fontSize)
            }
        }
    }

    // MARK: - Scrubable progress bar

    private var scrubBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                // Fill
                Capsule()
                    .fill(Color.orange)
                    .frame(width: max(0, geo.size.width * smoothProgress), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            wasPlayingBeforeScrub = isPlaying
                            isPlaying = false
                        }
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let index = min(chunks.count - 1, Int(fraction * Double(chunks.count)))
                        guard index >= 0 else { return }
                        currentChunkIndex = index
                        // Snap progress to chunk position (no animation while scrubbing)
                        withAnimation(.none) {
                            smoothProgress = Double(index) / Double(max(1, chunks.count))
                        }
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let index = min(chunks.count - 1, Int(fraction * Double(chunks.count)))
                        guard index >= 0 else { return }
                        currentChunkIndex = index
                        smoothProgress = Double(index) / Double(max(1, chunks.count))
                        wbwResetToken = UUID()
                        isScrubbing = false
                        if wasPlayingBeforeScrub {
                            isPlaying = true
                        }
                    }
            )
        }
        .frame(height: 44) // Accessibility hit area
        .padding(.horizontal, 24)
    }

    /// Animate progress bar smoothly across the current chunk's duration
    private func animateProgressForChunk(at index: Int) {
        guard !chunks.isEmpty, !isScrubbing else { return }
        let target = Double(index + 1) / Double(chunks.count)
        let duration = WordChunkEngine.duration(
            for: chunks[index],
            speed: readingSpeed
        )
        withAnimation(.linear(duration: duration)) {
            smoothProgress = target
        }
    }

    // MARK: - Controls overlay

    private var controlsOverlay: some View {
        VStack(spacing: 16) {
            // Top row: close + progress + camera switch
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }

                Spacer()

                // DISABLED: front camera only for now
                // Button { cameraManager.switchCamera() } label: {
                //     Image(systemName: "camera.rotate.fill")
                //         .font(.title2)
                //         .foregroundStyle(.white)
                //         .shadow(radius: 4)
                // }
            }
            .padding(.horizontal, 20)

            // Speed picker
            Picker("Speed", selection: $readingSpeed) {
                ForEach(WordChunkEngine.ReadingSpeed.allCases) { speed in
                    Text(speed.rawValue).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            // Scrubable progress bar
            scrubBar

            // Play/Pause — Record — Reset
            HStack(spacing: 48) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(chunks.isEmpty)

                // Record button
                Button { toggleRecording() } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .frame(width: 72, height: 72)
                        RoundedRectangle(cornerRadius: cameraManager.isRecording ? 6 : 28)
                            .fill(.red)
                            .frame(
                                width: cameraManager.isRecording ? 28 : 52,
                                height: cameraManager.isRecording ? 28 : 52
                            )
                            .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
                    }
                }

                Button { resetDisplay() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.bottom, 48)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Recording indicator

    private var recordingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(durationString(cameraManager.recordingDuration))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.trailing, 20)
            }
            .padding(.top, 64)
            Spacer()
        }
    }

    // MARK: - Countdown overlay

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            Text("\(countdownValue)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 10)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Teleprompter control

    private func togglePlay() {
        guard !chunks.isEmpty else { return }
        if !hasStartedPlayback {
            hasStartedPlayback = true
        }
        isPlaying.toggle()
    }

    private func resetDisplay() {
        isPlaying = false
        hasStartedPlayback = false
        currentChunkIndex = 0
        smoothProgress = 0
        wbwResetToken = UUID()
        // Container stays open — only collapses when leaving the screen
    }

    // MARK: - Recording control

    private func toggleRecording() {
        if cameraManager.isRecording {
            cameraManager.stopRecording()
        } else {
            startCountdown()
        }
    }

    private func startCountdown() {
        countdownValue = countdownSeconds
        isCountingDown = true

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if countdownValue > 1 {
                withAnimation { countdownValue -= 1 }
            } else {
                timer.invalidate()
                countdownTimer = nil
                isCountingDown = false
                cameraManager.startRecording()
                hasStartedPlayback = true
                isPlaying = true
            }
        }
    }

    // MARK: - Helpers

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showControls = false
                }
            }
        }
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
