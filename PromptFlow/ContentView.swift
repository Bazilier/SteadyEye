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
    @StateObject private var chatBadgeState = ChatBadgeState.shared
    /// Injected at the app root; its `state` is nil except on iPhone Duo.
    @Environment(DuoDisplayMonitor.self) private var duoMonitor: DuoDisplayMonitor?
    @State private var showSettingsSheet = false

    /// iPhone Duo unfolded: scripts and recordings side by side on the two
    /// halves, no tab bar, settings from a button. Its crease, else nil.
    private var splitCrease: CGRect? {
        guard let state = duoMonitor?.state, state.posture == .unfolded else { return nil }
        return state.creaseFrame
    }

    /// The crease runs top to bottom (held like a book): halves side by side.
    private var splitSideBySide: Bool {
        guard let crease = splitCrease else { return false }
        return crease.height >= crease.width
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // One container for both layouts, so the scripts list — and an
            // editor open on it — survives folding, unfolding and turning.
            CreaseSplitLayout(
                sideBySide: splitSideBySide,
                gap: splitCrease.map { min($0.width, $0.height) } ?? 0
            ) {
                // The edge facing the crease is not an unsafe edge of the
                // display, but a half would otherwise take the whole window's
                // insets — the far side's camera inset included.
                ScriptListView(selectedTab: $selectedTab)
                    .ignoresSafeArea(edges: splitCrease == nil ? [] : (splitSideBySide ? .trailing : .bottom))
                if splitCrease != nil {
                    RecordingsView(selectedTab: $selectedTab, onOpenSettings: { showSettingsSheet = true })
                        .ignoresSafeArea(edges: splitSideBySide ? .leading : .top)
                }
            }
                // Window-wide, so the halves meet the crease; each list still
                // keeps out of the parts of the display that are not safe.
                .ignoresSafeArea(edges: splitCrease != nil ? .all : [])
                .toolbar(splitCrease != nil ? .hidden : .automatic, for: .tabBar)
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
                .badge(chatBadgeState.unreadCount)
                .tag(AppTab.settings)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Both lists are on screen when split: stay on the tab that holds
        // them, and route a request for Settings to the sheet.
        .onChange(of: splitCrease != nil, initial: true) { _, split in
            if split, selectedTab != .scripts {
                if selectedTab == .settings { showSettingsSheet = true }
                selectedTab = .scripts
            }
        }
        .onChange(of: selectedTab) { _, tab in
            guard splitCrease != nil, tab != .scripts else { return }
            if tab == .settings { showSettingsSheet = true }
            selectedTab = .scripts
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
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
            // The arbiter runs last, after this trigger's own rules, so a
            // denial here does not consume the once-per-day slot.
            if shouldShowColdStartPaywall(),
               PromptArbiter.shared.canPresent(.coldStartPaywall) {
                lastColdStartPaywallDateInterval = Date().timeIntervalSince1970
                PromptArbiter.shared.didPresent(.coldStartPaywall)
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
