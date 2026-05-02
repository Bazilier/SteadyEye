import SwiftUI
import SwiftData
import AVFoundation
import AdServices
import FirebaseAnalytics
import FirebaseCore
import RevenueCat
import UserNotifications

@main
struct SteadyEyeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: ModelContainer?
    @StateObject private var subscriptionManager = SubscriptionManager.shared

    init() {
        // iOS doesn't auto-create the Application Support directory; SwiftData
        // tries to write its store there on first container init and the OS
        // rejects the path with errno=2 (no such file or directory) until
        // CoreData's recovery dance creates it. The recovery succeeds but
        // floods the console with errors and adds latency to every cold
        // launch. Creating the directory upfront avoids the round-trip.
        Self.ensureApplicationSupportDirectoryExists()
        cleanUpTempRecordings()

        #if !DEV
        // Sync: Crashlytics needs Firebase active before any pre-frame
        // crash so reports are captured.
        FirebaseApp.configure()

        // Configure RevenueCat synchronously and BEFORE
        // SubscriptionManager.shared.configure() so the
        // customerInfoStream listener can establish on first launch.
        // Previously this block was deferred 500ms via
        // DispatchQueue.main.asyncAfter to avoid an alleged Keychain
        // stutter; the side effect was that SubscriptionManager.configure()'s
        // `Purchases.isConfigured` guard ran first and silently skipped
        // listener setup, so renewals, expirations, refunds and trial→paid
        // transitions stopped propagating into isSubscribedReal mid-session.
        // If launch stutter resurfaces we'll address it specifically — sync
        // configure in init is the SDK-supported pattern.
        if let apiKey = SecretsManager.revenueCatAPIKey() {
            Purchases.configure(withAPIKey: apiKey)
            Purchases.shared.attribution.enableAdServicesAttributionTokenCollection()

            if let firebaseAppInstanceID = Analytics.appInstanceID() {
                Purchases.shared.attribution.setFirebaseAppInstanceID(firebaseAppInstanceID)
            }
        }
        MetaAnalytics.logAppActivation()
        #endif

        // Runs after Purchases.configure above, so its internal
        // `Purchases.isConfigured` guard passes and the customerInfoStream
        // listener attaches immediately. The guards remain as
        // defense-in-depth for the apiKey-missing edge case.
        SubscriptionManager.shared.configure()

        // Local-notification routing. The delegate owns presentation
        // policy (foreground banners) and deep-link signaling. Set after
        // SubscriptionManager.configure so any push-related logic the
        // manager schedules during configure has the delegate in place.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
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
                Task { await SubscriptionManager.shared.rescheduleInactiveReminder() }
                consumePendingDeepLink()
            } else if newPhase == .background {
                Task { await SubscriptionManager.shared.rescheduleInactiveReminder() }
            }
        }
    }

    /// Reads any deep link signaled by `NotificationDelegate` and routes
    /// the user accordingly. Called on scenePhase → .active. Phase 2
    /// wires the signal end-to-end but leaves the actual tab/route
    /// switching as a no-op until Phase 3 — implementing the routing
    /// would require touching ContentView's `selectedTab` state, which
    /// is outside this phase's scope.
    private func consumePendingDeepLink() {
        guard let link = NotificationDelegate.pendingDeepLink else { return }
        NotificationDelegate.pendingDeepLink = nil
        switch link {
        case .openScripts:
            break // TODO: implement when router supports it (Phase 3).
        case .openSettings:
            break // TODO: implement when router supports it (Phase 3).
        case .openPaywall:
            break // TODO: implement when router supports it (Phase 3).
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

    /// Idempotent: creates `Library/Application Support/` if missing. iOS
    /// doesn't ship with this directory by default, so SwiftData's first
    /// container init throws errno=2, triggers a CoreData recovery cycle,
    /// and emits a wall of error spam to the console even when recovery
    /// succeeds. Called from `init()` before the WindowGroup builds, so
    /// the path exists by the time `prepareApp()`'s `ModelContainer(...)`
    /// call runs on a background task.
    private static func ensureApplicationSupportDirectoryExists() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        if !fileManager.fileExists(atPath: appSupportURL.path) {
            try? fileManager.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
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

// MARK: - Local notification routing

/// `UNUserNotificationCenterDelegate` for foreground presentation policy
/// and tap → deep-link signaling. The delegate is registered once in
/// `SteadyEyeApp.init`. Tap handling writes the decoded route into a
/// static var that the App's scenePhase observer consumes on `.active`.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Routing target after tap, observed by `SteadyEyeApp` and reset
    /// to nil after consumed.
    @MainActor static var pendingDeepLink: NotificationDeepLink? = nil

    /// Show notifications when the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let kind = notification.request.content.userInfo["kind"] as? String ?? "unknown"
        AppAnalytics.log("push_received", params: ["kind": kind])
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let kind = response.notification.request.content.userInfo["kind"] as? String ?? "unknown"
        AppAnalytics.log("push_opened", params: ["kind": kind])

        if let link = NotificationDeepLink.decode(from: response.notification.request.content.userInfo) {
            Task { @MainActor in
                Self.pendingDeepLink = link
            }
        }
        completionHandler()
    }
}
