import SwiftUI
import SwiftData

/// Identifiable wrapper for the editor sheet — guarantees the correct value
/// is passed into .sheet(item:), avoiding the stale-state capture bug.
enum EditorMode: Identifiable {
    case new
    case edit(Script)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let s): return s.id.uuidString
        }
    }

    var script: Script? {
        switch self {
        case .new: return nil
        case .edit(let s): return s
        }
    }
}

struct ScriptListView: View {
    /// Plumbed down to RecordingView so the HUD's tappable mic/resolution
    /// indicators can switch the host TabView to the Settings tab from inside
    /// the fullScreenCover. Owned by ContentView. Mirrors the existing
    /// RecordingsView pattern.
    @Binding var selectedTab: AppTab

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Query(sort: \Script.createdAt, order: .reverse) private var scripts: [Script]

    @State private var searchText = ""
    @State private var editorMode: EditorMode?
    @State private var scriptToRecord: Script?
    @State private var showBulkImport = false
    @State private var showPaywall = false
    @State private var paywallSource: String = ""
    /// Captured at tap time and passed into BulkImportView so the
    /// `bulk_import_opened` analytics event can split funnels by entry
    /// surface. Both the toolbar `doc.on.doc` button and the empty-state
    /// button route through `handleBulkImportTap(entryPoint:)` below.
    @State private var bulkImportEntryPoint: String = "toolbar"
    /// One-shot flag flipped to true only after a successful demo
    /// completes (3 mock scripts inserted). Drives the decision tree in
    /// `handleBulkImportTap`: first tap shows the demo regardless of
    /// subscription; subsequent taps route Pro users to the real flow
    /// and free users to the post-demo paywall.
    @AppStorage("hasSeenBulkImportDemo") private var hasSeenBulkImportDemo: Bool = false
    /// Set true by `OnboardingView.finishOnboarding` when camera permission
    /// was granted. Consumed by either `.onChange(of: hasSeenOnboarding)`
    /// (the primary trigger — fires when the onboarding cover starts
    /// dismissing) or `.onAppear` (defensive backup for cold launches where
    /// the flag persisted across a kill mid-flow). Both consumers reset
    /// pendingDemoRecording to false BEFORE setting `scriptToRecord`, so
    /// they're idempotent and don't fight each other.
    @AppStorage("pendingDemoRecording") private var pendingDemoRecording: Bool = false
    /// Observed (not written) here. The flip false → true happens inside
    /// `OnboardingView.finishOnboarding`; ScriptsList watches that flip
    /// to drive the demo auto-open. `.onAppear` doesn't fire reliably
    /// when a fullScreenCover dismisses on top of an already-mounted view,
    /// so direct binding observation is the load-bearing trigger.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    /// Counts post-onboarding cold starts. Bumped to 1 by the
    /// `.onChange(of: hasSeenOnboarding)` handler below when onboarding
    /// completes (so the onboarding session itself counts as session 1).
    /// Bumped on every subsequent cold start by `SteadyEyeApp.init()`.
    /// Read in `.onAppear` to drive the notification soft-ask trigger.
    @AppStorage("coldStartCountAfterOnboarding") private var coldStartCountAfterOnboarding: Int = 0
    /// One-shot guard. Flipped true the first time the soft-ask sheet
    /// is presented under the new (post-cold-start) trigger. Decoupled
    /// from the legacy `notificationSoftAskShown` key so existing
    /// users who saw the previous post-paywall trigger get one more
    /// chance under the better timing.
    @AppStorage("hasShownNotificationSoftAsk") private var hasShownNotificationSoftAsk: Bool = false
    @State private var showNotificationSoftAsk: Bool = false

