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
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: ModelContainer?
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        cleanUpTempRecordings()

        #if !DEV
        FirebaseApp.configure()
        if let apiKey = SecretsManager.revenueCatAPIKey(), !apiKey.isEmpty {
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
        .onChange(of: scenePhase) { _, newPhase in
            // Re-query RC every time the app becomes active. Catches the case
            // where a trial expired (or was cancelled / refunded) while the
            // app was backgrounded — without this, isSubscribedReal would
            // stay stale until the next cold launch. Belt-and-suspenders with
            // the customerInfoStream listener inside SubscriptionManager.
            if newPhase == .active {
                Task { await SubscriptionManager.shared.checkAccess() }
            }
        }
    }

    private func prepareApp() async {
        // ModelContainer (off main thread to avoid blocking UI). The Recording
        // schema changed in a breaking way (URL → relative String filenames)
        // and SwiftData can't lightweight-migrate a property type change, so
        // if init fails we wipe the on-disk store and retry. This also resets
        // Scripts/AppSettings — pre-launch trade-off, no versioned migration.
        let schema = Schema([Script.self, AppSettings.self, Recording.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let newContainer: ModelContainer? = {
            if let c = try? ModelContainer(for: schema, configurations: [config]) {
                return c
            }
            Self.wipeSwiftDataStore()
            return try? ModelContainer(for: schema, configurations: [config])
        }()

        // 3. Device detection (warm lazy property)
        _ = DeviceDetectionService.shared.cutoutType

        // 5. Show main UI
        if let newContainer {
            await migrateRecordingsIfNeeded(container: newContainer)
            container = newContainer
        } else {
            fatalError("Could not create ModelContainer")
        }
    }

    /// One-time wipe of pre-v2 `Recording` entities. The old schema persisted
    /// absolute file URLs, which silently invalidated when the app's sandbox
    /// container UUID changed across rebuilds/reinstalls. After a successful
    /// container open we delete any orphan Recording rows; if the store had
    /// to be wiped at the file level this is a no-op.
    @MainActor
    private func migrateRecordingsIfNeeded(container: ModelContainer) async {
        let key = "recordings_migrated_v2"
        if UserDefaults.standard.bool(forKey: key) { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Recording>()
        if let recordings = try? context.fetch(descriptor) {
            for recording in recordings {
                context.delete(recording)
            }
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Remove the default SwiftData store and its SQLite WAL companions.
    /// Called only when the schema is incompatible with the existing store.
    private static func wipeSwiftDataStore() {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        for suffix in ["", "-shm", "-wal"] {
            let url = appSupport.appendingPathComponent("default.store\(suffix)")
            try? FileManager.default.removeItem(at: url)
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
