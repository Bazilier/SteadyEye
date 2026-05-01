import SwiftUI
import SwiftData

enum AppTab: String, Hashable {
    case scripts, recordings, settings
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("demoScriptCreated") private var demoScriptCreated = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @AppStorage("lastColdStartPaywallDate") private var lastColdStartPaywallDateInterval: Double = 0
    @AppStorage("lastAnyPaywallShownAt") private var lastAnyPaywallShownAt: Double = 0
    @AppStorage("installDate") private var installDateInterval: Double = 0
    @State private var selectedTab: AppTab = .scripts
    @State private var showColdStartPaywall = false
    /// In-memory (NOT @AppStorage) one-shot lock so the cold-start trigger
    /// runs at most once per process lifetime. ContentView's `.onAppear` can
    /// re-fire when a fullScreenCover dismisses on top of it; without this,
    /// every paywall dismissal would re-evaluate the trigger.
    @State private var didCheckColdStartPaywallThisLaunch = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ScriptListView()
                .tabItem {
                    Label {
                        Text("scripts.title", comment: "Scripts tab label / nav title")
                    } icon: {
                        Image(systemName: "doc.text.fill")
                    }
                }
                .tag(AppTab.scripts)

            RecordingsView(selectedTab: $selectedTab)
                .tabItem {
                    Label {
                        Text(String(
                            localized: "recordings.tabTitle",
                            defaultValue: "Recordings",
                            comment: "Recordings tab label / nav title."
                        ))
                    } icon: {
                        Image(systemName: "video.fill")
                    }
                }
                .tag(AppTab.recordings)

            SettingsView()
                .tabItem {
                    Label {
                        Text("settings.title", comment: "Settings tab label / nav title")
                    } icon: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onAppear {
            // Stamp install date on the very first app launch ever. Idempotent
            // — only writes when the key is unset (== 0). Read by Rule 0 in
            // shouldShowColdStartPaywall() to suppress the paywall on the
            // user's install day. Existing installs that don't have this
            // stamped will simply have today as their "install day," skipping
            // one day of cold-start triggers — acceptable per spec.
            if installDateInterval == 0 {
                installDateInterval = Date().timeIntervalSince1970
            }
            createDemoScriptIfNeeded()
            triggerColdStartPaywallIfNeeded()
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { _ in /* dismiss handled by hasSeenOnboarding flag inside OnboardingView */ }
        )) {
            OnboardingView()
        }
        .fullScreenCover(isPresented: $showColdStartPaywall) {
            PaywallView(source: "cold_start_recurring")
        }
    }

    // MARK: - Cold-start paywall (recurring, free users only)

    /// Two frequency rules:
    ///   1. At most once per calendar day.
    ///   2. Never within 1 hour of any other paywall (read via shared
    ///      `lastAnyPaywallShownAt` written by PaywallView's onAppear, so this
    ///      cooldown applies across every source — crown taps, settings row,
    ///      AI optimize, watermark prompt, firstRecording, etc.).
    /// Pro users skip via the SubscriptionManager guard in
    /// `shouldShowColdStartPaywall()`.
    private func triggerColdStartPaywallIfNeeded() {
        // One-shot per process lifetime. ContentView.onAppear re-fires when
        // any fullScreenCover above it dismisses — without this guard, the
        // cold-start trigger would re-evaluate on every paywall close and
        // could fire repeatedly within seconds.
        guard !didCheckColdStartPaywallThisLaunch else { return }
        didCheckColdStartPaywallThisLaunch = true

        Task { @MainActor in
            // Brief delay so the UI is settled and other immediate triggers
            // (firstRecording flag check, onboarding dismissal) don't race
            // this one. 500ms is also enough for RC's checkAccess to populate
            // isSubscribedReal in the typical case.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if shouldShowColdStartPaywall() {
                lastColdStartPaywallDateInterval = Date().timeIntervalSince1970
                showColdStartPaywall = true
            }
        }
    }

    @MainActor
    private func shouldShowColdStartPaywall() -> Bool {
        // Pro users never see it. The check is a live read via the singleton,
        // not a captured snapshot — so a Pro→Free downgrade between cold
        // launches will let the trigger fire on the next launch.
        guard !SubscriptionManager.shared.isSubscribed else { return false }

        let now = Date()
        let calendar = Calendar.current

        // Rule 0: never on install day. Avoids hitting the user with a
        // recurring trigger on the same day they first opened the app, when
        // they're typically already navigating onboarding / first-recording
        // surfaces and don't need a third forced paywall.
        if installDateInterval > 0 {
            let installDate = Date(timeIntervalSince1970: installDateInterval)
            if calendar.isDate(installDate, inSameDayAs: now) {
                return false
            }
        }

        // Rule 1: at most once per calendar day.
        if lastColdStartPaywallDateInterval > 0 {
            let lastDate = Date(timeIntervalSince1970: lastColdStartPaywallDateInterval)
            if calendar.isDate(lastDate, inSameDayAs: now) {
                return false
            }
        }

        // Rule 2: at least 1 hour since any paywall (any source).
        if lastAnyPaywallShownAt > 0 {
            let elapsed = now.timeIntervalSince1970 - lastAnyPaywallShownAt
            if elapsed < 3600 {
                return false
            }
        }

        return true
    }

    private func createDemoScriptIfNeeded() {
        guard !demoScriptCreated else { return }
        // The original English demo title is intentionally hardcoded in the
        // existence-check predicate so users who already had the seeded English
        // demo on their device do not get a second copy after upgrading.
        let descriptor = FetchDescriptor<Script>(
            predicate: #Predicate { $0.title == "Demo Script" || $0.title == "Try it now" }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        guard existing.isEmpty else { demoScriptCreated = true; return }

        let demoTitle = String(
            localized: "demo.script.title",
            defaultValue: "Demo Script",
            comment: "Title of the seeded demo script created on first launch."
        )
        let demoContent = String(
            localized: "demo.script.content",
            defaultValue: "Hi. I'm reading a script right now, but my eyes stay on the camera. Words appear right under the lens, one at a time. Natural eye contact. Try it yourself — create your own script.",
            comment: "Body of the seeded demo script created on first launch. Plays through the WBW prompter to demonstrate the eye-contact mechanic. Translate naturally; the second-person closing invites the user to create their own script."
        )
        let demo = Script(
            title: demoTitle,
            content: demoContent
        )
        demo.isDemo = true
        modelContext.insert(demo)
        try? modelContext.save()
        demoScriptCreated = true
    }
}
