import SwiftUI
import SwiftData
import AVFoundation
import AdServices
import FirebaseAnalytics
import FirebaseCore
import RevenueCat

@main
struct SteadyEyeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var container: ModelContainer?
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        cleanUpTempRecordings()

        #if !DEV
        FirebaseApp.configure()
        if let apiKey = SecretsManager.revenueCatAPIKey(), !apiKey.isEmpty {
            #if DEV
            Purchases.logLevel = .debug
            #endif
            Purchases.configure(withAPIKey: apiKey)
            Purchases.shared.attribution.enableAdServicesAttributionTokenCollection()

            if let firebaseAppInstanceID = Analytics.appInstanceID() {
                Purchases.shared.attribution.setFirebaseAppInstanceID(firebaseAppInstanceID)
            }
        }
        MetaAnalytics.logAppActivation()
        #endif

        SubscriptionManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let container {
                    ContentView()
                        .modelContainer(container)
                        .environmentObject(subscriptionManager)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(1))
                            await ATTManager.requestIfNeeded()
                        }
                } else {
                    SplashView()
                        .transition(.opacity)
                        .task { await prepareApp() }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: container != nil)
        }
    }

    private func prepareApp() async {
        // 1. Request permissions (shows system dialogs over splash)
        let cameraWasPrompt = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                AppAnalytics.log(
                    granted ? "permissions_camera_granted" : "permissions_camera_denied",
                    params: ["was_prompt": cameraWasPrompt]
                )
                cont.resume()
            }
        }
        let micWasPrompt = AVAudioApplication.shared.recordPermission == .undetermined
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                AppAnalytics.log(
                    granted ? "permissions_mic_granted" : "permissions_mic_denied",
                    params: ["was_prompt": micWasPrompt]
                )
                cont.resume()
            }
        }

        // 2. ModelContainer (off main thread to avoid blocking UI)
        let schema = Schema([Script.self, AppSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let newContainer = await Task.detached {
            try? ModelContainer(for: schema, configurations: [config])
        }.value

        // 3. Device detection (warm lazy property)
        _ = DeviceDetectionService.shared.cutoutType

        // 5. Show main UI
        if let newContainer {
            container = newContainer
        } else {
            fatalError("Could not create ModelContainer")
        }
    }

    private func cleanUpTempRecordings() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "mov" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
