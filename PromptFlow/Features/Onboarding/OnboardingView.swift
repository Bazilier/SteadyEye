import SwiftUI
import AVFoundation
import Photos
import UIKit

enum OnboardingStage {
    /// The product at a glance: the real prompter pill under the lens, and
    /// what the eye on it means.
    case welcome
    /// The user's first script: AI from a topic, the ready-made sample, or
    /// their own text (`OnboardingScriptView`).
    case script
    /// What we are about to ask for, right before the system prompts.
    case access
    /// Camera or microphone turned down: the way to Settings.
    case permissionExplainer
}

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    /// Set true in `finishOnboarding` when camera and microphone were
    /// granted — signals to ScriptListView that it should auto-present
    /// RecordingView with the flow's script as soon as the onboarding cover
    /// dismisses. Reset to false by ScriptListView after consumption.
    @AppStorage(OnboardingFlow.pendingRecordingKey) private var pendingFlowRecording: Bool = false
    @State private var stage: OnboardingStage = .welcome
    @AppStorage("teleprompterMode") private var displayMode: String = "wbw"
    @State private var didDefaultReadingStyle = false
    @State private var cameraGranted: Bool = false
    @State private var micGranted: Bool = false
    @State private var photosGranted: Bool = false

    @State private var didLogStart: Bool = false

    var body: some View {
        ZStack {
            switch stage {
            case .welcome:
                welcomeView
                    .transition(.opacity)
            case .script:
                ZStack {
                    backgroundGradient
                    OnboardingScriptView(
                        onScript: { script in
                            OnboardingFlow.noteFlowScript(script.id)
                            stage = .access
                        },
                        onSkip: {
                            OnboardingFlow.abandon(reason: "skipped_script")
                            finishOnboarding(path: "skipped_script")
                        }
                    )
                }
                .transition(.opacity)
            case .access:
                accessView
                    .transition(.opacity)
            case .permissionExplainer:
                explainerView
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
        // Welcome shows the pill where it sits on the camera, whose screen
        // hides the status bar; the clock would collide with the pill's eye.
        .statusBarHidden(stage == .welcome)
        .preferredColorScheme(.dark)
        .onAppear {
            if !didLogStart {
                didLogStart = true
                AppAnalytics.log("onboarding_started")
            }
            OnboardingFlow.start()
            // Three lines is the new-user default: it shows the next word,
            // which the eyes want before the voice gets there.
            if !didDefaultReadingStyle {
                didDefaultReadingStyle = true
                displayMode = "classic"
            }
            // Relaunched after the script was saved: pick up at access.
            if stage == .welcome, OnboardingFlow.isActive, OnboardingFlow.flowScriptID != nil {
                stage = .access
            }
        }
        .onChange(of: stage) { _, newStage in
            switch newStage {
            case .script:
                break
            case .access:
                AppAnalytics.log("onboarding_access_shown")
            case .permissionExplainer:
                AppAnalytics.log("onboarding_permission_explainer_shown")
            case .welcome:
                break
            }
        }
    }

    // MARK: - Stages

    private var welcomeView: some View {
        ZStack(alignment: .top) {
            pillBackdrop
            PrompterPillPreview(phrase: String(
                localized: "onboarding.welcome.pill_phrase",
                defaultValue: "Read your script and keep your eyes on the camera",
                comment: "Words cycled through the prompter pill on the first onboarding screen, three at a time, one word per line. Keep it short and natural."
            ))
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                Text(String(
                    localized: "onboarding.welcome.title",
                    defaultValue: "Look into the lens. Read every word.",
                    comment: "Headline of the first onboarding screen."
                ))
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) {
                    welcomeRow(
                        icon: "text.line.first.and.arrowtriangle.forward",
                        tint: Theme.accent,
                        title: String(
                            localized: "onboarding.welcome.text_row.title",
                            defaultValue: "Your script runs under the camera",
                            comment: "First onboarding screen, first explanation row: the prompter text runs right under the lens."
                        ),
                        detail: String(
                            localized: "onboarding.welcome.text_row.detail",
                            defaultValue: "Word by word, right where you look.",
                            comment: "First onboarding screen, detail under 'Your script runs under the camera'."
                        )
                    )
                    welcomeRow(
                        icon: "eye.fill",
                        tint: .green,
                        title: String(
                            localized: "onboarding.welcome.eye_row.title",
                            defaultValue: "Green eye means eye contact",
                            comment: "First onboarding screen, second explanation row: the eye on the prompter pill turns green while the user looks at the lens."
                        ),
                        detail: String(
                            localized: "onboarding.welcome.eye_row.detail",
                            defaultValue: "It goes grey when you look away from the lens.",
                            comment: "First onboarding screen, detail under 'Green eye means eye contact'."
                        )
                    )
                }
                .padding(.top, 8)
                Spacer()
                Button {
                    AppAnalytics.log("onboarding_continue_tapped")
                    stage = .script
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                Text(String(
                    localized: "onboarding.welcome.caption_next",
                    defaultValue: "Next: your script, then your first take",
                    comment: "Caption under the Continue button on the first onboarding screen: what comes next."
                ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
            // Clear of the pill: cutout band plus its three rows.
            .padding(.top, 180)
        }
    }

    /// Lighter at the top than `backgroundGradient`, so the black pill reads
    /// against it the way it does against a camera image.
    private var pillBackdrop: some View {
        LinearGradient(
            colors: [Color(white: 0.16), Color(red: 0.1, green: 0.04, blue: 0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func welcomeRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var accessView: some View {
        ZStack {
            backgroundGradient
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(
                        localized: "onboarding.access.title_ready",
                        defaultValue: "Your script is ready. Let’s film it.",
                        comment: "Title of the onboarding screen shown right before the camera, microphone and photos permission prompts, after the user's first script was saved."
                    ))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(
                        localized: "onboarding.access.subtitle",
                        defaultValue: "iOS will ask next. Your takes stay on your phone.",
                        comment: "Subtitle on the onboarding permissions screen. The system prompts follow; recordings are stored on the device."
                    ))
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)
                VStack(spacing: 10) {
                    accessRow(
                        icon: "video.fill",
                        title: String(localized: "onboarding.access.camera.title", defaultValue: "Camera", comment: "Onboarding permissions screen: camera row title."),
                        detail: String(localized: "onboarding.access.camera.detail", defaultValue: "To record you, and to see where you look", comment: "Onboarding permissions screen: why the camera is needed. Mentions eye-contact tracking, which runs on the camera frames.")
                    )
                    accessRow(
                        icon: "mic.fill",
                        title: String(localized: "onboarding.access.mic.title", defaultValue: "Microphone", comment: "Onboarding permissions screen: microphone row title."),
                        detail: String(localized: "onboarding.access.mic.detail", defaultValue: "For your voice", comment: "Onboarding permissions screen: why the microphone is needed.")
                    )
                    accessRow(
                        icon: "photo.on.rectangle.angled",
                        title: String(localized: "onboarding.access.photos.title", defaultValue: "Photos", comment: "Onboarding permissions screen: photos row title."),
                        detail: String(localized: "onboarding.access.photos.detail", defaultValue: "Only to save takes to your library", comment: "Onboarding permissions screen: why photo library (add-only) access is needed.")
                    )
                }
                Spacer()
                Button {
                    AppAnalytics.log("onboarding_access_allow_tapped")
                    Task { await requestPermissionsAndAdvance() }
                } label: {
                    Text(String(
                        localized: "onboarding.access.allow",
                        defaultValue: "Allow access",
                        comment: "Button on the onboarding permissions screen that triggers the system permission prompts."
                    ))
                        .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
    }

    private func accessRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var explainerView: some View {
        ZStack {
            backgroundGradient
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(
                        localized: "onboarding.denied.title",
                        defaultValue: "Turn on the camera to film",
                        comment: "Title of the onboarding screen shown when the user turned down camera or microphone access."
                    ))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(
                        localized: "onboarding.denied.body",
                        defaultValue: "Your script is saved. Switch these on in Settings and come back. We’ll open the camera with your script.",
                        comment: "Body of the onboarding access-denied screen. The user's script is already saved; after enabling access in iOS Settings, returning to the app opens the camera with it."
                    ))
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)

                VStack(spacing: 0) {
                    accessStatusRow(
                        String(localized: "onboarding.access.camera.title", defaultValue: "Camera", comment: "Onboarding permissions screen: camera row title."),
                        isOn: cameraGranted
                    )
                    Divider().overlay(Color.white.opacity(0.08))
                    accessStatusRow(
                        String(localized: "onboarding.access.mic.title", defaultValue: "Microphone", comment: "Onboarding permissions screen: microphone row title."),
                        isOn: micGranted
                    )
                    Divider().overlay(Color.white.opacity(0.08))
                    accessStatusRow(
                        String(localized: "onboarding.access.photos.title", defaultValue: "Photos", comment: "Onboarding permissions screen: photos row title."),
                        isOn: photosGranted,
                        isOptional: true
                    )
                }
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))

                Spacer()

                Button {
                    UserDefaults.standard.set(true, forKey: OnboardingFlow.awaitingSettingsKey)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    finishOnboarding(path: "settings_opened")
                } label: {
                    Text(String(localized: "common.open_settings", defaultValue: "Open Settings"))
                        .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                Button {
                    AppAnalytics.log("onboarding_skip_for_now_tapped", params: [
                        "camera_granted": cameraGranted,
                        "mic_granted": micGranted,
                        "photos_granted": photosGranted
                    ])
                    finishOnboarding(path: "skipped_after_denied")
                } label: {
                    Text(String(
                        localized: "onboarding.denied.not_now",
                        defaultValue: "Not now",
                        comment: "Quiet button on the onboarding access-denied screen: go to the scripts list; the saved script waits there."
                    ))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
        }
    }

    private func accessStatusRow(_ title: String, isOn: Bool, isOptional: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(.white)
            if isOptional {
                Text(String(
                    localized: "onboarding.denied.optional",
                    defaultValue: "optional",
                    comment: "Small label next to Photos on the onboarding access-denied screen: recording works without it."
                ))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text(isOn
                 ? String(localized: "onboarding.denied.on", defaultValue: "On", comment: "Status of a permission on the onboarding access-denied screen: granted.")
                 : String(localized: "onboarding.denied.off", defaultValue: "Off", comment: "Status of a permission on the onboarding access-denied screen: not granted."))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.green : Color(red: 1, green: 0.41, blue: 0.38))
        }
        .frame(minHeight: 52)
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
        // Auto-open requires BOTH camera and mic. Without mic, the first
        // take would just hit RecordingView's mic-permission alert
        // immediately on the record-button tap — so it's better UX to
        // land the user on ScriptsList where they can re-enter the flow
        // after fixing mic in Settings (which now has a toggle because
        // the mic prompt always runs in this onboarding flow).
        // Photos is intentionally NOT part of this gate — recording works
        // without photos access; the Save → Camera Roll path surfaces a
        // deny-toast with a Settings deep link if photos was denied.
        pendingFlowRecording = cameraGranted && micGranted && OnboardingFlow.flowScriptID != nil
        // Request ATT at the very end of onboarding, immediately before the
        // first main screen appears. The MMP is NOT started here — it starts in
        // `SteadyEyeApp.init`, ungated, so an abandoned onboarding still
        // registers an install. The SDK holds its first session back until this
        // prompt resolves (or its timeout elapses), so the IDFA still reaches
        // the install event when the user grants.
        // Only after the prompt resolves do we flip `hasSeenOnboarding`, which
        // drives the transition to the main UI.
        Task { @MainActor in
            await ATTManager.requestIfNeeded()
            // Now that the ATT decision is in, write the (real or all-zeros)
            // IDFA through to RevenueCat. Retries here because the launch-time
            // call ran before the user had answered.
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
