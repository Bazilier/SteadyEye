import SwiftUI
import SwiftData
import AVKit
import AVFoundation
import Photos
import UIKit
import FirebaseCrashlytics

struct VideoPreviewView: View {
    let recording: Recording
    let onDismiss: () -> Void
    /// Asked after a successful save to Camera Roll. Returning true presents
    /// the first-own-recording paywall on top of the preview. `nil` (the
    /// Recordings tab) never shows it.
    var shouldShowPaywallAfterSave: (() -> Bool)? = nil
    /// Whether this take came from a script the user wrote themselves —
    /// `!script.isDemo && !script.isSample`, the same definition the
    /// first-own-recording paywall uses.
    ///
    /// Kept as its own value rather than read off `shouldShowPaywallAfterSave`,
    /// which fuses that origin with subscription state and the paywall's
    /// one-shot flag and so cannot answer the question on its own.
    ///
    /// Defaults to `false`: the Recordings tab reaches this view with no
    /// script in scope, and a `Recording` carries only a title string, so the
    /// origin is genuinely unknowable there.
    var isUserWrittenScript: Bool = false
    /// The card's thumbnail, shown in the video frame until the player
    /// draws its first frame, so the zoom from the card never shows black.
    /// `nil` (the recording screen right after a take) keeps today's look.
    var poster: UIImage? = nil
    /// Set only for the guided first run's take: shows the result sheet over
    /// the preview (see `FirstTakeResultSheet`).
    var firstTakeResult: FirstTakeResult? = nil
    /// Eye contact over the take just recorded, 0...1; nil when it was not
    /// tracked or the preview was opened from the Recordings tab.
    var takeEyeContact: Double? = nil
    /// The result sheet's Continue: leave the camera; the list takes the
    /// guided run on from there (its paywall, or the older own-script offer).
    var onRecordOwnScript: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Injected at the app root; its `state` is nil except on iPhone Duo.
    @Environment(DuoDisplayMonitor.self) private var duoMonitor: DuoDisplayMonitor?
    /// A wide screen: regular width, or iPhone Duo unfolded — whose halves
    /// tell the lists they are compact, an override that can reach here.
    private var isWideScreen: Bool {
        horizontalSizeClass == .regular || duoMonitor?.state?.posture == .unfolded
    }
    /// Set by a pinch: in shows the whole frame, out fills the width. Nil
    /// keeps the default for the screen (`showsWholeFrame`).
    @State private var pinchedWholeFrame: Bool?
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @StateObject private var playback = PlaybackController()
    @State private var showDeleteConfirmation = false
    @State private var showSaveError = false
    /// The composition with both soundtracks, once Studio Sound is ready.
    @State private var studioItem: StudioSoundAudio.PlayerItem?
    /// Which soundtrack the top chip names while it is up; nil when hidden.
    @State private var studioChip: Bool?
    @State private var studioChipHideToken = UUID()
    @State private var showStudioSaveSheet = false
    @State private var showStudioPaywall = false
    @State private var showStudioWillSaveToast = false
    /// The tip above the Studio Sound button that explains its counter.
    @State private var showStudioCoach = false
    /// The tier the tip was last shown for: it shows once per tier, so a
    /// free user who subscribes learns what the new number means.
    @AppStorage("studioCoachTier") private var studioCoachTier = ""
    @State private var showStudioIntro = false
    @State private var showStudioLimit = false
    /// Set once the user went through the first-use sheet, which is also
    /// their consent to the audio going to Auphonic.
    @AppStorage("studioIntroAccepted") private var studioIntroAccepted = false
    @State private var showStudioConfirm = false
    /// "Don't show again" on the Studio Sound sheets. Subscribers only: the
    /// free try always asks.
    @AppStorage("studioSkipConfirm") private var studioSkipConfirm = false
    /// Flipped between the two soundtracks during this visit: heard the
    /// difference, which makes the end of the video a happy moment.
    @State private var comparedStudioSound = false
    @ObservedObject private var studioSound = StudioSoundManager.shared
    @State private var showSaveSuccess = false
    @State private var showPhotosDeniedToast = false
    @State private var isSavingToCameraRoll = false
    /// Placeholder localIdentifier captured during the PHPhotoLibrary
    /// performChanges block. Drives the save-success toast's tap-to-open
    /// deep link into the Photos app at the just-saved asset.
    @State private var savedAssetLocalIdentifier: String?
    @State private var videoSize: CGSize = CGSize(width: 9, height: 16)
    @State private var didLoadVideoSize = false
    /// Set by the player view once its layer can display a frame.
    @State private var isVideoReady = false
    /// The poster's shape until the track's real size has loaded, so a
    /// landscape recording doesn't start in the 9:16 default frame.
    private var frameSize: CGSize {
        if !didLoadVideoSize, let poster, poster.size.width > 0, poster.size.height > 0 {
            return poster.size
        }
        return videoSize
    }
    private var isLandscapeVideo: Bool { frameSize.width > frameSize.height }
    /// The whole frame, centred, instead of full width from the top. Default
    /// on a wide screen (iPhone Duo unfolded), where a full-width portrait
    /// video would leave little more than its top on screen.
    private var showsWholeFrame: Bool { pinchedWholeFrame ?? isWideScreen }
    /// Keeps the bottom controls a comfortable width on a wide screen.
    private var controlsMaxWidth: CGFloat { isWideScreen ? 520 : .infinity }
    @State private var showPostSavePaywall = false
    @State private var showSatisfactionPrompt = false
    @State private var satisfactionTrigger: ReviewPromptManager.Trigger = .greatTake
    @State private var showFounderChat = false
    /// Set when the user answers No, so the chat is presented from the
    /// satisfaction sheet's `onDismiss` rather than stacked on top of it.
    @State private var pendingFounderChat = false
    /// Tracks whether the preview is on screen, so the delayed post-save
    /// paywall is not presented after the user has already left.
    @State private var isVisible = false
    /// Set when the post-save paywall came due while the app was not active;
    /// presented once the scene becomes active again.
    @State private var pendingPostSavePaywall = false
    @Environment(\.scenePhase) private var scenePhase
    /// Identifies the latest scheduled hide of the success toast. The toast's
    /// built-in timer is effectively disabled (see its `duration`), so this
    /// view owns the hide: a new token invalidates any earlier scheduled hide.
    @State private var successToastHideToken = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Stage: everything above the scrubber row, from the very top
                // of the screen. A portrait recording runs full width from the
                // top edge and may extend behind the controls below; a
                // landscape one is fitted to the width and centred here.
                Color.clear
                    // Top-aligned full width only on a phone, where a portrait
                    // video is about the screen's shape; on a wide screen the
                    // zoomed video is centred on the screen's middle, not cut to
                    // its top.
                    .overlay(alignment: isLandscapeVideo || showsWholeFrame || isWideScreen ? .center : .top) {
                        videoLayer
                    }
                    // Top scrim — keeps Back / Delete legible over the video.
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color.black.opacity(0.35), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 130)
                        .allowsHitTesting(false)
                    }
                    // Bottom scrim — the video dissolves into the solid black
                    // behind the controls, so no hard edge near the scrubber.
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.black.opacity(0.55), location: 0.5),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .allowsHitTesting(false)
                    }
                    .ignoresSafeArea(edges: .top)
                    // Pinch in for the whole frame, out to fill the width.
                    .simultaneousGesture(
                        MagnifyGesture().onEnded { value in
                            let scale = value.magnification
                            guard scale < 0.92 || scale > 1.08 else { return }
                            withAnimation(.smooth(duration: 0.3)) {
                                pinchedWholeFrame = scale < 1
                            }
                        }
                    )

                // Bottom block, pinned to the bottom safe area. The scrubber's
                // DragGesture lives here, not over the video, so it doesn't
                // conflict with the video's tap gesture.
                VStack(spacing: 8) {
                    scrubberRow
                    HStack(spacing: 10) {
                        if showsStudioButton {
                            StudioSoundButton(
                                recording: recording,
                                quota: studioSound.quota,
                                action: handleStudioTap
                            )
                        }
                        saveButton
                    }
                }
                // Floats above the controls without pushing the video up.
                .overlay(alignment: .topLeading) {
                    studioHint
                        .alignmentGuide(.top) { $0[.bottom] + 12 }
                }
                .frame(maxWidth: controlsMaxWidth)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(Color.black.ignoresSafeArea(edges: .bottom))
            }

            // The guided run's take has one way out: the sheet's Continue.
            if firstTakeResult == nil {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                }
            }

            if let result = firstTakeResult {
                VStack {
                    Spacer()
                    FirstTakeResultSheet(
                        result: result,
                        onContinue: {
                            AppAnalytics.log("take_result_continue_tapped")
                            onRecordOwnScript?()
                        }
                    )
                }
                .transition(.move(edge: .bottom))
                .onAppear {
                    AppAnalytics.log("take_result_shown", params: [
                        "eye_contact_pct": result.gaze.map { Int(($0.lookingFraction * 100).rounded()) } ?? -1
                    ])
                }
            }
        }
        .statusBarHidden()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .alert(
            Text(String(
                localized: "recordings.delete.title",
                defaultValue: "Delete recording?",
                comment: "Title of the delete-confirmation alert in the Recordings tab and finished view."
            )),
            isPresented: $showDeleteConfirmation
        ) {
            Button(role: .cancel) {} label: {
                Text("common.cancel", comment: "Cancel button on the recording delete-confirmation alert.")
            }
            Button(role: .destructive) {
                deleteAndDismiss()
            } label: {
                Text(String(
                    localized: "recordings.delete.confirm",
                    defaultValue: "Delete",
                    comment: "Destructive button on the recording delete-confirmation alert."
                ))
            }
        } message: {
            Text(String(
                localized: "recordings.delete.message",
                defaultValue: "This action cannot be undone.",
                comment: "Body of the recording delete-confirmation alert."
            ))
        }
        .toast(
            isPresented: $showSaveSuccess,
            message: String(
                localized: "preview.saved.toast",
                defaultValue: "Saved to Camera Roll",
                comment: "Toast shown after the recording is successfully saved to the Photos library."
            ),
            style: .success,
            // Hidden by `scheduleSuccessToastHide` instead, so it can stay up
            // while the post-save paywall is on screen.
            duration: 3600,
            tapAction: openSavedAssetInPhotos,
            showsChevron: true
        )
        .toast(
            isPresented: $showSaveError,
            message: String(
                localized: "preview.saveError.toast",
                defaultValue: "Couldn't save to Camera Roll",
                comment: "Toast shown when saving the recording to the Photos library fails."
            ),
            style: .error,
            duration: 4.0
        )
        .toast(
            isPresented: $showPhotosDeniedToast,
            message: String(
                localized: "preview.photosDenied.toast",
                defaultValue: "Photos access denied",
                comment: "Toast shown when the user tries to save but Photos access is denied or restricted."
            ),
            style: .error,
            duration: 6.0,
            actionLabel: String(
                localized: "toast.openSettings",
                defaultValue: "Settings",
                comment: "Compact button label inside a toast that opens iOS Settings. Distinct from common.open_settings (the longer 'Open Settings' label used in full-button alert surfaces) — Xcode's String Catalog symbol generator collapses common.openSettings and common.open_settings to the same Swift symbol, hence the toast.* namespace."
            ),
            action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
        .fullScreenCover(isPresented: $showPostSavePaywall, onDismiss: {
            scheduleSuccessToastHide(after: 2)
        }) {
            PaywallView(source: "first_own_recording", eyeContact: takeEyeContact)
                .onAppear {
                    // Written only once the paywall actually appears.
                    UserDefaults.standard.set(true, forKey: "postFirstOwnRecordingPaywallShown")
                    PromptArbiter.shared.didPresent(.firstOwnRecordingPaywall)
                }
        }
        .sheet(isPresented: $showSatisfactionPrompt, onDismiss: {
            // Sequenced, not stacked: SwiftUI cannot raise the chat while the
            // satisfaction sheet is still on screen.
            guard pendingFounderChat else { return }
            pendingFounderChat = false
            showFounderChat = true
        }) {
            SatisfactionPromptView(
                trigger: satisfactionTrigger,
                eyeContactPercent: satisfactionTrigger == .greatTake
                    ? takeEyeContact.map { Int(($0 * 100).rounded()) }
                    : nil,
                onRate: {
                    ReviewPromptManager.noteAnsweredYes()
                    ReviewPromptManager.openWriteReviewPage()
                },
                onNo: {
                    pendingFounderChat = true
                }
            )
            .onAppear {
                // Burned HERE, once the sheet is really on screen — a prompt
                // the arbiter denied must stay retryable. Same discipline as
                // the notification soft-ask.
                ReviewPromptManager.notePresented()
                PromptArbiter.shared.didPresent(.reviewPrompt)
            }
            .onDisappear {
                PromptArbiter.shared.didDismiss()
            }
        }
        .sheet(isPresented: $showFounderChat) {
            ChatView(pinnedMessage: .satisfactionFollowUp)
        }
        .sheet(isPresented: $showStudioSaveSheet) {
            StudioSaveSheet(
                onSaveWhenReady: saveWhenStudioReady,
                onSaveOriginal: {
                    showStudioSaveSheet = false
                    proceedWithSave(forceOriginal: true)
                },
                onCancel: { showStudioSaveSheet = false }
            )
        }
        .fullScreenCover(isPresented: $showStudioPaywall) {
            PaywallView(source: "studio_sound")
        }
        .sheet(isPresented: $showStudioIntro) {
            StudioIntroSheet(
                quota: studioSound.quota,
                dontAskAgain: $studioSkipConfirm,
                onContinue: {
                    studioIntroAccepted = true
                    showStudioIntro = false
                    AppAnalytics.log("studio_sound_intro_accepted", params: [
                        "tier": studioSound.quota?.tier.rawValue ?? "unknown"
                    ])
                    startStudio()
                },
                onCancel: { showStudioIntro = false }
            )
        }
        .sheet(isPresented: $showStudioConfirm) {
            if let quota = studioSound.quota {
                StudioConfirmSheet(
                    quota: quota,
                    units: studioUnits,
                    dontAskAgain: $studioSkipConfirm,
                    onConfirm: {
                        showStudioConfirm = false
                        startStudio()
                    },
                    onCancel: { showStudioConfirm = false }
                )
            }
        }
        .sheet(isPresented: $showStudioLimit) {
            if let quota = studioSound.quota {
                StudioLimitSheet(quota: quota, onClose: { showStudioLimit = false })
            }
        }
        .toast(
            isPresented: $showStudioWillSaveToast,
            message: String(
                localized: "studio.toast.willSave",
                defaultValue: "We'll save it as soon as the sound is ready",
                comment: "Toast after the user chose to save the recording to Camera Roll once Studio Sound finishes."
            ),
            style: .info,
            duration: 3.0
        )
        .onAppear {
            isVisible = true
            setupPlayer()
            Task {
                await studioSound.refreshQuota()
                showStudioCoachIfDue()
            }
        }
        // A purchase from the paywall changes the allowance.
        .onChange(of: subscriptionManager.isSubscribed) { _, _ in
            Task {
                await studioSound.refreshQuota()
                showStudioCoachIfDue()
            }
        }
        .onChange(of: recording.studioStatusRaw) { _, _ in
            guard isVisible, recording.studioStatus == .ready, studioItem == nil else { return }
            Task { await attachStudioAudio(replacingCurrentItem: true) }
        }
        // The happy moments: the user just watched a take of their own script
        // that held eye contact, or watched one with Studio Sound on after
        // comparing it with the original. Ask then, not on the way out.
        .onChange(of: playback.didPlayToEnd) { _, finished in
            guard finished,
                  firstTakeResult == nil,
                  !showPostSavePaywall, !showSatisfactionPrompt,
                  scenePhase == .active
            else { return }
            if let eyeContact = takeEyeContact,
               eyeContact >= ReviewPromptManager.greatTakeThreshold,
               ReviewPromptManager.shouldPresentSatisfactionPrompt(isUserWrittenScript: isUserWrittenScript) {
                satisfactionTrigger = .greatTake
                showSatisfactionPrompt = true
            } else if comparedStudioSound,
                      recording.usesStudioAudio,
                      // The user's own voice, enhanced: a happy moment whatever
                      // script it was read from, so the origin gate is passed.
                      ReviewPromptManager.shouldPresentSatisfactionPrompt(isUserWrittenScript: true) {
                satisfactionTrigger = .studioSound
                showSatisfactionPrompt = true
            }
        }
        .onDisappear {
            isVisible = false
            pendingPostSavePaywall = false
            successToastHideToken = UUID()
            teardownPlayer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, pendingPostSavePaywall else { return }
            guard isVisible,
                  !showPostSavePaywall,
                  shouldShowPaywallAfterSave?() == true,
                  PromptArbiter.shared.canPresent(.firstOwnRecordingPaywall)
            else {
                // Pending paywall dropped: let the held-back toast hide.
                pendingPostSavePaywall = false
                scheduleSuccessToastHide(after: 2)
                return
            }
            // Short delay so the scene finishes becoming active first. Pending
            // stays set until then so a scheduled toast hide cannot fire in
            // between.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pendingPostSavePaywall = false
                guard isVisible else { return }
                showPostSavePaywall = true
            }
        }
    }

    // MARK: - Video

    /// Width-driven: the height follows the video's natural aspect ratio
    /// (loaded async into `videoSize`; the poster's, or 9:16, until then), so
    /// a portrait video is never cropped horizontally. The poster sits under
    /// the player in the same frame until the player is ready for display.
    /// The paused-state play glyph tracks the video's centre, not the screen's.
    @ViewBuilder
    private var videoLayer: some View {
        if poster != nil || playback.player != nil {
            ZStack {
                if let poster, !isVideoReady {
                    Image(uiImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                if let player = playback.player {
                    CustomVideoPlayer(player: player, isReady: $isVideoReady)
                }
            }
            .aspectRatio(frameSize.width / frameSize.height, contentMode: .fit)
            // Full width from the top, possibly past the stage's bottom; or the
            // whole frame fitted inside the stage.
            .frame(maxWidth: .infinity, maxHeight: showsWholeFrame ? .infinity : nil)
            .fixedSize(horizontal: false, vertical: !showsWholeFrame)
            .overlay {
                if playback.player != nil && !playback.isPlaying && !playback.isScrubbing {
                    Image(systemName: "play.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(radius: 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { playback.togglePlayPause() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier())
            }
            .accessibilityLabel(String(
                localized: "recordings.preview.back",
                defaultValue: "Back",
                comment: "VoiceOver label for the back button in the recording preview."
            ))
            Spacer()
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircleModifier())
            }
            .accessibilityLabel(String(
                localized: "recordings.preview.delete",
                defaultValue: "Delete recording",
                comment: "VoiceOver label for the trash button in the recording preview."
            ))
        }
        .overlay {
            if let isStudio = studioChip {
                StudioChip(isStudio: isStudio)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Save CTA

    private var saveButton: some View {
        Button {
            handleSaveTap()
        } label: {
            HStack(spacing: 8) {
                if isSavingToCameraRoll {
                    ProgressView().tint(.black)
                }
                Text(String(
                    localized: "recordings.preview.saveToCameraRoll",
                    defaultValue: "Save to Camera Roll",
                    comment: "Primary button in the recording preview that exports the (already-persisted) video to the Photos library."
                ))
            }
            .frame(maxWidth: .infinity)
        }
        .primaryButtonStyle()
        .disabled(isSavingToCameraRoll)
    }

    // MARK: - Player lifecycle

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            return
        }
        if recording.studioStatus == .ready, recording.studioAudioURL != nil {
            Task {
                await attachStudioAudio(replacingCurrentItem: false)
                if playback.player == nil, isVisible {
                    playback.setup(url: recording.fileURL, initialDuration: recording.duration)
                }
                loadVideoSize()
            }
        } else {
            playback.setup(url: recording.fileURL, initialDuration: recording.duration)
            loadVideoSize()
        }
    }

    /// Builds the two-soundtrack item and starts playback with it, or swaps
    /// it in when Studio Sound finished while the preview was open. On any
    /// failure the plain file keeps playing.
    private func attachStudioAudio(replacingCurrentItem: Bool) async {
        guard let studioURL = recording.studioAudioURL else { return }
        let prepared: StudioSoundAudio.PlayerItem
        do {
            prepared = try await StudioSoundAudio.makePlayerItem(
                videoURL: recording.fileURL,
                studioAudioURL: studioURL,
                useStudio: recording.studioEnabled
            )
        } catch {
            AppAnalytics.log("studio_sound_playback_failed", params: [
                "error_reason": (error as NSError).code
            ])
            return
        }
        guard isVisible else { return }
        studioItem = prepared
        if replacingCurrentItem {
            playback.replaceItem(with: prepared.item)
            flashStudioChip(isStudio: recording.studioEnabled)
        } else {
            playback.setup(item: prepared.item, initialDuration: recording.duration)
        }
    }

    private func loadVideoSize() {
        // Load the video track's natural size + preferred transform so the
        // container can size to the actual aspect ratio. Falls back silently
        // to the 9:16 default if any step fails. The MainActor write checks
        // that the player is still set, so a late completion after dismiss
        // won't clobber the next presentation's state.
        guard let avPlayer = playback.player else { return }
        Task {
            guard let item = avPlayer.currentItem else { return }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = naturalSize.applying(transform)
                let displayedSize = CGSize(
                    width: abs(transformed.width),
                    height: abs(transformed.height)
                )
                guard displayedSize.width > 0, displayedSize.height > 0 else { return }
                await MainActor.run {
                    if self.playback.player != nil {
                        self.videoSize = displayedSize
                        self.didLoadVideoSize = true
                    }
                }
            } catch {
                // Silently fall back to the 9:16 default.
            }
        }
    }

    /// Hides the success toast after `delay`, unless a newer hide was scheduled
    /// since, the preview went away, or the post-save paywall is pending or on
    /// screen (its dismissal schedules a fresh hide).
    private func scheduleSuccessToastHide(after delay: TimeInterval) {
        let token = UUID()
        successToastHideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard token == successToastHideToken,
                  !pendingPostSavePaywall,
                  !showPostSavePaywall
            else { return }
            withAnimation { showSaveSuccess = false }
        }
    }

    private func teardownPlayer() {
        playback.teardown()
    }

    // MARK: - Scrubber row

    /// Compact playback chrome: current-time label, draggable
    /// scrubber, total-duration label. Sits in the bottom block above
    /// the Save CTA — not over the video surface — so its DragGesture
    /// doesn't conflict with the video's onTapGesture.
    private var scrubberRow: some View {
        HStack(spacing: 12) {
            PlaybackTimeLabel(clock: playback.clock)
                .frame(width: 44, alignment: .leading)
            ScrubberView(playback: playback, clock: playback.clock)
            Text(Self.formatTime(playback.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: 44)
    }

    /// Formats `seconds` as `M:SS` (or `MM:SS` when total length is
    /// ≥ 10 minutes). Negative values clamp to 0; fractional seconds
    /// are floored.
    static func formatTime(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let total = Int(safe)
        let m = total / 60
        let s = total % 60
        if m >= 10 {
            return String(format: "%02d:%02d", m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Save flow

    /// Photo-library authorization gate. The watermark itself was already
    /// burned in (or skipped, for Pro) at recording time by the realtime
    /// composer, so Save is just a PhotoKit hand-off — no upgrade prompt,
    /// no post-process step.
    private func handleSaveTap() {
        // Status check only — never request inline. The system prompt for
        // PHPhotoLibrary.requestAuthorization tears down the underlying
        // fullScreenCover stack (preview AND the recording view), returning
        // the user to the scripts list with no toast and no recovery surface.
        // Onboarding asks for Photos up-front where no cover is mounted; if
        // we land in any non-granted branch here, the user either denied at
        // onboarding or revoked later. Surface the Settings deep link via
        // the denied-toast and let them recover manually. .restricted
        // (parental controls / MDM) routes to the same toast even though
        // Settings won't help — keeps the flow simple, and the toast text
        // ("Photos access denied") remains technically accurate.
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            if recording.studioStatus?.isInFlight == true {
                showStudioSaveSheet = true
            } else {
                proceedWithSave()
            }
        case .denied, .notDetermined, .restricted:
            showPhotosDeniedToast = true
        @unknown default:
            showPhotosDeniedToast = true
        }
    }

    /// The file on disk already has the watermark burned in (free) or no
    /// watermark (Pro), so Save is just a direct PhotoKit hand-off — of the
    /// file itself, or of a copy carrying the processed audio when the
    /// Studio Sound toggle is on.
    private func proceedWithSave(forceOriginal: Bool = false) {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            showSaveError = true
            return
        }
        isSavingToCameraRoll = true
        Task {
            var file = StudioSoundManager.SaveFile(url: recording.fileURL, isTemporary: false)
            if !forceOriginal, recording.usesStudioAudio {
                // A failed export falls back to the original rather than
                // failing the save.
                do {
                    file = try await StudioSoundManager.shared.fileForSaving(recording)
                } catch {
                    AppAnalytics.log("studio_sound_export_failed", params: [
                        "error_reason": (error as NSError).code
                    ])
                }
            }
            save(file)
        }
    }

    private func save(_ file: StudioSoundManager.SaveFile) {
        // Capture the new asset's localIdentifier inside the change
        // block so the success toast can deep-link straight into
        // Photos.app at the saved video. PhotoKit serializes the
        // change block before firing the completion handler, so
        // `capturedAssetID` is already populated by the time we read
        // it on main.
        var capturedAssetID: String?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.url)
            capturedAssetID = request?.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            if file.isTemporary {
                try? FileManager.default.removeItem(at: file.url)
            }
            DispatchQueue.main.async {
                isSavingToCameraRoll = false
                if success {
                    AppAnalytics.log("recording_exported_to_camera_roll", params: [
                        "duration_sec": Int(recording.duration.rounded()),
                        "had_watermark": recording.hasWatermark,
                        "via": "preview",
                        "studio_sound": file.isTemporary
                    ])
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    savedAssetLocalIdentifier = capturedAssetID
                    showSaveSuccess = true
                    scheduleSuccessToastHide(after: 2.5)
                    if shouldShowPaywallAfterSave?() == true {
                        // Let the success toast show first. Re-check on fire:
                        // the user may have left the preview, or another save
                        // may already have shown the paywall.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard isVisible,
                                  !showPostSavePaywall,
                                  shouldShowPaywallAfterSave?() == true,
                                  // Denied: present nothing and burn no flag —
                                  // the next own-script save tries again.
                                  PromptArbiter.shared.canPresent(.firstOwnRecordingPaywall)
                            else { return }
                            if scenePhase == .active {
                                showPostSavePaywall = true
                            } else {
                                // Presenting while inactive may be dropped;
                                // defer until the scene is active again.
                                pendingPostSavePaywall = true
                            }
                        }
                    } else if isUserWrittenScript {
                        // No paywall due for this save. The user saved it to
                        // share it, so don't stand in the way now: ask how it
                        // turned out once they are back (see ScriptListView).
                        ReviewPromptManager.noteOwnScriptExported()
                    }
                } else {
                    AppAnalytics.log("recording_export_failed", params: [
                        "duration_sec": Int(recording.duration.rounded()),
                        "had_watermark": recording.hasWatermark,
                        "via": "preview",
                        "error_reason": error?.localizedDescription ?? "unknown"
                    ])
                    #if !DEV
                    if let error {
                        Crashlytics.crashlytics().record(error: error)
                    }
                    #endif
                    showSaveError = true
                }
            }
        }
    }

    /// Deep-links into the Photos app at the just-saved asset using
    /// the `photos-redirect://asset/<UUID>` scheme. The `localIdentifier`
    /// returned by PhotoKit looks like `<UUID>/L0/001`; the deep link
    /// only accepts the UUID prefix, so we strip the suffix before
    /// constructing the URL. Falls back to plain `photos-redirect://`
    /// (Photos at last-viewed location, typically the just-saved video)
    /// if the asset-specific link doesn't resolve, or if we never
    /// captured a localIdentifier.
    private func openSavedAssetInPhotos() {
        let target: URL? = {
            if let identifier = savedAssetLocalIdentifier {
                let cleanID = identifier.components(separatedBy: "/").first ?? identifier
                return URL(string: "photos-redirect://asset/\(cleanID)")
            }
            return URL(string: "photos-redirect://")
        }()
        guard let url = target else { return }
        UIApplication.shared.open(url) { success in
            if !success, let fallback = URL(string: "photos-redirect://") {
                UIApplication.shared.open(fallback)
            }
        }
    }

    // MARK: - Studio Sound

    /// Everyone gets the button — subscribers spend their allowance, free
    /// users have one try and then see the paywall from it — except on the
    /// onboarding's demo take, where a free user would spend the one try on
    /// a sample they never meant to keep.
    private var showsStudioButton: Bool { firstTakeResult == nil }

    /// Once per tier, with the counter loaded: what the number means.
    private func showStudioCoachIfDue() {
        guard isVisible,
              showsStudioButton,
              recording.studioStatus == nil,
              let quota = studioSound.quota,
              quota.remaining > 0,
              studioCoachTier != quota.tier.rawValue
        else { return }
        studioCoachTier = quota.tier.rawValue
        withAnimation { showStudioCoach = true }
    }

    @ViewBuilder
    private var studioHint: some View {
        if showsStudioButton {
            switch recording.studioStatus {
            case .preparing, .uploading, .processing, .downloading:
                StudioHintCard(kind: .processing)
                    .transition(.opacity)
            case .failed:
                StudioHintCard(
                    kind: .failed,
                    message: StudioSoundManager.failureMessage(for: recording.studioErrorCode)
                )
                .transition(.opacity)
            case nil where showStudioCoach:
                StudioCoachBubble(tier: studioSound.quota?.tier ?? .paid)
                    .onTapGesture { withAnimation { showStudioCoach = false } }
                    .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }

    /// Idle or failed: start. Ready: flip between the two soundtracks.
    private func handleStudioTap() {
        withAnimation { showStudioCoach = false }
        switch recording.studioStatus {
        case nil, .failed:
            if let quota = studioSound.quota, quota.remaining == 0 {
                AppAnalytics.log("studio_sound_limit_tapped", params: ["tier": quota.tier.rawValue])
                if quota.tier == .free {
                    showStudioPaywall = true
                } else {
                    showStudioLimit = true
                }
                return
            }
            guard studioIntroAccepted else {
                showStudioIntro = true
                return
            }
            if let quota = studioSound.quota,
               quota.tier == .free || !studioSkipConfirm || studioUnits > quota.remaining {
                showStudioConfirm = true
                return
            }
            startStudio()
        case .ready:
            let enabled = !recording.studioEnabled
            StudioSoundManager.shared.setEnabled(enabled, for: recording)
            if let studioItem {
                playback.setAudioMix(enabled ? studioItem.studioMix : studioItem.originalMix)
            } else {
                // The two-soundtrack item never got built; try again now.
                Task { await attachStudioAudio(replacingCurrentItem: true) }
            }
            UISelectionFeedbackGenerator().selectionChanged()
            flashStudioChip(isStudio: enabled)
            comparedStudioSound = true
        default:
            break
        }
    }

    /// What this recording costs: one enhancement per started 3 minutes,
    /// as the server counts it.
    private var studioUnits: Int {
        max(1, Int((recording.duration / 180).rounded(.up)))
    }

    private func startStudio() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { StudioSoundManager.shared.start(recording) }
    }

    private func flashStudioChip(isStudio: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { studioChip = isStudio }
        let token = UUID()
        studioChipHideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard token == studioChipHideToken else { return }
            withAnimation(.easeIn(duration: 0.3)) { studioChip = nil }
        }
    }

    /// "Save when ready" from the save sheet. If processing finished or
    /// failed while the sheet was up, save right away instead.
    private func saveWhenStudioReady() {
        showStudioSaveSheet = false
        guard recording.studioStatus?.isInFlight == true else {
            proceedWithSave()
            return
        }
        recording.studioSaveWhenReady = true
        try? modelContext.save()
        AppAnalytics.log("studio_sound_save_when_ready")
        showStudioWillSaveToast = true
    }

    // MARK: - Delete

    private func deleteAndDismiss() {
        AppAnalytics.log("recording_deleted", params: [
            "duration_sec": Int(recording.duration.rounded()),
            "had_watermark": recording.hasWatermark
        ])
        teardownPlayer()
        RecordingPersistence.delete(recording, modelContext: modelContext)
        onDismiss()
    }
}

