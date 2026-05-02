import SwiftUI
import SwiftData
import AVFoundation
import Photos
import UIKit

enum OnboardingStage {
    case priming
    case permissionExplainer
    case launchCamera
}

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var stage: OnboardingStage = .priming
    @State private var cameraGranted: Bool = false
    @State private var micGranted: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.createdAt, order: .reverse) private var scripts: [Script]

    @State private var showRecording: Bool = false
    @State private var didLogStart: Bool = false

    var body: some View {
        ZStack {
            switch stage {
            case .priming:
                primingView
            case .permissionExplainer:
                explainerView
            case .launchCamera:
                Color.black.ignoresSafeArea()
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
            case .launchCamera:
                if demoScript != nil {
                    showRecording = true
                } else {
                    finishOnboarding(path: "no_demo")
                }
            case .priming:
                break
            }
        }
        .onChange(of: showRecording) { _, newValue in
            // Fires `finishOnboarding` at the START of the inner cover's
            // dismissal (when SwiftUI sets the binding to false), not at the
            // end (which would be the conventional `.onDismiss:` path). This
            // flips `hasSeenOnboarding = true` immediately, so the OUTER
            // OnboardingView cover (bound to !hasSeenOnboarding in ContentView)
            // begins dismissing in parallel with the inner one. Without this,
            // the user sees ~250ms of OnboardingView's `.launchCamera` stage
            // (a solid Color.black backdrop) during the gap between the inner
            // cover finishing its dismiss animation and the outer cover
            // starting its own.
            if !newValue {
                finishOnboarding(path: "camera_dismissed")
            }
        }
        .fullScreenCover(isPresented: $showRecording) {
            if let demo = demoScript {
                RecordingView(script: demo)
            } else {
                Color.black.ignoresSafeArea()
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
                Text("Camera access needed")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("SteadyEye needs camera access to record your videos. You can enable it later in Settings if you change your mind.")
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

    // MARK: - Demo lookup (with defensive fetch fallback if @Query hasn't propagated yet)

    private var demoScript: Script? {
        if let viaQuery = scripts.first(where: { $0.isDemo }) {
            return viaQuery
        }
        let descriptor = FetchDescriptor<Script>(predicate: #Predicate { $0.isDemo == true })
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Permission flow

    func requestPermissionsAndAdvance() async {
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVAudioApplication.shared.recordPermission

        // Returning user: both already authorized → skip system dialogs entirely.
        if camStatus == .authorized && micStatus == .granted {
            cameraGranted = true
            micGranted = true
            stage = .launchCamera
            return
        }
        // Camera already denied (or restricted) → straight to explainer.
        if camStatus == .denied || camStatus == .restricted {
            stage = .permissionExplainer
            return
        }

        // Camera: request only if not determined; otherwise (.authorized) use cached.
        let cameraWasPrompt = camStatus == .notDetermined
        let cameraResult: Bool
        if camStatus == .authorized {
            cameraResult = true
        } else {
            cameraResult = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    cont.resume(returning: granted)
                }
            }
            AppAnalytics.log(
                cameraResult ? "permissions_camera_granted" : "permissions_camera_denied",
                params: ["was_prompt": cameraWasPrompt]
            )
        }
        cameraGranted = cameraResult

        if !cameraResult {
            stage = .permissionExplainer
            return
        }

        // Pre-warm AVCaptureSession while the user finishes the mic +
        // photos permission prompts. session.startRunning() is the
        // dominant cold-start cost (~2-3s of mediaserver IPC + format
        // negotiation); kicking it off now means RecordingView's
        // .onAppear hits the early-return guard inside CameraManager.start
        // (session already running) and the live preview shows
        // immediately rather than after a 2-3s black-screen wait.
        // CameraManager.start dispatches the heavy work to its internal
        // serial queue; the main-thread hop is just to keep the
        // @Published `cameraPosition` setter on main. No cleanup needed
        // on abandoned onboarding — the only path off this screen is
        // through RecordingView, whose .onDisappear runs cameraManager.stop().
        DispatchQueue.main.async {
            CameraManager.shared.start(position: .front)
        }

        // Mic: request only if undetermined; cached states use stored value, no log.
        let micWasPrompt = micStatus == .undetermined
        let micResult: Bool
        if micStatus == .granted {
            micResult = true
        } else if micStatus == .denied {
            micResult = false
        } else {
            micResult = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            AppAnalytics.log(
                micResult ? "permissions_mic_granted" : "permissions_mic_denied",
                params: ["was_prompt": micWasPrompt]
            )
        }
        micGranted = micResult

        // Photos (.addOnly): request only if not determined; cached states are
        // a no-op. Outcome does not gate progression — onboarding continues
        // regardless. The Save flow in VideoPreviewView later checks status
        // (without requesting, to avoid tearing down the modal stack via the
        // system prompt) and surfaces a Settings deep link if denied. Asking
        // here, where no fullScreenCover is mounted above, is the only safe
        // place to trigger the system Photos prompt.
        let photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if photosStatus == .notDetermined {
            let photosResult = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    cont.resume(returning: status)
                }
            }
            let granted = photosResult == .authorized || photosResult == .limited
            AppAnalytics.log(
                granted ? "permissions_photos_granted" : "permissions_photos_denied",
                params: ["was_prompt": true]
            )
        }

        stage = .launchCamera
    }

    func finishOnboarding(path: String) {
        AppAnalytics.log("onboarding_completed", params: ["path": path])
        hasSeenOnboarding = true
    }
}
