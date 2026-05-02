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

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var showDeleteConfirmation = false
    @State private var showSaveError = false
    @State private var showSaveSuccess = false
    @State private var showPhotosDeniedToast = false
    @State private var isSavingToCameraRoll = false
    /// Placeholder localIdentifier captured during the PHPhotoLibrary
    /// performChanges block. Drives the save-success toast's tap-to-open
    /// deep link into the Photos app at the just-saved asset.
    @State private var savedAssetLocalIdentifier: String?
    @State private var isPlaying = true
    @State private var videoSize: CGSize = CGSize(width: 9, height: 16)

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
            if let player {
                CustomVideoPlayer(player: player)
                    .aspectRatio(videoSize.width / videoSize.height, contentMode: .fit)
                    .overlay {
                        if !isPlaying {
                            Image(systemName: "play.fill")
                                .font(.system(size: 56))
                                .foregroundColor(.white.opacity(0.85))
                                .shadow(radius: 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlayPause() }
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

            // Floating overlay: top bar + Spacer + save CTA. Stays inside the
            // safe area so chevron/trash and the orange button aren't clipped.
            VStack(spacing: 0) {
                topBar
                Spacer()
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
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
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
        let avPlayer = AVPlayer(url: recording.fileURL)
        self.player = avPlayer

        // Load the video track's natural size + preferred transform so the
        // container can size to the actual aspect ratio. Falls back silently
        // to the 9:16 default if any step fails. The MainActor write checks
        // that the player is still set, so a late completion after dismiss
        // won't clobber the next presentation's state.
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
                    if self.player != nil {
                        self.videoSize = displayedSize
                    }
                }
            } catch {
                // Silently fall back to the 9:16 default.
            }
        }

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            avPlayer.seek(to: .zero)
            avPlayer.play()
        }

        avPlayer.play()
        isPlaying = true
    }

    private func teardownPlayer() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
        player?.pause()
        player = nil
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
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