    private var filteredScripts: [Script] {
        if searchText.isEmpty { return scripts }
        return scripts.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if scripts.isEmpty {
                    emptyStateView
                } else {
                    scriptsList
                }
            }
            .navigationTitle(Text("scripts.title", comment: "Scripts list nav title"))
            .searchable(text: $searchText, prompt: Text("scripts.search.prompt", comment: "Search bar placeholder above the script list"))
            .toolbar {
                // Free-tier upgrade entry point — hidden for Pro users.
                ToolbarItem(placement: .topBarLeading) {
                    if !subscriptionManager.isSubscribed {
                        Button(action: {
                            paywallSource = "scripts_crown"
                            showPaywall = true
                        }) {
                            Image(systemName: "crown.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        handleBulkImportTap(entryPoint: "toolbar")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editorMode = .new
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editorMode) { mode in
                ScriptEditorView(script: mode.script)
            }
            .fullScreenCover(item: $scriptToRecord) { script in
                RecordingView(script: script, selectedTab: $selectedTab)
            }
            .sheet(isPresented: $showBulkImport) {
                BulkImportView(entryPoint: bulkImportEntryPoint)
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(source: paywallSource)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNotificationSoftAsk) {
            SoftAskNotificationView {
                Task { await NotificationScheduler.shared.requestPermissionIfNeeded() }
            }
        }
        .onAppear {
            #if DEBUG
            print("📋 ScriptsList .onAppear at \(CFAbsoluteTimeGetCurrent())")
            #endif
            // Notification soft-ask trigger. Fires on the SECOND
            // post-onboarding cold start (counter == 2): the first being
            // the onboarding session itself, the second being the next
            // launch after the user kills and reopens. Gates: onboarding
            // complete, not yet shown under the new key, and the system
            // hasn't already received an authorization decision through
            // some other path. The 0.5s delay avoids modal-collision
            // with the post-onboarding auto-open's fullScreenCover, the
            // demo-completion paywall, or any other cold-start
            // navigation that may still be settling.
            if hasSeenOnboarding,
               !hasShownNotificationSoftAsk,
               coldStartCountAfterOnboarding >= 2 {
                let countAtTrigger = coldStartCountAfterOnboarding
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    guard settings.authorizationStatus == .notDetermined else { return }
                    hasShownNotificationSoftAsk = true
                    showNotificationSoftAsk = true
                    AppAnalytics.log("soft_ask_shown", params: [
                        "cold_start_count": countAtTrigger
                    ])
                }
            }
            // Defensive backup auto-open. SwiftUI's `.onAppear` does NOT
            // reliably fire when a fullScreenCover dismisses on top of an
            // already-mounted view, so the primary trigger lives in the
            // `.onChange(of: hasSeenOnboarding)` handler below. This block
            // covers the cold-launch edge case where the flag persisted
            // across a kill mid-flow (rare but possible).
            if pendingDemoRecording {
                pendingDemoRecording = false
                if let demo = scripts.first(where: { $0.isDemo }) {
                    // Transient signal consumed by RecordingView's
                    // .onAppear to suppress the camera explainer for
                    // exactly this one auto-open mount. Without this
                    // flag, RecordingView would have to use
                    // `script.isDemo` as a proxy, which would also
                    // suppress the explainer on later manual demo-script
                    // opens (wrong — only the onboarding auto-open
                    // should be silent).
                    UserDefaults.standard.set(true, forKey: "nextRecordingIsOnboardingAuto")
                    scriptToRecord = demo
                }
            }
        }
        .onChange(of: hasSeenOnboarding) { _, newValue in
            // Primary auto-open trigger: fires the moment onboarding
            // completes (`finishOnboarding` flips the AppStorage value to
            // true, after having already set pendingDemoRecording). The
            // outer onboarding cover's dismiss animation runs in parallel
            // with the inner cover's present animation, so by the time
            // the user sees ScriptsList revealed, RecordingView is already
            // sliding up on top of it.
            if newValue && pendingDemoRecording {
                pendingDemoRecording = false
                if let demo = scripts.first(where: { $0.isDemo }) {
                    #if DEBUG
                    print("📋 Auto-opening demo recording after onboarding")
                    #endif
                    UserDefaults.standard.set(true, forKey: "nextRecordingIsOnboardingAuto")
                    scriptToRecord = demo
                }
            }
            // Mark the onboarding session itself as cold-start "1" so
            // the next true cold start observed by SteadyEyeApp.init()
            // bumps to 2 and trips the notification soft-ask. Idempotent:
            // only flips when the counter is still at the install default.
            if newValue && coldStartCountAfterOnboarding == 0 {
                coldStartCountAfterOnboarding = 1
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("scripts.empty.title", comment: "Empty state title when the user has no scripts")
                .font(.title2.bold())
            Text("scripts.empty.body", comment: "Empty state body when the user has no scripts")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                editorMode = .new
            } label: {
                Label {
                    Text("scripts.new", comment: "New Script button label and editor nav title")
                } icon: {
                    Image(systemName: "plus")
                }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button {
                handleBulkImportTap(entryPoint: "empty_state")
            } label: {
                Label {
                    Text("scripts.import.title", comment: "Import Multiple Scripts button label")
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
    }

    private var scriptsList: some View {
        List {
            ForEach(filteredScripts) { script in
                HStack {
                    ScriptRowView(script: script)
                    Spacer()
                    Button {
                        editorMode = .edit(script)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    AppAnalytics.log("script_tapped", params: [
                        "script_source": script.isDemo ? "demo" : "user",
                        "script_length_words": script.content.split(separator: " ").count
                    ])
                    scriptToRecord = script
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteScript(script)
                    } label: {
                        Label {
                            Text("scripts.delete", comment: "Swipe-to-delete action on a script row")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func deleteScript(_ script: Script) {
        modelContext.delete(script)
    }

    /// Decision tree shared by every "Import Multiple Scripts" entry
    /// point (toolbar `doc.on.doc` button and empty-state button).
    /// First tap (no completed demo): present BulkImportView in demo
    /// mode regardless of subscription. After a successful demo, free
    /// users see the paywall directly; Pro users get the real import
    /// flow. The paywall source differentiates by entry point so the
    /// funnel can attribute conversions correctly.
    private func handleBulkImportTap(entryPoint: String) {
        if !hasSeenBulkImportDemo {
            bulkImportEntryPoint = entryPoint
            showBulkImport = true
            return
        }
        if !subscriptionManager.canBulkImport {
            paywallSource = entryPoint == "toolbar"
                ? "import_gate_post_demo"
                : "import_gate_empty"
            showPaywall = true
            return
        }
        bulkImportEntryPoint = entryPoint
        showBulkImport = true
    }
}

// MARK: - Script Row

struct ScriptRowView: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(script.title.isEmpty
                ? String(localized: "script.untitled", defaultValue: "Untitled Script", comment: "Fallback title for an untitled script")
                : script.title)
                .font(.headline)
            Text(script.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "text.word.spacing")
                    Text(String(
                        localized: "script.wordCount",
                        defaultValue: "\(script.wordCount) words",
                        comment: "Word count display in script row and editor stats bar"
                    ))
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(script.estimatedReadTimeFormatted)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
