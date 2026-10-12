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
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]

    @State private var searchText = ""
    @State private var editorMode: EditorMode?
    /// "What's your video about?", offered after the first take.
    @State private var showDraftScript = false
    /// The draft sheet closed through one of its outcomes, not the X.
    @State private var draftOutcomeTaken = false
    @State private var scriptToRecord: Script?
    /// Opens a card's recording screen after its press shrink (see
    /// `CardPressStyle`).
    @State private var cardOpener = CardOpener()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Zoom from a card into the recording screen (iOS 18+).
    @Namespace private var recordZoom
    @State private var showBulkImport = false
    @State private var paywallPresentation: PaywallPresentation?
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
    /// In-memory, per-process: `.onAppear` can re-fire when a cover above this
    /// view dismisses, and the soft-ask decision must run at most once a launch.
    private static var didCheckSoftAskThisLaunch = false

    private var filteredScripts: [Script] {
        if searchText.isEmpty { return scripts }
        return scripts.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// `filteredScripts` split into runs that share a calendar day of
    /// `updatedAt`. The query is already newest-first, so each day's
    /// scripts are contiguous.
    private var scriptsByDay: [(day: Date, scripts: [Script])] {
        let calendar = Calendar.current
        var groups: [(day: Date, scripts: [Script])] = []
        for script in filteredScripts {
            let day = calendar.startOfDay(for: script.updatedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].scripts.append(script)
            } else {
                groups.append((day, [script]))
            }
        }
        return groups
    }

    /// Trims the system header insets (10/10 pt on iOS 26, 17/6 pt on iOS
    /// 17/18) so that, with the 10 pt section spacing, a date header has 20 pt
    /// above it and 8 pt below. The leading inset stays the system one, which
    /// lines up with the cards' content at every width.
    private static var dayHeaderPadding: EdgeInsets {
        if #available(iOS 26.0, *) {
            return EdgeInsets(top: 0, leading: 0, bottom: -2, trailing: 0)
        }
        return EdgeInsets(top: -7, leading: 0, bottom: 2, trailing: 0)
    }

    /// The system row insets, applied inside the card so that the card
    /// background is part of the button and scales with the press.
    private static var cardPadding: EdgeInsets {
        if #available(iOS 26.0, *) {
            return EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
        }
        return EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
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
                            paywallPresentation = PaywallPresentation(source: "scripts_crown")
                        }) {
                            Image(systemName: "crown.fill")
                                .foregroundColor(Theme.accent)
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
            .sheet(isPresented: $showDraftScript, onDismiss: {
                // Closed without an outcome: the user declined the own
                // script, so the guided run is over.
                if !draftOutcomeTaken { OnboardingFlow.finish(reason: "declined_draft") }
                draftOutcomeTaken = false
            }) {
                DraftScriptView(onFinish: handleDraftOutcome)
                    // Burned once it is really on screen, so an offer that
                    // never got shown is retried.
                    .onAppear {
                        UserDefaults.standard.set(false, forKey: "pendingOwnScriptAfterFirstTake")
                    }
            }
            .fullScreenCover(item: $scriptToRecord) { script in
                RecordingView(script: script, selectedTab: $selectedTab)
                    .cardZoomTransition(id: script.id, in: recordZoom)
                    .onPresentationComplete { cardOpener.resetCard() }
            }
            .onChange(of: scriptToRecord) { _, script in
                // Closed before the presentation completed.
                if script == nil {
                    cardOpener.resetCard()
                    continueOnboardingFlow()
                }
            }
            .sheet(isPresented: $showBulkImport) {
                BulkImportView(entryPoint: bulkImportEntryPoint)
            }
            .fullScreenCover(item: $paywallPresentation, onDismiss: { continueOnboardingFlow() }) { presentation in
                PaywallView(source: presentation.source)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNotificationSoftAsk) {
            SoftAskNotificationView {
                Task { await NotificationScheduler.shared.requestPermissionIfNeeded() }
            }
            .onAppear {
                // The one-shot flag is burned HERE, once the sheet is really on
                // screen — a soft-ask the arbiter denied must be retryable.
                hasShownNotificationSoftAsk = true
                PromptArbiter.shared.didPresent(.notificationSoftAsk)
            }
            .onDisappear {
                PromptArbiter.shared.didDismiss()
                continueOnboardingFlow()
            }
        }
        .onAppear {
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
               !Self.didCheckSoftAskThisLaunch,
               coldStartCountAfterOnboarding >= 2 {
                Self.didCheckSoftAskThisLaunch = true
                let countAtTrigger = coldStartCountAfterOnboarding
                Task { @MainActor in
                    // 1.5s, not 0.5s: the cold-start paywall decides at 0.5s, so
                    // on a launch where both are due the paywall goes first and
                    // the arbiter's gap then defers the soft-ask to a later
                    // launch instead of stacking two modals.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    guard settings.authorizationStatus == .notDetermined else { return }
                    // No flag write here — `hasShownNotificationSoftAsk` is set
                    // in the sheet's onAppear, so a denial retries next launch.
                    guard PromptArbiter.shared.canPresent(.notificationSoftAsk) else { return }
                    showNotificationSoftAsk = true
                    AppAnalytics.log("soft_ask_shown", params: [
                        "cold_start_count": countAtTrigger
                    ])
                }
            }
            // Resume an unfinished post-onboarding flow after a relaunch. Late
            // enough that the cold-start paywall (0.5s) and the soft-ask
            // (1.5s) decide first; the arbiter sorts out any overlap.
            if !Self.didResumeFlowThisLaunch, !pendingDemoRecording {
                Self.didResumeFlowThisLaunch = true
                continueOnboardingFlow(after: 2.5)
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
            }
            .primaryButtonStyle(fullWidth: false)
            .tint(Theme.accent)

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

    /// One `Section` per script so each row renders as its own card while
    /// keeping the system List swipe-to-delete.
    private var scriptsList: some View {
        List {
            ForEach(scriptsByDay, id: \.day) { group in
                ForEach(group.scripts) { script in
                    Section {
                        Button {
                            AppAnalytics.log("script_tapped", params: [
                                "script_source": script.isDemo ? "demo" : "user",
                                "script_length_words": script.content.split(separator: " ").count
                            ])
                            cardOpener.open(script.id, reduceMotion: reduceMotion) {
                                scriptToRecord = script
                            }
                        } label: {
                            HStack {
                                ScriptRowView(script: script)
                                Spacer()
                                // Drawn in the card so it scales with it; the
                                // edit button overlaid below takes the taps.
                                Image(systemName: "square.and.pencil")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 44, height: 44)
                                    .accessibilityHidden(true)
                            }
                            .padding(Self.cardPadding)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            // Inside the press scale, so the zoom starts from
                            // the pressed frame.
                            .cardZoomSource(id: script.id, in: recordZoom)
                        }
                        .buttonStyle(CardPressStyle(id: script.id, opener: cardOpener))
                        .disabled(cardOpener.pendingID != nil)
                        .overlay(alignment: .trailing) {
                            Button {
                                editorMode = .edit(script)
                            } label: {
                                Color.clear
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.trailing, Self.cardPadding.trailing)
                            .disabled(cardOpener.pendingID != nil)
                            .accessibilityLabel(Text("scripts.editor.title.edit", comment: "Navigation title of the script editor when editing an existing script."))
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
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } header: {
                        // Only the day's first card carries the date header.
                        if script.id == group.scripts.first?.id {
                            Text(DayTitle.string(for: group.day))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                                .padding(Self.dayHeaderPadding)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .cancelsPendingCardOpen(cardOpener)
        .onDisappear { cardOpener.cancelPending() }
    }

    // MARK: - Actions

    private func deleteScript(_ script: Script) {
        modelContext.delete(script)
    }

    // MARK: - Onboarding flow, resumable

    /// In-memory, per-process: the launch-time resume runs once.
    private static var didResumeFlowThisLaunch = false

    /// Continues the post-onboarding flow wherever it was left, from any of
    /// its natural moments: the camera closing, a paywall closing, or the app
    /// launching. Two persisted marks drive it, and each is cleared only once
    /// its screen is really up, so a kill or a collision just defers it:
    ///  - `ownTakePaywallDue`: the first successful take of an own script —
    ///    the real value moment — earns free users the paywall, once.
    ///  - `pendingOwnScriptAfterFirstTake`: after the sample take, offer
    ///    "What's your video about?".
    private func continueOnboardingFlow(after delay: TimeInterval = 0.45) {
        let defaults = UserDefaults.standard
        guard hasSeenOnboarding,
              defaults.bool(forKey: "ownTakePaywallDue")
                || defaults.bool(forKey: "pendingOwnScriptAfterFirstTake")
        else { return }
        Task { @MainActor in
            // Let whatever just closed finish dismissing.
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Something else is on screen: its own dismissal comes back here,
            // or the next launch does.
            guard scriptToRecord == nil, editorMode == nil, paywallPresentation == nil,
                  !showDraftScript, !showBulkImport, !showNotificationSoftAsk,
                  !PromptArbiter.shared.isPromptVisible
            else { return }

            if defaults.bool(forKey: "ownTakePaywallDue") {
                if subscriptionManager.isSubscribed
                    || defaults.bool(forKey: "postFirstOwnRecordingPaywallShown") {
                    defaults.set(false, forKey: "ownTakePaywallDue")
                    OnboardingFlow.finish(reason: subscriptionManager.isSubscribed ? "subscribed" : "paywall_already_shown")
                } else if PromptArbiter.shared.canPresent(.onboardingPaywall) {
                    defaults.set(false, forKey: "ownTakePaywallDue")
                    defaults.set(true, forKey: "postFirstOwnRecordingPaywallShown")
                    PromptArbiter.shared.didPresent(.onboardingPaywall)
                    // The flow's planned end: ordinary prompts may run again.
                    OnboardingFlow.finish(reason: "paywall")
                    paywallPresentation = PaywallPresentation(source: "first_own_take")
                    return
                } else {
                    // Too soon after another prompt: keep the mark, retry later.
                    return
                }
            }
            if defaults.bool(forKey: "pendingOwnScriptAfterFirstTake") {
                showDraftScript = true
            }
        }
    }

    /// Where the draft screen hands off, once its sheet is down.
    private func handleDraftOutcome(_ outcome: DraftScriptView.Outcome) {
        draftOutcomeTaken = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            switch outcome {
            case .record(let script): scriptToRecord = script
            case .writeMyself: editorMode = .new
            case .paywall: paywallPresentation = PaywallPresentation(source: "ai_draft")
            }
        }
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
            paywallPresentation = PaywallPresentation(
                source: entryPoint == "toolbar"
                    ? "import_gate_post_demo"
                    : "import_gate_empty"
            )
            return
        }
        bulkImportEntryPoint = entryPoint
        showBulkImport = true
    }
}

// MARK: - Script Row

struct ScriptRowView: View {
    let script: Script

    private var wordCountText: String {
        String(
            localized: "script.wordCount",
            defaultValue: "\(script.wordCount) words",
            comment: "Word count display in script row and editor stats bar"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(script.title.isEmpty
                ? String(localized: "script.untitled", defaultValue: "Untitled Script", comment: "Fallback title for an untitled script")
                : script.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(script.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: "\(wordCountText) · \(script.estimatedReadTimeFormatted)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