// MARK: - Custom scrubber

/// Drag-to-seek scrubber. The track and filled portion are simple
/// capsules; the thumb is centered on the leading edge of the filled
/// portion (so its center tracks the playhead). While the user is
/// actively dragging, the thumb position is driven from a local
/// `scrubTime` so it follows the finger without waiting for AVPlayer
/// to confirm each seek; otherwise it follows `playback.currentTime`
/// from the periodic time observer.
///
/// `DragGesture(minimumDistance: 0)` doubles as tap-to-seek: a single
/// tap fires `.onChanged` once at the touch point (jumping the thumb)
/// and immediately `.onEnded`.
/// The elapsed-time readout, re-rendered alone at the playhead's rate.
private struct PlaybackTimeLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(VideoPreviewView.formatTime(clock.time))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white)
    }
}

private struct ScrubberView: View {
    @ObservedObject var playback: PlaybackController
    /// The playhead, observed here rather than in the preview screen.
    @ObservedObject var clock: PlaybackClock
    @State private var scrubTime: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Avoid divide-by-zero on the very first frame before
            // duration is seeded; playback always sets a real
            // `initialDuration` before the View binds, so this is a
            // belt-and-suspenders default.
            let denom = max(playback.duration, 0.001)
            let displayTime = playback.isScrubbing ? scrubTime : clock.time
            let progress = min(1, max(0, displayTime / denom))
            let filledWidth = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white)
                    .frame(width: filledWidth, height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: filledWidth - 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !playback.isScrubbing {
                            playback.beginScrubbing()
                        }
                        let raw = (value.location.x / width) * playback.duration
                        let clamped = max(0, min(playback.duration, raw))
                        scrubTime = clamped
                        playback.scrub(to: clamped)
                    }
                    .onEnded { _ in
                        playback.endScrubbing()
                    }
            )
        }
        .frame(height: 14)
    }
}

