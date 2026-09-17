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
    /// First-run explainer for the long-press-and-drag gesture that
    /// repositions the prompter text vertically against the camera lens.
    /// One-shot per install. Suppressed for demo-script mounts (which
    /// covers the post-onboarding auto-open path — `pendingDemoRecording`
    /// is consumed in ScriptListView before this view mounts, so
    /// `script.isDemo` is the only signal that survives down here).
    @AppStorage("hasSeenCameraExplainer") private var hasSeenCameraExplainer: Bool = false
    @State private var showCameraExplainer: Bool = false

    /// Orientation this screen renders in, read ONCE when the view is first
    /// created so the very first frame is already correct: the user opens the
    /// recording screen and sees a landscape layout immediately, with no
    /// transitional portrait frame and no dependency on the accelerometer.
    ///
    /// Mirrors the capture side, which reads the mode at `setupSession` and
    /// freezes it for the session. `@State`'s initial value is used only on
    /// first mount, so a Settings change cannot re-render an open screen.
    @State private var layoutOrientation: RecordingOrientation = RecordingOrientation.current()
    private var isLandscape: Bool { layoutOrientation == .landscape }

    /// Landscape panel long axis, as a fraction of screen HEIGHT.
    ///
    /// The interface stays portrait-locked, so with the device turned left,
    /// view-space +Y points physically right — the direction the reader's eye
    /// travels. The panel's long axis therefore runs along Y, whose extent is
    /// the screen's height; `geo.size.width` measures the wrong axis entirely.
    /// 0.35 of a 932pt device gives ~326pt, matching portrait's
    /// 0.75 x 430 ~= 322pt, so the 3-line mode keeps the line length it was
    /// tuned for instead of collapsing onto its 0.5 scale floor.
    private static let landscapeLongAxisFraction: CGFloat = 0.35

    /// Offset of the landscape panel from the screen's centre line, toward the
    /// lens, on devices whose front camera is off-centre.
    ///
    /// UNVERIFIED — a starting value, not a measurement. The DIRECTION is
    /// derived: in portrait the lens sits right of centre (`cfg.isCameraOffset`
    /// aligns the panel trailing), and turning the device left maps view +X
    /// onto physical up, so the same positive offset carries the panel toward
    /// the lens. The MAGNITUDE is a guess. Replace it from a device
    /// measurement rather than trusting it — geometric reasoning about this
    /// hardware was refuted twice by measurement during the capture work.
    private static let landscapeLensOffset: CGFloat = 24

    /// Layout footprint of the recording timer AFTER its quarter turn.
    ///
    /// `rotationEffect` does not change layout, so the badge is given this
    /// explicit frame: its natural width becomes the height and vice versa,
    /// with slack. The duration string is always `%02d:%02d`, so the badge's
    /// natural size does not vary with elapsed time.
    private static let landscapeBadgeFootprint = CGSize(width: 32, height: 96)

    /// Inset of the landscape close button from the two screen edges that meet
    /// at the user's top-left corner.
    private static let landscapeCloseInset: CGFloat = 16

    /// Floor on the landscape panel's thickness, so the cutout sits entirely
    /// inside the panel instead of protruding past its edge.
    ///
    /// MEASURED, NOT DERIVED — like `landscapeLensOffset`. There is no field in
    /// `CutoutLayoutConfig` that describes the cutout's extent along this axis:
    /// `collapsedWidth` (126) is the collapsed PILL's width, tuned to match the
    /// Dynamic Island, and it carries the same 126 for notch devices whose
    /// notch is far wider — so treating it as the cutout's width would look
    /// principled and be wrong on half the fleet.
    ///
    /// Why a floor is needed at all: in portrait the cutout's WIDTH lies along
    /// the panel's long axis (~322pt) and is swallowed for free. Turned a
    /// quarter turn, that same width lies along the panel's THICKNESS, which
    /// derived to only ~94pt — so the island's lower lobe, the one carrying the
    /// green recording dot, hung outside the panel. The value must also absorb
    /// `landscapeLensOffset`, which moves the panel's centre off the cutout's
    /// centre and so concentrates the whole overhang on one side.
    ///
    /// Raise it if any part of the cutout still shows against the preview.
    private static let landscapeMinThickness: CGFloat = 190

    /// Gap between the record button and the reset/play pair above it.
    ///
    /// Aesthetic, but the resulting footprint is not: the column's physical
    /// VERTICAL extent is 72 (record) + this + 56 (the pair's width) = 148pt,
    /// down from 240pt when the three sat in a line. The column is centred
    /// across view X, so at 240 it reached ~33pt into the bottom bar's
    /// 8–128pt band; at 148 it stops ~13pt clear of it. That is what lets the
    /// two coexist without moving the bar.
    private static let landscapeTransportSpacing: CGFloat = 20

    /// Gap between play and reset within the pair, along the physical
    /// horizontal. Kept tight so the pair reads as one unit above the record
    /// button rather than as two separate controls.
    private static let landscapeTransportPairSpacing: CGFloat = 16

    /// Frame sizes of the transport buttons. Named so `landscapeTransportBalance`
    /// is derived from the real sizes rather than a number that happens to look
    /// right and then drifts when a frame changes.
    private static let recordButtonSize: CGFloat = 72
    private static let transportButtonSize: CGFloat = 56

    /// Padding on the physically LOWER side of the landscape transport group,
    /// making the group symmetric about the record button so that the RECORD
    /// button's centre — not the group's — lands on the screen's vertical
    /// midpoint. Equal to the pair's extent above it: one transport button plus
    /// the gap.
    private static let landscapeTransportBalance: CGFloat =
        transportButtonSize + landscapeTransportSpacing

    /// Horizontal inset shared by the landscape bar's top row and its scrub
    /// bar, so the two span exactly the same extent.
    private static let landscapeBarRowInset: CGFloat = 12

    /// Inset of the landscape transport column from the physical right edge —
    /// which, with the interface portrait-locked, is the view's bottom.
    private static let landscapeTransportInset: CGFloat = 24

    /// Tappable size of the gear in the landscape bar. 44 is the documented
    /// minimum touch target, not a value tuned until taps started landing: the
    /// glyph alone measures ~22x20, which the bar's quarter turn presents as a
    /// ~20pt band in view x with dead row margin either side of it.
    ///
    /// Landscape only. Portrait shares `settingsGearButton`, and framing it
    /// there would grow portrait's row by the same amount.
    private static let landscapeGearHitTarget: CGFloat = 44

    /// Height of the scrub bar, and therefore of the landscape bar's lower
    /// slot. ONE constant with two consumers rather than two literals that have
    /// to agree: the slot exists precisely to hold this height constant across
    /// the exposure swap, so a drift between the two would be the very bug it
    /// is there to prevent. Shared with portrait, like the transport sizes.
    private static let scrubBarHeight: CGFloat = 44

    /// Thickness of the landscape bottom bar — how far it reaches up from the
    /// physical bottom edge. Aesthetic, not derived: sized to clear the two
    /// rows (the status/gear/slider row, then the `scrubBarHeight` lower slot)
    /// with slack, since the content is framed to this height rather than
    /// measuring itself.
    ///
    /// CONSTANT, and now trivially so: the gear SWAPS the lower slot's occupant
    /// rather than inserting a third row, so there is nothing to make room for.
    /// An earlier attempt grew this 120 → 184 on disclosure, which looked
    /// reasonable and was wrong — the bar is pinned at the physical bottom edge
    /// and therefore grows AWAY from it, so the growth travelled up through the
    /// content and moved the status row ~66pt, the very row whose gear had just
    /// been tapped, while the scrub bar stayed put.
    private static let landscapeBarThickness: CGFloat = 120
    /// Inset from the physical bottom edge — the view's leading edge.
    private static let landscapeBarInset: CGFloat = 8
    /// Inset at each end of the bar, along the physical horizontal.
    private static let landscapeBarEndInset: CGFloat = 16

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
    /// Landscape keeps its own nudge. In view space the gesture axis is the
    /// same in both orientations, but it means "toward the lens above" in
    /// portrait and "toward the lens on the left" in landscape, against a panel
    /// of different geometry — a value calibrated for one should not silently
    /// become the other's starting point.
    @AppStorage("textLensOffsetLandscape") private var textOffsetLandscape: Double = 0
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true
    @State private var exposureCompensation: Double = 0
    @AppStorage("autoStartPrompting") private var autoStartPrompting: Bool = true
    @State private var showCameraSettings = false

    /// Idle delay before the exposure control hides itself, in both
    /// orientations.
    private static let exposureAutoHideSeconds: TimeInterval = 3
    /// The pending auto-hide. Held so it can be CANCELLED rather than left to
    /// fire and be ignored — a timer outliving its panel, or its view, is the
    /// failure this exists to avoid.
    @State private var exposureAutoHideTask: Task<Void, Never>?

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
            // Dragging the slider is the one interaction that restarts the
            // countdown. Guarded so a programmatic change cannot resurrect a
            // timer for a panel that is not open.
            if showCameraSettings { scheduleExposureAutoHide() }
        }
        // Single choke point for the timer's lifetime. Every route that opens
        // or closes the panel — the gear, the recording side effect below, the
        // auto-hide itself — passes through this one `onChange`, so no call
        // site has to remember to cancel and none can be missed.
        .onChange(of: showCameraSettings) { _, isOpen in
            if isOpen {
                scheduleExposureAutoHide()
            } else {
                cancelExposureAutoHide()
            }
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
            // Teardown: `showCameraSettings` is not reset here, so the
            // `onChange` choke point never fires on dismissal. Cancel directly
            // or a pending task outlives the view.
            cancelExposureAutoHide()
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
            }, shouldShowPaywallAfterSave: {
                // First successful Camera Roll save of a user-written script
                // (not the onboarding demo, not an app-provided sample), once
                // per install. Reads UserDefaults directly rather than through
                // an @AppStorage wrapper to avoid a stale captured value.
                !script.isDemo
                    && !script.isSample
                    && !subscriptionManager.isSubscribed
                    && !UserDefaults.standard.bool(forKey: "postFirstOwnRecordingPaywallShown")
            })
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(source: "record_button", onPurchaseSuccess: { startCountdown() })
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
            // 1. Camera preview. Kept mounted and fed at all times — the opacity
            // is a presentation gate only, so the session, `startRunning` and the
            // landscape pin are unaffected. Portrait reveals immediately;
            // landscape waits for the angle to be pinned so the first thing the
            // user sees is already landscape.
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()
                .opacity(cameraManager.isPreviewRevealed ? 1 : 0)

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

            // 3. Controls. Portrait keeps one stack at the bottom; landscape
            // splits it into the bottom bar here and the transport column (3b).
            if isLandscape {
                landscapeBottomBar
            } else {
                VStack {
                    Spacer()
                    controlsOverlay
                }
            }

            // 3b. Landscape transport column — the same three buttons against
            // the physical right edge. Layered after the controls so its hit
            // areas win where the two still overlap, which they do until the
            // bottom bar moves in the next step.
            if isLandscape {
                landscapeTransportColumn
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

    // MARK: - Shared panel geometry

    /// Geometry for the prompter panel, derived once per layout pass and shared
    /// with the close button. Both used to compute this independently, so
    /// moving one silently stranded the other at a phantom position.
    ///
    /// Axis names are deliberately orientation-neutral. In portrait the long
    /// axis runs along view X and the thickness along view Y; in landscape they
    /// swap, because the panel is rotated a quarter turn relative to the
    /// portrait-locked interface.
    private struct PrompterGeometry {
        let cfg: CutoutLayoutConfig
        /// The cutout band: the panel's leading edge to the safe-area boundary.
        let collapsedExtent: CGFloat
        /// Content extent for the CURRENT display mode, along the short axis.
        let contentExtent: CGFloat
        /// Content extent for word-by-word, used for the close button's anchor
        /// in BOTH modes so the button does not jump when the mode is toggled.
        /// That was the existing behaviour and is preserved exactly.
        let anchorContentExtent: CGFloat
        /// The long axis — the direction the text reads.
        let longAxis: CGFloat
        /// Floor on the short axis, so landscape can be forced wide enough to
        /// swallow the cutout. Zero in portrait, which leaves `thickness`
        /// exactly what it was.
        let minThickness: CGFloat

        /// Short axis before any floor: cutout band plus content.
        var naturalThickness: CGFloat { collapsedExtent + contentExtent }
        /// Short axis, never less than `minThickness`.
        var thickness: CGFloat { max(naturalThickness, minThickness) }
        /// Centre the close button aligns to, measured from the screen edge.
        var anchorCentre: CGFloat {
            cfg.topPadding + (collapsedExtent + anchorContentExtent) / 2
        }
    }

    private func prompterGeometry(_ geo: GeometryProxy) -> PrompterGeometry {
        let cfg = CutoutLayoutConfig.current(
            for: DeviceDetectionService.shared.cutoutType,
            screenWidth: geo.size.width,
            safeAreaTop: geo.safeAreaInsets.top
        )
        let wbwContentHeight: CGFloat = fontSize + 4 + 10
        let classicContentHeight: CGFloat = 28 * 3 + 10
        return PrompterGeometry(
            cfg: cfg,
            collapsedExtent: max(1, geo.safeAreaInsets.top - cfg.topPadding),
            contentExtent: isClassicMode ? classicContentHeight : wbwContentHeight,
            anchorContentExtent: wbwContentHeight,
            longAxis: isLandscape
                ? geo.size.height * Self.landscapeLongAxisFraction
                : geo.size.width * 0.75,
            minThickness: isLandscape ? Self.landscapeMinThickness : 0
        )
    }

    /// The persisted nudge for the current layout, with the same rubber-banding
    /// past the limits as before. The axis is view-space Y in both
    /// orientations — what changes is what that means physically: nearer to or
    /// further from the lens above (portrait) or on the left (landscape).
    private var lensNudge: CGFloat {
        let stored = isLandscape ? textOffsetLandscape : textVerticalOffset
        let rawY = CGFloat(stored) + textDragY
        let minY: CGFloat = -15
        let maxY: CGFloat = 20
        if rawY < minY { return minY + (rawY - minY) * 0.05 }
        if rawY > maxY { return maxY + (rawY - maxY) * 0.05 }
        return rawY
    }

    // MARK: - Prompter container panel

    /// The black pill/rectangle that expands from the cutout area, showing the
    /// teleprompter text and the recording-timer badge.
    private var prompterContainerPanel: some View {
        GeometryReader { geo in
            let g = prompterGeometry(geo)
            Group {
                if isLandscape {
                    landscapePanelStack(g)
                } else {
                    portraitPanelStack(g)
                }
            }
            .ignoresSafeArea(edges: .top)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: displayMode)
            .animation(.interactiveSpring(), value: isDragging)
            .animation(.interactiveSpring(), value: isTextEditMode)
        }
    }

    /// Unchanged portrait layout: a wide strip under the cutout, trailing-
    /// aligned on devices whose lens is off-centre.
    private func portraitPanelStack(_ g: PrompterGeometry) -> some View {
        VStack(spacing: 8) {
            prompterPill(
                cfg: g.cfg,
                width: isExpanded ? g.longAxis : g.cfg.collapsedWidth,
                height: isExpanded ? g.thickness : 0,
                overlayAlignment: .top
            ) {
                if showTextContent {
                    wordDisplay
                        .frame(width: g.longAxis - 32)
                        .padding(.top, g.cfg.textTopOffset)
                        .offset(y: lensNudge)
                        .transition(.opacity.animation(.easeIn(duration: 0.15)))
                }
            }
            // Recording timer — follows the container horizontally.
            if cameraManager.isRecording { recordingTimerBadge }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: g.cfg.isCameraOffset ? .topTrailing : .top
        )
        .padding(.trailing, g.cfg.isCameraOffset ? 8 : 0)
        .padding(.top, g.cfg.topPadding)
    }

    /// Landscape layout. The interface is portrait-locked, so this is the SAME
    /// panel turned a quarter turn: it still starts at the view's top edge —
    /// which, with the device turned left, is the physical left edge where the
    /// lens sits — but its long axis now runs down view Y (physically
    /// rightward, the reading direction) and its thickness across view X
    /// (physically vertical).
    ///
    /// Centred across X rather than trailing-aligned, then carried toward the
    /// lens by `landscapeLensOffset`.
    private func landscapePanelStack(_ g: PrompterGeometry) -> some View {
        prompterPill(
            cfg: g.cfg,
            width: g.thickness,
            height: isExpanded ? g.longAxis : 0,
            overlayAlignment: .center
        ) {
            if showTextContent {
                // Sized along its own reading direction, THEN turned a
                // quarter turn clockwise so it reads left-to-right for a
                // viewer holding the device in landscape. `rotationEffect`
                // does not change layout, so the frame below is the text's
                // unrotated box and the turn happens about its centre —
                // which is why the overlay is centre-aligned.
                // Centred across the panel's thickness: the overlay is
                // centre-aligned and nothing offsets it on that axis, so the
                // text sits equidistant from both long edges however thick the
                // panel is. `lensNudge` still moves it along the LONG axis —
                // toward or away from the lens — which is a different axis.
                wordDisplay
                    .frame(width: g.longAxis - 32)
                    .rotationEffect(.degrees(90))
                    .offset(y: lensNudge)
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            }
        }
        // Recording timer, immediately alongside the panel and centred on its
        // long axis, mirroring the gap portrait's VStack gives for free.
        //
        // TRAILING, physically ABOVE the panel. `Alignment.trailing` is the
        // large-view-x edge, and view +X is physically up with the device
        // turned left — the same mapping that puts `landscapeBottomBar`, which
        // is pinned at view-LEADING, along the physical bottom. So a positive
        // x offset carries the badge off the panel's upper side. It used to be
        // `.leading` with a negative offset, the mirror image of this, which
        // placed it physically below the panel — directly in the band the
        // bottom bar occupies, over the status line's mic name.
        //
        // An OVERLAY rather than a stack. A stack cannot work here: the badge's
        // unrotated box would reserve its width along the panel's thickness
        // axis, and — decisively — any stack that centres its content shifts
        // the panel when the badge appears, so starting a take would knock the
        // panel off the lens. Portrait escapes that only because its stack is
        // anchored on the panel's side. An overlay is outside layout flow, so
        // it cannot move the panel, and — being inside the pill's subtree,
        // above the `.offset` below — it still travels with the panel.
        .overlay(alignment: .trailing) {
            if cameraManager.isRecording {
                landscapeTimerBadge
                    .offset(x: Self.landscapeBadgeFootprint.width + 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: g.cfg.isCameraOffset ? Self.landscapeLensOffset : 0)
        .padding(.top, g.cfg.topPadding)
    }

    private var recordingTimerBadge: some View {
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

    /// The recording timer turned a quarter turn, with a layout footprint that
    /// matches what it DRAWS rather than what it measures — see
    /// `landscapeBadgeFootprint`. `fixedSize` keeps it at its natural size
    /// before the turn so the frame below centres the drawn result.
    private var landscapeTimerBadge: some View {
        recordingTimerBadge
            .fixedSize()
            .rotationEffect(.degrees(90))
            .frame(
                width: Self.landscapeBadgeFootprint.width,
                height: Self.landscapeBadgeFootprint.height
            )
    }

    /// Word-by-word / 3-line mode toggle.
    private var modeToggleButton: some View {
        Group {
            if isExpanded {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        displayMode = isClassicMode ? "wbw" : "classic"
                    }
                } label: {
                    Image(systemName: isClassicMode ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
                        .frame(width: 44, height: 44)
                }
            }
        }
    }

    /// The black pill shape itself (extracted so `prompterContainerPanel`
    /// stays within the type-checker's complexity budget). Takes explicit
    /// dimensions and a text overlay so both orientations share one shape,
    /// one set of gestures and one border.
    private func prompterPill<Overlay: View>(
        cfg: CutoutLayoutConfig,
        width: CGFloat,
        height: CGFloat,
        overlayAlignment: Alignment,
        @ViewBuilder textOverlay: () -> Overlay
    ) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: cfg.topCornerRadius,
            bottomLeadingRadius: cfg.bottomCornerRadius,
            bottomTrailingRadius: cfg.bottomCornerRadius,
            topTrailingRadius: cfg.topCornerRadius,
            style: .continuous
        )
        .fill(Color.black)
        .frame(width: width, height: height)
        .opacity(isExpanded ? 1 : 0)
        .overlay(alignment: overlayAlignment) { textOverlay() }
        .clipped()
        .overlay(alignment: .topTrailing) { modeToggleButton }
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
        // Long press + drag = move the text toward or away from the lens.
        // The gesture axis is view-space Y in both orientations; only its
        // physical meaning changes with the quarter turn.
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
                    let stored = isLandscape ? textOffsetLandscape : textVerticalOffset
                    let rawY = CGFloat(stored) + textDragY
                    let clampedY = min(max(rawY, -15), 20)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        if isLandscape {
                            textOffsetLandscape = Double(clampedY)
                        } else {
                            textVerticalOffset = Double(clampedY)
                        }
                        textDragY = 0
                        isTextEditMode = false
                    }
                }
            : nil
        )
        // Double tap = reset the nudge for the current orientation.
        .simultaneousGesture(
            isExpanded ?
            TapGesture(count: 2)
                .onEnded {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        if isLandscape {
                            textOffsetLandscape = 0
                        } else {
                            textVerticalOffset = 0
                        }
                        textDragY = 0
                    }
                }
            : nil
        )
    }

    // MARK: - Close button

    /// Back chevron. Visible only when not recording.
    private var closeButton: some View {
        GeometryReader { geo in
            let g = prompterGeometry(geo)
            Group {
                if isLandscape {
                    landscapeCloseButton(g)
                } else {
                    portraitCloseButton(g)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    /// Portrait: top-leading, its centre glued to the panel's anchor midpoint
    /// via the shared geometry. Sized + offset slightly tighter on SE-class
    /// devices because the centered WBW container leaves less horizontal
    /// clearance there (~47pt) than on notch/Dynamic Island layouts (~90pt).
    private func portraitCloseButton(_ g: PrompterGeometry) -> some View {
        let closeBtnSize: CGFloat = g.cfg.isCameraOffset ? 42 : 32
        let closeBtnLeading: CGFloat = g.cfg.isCameraOffset ? 12 : 8
        let closeBtnTopPadding = max(0, g.anchorCentre - (closeBtnSize / 2))
        return VStack {
            HStack {
                closeChevron(size: closeBtnSize)
                    .padding(.leading, closeBtnLeading)
                    .padding(.top, closeBtnTopPadding)
                Spacer()
            }
            Spacer()
        }
    }

    /// Landscape: the corner the USER reads as top-left.
    ///
    /// With the interface portrait-locked and the content turned a quarter
    /// turn, view +X points physically up and view +Y physically right, so the
    /// user's top-left corner is view-space TOP-TRAILING — the opposite
    /// horizontal edge from portrait. It sits clear of the panel (which is
    /// centred across X, far from the trailing edge) and clear of the cutout
    /// (which spans the middle of X, not its end).
    ///
    /// This no longer tracks the panel, so it does not read `anchorCentre`;
    /// that value remains in the shared geometry for portrait's use.
    private func landscapeCloseButton(_ g: PrompterGeometry) -> some View {
        let closeBtnSize: CGFloat = g.cfg.isCameraOffset ? 42 : 32
        return VStack {
            HStack {
                Spacer()
                closeChevron(size: closeBtnSize)
                    .padding(.trailing, Self.landscapeCloseInset)
                    .padding(.top, Self.landscapeCloseInset)
            }
            Spacer()
        }
    }

    private func closeChevron(size: CGFloat) -> some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                // Turned with everything else, so the chevron still points
                // physically leftward — "back" — to a viewer holding the
                // device sideways.
                .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
                .frame(width: size, height: size)
                .modifier(GlassCircleModifier())
                .clipShape(Circle())
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
        .frame(height: Self.scrubBarHeight)
        // Horizontal inset is deliberately a CALL-SITE concern. It used to be a
        // built-in `.padding(.horizontal, 24)` here, which portrait wanted but
        // which left the landscape bar's scrub track 12pt shy at each end of the
        // row above it — the two simply had different insets, 24 against 12.
        // Each call site now states its own, so they can be tied together.
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
                    settingsGearButton
                }
                .padding(.horizontal, 20)
            }

            statusLine

            if showCameraSettings { cameraSettingsPanel }

            speedSliderRow

            // 24 is exactly what `scrubBar` carried internally before the inset
            // moved out to its call sites; portrait renders identically.
            scrubBar
                .padding(.horizontal, 24)

            // `controlsOverlay` is portrait-only — landscape mounts
            // `landscapeBottomBar` and `landscapeTransportColumn` instead — so
            // this is unconditional.
            transportRow
        }
        .padding(.bottom, 48)
        .padding(.top, 12)
    }

    // MARK: - Control pieces, shared by both orientations

    /// Discloses the exposure panel. Hidden while recording at every call site.
    private var settingsGearButton: some View {
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

    /// Audio source + video quality indicators. Both are tappable discovery
    /// affordances: the audio side opens an "audio source can be changed in
    /// Settings" toast with an Open Settings CTA; the resolution side does the
    /// same for video quality. The indicators were previously decorative-only —
    /// users reached for them and nothing happened.
    private var statusLine: some View {
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
    }

    /// The exposure row itself — label, slider, EV readout — with no chrome.
    /// Shared, so the two orientations differ only in what surrounds it:
    /// portrait wraps it in the card below, landscape drops it bare into the
    /// bar's lower slot, where the card's vertical padding would not fit.
    private var exposureControl: some View {
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

    /// Schedules the idle auto-hide, replacing any pending one.
    ///
    /// Restarted ONLY by a touch on the exposure control. Interaction elsewhere
    /// deliberately does not restart it: the neighbouring controls — speed,
    /// transport, and in portrait the scrub bar — have nothing to do with
    /// exposure, so letting them hold it open would mean a user scrubbing
    /// through a script keeps an exposure slider on screen indefinitely, which
    /// is the situation auto-hide exists to prevent.
    private func scheduleExposureAutoHide() {
        cancelExposureAutoHide()
        exposureAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.exposureAutoHideSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.25)) { showCameraSettings = false }
        }
    }

    private func cancelExposureAutoHide() {
        exposureAutoHideTask?.cancel()
        exposureAutoHideTask = nil
    }

    /// The exposure disclosure, shown when the gear is toggled. PORTRAIT only —
    /// landscape swaps `exposureControl` into its bar instead, without this
    /// card, so this view and its position are exactly what they were.
    private var cameraSettingsPanel: some View {
        VStack(spacing: 12) {
            // Exposure
            exposureControl

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Speed slider with its tortoise/hare ends. `FMVSliderSync` stays attached
    /// via `.background` — it binds to the slider's lifecycle, so it travels
    /// with the row wherever the row is mounted.
    private var speedSliderRow: some View {
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
    }

    // MARK: - Landscape bottom bar

    /// Status line, gear and speed slider in one row, with the scrub bar
    /// beneath, along the physical bottom edge.
    ///
    /// This group rotates as ONE unit — unlike every other landscape element,
    /// which turns only its inner content and keeps an axis-aligned hit area.
    /// It has to: two of its children are drag targets that must track along
    /// the physical horizontal, and a `Slider` tracks along its own x-axis, so
    /// the control itself must turn. The DEV spike proved on device that a
    /// rotated `Slider` follows a sustained drag correctly, which is why this
    /// uses the native control rather than a hand-rolled gesture.
    ///
    /// The explicit `.frame` AFTER the rotation is the other half of what the
    /// spike established: `rotationEffect` does not change layout, so without
    /// it the content centres on its unrotated box and lands mid-screen
    /// instead of at the edge.
    private var landscapeBottomBar: some View {
        GeometryReader { geo in
            let length = max(0, geo.size.height - Self.landscapeBarEndInset * 2)
            let thickness = Self.landscapeBarThickness
            HStack {
                landscapeBottomBarContent
                    .frame(width: length, height: thickness)
                    .rotationEffect(.degrees(90))
                    // Swapped dimensions so the layout box equals the drawn
                    // result and the bar sits where it appears to sit.
                    .frame(width: thickness, height: length)
                    .padding(.leading, Self.landscapeBarInset)
                Spacer()
            }
            .frame(maxHeight: .infinity)
            .animation(.spring(duration: 0.25), value: showCameraSettings)
        }
    }

    /// The bar's contents, in their own unrotated space. A `VStack` stacks
    /// along its local +Y, which the quarter turn maps to physically downward,
    /// so the first child is the upper row as the user sees it; an `HStack`
    /// stacks along local +X, which maps to physically rightward. Both read in
    /// the natural order with nothing reversed.
    ///
    /// The exposure panel sits between the two rows — the same relative place
    /// it occupies in portrait, below the status line and above the scrub bar.
    private var landscapeBottomBarContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                statusLine
                if !cameraManager.isRecording {
                    // Explicit hit region — the one interactive control in this
                    // bar that lacked one. Nothing intercepts these taps: the
                    // file's only other hit-testing participants are the dim
                    // overlay (hit testing off), the prompter pill's gestures
                    // (bounded by the pill, and a lower ZStack layer than this
                    // bar), the scrub bar's contentShape (the slot below), and
                    // statusLine's two buttons. There was simply very little to
                    // hit: a ~22x20 glyph, which the quarter turn renders as a
                    // ~20pt band in view x.
                    //
                    // `contentShape` so the whole frame is tappable rather than
                    // just where the symbol's strokes fall.
                    settingsGearButton
                        .frame(
                            width: Self.landscapeGearHitTarget,
                            height: Self.landscapeGearHitTarget
                        )
                        .contentShape(Rectangle())
                }
                speedSliderRow
            }
            .padding(.horizontal, Self.landscapeBarRowInset)

            // One slot, two occupants. The gear SWAPS the scrub bar for the
            // exposure row rather than inserting anything, so the content is
            // the same height either way: nothing is pushed, nothing needs
            // reserving, and the row above cannot move.
            //
            // The slot is pinned to `scrubBarHeight` because the two occupants
            // are NOT the same height — the scrub bar declares 44, the exposure
            // row is ~33 of slider. Without the frame the bar would shrink by
            // 11 on every swap and the row would drift ~5.5. The shorter
            // occupant centres in the slot; the taller one, portrait's ~57pt
            // card, never enters this path.
            //
            // Hidden by conditional insertion, not opacity: the occupant that
            // is not showing is not mounted, so it leaves the accessibility
            // tree rather than lurking in it as a silent, swipeable control.
            //
            // The same inset as the row above, from the same constant, so the
            // two span identical extents and cannot drift apart again.
            Group {
                if showCameraSettings {
                    exposureControl
                } else {
                    scrubBar
                }
            }
            .frame(height: Self.scrubBarHeight)
            .padding(.horizontal, Self.landscapeBarRowInset)
        }
    }

    // MARK: - Transport controls

    /// Portrait: the three transport buttons in a row, unchanged.
    private var transportRow: some View {
        HStack(spacing: 48) {
            playPauseButton
            recordButton
            resetButton
        }
    }

    /// Landscape: the record button on the screen's vertical centre line, with
    /// the play/reset pair side by side above it, against the physical RIGHT
    /// edge.
    ///
    /// Two axes are in play and both follow from one mapping — the interface is
    /// portrait-locked, so physical up is view +X and physical right is view +Y:
    ///
    /// * The outer `HStack` lays out along +X, i.e. bottom-to-top on screen, so
    ///   listing `recordButton` FIRST puts it lowest with the pair above it.
    /// * The inner `VStack` lays out along +Y, i.e. left-to-right on screen, so
    ///   listing `playPauseButton` first puts play on the left and reset on the
    ///   right — the same left-to-right relationship the two have in portrait's
    ///   row. Swapping the two lines is all it takes to reverse that.
    ///
    /// `landscapeTransportBalance` is what centres the RECORD button rather
    /// than the group, and the arithmetic is checkable. Without it the group is
    /// 72 + 20 + 56 = 148 wide and the enclosing `VStack` centres it across
    /// [mid-74, mid+74]; the record button, as the leading child, occupies
    /// [mid-74, mid-2], putting its centre 38pt BELOW the midpoint — which is
    /// exactly the dead space that appeared above the pair. Padding the leading
    /// (physically lower) side by the pair's own extent, 56 + 20 = 76, makes
    /// the padded box 224 wide, centred across [mid-112, mid+112]; the leading
    /// padding consumes [mid-112, mid-36], so the record button lands at
    /// [mid-36, mid+36] — its centre exactly on the midpoint.
    ///
    /// The pair stays in layout flow rather than becoming an overlay: an
    /// overlay would draw outside the record button's bounds, and content drawn
    /// outside a parent's bounds is not reliably hit-testable. These are
    /// buttons, so that risk is not worth taking for a tidier expression.
    private var landscapeTransportColumn: some View {
        VStack {
            Spacer()
            HStack(spacing: Self.landscapeTransportSpacing) {
                recordButton
                VStack(spacing: Self.landscapeTransportPairSpacing) {
                    playPauseButton
                    resetButton
                }
            }
            .padding(.leading, Self.landscapeTransportBalance)
            .padding(.bottom, Self.landscapeTransportInset)
        }
    }

    private var playPauseButton: some View {
        Button { togglePlay() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                // Glyph turned, frame applied AFTER, so the tappable bounds
                // stay an axis-aligned square. Same pattern as `closeChevron`,
                // `modeToggleButton` and the timer badge — the interactive
                // control is never itself rotated.
                .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
                .frame(width: Self.transportButtonSize, height: Self.transportButtonSize)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(!player.isReady)
    }

    /// Unchanged from the portrait row: a static 72pt ring with the inner shape
    /// animating between 52pt/radius 28 and 28pt/radius 6 on
    /// `cameraManager.isRecording`, the animation attached to that value.
    ///
    /// Deliberately NOT rotated. A circle and a rounded square are identical
    /// under a quarter turn, so a `rotationEffect` here would be a no-op
    /// transform carrying a comment that implied otherwise.
    private var recordButton: some View {
        Button { toggleRecording() } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: Self.recordButtonSize, height: Self.recordButtonSize)
                RoundedRectangle(cornerRadius: cameraManager.isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(
                        width: cameraManager.isRecording ? 28 : 52,
                        height: cameraManager.isRecording ? 28 : 52
                    )
                    .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
            }
        }
    }

    private var resetButton: some View {
        Button { resetDisplay() } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
                .frame(width: Self.transportButtonSize, height: Self.transportButtonSize)
                .background(.ultraThinMaterial, in: Circle())
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
                // No `.frame` after this one, deliberately. The frame-after-
                // rotation pattern used elsewhere here exists to keep a hit
                // area axis-aligned, or to make a parent's layout box match the
                // drawn result. The countdown has no hit area, and nothing
                // sizes to it: the ZStack takes its size from the full-screen
                // Color, and the numeral is centred, so turning it about its
                // own centre leaves that centre exactly where it was.
                .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
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
            if AVAudioApplication.shared.recordPermission != .granted {
                showMicPermissionAlert = true
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
                    AppAnalytics.log("first_recording_completed", params: [
                        "duration_sec": Int(duration.rounded())
                    ])
                    // MMP funnel event (once, gated by `wasFirst`).
                    AppServices.attribution?.trackEvent("first_recording_completed")
                }
                // Counter only. The prompt itself is requested from the
                // post-save slot in VideoPreviewView, where it can be ordered
                // against the first-own-recording paywall; counting every
                // successful recording here means a recording that yields to a
                // paywall still moves the user toward the prompt.
                ReviewPromptManager.recordSuccessfulRecording()
                previewRecording = recording
            case .failure(let error):
                // Auto-save failed entirely (file move error, generator error,
                // etc.). Don't present the preview — clean up the temp source
                // file so it doesn't leak. The user can retake the clip.
                //
                // Mirrors `recording_stopped`'s parameter shape so the two can
                // be joined on a session. `error_reason` is the NSError
                // domain/code, NOT `localizedDescription`: this app ships four
                // locales and a localized reason fragments into four buckets
                // for one failure.
                let nsError = error as NSError
                AppAnalytics.log("recording_failed", params: [
                    "duration_sec": Int(duration.rounded()),
                    "display_mode": displayMode,
                    "error_reason": "\(nsError.domain)/\(nsError.code)"
                ])
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

