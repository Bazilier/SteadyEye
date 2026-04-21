import SwiftUI
import AVFoundation

// MARK: - Identifiable URL wrapper for fullScreenCover

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct RecordingView: View {
    let script: Script

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRecordingTip = false
    @AppStorage("hasSeenRecordingTip") private var hasSeenRecordingTip = false
    @ObservedObject private var cameraManager = CameraManager.shared
    @StateObject private var player = ChunkPlayerEngine()
    @State private var showSavedToast = false
    @State private var previewVideo: IdentifiableURL?
    @State private var showPaywall: Bool = false

    // Display settings
    private let fontSize: CGFloat = 32
    @AppStorage("speedSliderValue") private var speedSlider: Double = 0.5
    @AppStorage("teleprompterMode") private var displayMode: String = "wbw"
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    private var isClassicMode: Bool { displayMode == "classic" }

    // Container positioning — persisted
    @AppStorage("textContainerOffsetX") private var savedOffsetX: Double = 20
    @AppStorage("textVerticalOffset") private var textVerticalOffset: Double = 0
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true
    @State private var exposureCompensation: Double = 0
    @AppStorage("autoStartPrompting") private var autoStartPrompting: Bool = true
    @State private var showCameraSettings = false

    // Drag state
    @State private var dragOffsetX: CGFloat = 0
    @State private var isDragging = false
    @State private var isTextEditMode = false
    @State private var textDragY: CGFloat = 0

    // Recording countdown
    @State private var countdownValue: Int = 0
    @State private var isCountingDown = false
    @State private var countdownTimer: Timer?
    private let countdownSeconds = 3

    // UI

    @State private var isExpanded = false
    @State private var showTextContent = false
    @State private var smoothProgress: Double = 0
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false
    @State private var hasStartedPlayback = false

    var body: some View {
        ZStack {
            // 1. Camera preview
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            // 1b. Dim overlay during recording
            if dimDuringRecording {
                Color.black
                    .opacity(cameraManager.isRecording ? 0.4 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.3), value: cameraManager.isRecording)
            }

            // 2. Black container expanding from top cutout area
            GeometryReader { geo in
                let cfg = CutoutLayoutConfig.current(
                    for: DeviceDetectionService.shared.cutoutType,
                    screenWidth: geo.size.width,
                    safeAreaTop: geo.safeAreaInsets.top
                )

                let safeTop = geo.safeAreaInsets.top
                let collapsedHeight = max(1, safeTop - cfg.topPadding)
                let wbwContentHeight: CGFloat = fontSize + 4 + 10
                let classicContentHeight: CGFloat = 28 * 3 + 10
                let contentHeight = isClassicMode ? classicContentHeight : wbwContentHeight
                let expandedContentHeight = collapsedHeight + contentHeight
                let expandedWidth = geo.size.width * 0.65

                let minOffset: CGFloat = 0
                let diCoverLimit = (expandedWidth - cfg.collapsedWidth) / 2 - 16
                let edgeLimit = (geo.size.width - expandedWidth) / 2 - 16
                let maxOffset = max(0, min(diCoverLimit, edgeLimit))

                let displayX: CGFloat = {
                    guard cfg.dragEnabled else { return 0 }
                    let rawX = CGFloat(savedOffsetX) + dragOffsetX
                    if rawX < minOffset {
                        return minOffset + (rawX - minOffset) * 0.05
                    } else if rawX > maxOffset {
                        return maxOffset + (rawX - maxOffset) * 0.05
                    }
                    return rawX
                }()

                let textDisplayY: CGFloat = {
                    let rawY = CGFloat(textVerticalOffset) + textDragY
                    let minY: CGFloat = -15
                    let maxY: CGFloat = 20
                    if rawY < minY { return minY + (rawY - minY) * 0.05 }
                    if rawY > maxY { return maxY + (rawY - maxY) * 0.05 }
                    return rawY
                }()

                VStack(spacing: 8) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: cfg.topCornerRadius,
                        bottomLeadingRadius: cfg.bottomCornerRadius,
                        bottomTrailingRadius: cfg.bottomCornerRadius,
                        topTrailingRadius: cfg.topCornerRadius,
                        style: .continuous
                    )
                        .fill(Color.black)
                        .frame(
                            width: isExpanded ? expandedWidth : cfg.collapsedWidth,
                            height: isExpanded ? expandedContentHeight : 0
                        )
                        .opacity(isExpanded ? 1 : 0)
                        .overlay(alignment: .top) {
                            if showTextContent {
                                wordDisplay
                                    .frame(width: expandedWidth - 32)
                                    .padding(.top, cfg.textTopOffset)
                                    .offset(y: textDisplayY)
                                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
                            }
                        }
                        .clipped()
                        .overlay(alignment: .topTrailing) {
                            if isExpanded {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        displayMode = isClassicMode ? "wbw" : "classic"
                                    }
                                } label: {
                                    Image(systemName: isClassicMode ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 44, height: 44)
                                }
                            }
                        }
                        .scaleEffect(isDragging || isTextEditMode ? 1.02 : 1.0)
                        .overlay(
                            UnevenRoundedRectangle(
                                topLeadingRadius: cfg.topCornerRadius,
                                bottomLeadingRadius: cfg.bottomCornerRadius,
                                bottomTrailingRadius: cfg.bottomCornerRadius,
                                topTrailingRadius: cfg.topCornerRadius,
                                style: .continuous
                            )
                            .strokeBorder(.white.opacity(isTextEditMode ? 0.2 : 0), lineWidth: 1)
                        )
                        .offset(x: isExpanded ? displayX : 0)
                        .gesture(
                            isExpanded && cfg.dragEnabled ?
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    isDragging = true
                                    dragOffsetX = value.translation.width
                                }
                                .onEnded { value in
                                    let raw = CGFloat(savedOffsetX) + value.translation.width
                                    let clamped = min(max(raw, minOffset), maxOffset)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        savedOffsetX = Double(clamped)
                                        dragOffsetX = 0
                                        isDragging = false
                                    }
                                }
                            : nil
                        )
                        // Long press + vertical drag = text offset inside container
                        .simultaneousGesture(
                            isExpanded ?
                            LongPressGesture(minimumDuration: 0.5)
                                .sequenced(before: DragGesture())
                                .onChanged { value in
                                    switch value {
                                    case .second(true, let drag):
                                        if !isTextEditMode {
                                            isTextEditMode = true
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        }
                                        if let drag {
                                            textDragY = drag.translation.height
                                        }
                                    default:
                                        break
                                    }
                                }
                                .onEnded { _ in
                                    let rawY = CGFloat(textVerticalOffset) + textDragY
                                    let clampedY = min(max(rawY, -15), 20)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        textVerticalOffset = Double(clampedY)
                                        textDragY = 0
                                        isTextEditMode = false
                                    }
                                }
                            : nil
                        )
                        // Double tap = reset text and container position
                        .simultaneousGesture(
                            isExpanded ?
                            TapGesture(count: 2)
                                .onEnded {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        savedOffsetX = cfg.defaultOffset
                                        textVerticalOffset = 0
                                        textDragY = 0
                                        dragOffsetX = 0
                                    }
                                }
                            : nil
                        )

                    // Recording timer — follows the container horizontally
                    if cameraManager.isRecording {
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
                        .offset(x: isExpanded ? displayX : 0)
                    }

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, cfg.topPadding)
                .ignoresSafeArea(edges: .top)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: displayMode)
                .animation(.interactiveSpring(), value: isDragging)
                .animation(.interactiveSpring(), value: isTextEditMode)
            }

            // 3. Controls — always visible
            VStack {
                Spacer()
                controlsOverlay
            }

            // 4. Countdown
            if isCountingDown {
                countdownOverlay
            }

            // 5. Audio route change toast
            if let audioToast = cameraManager.audioRouteToast {
                VStack {
                    Text(audioToast)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                }
                .padding(.top, 80)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation { cameraManager.audioRouteToast = nil }
                    }
                }
            }

            // 6. Toast
            if showSavedToast {
                VStack {
                    Text("recording.toast.saved", comment: "Toast shown after a recording is auto-saved when the app goes to background")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                }
                .padding(.top, 80)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { showSavedToast = false }
                    }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            player.loadScript(script.content)
            player.sliderValue = speedSlider
            cameraManager.start(position: .front)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeIn(duration: 0.15)) {
                        showTextContent = true
                    }
                }
            }
            if !hasSeenRecordingTip {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showRecordingTip = true
                }
            }
        }
        .alert(
            Text("common.tip.title", comment: "First-run tip alert title on the recording screen"),
            isPresented: $showRecordingTip
        ) {
            Button {
                hasSeenRecordingTip = true
            } label: {
                Text("common.tip.gotIt", comment: "Got it button dismissing the recording tip")
            }
        } message: {
            Text("recording.tip.body", comment: "First-run tip body explaining how to position the teleprompter text bar")
        }
        .onChange(of: player.currentChunkIndex) { _, newIndex in
            guard newIndex < player.chunks.count, player.isPlaying else { return }
            animateProgressForChunk(at: newIndex)
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing && player.currentChunkIndex < player.chunks.count {
                animateProgressForChunk(at: player.currentChunkIndex)
            }
        }
        .onChange(of: speedSlider) { _, newVal in
            player.sliderValue = newVal
        }
        .onChange(of: exposureCompensation) { _, newVal in
            cameraManager.setExposureCompensation(Float(newVal))
        }
        .onChange(of: cameraManager.isRecording) { _, recording in
            if recording {
                withAnimation(.spring(duration: 0.25)) { showCameraSettings = false }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            player.pause()
            cameraManager.stopRecording()
            cameraManager.stop()
            showTextContent = false
            isExpanded = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background || newPhase == .inactive else { return }
            if cameraManager.isRecording {
                cameraManager.saveDirectlyOnStop = true
                cameraManager.stopRecording()
                player.pause()
                smoothProgress = 0
                showSavedToast = true
            }
            cameraManager.stop()
            dismiss()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onChange(of: cameraManager.lastRecordedURL) { _, url in
            guard let url else { return }
            cameraManager.lastRecordedURL = nil
            previewVideo = IdentifiableURL(url: url)
        }
        .fullScreenCover(item: $previewVideo) { item in
            VideoPreviewView(
                videoURL: item.url,
                onRetake: {
                    previewVideo = nil
                    resetDisplay()
                },
                onSaved: {
                    previewVideo = nil
                    resetDisplay()
                    showSavedToast = true
                }
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(source: "record_button", onPurchaseSuccess: {
                startCountdown()
            })
        }
        .alert(
            Text("recording.error.title", comment: "Title of the camera error alert on the recording screen"),
            isPresented: .constant(cameraManager.errorMessage != nil)
        ) {
            Button {
                cameraManager.errorMessage = nil
            } label: {
                Text("common.ok", comment: "OK button on the camera error alert")
            }
        } message: {
            Text(cameraManager.errorMessage ?? "")
        }
    }

    // MARK: - Word display area

    private var wordDisplay: some View {
        Group {
            if hasStartedPlayback && player.isReady {
                if isClassicMode {
                    ClassicThreeLineView(player: player)
                } else {
                    WordByWordView(player: player, fontSize: fontSize)
                }
            } else {
                PlaceholderLoopView(fontSize: fontSize, isClassicMode: isClassicMode)
            }
        }
    }

    // MARK: - Scrubable progress bar

    private var scrubBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
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
                            wasPlayingBeforeScrub = player.isPlaying
                            player.pause()
                        }
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let index = min(player.chunks.count - 1, Int(fraction * Double(player.chunks.count)))
                        guard index >= 0 else { return }
                        player.seekTo(index: index)
                        withAnimation(.none) {
                            smoothProgress = Double(index) / Double(max(1, player.chunks.count))
                        }
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let index = min(player.chunks.count - 1, Int(fraction * Double(player.chunks.count)))
                        guard index >= 0 else { return }
                        player.seekTo(index: index)
                        smoothProgress = Double(index) / Double(max(1, player.chunks.count))
                        isScrubbing = false
                        if wasPlayingBeforeScrub {
                            player.play()
                        }
                    }
            )
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
    }

    private func animateProgressForChunk(at index: Int) {
        guard !player.chunks.isEmpty, !isScrubbing else { return }
        let target = Double(index + 1) / Double(player.chunks.count)
        let duration = player.chunkDuration(player.chunks[index])
        withAnimation(.linear(duration: duration)) {
            smoothProgress = target
        }
    }

    // MARK: - Controls overlay

    private var controlsOverlay: some View {
        VStack(spacing: 16) {
            if !cameraManager.isRecording {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            showCameraSettings.toggle()
                        }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                }
                .padding(.horizontal, 20)
            }

            // Audio source + video quality indicators
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                    Text(cameraManager.isAudioReady
                        ? cameraManager.audioSourceName
                        : String(localized: "recording.audio.connecting", defaultValue: "Connecting audio...", comment: "Status until the audio session has fully connected"))
                        .font(.caption2)
                }
                Text("·")
                    .font(.caption2)
                Text("\(videoResolution == "4k" ? "4K" : "1080p") · \(videoFPS)fps")
                    .font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.5))

            // Camera settings panel
            if showCameraSettings {
                VStack(spacing: 12) {
                    // Exposure
                    HStack {
                        Text("camera.exposure.label", comment: "Label for the exposure compensation slider")
                            .font(.caption)
                            .foregroundStyle(.white)
                        Slider(value: $exposureCompensation, in: -2...2, step: 0.1)
                            .tint(.orange)
                        Text(String(format: "%+.1f EV", exposureCompensation))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 55, alignment: .trailing)
                    }

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $speedSlider, in: 0...1)
                    .tint(.orange)
                Image(systemName: "hare.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 24)

            scrubBar

            HStack(spacing: 48) {
                Button { togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!player.isReady)

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
        guard player.isReady else { return }
        if !hasStartedPlayback { hasStartedPlayback = true }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func resetDisplay() {
        player.reset()
        smoothProgress = 0
    }

    // MARK: - Recording control

    private func toggleRecording() {
        if cameraManager.isRecording {
            cameraManager.stopRecording()
            player.pause()
            // Stay on current chunk — do not reset
        } else {
            guard SubscriptionManager.shared.canRecord else {
                showPaywall = true
                return
            }
            startCountdown()
        }
    }

    private func startCountdown() {
        // Show real chunks statically during countdown (no advancement)
        player.reset()
        smoothProgress = 0
        hasStartedPlayback = true
        // Player stays paused — chunks visible but frozen

        countdownValue = countdownSeconds
        isCountingDown = true

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] t in
            MainActor.assumeIsolated {
                if countdownValue > 1 {
                    withAnimation { countdownValue -= 1 }
                } else {
                    t.invalidate()
                    countdownTimer = nil
                    isCountingDown = false
                    cameraManager.startRecording()
                    if autoStartPrompting {
                        player.play()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func durationString(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