// MARK: - Custom AVPlayerLayer-backed video view

/// Plays an `AVPlayer` without any AVKit chrome. Replacing SwiftUI's
/// `VideoPlayer` here is the only way to drop the native scrub bar, AirPlay
/// icon, skip-±10s controls, and the metadata title banner that AVKit shows
/// in its top chrome.
private struct CustomVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    /// Mirrors `AVPlayerLayer.isReadyForDisplay`.
    @Binding var isReady: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        view.onReadyForDisplay = { ready in
            if isReady != ready { isReady = ready }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
}

private final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onReadyForDisplay: ((Bool) -> Void)?
    private var readyObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Clear until the first frame can be drawn, so the poster behind the
        // layer shows through instead of a black rectangle.
        playerLayer.backgroundColor = UIColor.clear.cgColor
        // Touches go to the SwiftUI gestures above (tap to play, pinch to
        // fit): a UIView takes only the first finger of a pinch.
        isUserInteractionEnabled = false
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.readyForDisplayChanged(ready) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func readyForDisplayChanged(_ ready: Bool) {
        // Once a frame can be drawn, paint letterbox bands opaque black so
        // the layer reaches the device edges itself, independently of how
        // SwiftUI propagates .ignoresSafeArea() to the representable host.
        playerLayer.backgroundColor = ready ? UIColor.black.cgColor : UIColor.clear.cgColor
        onReadyForDisplay?(ready)
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }
}
