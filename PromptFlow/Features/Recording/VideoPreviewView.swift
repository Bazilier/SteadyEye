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

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @StateObject private var playback = PlaybackController()
    @State private var showDeleteConfirmation = false
    @State private var showSaveError = false
    @State private var showSaveSuccess = false
    @State private var showPhotosDeniedToast = false
    @State private var isSavingToCameraRoll = false
    /// Placeholder localIdentifier captured during the PHPhotoLibrary
    /// performChanges block. Drives the save-success toast's tap-to-open
    /// deep link into the Photos app at the just-saved asset.
    @State private var savedAssetLocalIdentifier: String?
    @State private var videoSize: CGSize = CGSize(width: 9, height: 16)
    @State private var showPostSavePaywall = false
    @State private var showSatisfactionPrompt = false
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

            // Video container: scales to fit the available vertical space
            // between the top bar (~48pt + 16pt gap = 64pt below the safe-area
            // top) and the Save button (~62pt + 16pt gap = 78pt above the
            // safe-area bottom). Width is auto-derived from the video's
            // natural aspect ratio (loaded async into `videoSize`; defaults
            // to 9:16 portrait if loading fails). The aspect-ratio'd inner
            // view owns the contentShape + tap gesture, so taps in the
            // letterbox margins fall through to the background. The paused-
            // state play glyph is overlaid on the aspect-ratio'd view so it
            // tracks the video's center, not the screen's.
            if let player = playback.player {
                CustomVideoPlayer(player: player)
                    .aspectRatio(videoSize.width / videoSize.height, contentMode: .fit)
                    .overlay {
                        if !playback.isPlaying && !playback.isScrubbing {
                            Image(systemName: "play.fill")
                                .font(.system(size: 56))
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(radius: 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { playback.togglePlayPause() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 64)
                    .padding(.bottom, 78)
            }

            // Top scrim — keeps the back/trash buttons legible against bright
            // video content. Hit-testing disabled so taps fall through to the
            // video.
            LinearGradient(
                colors: [Color.black.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            // Bottom scrim — keeps the orange Save button legible.
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            // Floating overlay: top bar + Spacer + scrubber row + save CTA.
            // Stays inside the safe area so chevron/trash, the scrubber
            // thumb, and the orange button aren't clipped. The scrubber
            // row sits in this bottom chrome layer (NOT over the video
            // surface), so its DragGesture doesn't conflict with the
            // video's onTapGesture.
            VStack(spacing: 0) {
                topBar
                Spacer()
                scrubberRow
                saveButton
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
            PaywallView(source: "first_own_recording")
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
                onYes: {
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
        .onAppear {
            isVisible = true
            setupPlayer()
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
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
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(String(
                localized: "recordings.preview.delete",
                defaultValue: "Delete recording",
                comment: "VoiceOver label for the trash button in the recording preview."
            ))
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
                    .font(.body.bold())
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.orange)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(isSavingToCameraRoll)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Player lifecycle

    private func setupPlayer() {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            return
        }
        playback.setup(url: recording.fileURL, initialDuration: recording.duration)

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
    /// scrubber, total-duration label. Sits in the bottom overlay
    /// VStack between the Spacer and the Save CTA — not over the
    /// video surface — so its DragGesture doesn't conflict with the
    /// video's onTapGesture (separate Z-stack layers).
    private var scrubberRow: some View {
        HStack(spacing: 12) {
            Text(Self.formatTime(playback.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 44, alignment: .leading)
            ScrubberView(playback: playback)
            Text(Self.formatTime(playback.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Formats `seconds` as `M:SS` (or `MM:SS` when total length is
    /// ≥ 10 minutes). Negative values clamp to 0; fractional seconds
    /// are floored.
    private static func formatTime(_ seconds: Double) -> String {
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
            proceedWithSave()
        case .denied, .notDetermined, .restricted:
            showPhotosDeniedToast = true
        @unknown default:
            showPhotosDeniedToast = true
        }
    }

    /// The file on disk already has the watermark burned in (free) or no
    /// watermark (Pro), so Save is just a direct PhotoKit hand-off.
    private func proceedWithSave() {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            showSaveError = true
            return
        }
        isSavingToCameraRoll = true
        // Capture the new asset's localIdentifier inside the change
        // block so the success toast can deep-link straight into
        // Photos.app at the saved video. PhotoKit serializes the
        // change block before firing the completion handler, so
        // `capturedAssetID` is already populated by the time we read
        // it on main.
        var capturedAssetID: String?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: recording.fileURL)
            capturedAssetID = request?.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSavingToCameraRoll = false
                if success {
                    AppAnalytics.log("recording_exported_to_camera_roll", params: [
                        "duration_sec": Int(recording.duration.rounded()),
                        "had_watermark": recording.hasWatermark,
                        "via": "preview"
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
                    } else {
                        // No paywall due for this save, so the same slot is the
                        // satisfaction prompt's moment. The origin bit, the
                        // one-shot Yes flag, the 14-day re-ask window and the
                        // arbiter are all checked inside.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard isVisible, scenePhase == .active else { return }
                            guard ReviewPromptManager.shouldPresentSatisfactionPrompt(
                                isUserWrittenScript: isUserWrittenScript
                            ) else { return }
                            showSatisfactionPrompt = true
                        }
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
private struct ScrubberView: View {
    @ObservedObject var playback: PlaybackController
    @State private var scrubTime: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Avoid divide-by-zero on the very first frame before
            // duration is seeded; playback always sets a real
            // `initialDuration` before the View binds, so this is a
            // belt-and-suspenders default.
            let denom = max(playback.duration, 0.001)
            let displayTime = playback.isScrubbing ? scrubTime : playback.currentTime
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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
}

private final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
            // Paint letterbox bands opaque black so the layer reaches the
            // device edges itself, independently of how SwiftUI propagates
            // .ignoresSafeArea() to the underlying UIViewRepresentable host.
            playerLayer.backgroundColor = UIColor.black.cgColor
        }
    }
}
