import SwiftUI
import AVFoundation
import Photos
import UIKit

enum OnboardingStage {
    case priming
    case permissionExplainer
}

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    /// Set true in `finishOnboarding` when camera permission was granted —
    /// signals to ScriptListView that it should auto-present RecordingView
    /// with the demo script as soon as the onboarding cover dismisses.
    /// Reset to false by ScriptListView after consumption.
    @AppStorage("pendingDemoRecording") private var pendingDemoRecording: Bool = false
    @State private var stage: OnboardingStage = .priming
    @State private var cameraGranted: Bool = false
    @State private var micGranted: Bool = false
    @State private var photosGranted: Bool = false

    @State private var didLogStart: Bool = false

    var body: some View {
        ZStack {
            switch stage {
            case .priming:
                primingView
            case .permissionExplainer:
                explainerView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !didLogStart {
                didLogStart = true
                AppAnalytics.log("onboarding_started")
            }
        }
        .onChange(of: stage) { _, newStage in
            switch newStage {
            case .permissionExplainer:
                AppAnalytics.log("onboarding_permission_explainer_shown")
            case .priming:
                break
            }
        }
    }

    // MARK: - Stages

    private var primingView: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                Spacer().frame(maxHeight: 120)
                MiniWBWView()
                Spacer().frame(height: 40)
                Text("Read your script. Look natural.")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("SteadyEye shows your text right under the camera lens — so your eyes never leave the camera.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                Spacer().frame(height: 32)
                permissionsBlock
                Spacer()
                Button {
                    AppAnalytics.log("onboarding_continue_tapped")
                    Task { await requestPermissionsAndAdvance() }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: Capsule())
                }
                .padding(.horizontal, 24)
                Spacer().frame(height: 8)
                Text(String(
                    localized: "onboarding.priming.permission_note",
                    defaultValue: "We'll ask for access next"
                ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 32)
            }
        }
    }

    private var explainerView: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Camera & microphone access needed")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("SteadyEye needs camera and microphone access to record your videos. You can enable them later in Settings if you change your mind.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    finishOnboarding(path: "settings_opened")
                } label: {
                    Text("Open Settings")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: Capsule())
                }
                .padding(.horizontal, 24)
                Button("Skip for now") {
                    AppAnalytics.log("onboarding_skip_for_now_tapped", params: [
                        "camera_granted": cameraGranted,
                        "mic_granted": micGranted,
                        "photos_granted": photosGranted
                    ])
                    finishOnboarding(path: "skipped_after_denied")
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 32)
            }
        }
    }

    private var permissionsBlock: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                Text(String(
                    localized: "onboarding.priming.camera_label",
                    defaultValue: "Camera — to record yourself"
                ))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                Text(String(
                    localized: "onboarding.priming.mic_label",
                    defaultValue: "Microphone — for audio"
                ))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                Text(String(
                    localized: "onboarding.priming.photos_label",
                    defaultValue: "Photos — to save to Camera Roll"
                ))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0, green: 0, blue: 0),
                     Color(red: 0.1, green: 0.04, blue: 0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Permission flow

    func requestPermissionsAndAdvance() async {
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVAudioApplication.shared.recordPermission

        // Returning user fast path: both camera AND mic already authorized
        // → skip the sequential resolution entirely. Photos status is not
        // part of this gate; if photos was previously denied we still
        // accept the cached state and don't reshow onboarding for it.
        if camStatus == .authorized && micStatus == .granted {
            cameraGranted = true
            micGranted = true
            let photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            photosGranted = (photosStatus == .authorized || photosStatus == .limited)
            finishOnboarding(path: "already_granted")
            return
        }

        // Camera: resolve via requestAccess only if .notDetermined; otherwise
        // use the cached status. iOS guarantees requestAccess is a no-op
        // (immediate callback with cached value) for non-.notDetermined
        // statuses, but we branch explicitly so the analytics event only
        // fires on actual prompt/answer transitions.
        let cameraWasPrompt = camStatus == .notDetermined
        let cameraResult: Bool
        switch camStatus {
        case .authorized:
            cameraResult = true
        case .denied, .restricted:
            cameraResult = false
        case .notDetermined:
            cameraResult = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    cont.resume(returning: granted)
                }
            }
            AppAnalytics.log(
                cameraResult ? "permissions_camera_granted" : "permissions_camera_denied",
                params: ["was_prompt": cameraWasPrompt]
            )
        @unknown default:
            cameraResult = false
        }
        cameraGranted = cameraResult

        // Pre-warm AVCaptureSession in parallel with the remaining mic +
        // photos prompts, but only if camera was actually granted. Without
        // a grant, AVCaptureSession.startRunning fails immediately and we
        // pay nothing.
        if cameraResult {
            DispatchQueue.main.async {
                CameraManager.shared.start(position: .front)
            }
        }

        // Mic: ALWAYS run, regardless of camera answer. Critical for the
        // "user denied camera" recovery path — without this, iOS never
        // shows a Microphone toggle in Settings → SteadyEye, leaving the
        // user unable to grant mic later if they change their mind about
        // camera.
        let micWasPrompt = micStatus == .undetermined
        let micResult: Bool
        switch micStatus {
        case .granted:
            micResult = true
        case .denied:
            micResult = false
        case .undetermined:
            micResult = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            AppAnalytics.log(
                micResult ? "permissions_mic_granted" : "permissions_mic_denied",
                params: ["was_prompt": micWasPrompt]
            )
        @unknown default:
            micResult = false
        }
        micGranted = micResult

        // Photos (.addOnly): ALWAYS run, regardless of previous answers —
        // same reasoning as mic. Outcome does not gate onboarding
        // progression itself; the Save flow in VideoPreviewView later
        // checks status (without requesting, to avoid tearing down the
        // modal stack via the system prompt) and surfaces a Settings
        // deep link if denied. Asking here, where no fullScreenCover is
        // mounted above, is the only safe place to trigger the system
        // Photos prompt.
        let photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let photosResult: Bool
        switch photosStatus {
        case .authorized, .limited:
            photosResult = true
        case .denied, .restricted:
            photosResult = false
        case .notDetermined:
            let phStatus = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    cont.resume(returning: status)
                }
            }
            photosResult = (phStatus == .authorized || phStatus == .limited)
            AppAnalytics.log(
                photosResult ? "permissions_photos_granted" : "permissions_photos_denied",
                params: ["was_prompt": true]
            )
        @unknown default:
            photosResult = false
        }
        photosGranted = photosResult

        // Outcome decision happens AFTER all three permissions are resolved.
        // Recording requires BOTH camera and mic; either one missing means
        // the user can't get past the record button. Show explainerView so
        // the user is told (and can recover via Settings — all three
        // toggles now exist there because the requests above always run).
        // Photos is intentionally NOT in the gate: recording still works
        // without photos access; the Save → Camera Roll path surfaces a
        // deny-toast with a Settings deep link if needed.
        if !cameraGranted || !micGranted {
            stage = .permissionExplainer
            return
        }

        finishOnboarding(path: "permissions_complete")
    }

    func finishOnboarding(path: String) {
        AppAnalytics.log("onboarding_completed", params: ["path": path])
        // Auto-open requires BOTH camera and mic. Without mic, the demo
        // recording would just hit RecordingView's mic-permission alert
        // immediately on the record-button tap — so it's better UX to
        // land the user on ScriptsList where they can re-enter the flow
        // after fixing mic in Settings (which now has a toggle because
        // the mic prompt always runs in this onboarding flow).
        // Photos is intentionally NOT part of this gate — recording works
        // without photos access; the Save → Camera Roll path surfaces a
        // deny-toast with a Settings deep link if photos was denied.
        pendingDemoRecording = cameraGranted && micGranted
        // Request ATT at the very end of onboarding, immediately before the
        // first main screen appears. The MMP (Tenjin) connect() runs inside
        // the completion handler — after the user responds, granted or denied
        // — so IDFA is available for the first install event when authorized.
        // Only after the prompt resolves do we flip `hasSeenOnboarding`, which
        // drives the transition to the main UI.
        Task { @MainActor in
            await ATTManager.requestIfNeeded()
            AppServices.attribution?.connect()
            AppServices.attribution?.syncToRevenueCat()
            hasSeenOnboarding = true
            // NOTE: The App Store review prompt used to fire here, but was
            // removed to avoid stacking two system dialogs (ATT + review) at
            // onboarding end and to align with the review strategy of asking
            // after a few days of use. There is currently no other review
            // trigger in the app — a usage-based one should be added later.
        }
    }
}
