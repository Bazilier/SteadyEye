import SwiftUI
import SwiftData
import AVFoundation
import UserNotifications

private struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive())
        } else {
            content
                .background(Color.white.opacity(0.2))
                .clipShape(Circle())
        }
    }
}

struct RecordingView: View {
    let script: Script
    /// Bound to ContentView's tab selection — toast CTAs from the tappable
    /// HUD indicators write `.settings` here and then dismiss this cover, so
    /// the user lands on the Settings tab when the modal stack collapses.
    @Binding var selectedTab: AppTab

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var cameraManager = CameraManager.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var player = ChunkPlayerEngine()
    /// Follow My Voice V2 toggle. iOS 26+ feature; on older OS the
    /// SettingsView toggle isn't shown so the value stays false.
    @AppStorage("fmv_enabled") private var fmvEnabled: Bool = false
    /// V2 service instance held as `AnyObject` so this file doesn't
    /// have to be `@available(iOS 26.0, *)`-gated. Cast to
    /// `FollowMyVoiceServiceV2` inside `#available` blocks.
    @State private var fmvService: AnyObject? = nil
    /// User's pre-FMV slider position. Captured at FMV start, restored
    /// at FMV stop. While non-nil, FMV's multiplier modulates the
    /// visible thumb position via `FMVSliderSync` while
    /// `player.sliderValue` stays held at this baseline (so the
    /// engine's internal `base / multiplier` math doesn't double-apply).
    @State private var fmvBaselineSlider: Double? = nil
    @State private var showSavedToast = false
    @State private var showAudioToast = false
    @State private var showResolutionToast = false
    @State private var previewRecording: Recording?
    @State private var isProcessingRecording: Bool = false
    @AppStorage("hasCompletedFirstRecording") private var hasCompletedFirstRecording = false
    @State private var showPaywall: Bool = false
    @State private var showMicPermissionAlert: Bool = false
    @State private var cameraAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micAuthStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    @State private var showFirstRecordingPaywall: Bool = false
    @AppStorage("postFirstRecordingPaywallShown") private var postFirstRecordingPaywallShown: Bool = false
    /// First-run explainer for the long-press-and-drag gesture that
    /// repositions the prompter text vertically against the camera lens.
    /// One-shot per install. Suppressed for demo-script mounts (which
    /// covers the post-onboarding auto-open path — `pendingDemoRecording`
    /// is consumed in ScriptListView before this view mounts, so
    /// `script.isDemo` is the only signal that survives down here).
    @AppStorage("hasSeenCameraExplainer") private var hasSeenCameraExplainer: Bool = false
    @State private var showCameraExplainer: Bool = false

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
        cameraContentOrPermission
    }

    // MARK: - Camera content

    /// Top-level view: either the camera ZStack (authorized) or the
    /// permission empty-state. All lifecycle and presentation modifiers
    /// live here so `body` stays within the type-checker's budget.
    private var cameraContentOrPermission: some View {
        Group {
            if cameraAuthStatus == .authorized {
                cameraZStack
            } else {
                permissionEmptyState
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isProcessingRecording)
        .onAppear {
            AppAnalytics.log("recording_view_opened", params: [
                "display_mode": displayMode,
                "script_source": script.isDemo ? "demo" : "user",
                "script_length_words": script.content.split(separator: " ").count
            ])
            UIApplication.shared.isIdleTimerDisabled = true
            player.loadScript(script.content)
            player.sliderValue = speedSlider
            cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
            micAuthStatus = AVAudioApplication.shared.recordPermission
            if cameraAuthStatus == .authorized {
                cameraManager.start(position: .front)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeIn(duration: 0.15)) {
                        showTextContent = true
                    }
                }
            }
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
            if let baseline = fmvBaselineSlider {
                // FMV is driving the visible thumb. If the new value is
                // far enough off the FMV-implied position
                // (baseline × multiplier), the user dragged manually:
                // recompute baseline so future FMV updates modulate
                // around the new set point, and mirror to
                // player.sliderValue so engine pace tracks the drag.
                if #available(iOS 26.0, *), let service = fmvService as? FollowMyVoiceServiceV2 {
                    let mult = max(service.currentMultiplier, 0.01)
                    let expected = max(0, min(1, baseline * mult))
                    if abs(newVal - expected) > 0.02 {
                        let newBaseline = max(0, min(1, newVal / mult))
                        fmvBaselineSlider = newBaseline
                        player.sliderValue = newBaseline
                    }
                }
                return
            }
            player.sliderValue = newVal
        }
        .onChange(of: exposureCompensation) { _, newVal in
            cameraManager.setExposureCompensation(Float(newVal))
        }
        .onChange(of: cameraManager.isRecording) { _, recording in
            if recording {
                withAnimation(.spring(duration: 0.25)) { showCameraSettings = false }
                startFMVIfEnabled()
            } else {
                stopFMV()
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
        .onChange(of: cameraManager.lastRecordedURL) { _, url in
            guard let url else { return }
            cameraManager.lastRecordedURL = nil
            handleRecordingFinished(sourceURL: url)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .withRecordingToasts(
            showAudioToast: $showAudioToast,
            showResolutionToast: $showResolutionToast,
            onOpenSettings: { selectedTab = .settings; dismiss() }
        )
        .fullScreenCover(item: $previewRecording) { recording in
            VideoPreviewView(recording: recording, onDismiss: {
                previewRecording = nil
                resetDisplay()
                // Read UserDefaults directly here rather than the @AppStorage
                // wrapper to avoid the stale-capture bug that caused the paywall
                // to fire twice in testing.
                let alreadyShown = UserDefaults.standard.bool(forKey: "postFirstRecordingPaywallShown")
                if !alreadyShown && !subscriptionManager.isSubscribed {
                    UserDefaults.standard.set(true, forKey: "postFirstRecordingPaywallShown")
                    postFirstRecordingPaywallShown = true
                    showFirstRecordingPaywall = true
                }
            })
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(source: "record_button", onPurchaseSuccess: { startCountdown() })
        }
        .fullScreenCover(isPresented: $showFirstRecordingPaywall) {
            PaywallView(source: "first_recording")
        }
        .alert(
            Text("recording.error.title", comment: "Title of the camera error alert on the recording screen"),
            isPresented: .constant(cameraManager.errorMessage != nil)
        ) {
            Button { cameraManager.errorMessage = nil } label: {
                Text("common.ok", comment: "OK button on the camera error alert")
            }
        } message: {
            Text(cameraManager.errorMessage ?? "")
        }
        .alert(
            Text("recording.mic_alert.title", comment: "Title of the alert shown when the user taps record but mic permission is denied"),
            isPresented: $showMicPermissionAlert
        ) {
            Button(String(localized: "common.open_settings", defaultValue: "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) { }
        } message: {
            Text("recording.mic_alert.body", comment: "Body of the alert shown when the user taps record but mic permission is denied")
        }
        .overlay {
            if showCameraExplainer {
                ExplainerOverlay(
                    isPresented: $showCameraExplainer,
                    icon: "hand.point.up.left",
                    title: "common.tip.title",
                    message: "scripts.recording.tip.body",
                    buttonLabel: "common.tip.gotIt",
                    onDismiss: { hasSeenCameraExplainer = true }
                )
            }
        }
        .onAppear {
            let wasOnboardingAuto = UserDefaults.standard.bool(forKey: "nextRecordingIsOnboardingAuto")
            if wasOnboardingAuto {
                UserDefaults.standard.set(false, forKey: "nextRecordingIsOnboardingAuto")
            }
            guard cameraAuthStatus == .authorized,
                  !wasOnboardingAuto,
                  !hasSeenCameraExplainer
            else { return }
            showCameraExplainer = true
        }
    }

    // MARK: - Camera ZStack

    /// The layers stacked over the camera preview when permission is granted.
    @ViewBuilder
    private var cameraZStack: some View {
        ZStack {
            // 1. Camera preview
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            // 1b. Dim overlay during recording / countdown
            if dimDuringRecording {
                Color.black
                    .opacity((isCountingDown || cameraManager.isRecording) ? 0.4 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.3), value: cameraManager.isRecording)
            }

            // 2. Black container expanding from top cutout area
            prompterContainerPanel

            // 2b. Top-leading close button
            if !cameraManager.isRecording {
                closeButton
                    .transition(.opacity)
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

            // 6. Saved toast
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

            // 7. Processing overlay
            if isProcessingRecording {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                        Text(String(
                            localized: "recording.processing",
                            defaultValue: "Saving recording…",
                            comment: "Overlay message shown while a just-finished recording is being watermarked, persisted, and indexed."
                        ))
                        .font(.body)
                        .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Prompter container panel

    /// The black pill/rectangle that expands from the top cutout area,
    /// showing the teleprompter text and the recording-timer badge.
    private var prompterContainerPanel: some View {
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
            let expandedWidth = geo.size.width * 0.75

            let textDisplayY: CGFloat = {
                let rawY = CGFloat(textVerticalOffset) + textDragY
                let minY: CGFloat = -15
                let maxY: CGFloat = 20
                if rawY < minY { return minY + (rawY - minY) * 0.05 }
                if rawY > maxY { return maxY + (rawY - maxY) * 0.05 }
                return rawY
            }()

            VStack(spacing: 8) {
                prompterPill(cfg: cfg, expandedWidth: expandedWidth, expandedContentHeight: expandedContentHeight, textDisplayY: textDisplayY)

                // Recording timer — follows the container horizontally.
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
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: cfg.isCameraOffset ? .topTrailing : .top
            )
            .padding(.trailing, cfg.isCameraOffset ? 8 : 0)
            .padding(.top, cfg.topPadding)
            .ignoresSafeArea(edges: .top)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: displayMode)
            .animation(.interactiveSpring(), value: isDragging)
            .animation(.interactiveSpring(), value: isTextEditMode)
        }
    }

    /// The black pill shape itself (extracted so `prompterContainerPanel`
    /// stays within the type-checker's complexity budget).
    @ViewBuilder
    private func prompterPill(
        cfg: CutoutLayoutConfig,
        expandedWidth: CGFloat,
        expandedContentHeight: CGFloat,
        textDisplayY: CGFloat
    ) -> some View {
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
                        textVerticalOffset = 0
                        textDragY = 0
                    }
                }
            : nil
        )
    }

    // MARK: - Close button

    /// Top-leading back chevron. Visible only when not recording.
    /// Sized + offset slightly tighter on SE-class devices because the
    /// centered WBW container leaves less horizontal clearance there (~47pt)
    /// than on notch/Dynamic Island layouts (~90pt).
    private var closeButton: some View {
        GeometryReader { geo in
            let cfg = CutoutLayoutConfig.current(
                for: DeviceDetectionService.shared.cutoutType,
                screenWidth: geo.size.width,
                safeAreaTop: geo.safeAreaInsets.top
            )
            let isCameraOffset = cfg.isCameraOffset
            let closeBtnSize: CGFloat = isCameraOffset ? 42 : 32
            let closeBtnLeading: CGFloat = isCameraOffset ? 12 : 8

            // Mirror block 2's container-height derivation so the
            // close button center stays glued to the container's
            // vertical midpoint regardless of device class.
            let safeTop = geo.safeAreaInsets.top
            let collapsedHeight = max(1, safeTop - cfg.topPadding)
            let wbwContentHeight: CGFloat = fontSize + 4 + 10
            let containerHeight = collapsedHeight + wbwContentHeight
            let containerVerticalCenter = cfg.topPadding + (containerHeight / 2)
            let closeBtnTopPadding = max(0, containerVerticalCenter - (closeBtnSize / 2))

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: closeBtnSize, height: closeBtnSize)
                            .modifier(GlassCircleModifier())
                            .clipShape(Circle())
                    }
                    .padding(.leading, closeBtnLeading)
                    .padding(.top, closeBtnTopPadding)
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Permission empty state

    private var permissionEmptyState: some View {
        let bothDenied = cameraAuthStatus != .authorized && micAuthStatus != .granted
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0, green: 0, blue: 0),
                         Color(red: 0.1, green: 0.04, blue: 0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.6))
                Text("recording.permission.title", comment: "Title of the inline empty state shown when camera permission is denied in the recording view")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text(bothDenied
                     ? String(localized: "recording.permission.body_both", defaultValue: "SteadyEye needs camera and microphone access to record your videos. Enable both in iOS Settings.")
                     : String(localized: "recording.permission.body_camera", defaultValue: "SteadyEye needs camera access to record your videos. Enable it in iOS Settings."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                Spacer().frame(height: 24)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(String(localized: "common.open_settings", defaultValue: "Open Settings"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: Capsule())
                }
                .padding(.horizontal, 24)
                Button(String(localized: "recording.permission.go_back", defaultValue: "Go back")) {
                    dismiss()
                }
                .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
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

    // MARK: - Follow My Voice V2 lifecycle

    /// Spin up V2 if the user has the toggle on AND is subscribed AND
    /// is on iOS 26+. The view-level `if #available` block guards the
    /// type reference; on iOS 18 the call is a no-op.
    private func startFMVIfEnabled() {
        guard fmvEnabled, subscriptionManager.isSubscribed else { return }
        if #available(iOS 26.0, *) {
            let service = FollowMyVoiceServiceV2(engine: player, cameraManager: cameraManager)
            self.fmvService = service
            // Capture user's slider position before FMV starts
            // modulating the thumb. Restored verbatim in stopFMV().
            self.fmvBaselineSlider = speedSlider
            let scriptText = script.content
            Task { @MainActor in
                do {
                    try await service.start(scriptText: scriptText)
                    AppAnalytics.log("follow_my_voice_v2_started", params: nil)
                } catch {
                    print("[FMV2] start failed: \(error)")
                    self.fmvService = nil
                    self.fmvBaselineSlider = nil
                    AppAnalytics.log("follow_my_voice_v2_unavailable", params: [
                        "reason": String(describing: error)
                    ])
                }
            }
        }
    }

    private func stopFMV() {
        guard fmvService != nil else { return }
        if #available(iOS 26.0, *), let v2 = fmvService as? FollowMyVoiceServiceV2 {
            Task { @MainActor in
                await v2.stop()
            }
        }
        // Clear baseline FIRST so the speedSlider write below takes the
        // non-FMV branch in the onChange watcher and mirrors back to
        // `player.sliderValue`. Otherwise the slider would visually
        // restore but the engine would keep playing at the held value.
        let baseline = fmvBaselineSlider
        fmvBaselineSlider = nil
        fmvService = nil
        if let baseline {
            speedSlider = baseline
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
        let duration = player.chunkDuration(at: index)
        withAnimation(.linear(duration: duration)) {
            smoothProgress = target
        }
    }

    // MARK: - Controls overlay

    private var controlsOverlay: some View {
        VStack(spacing: 16) {
            if !cameraManager.isRecording {
                HStack {
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

            // Audio source + video quality indicators. Both are tappable
            // discovery affordances: the audio side opens an "audio source
            // can be changed in Settings" toast with an Open Settings CTA;
            // the resolution side does the same for video quality. The
            // indicators were previously decorative-only — users reached
            // for them and nothing happened.
            HStack(spacing: 12) {
                Button {
                    showAudioToast = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10))
                        Text(cameraManager.audioSourceName)
                            .font(.caption2)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Button {
                    showResolutionToast = true
                } label: {
                    Text("\(videoResolution == "4k" && subscriptionManager.canRecord4K ? "4K" : "1080p") · \(videoFPS)fps")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

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
                    .animation(.easeInOut(duration: 0.5), value: player.externalSpeedMultiplier)
                Image(systemName: "hare.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .background {
                // Invisible bridge: when FMV V2 is running with a
                // captured baseline, FMVSliderSync observes the service
                // and writes `baseline × currentMultiplier` back into
                // $speedSlider whenever the step commits. The
                // .background attachment keeps the bridge bound to the
                // slider's lifecycle without touching layout.
                if #available(iOS 26.0, *),
                   let service = fmvService as? FollowMyVoiceServiceV2,
                   let baseline = fmvBaselineSlider {
                    FMVSliderSync(service: service, slider: $speedSlider, baseline: baseline)
                }
            }

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
            let isDemoScript = script.isDemo
            let canRecord = isDemoScript || SubscriptionManager.shared.canRecord
            guard canRecord else {
                showPaywall = true
                return
            }
            if AVAudioApplication.shared.recordPermission != .granted {
                showMicPermissionAlert = true
                return
            }
            if isDemoScript && !SubscriptionManager.shared.isSubscribed {
                AppAnalytics.log("recording_demo_bypass", params: [
                    "script_length_words": script.content.split(separator: " ").count
                ])
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
                    AppAnalytics.log("recording_started", params: [
                        "display_mode": displayMode,
                        "script_length_words": script.content.split(separator: " ").count
                    ])
                    if autoStartPrompting {
                        player.play()
                    }
                }
            }
        }
    }

    // MARK: - Auto-save flow

    /// Persist the just-finished recording (watermark + move + thumbnail +
    /// SwiftData entity) before presenting the preview view. Fires the
    /// `recording_saved` analytics event with `via: "auto_persist"` and the
    /// existing `first_recording_completed` Firebase + Meta events on the
    /// first-ever save.
    private func handleRecordingFinished(sourceURL: URL) {
        let duration = cameraManager.lastRecordingDuration
        let scriptTitle = script.title
        isProcessingRecording = true

        RecordingPersistence.persist(
            sourceURL: sourceURL,
            scriptTitle: scriptTitle,
            duration: duration,
            modelContext: modelContext
        ) { result in
            isProcessingRecording = false
            switch result {
            case .success(let recording):
                let wasFirst = !hasCompletedFirstRecording
                AppAnalytics.log("recording_saved", params: [
                    "duration_sec": Int(duration.rounded()),
                    "was_first": wasFirst,
                    "via": "auto_persist"
                ])
                if wasFirst {
                    hasCompletedFirstRecording = true
                    #if !DEV
                    MetaAnalytics.logFirstRecordingCompleted()
                    #endif
                    AppAnalytics.log("first_recording_completed", params: [
                        "duration_sec": Int(duration.rounded())
                    ])
                }
                previewRecording = recording
            case .failure:
                // Auto-save failed entirely (file move error, generator error,
                // etc.). Don't present the preview — clean up the temp source
                // file so it doesn't leak. The user can retake the clip.
                try? FileManager.default.removeItem(at: sourceURL)
                resetDisplay()
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
// MARK: - Recording toasts modifier

private struct RecordingToastsModifier: ViewModifier {
    @Binding var showAudioToast: Bool
    @Binding var showResolutionToast: Bool
    var onOpenSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .toast(
                isPresented: $showAudioToast,
                message: String(
                    localized: "hud.changeInSettings",
                    defaultValue: "Change in Settings",
                    comment: "Short imperative shown in the recording-HUD discovery toasts (mic indicator + resolution label). Paired with an Open Settings CTA."
                ),
                style: .info,
                duration: 5,
                actionLabel: String(
                    localized: "recording.hud.openSettings",
                    defaultValue: "Open Settings",
                    comment: "Button label inside the recording-HUD discovery toasts (audio + resolution) that switches the app to the Settings tab."
                ),
                action: onOpenSettings
            )
            .toast(
                isPresented: $showResolutionToast,
                message: String(
                    localized: "hud.changeInSettings",
                    defaultValue: "Change in Settings",
                    comment: "Same key as the audio-toast message; reused here for the resolution toast since the imperative is identical."
                ),
                style: .info,
                duration: 5,
                actionLabel: String(
                    localized: "recording.hud.openSettings",
                    defaultValue: "Open Settings",
                    comment: "Same key as the audio-toast action; reused here for the resolution toast since the action is identical."
                ),
                action: onOpenSettings
            )
    }
}

private extension View {
    func withRecordingToasts(
        showAudioToast: Binding<Bool>,
        showResolutionToast: Binding<Bool>,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        modifier(RecordingToastsModifier(
            showAudioToast: showAudioToast,
            showResolutionToast: showResolutionToast,
            onOpenSettings: onOpenSettings
        ))
    }
}

