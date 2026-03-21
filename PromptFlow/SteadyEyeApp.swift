import SwiftUI
import SwiftData
import AVFoundation

@main
struct SteadyEyeApp: App {
    @State private var container: ModelContainer?
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        cleanUpTempRecordings()
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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { _ in cont.resume() }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { _ in cont.resume() }
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
