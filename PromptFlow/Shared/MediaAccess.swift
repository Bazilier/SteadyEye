import AVFoundation
import Photos

/// The system prompts recording needs (camera, microphone, Photos add-only),
/// for when onboarding never got to ask: its script step can be skipped,
/// which ends onboarding before the access step.
///
/// Must run before the camera cover is up, never from inside it: a system
/// prompt makes the scene inactive, and both `RecordingView` and the
/// preview close on that. Statuses already decided are left alone, so this
/// is a no-op for anyone who answered in onboarding. Without a prompt, iOS
/// shows no Camera / Microphone / Photos toggle under Settings → SteadyEye,
/// and the app's "Open Settings" paths lead nowhere.
enum MediaAccess {
    @MainActor
    static func requestUndetermined() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            AppAnalytics.log(granted ? "permissions_camera_granted" : "permissions_camera_denied",
                             params: ["was_prompt": true, "source": "before_recording"])
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            AppAnalytics.log(granted ? "permissions_mic_granted" : "permissions_mic_denied",
                             params: ["was_prompt": true, "source": "before_recording"])
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            let granted = status == .authorized || status == .limited
            AppAnalytics.log(granted ? "permissions_photos_granted" : "permissions_photos_denied",
                             params: ["was_prompt": true, "source": "before_recording"])
        }
    }
}
