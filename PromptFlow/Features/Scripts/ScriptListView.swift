import SwiftUI
import AVFoundation
import SwiftData

/// Identifiable wrapper for the editor sheet — guarantees the correct value
/// is passed into .sheet(item:), avoiding the stale-state capture bug.
enum EditorMode: Identifiable {
    case new
    /// A new script the user chose to write themselves, from the draft
    /// screen: the editor does not offer the AI draft again.
    case newSelfWritten
    case edit(Script)

    var id: String {
        switch self {
        case .new: return "new"
        case .newSelfWritten: return "newSelfWritten"
        case .edit(let s): return s.id.uuidString
        }
    }

    var script: Script? {
        switch self {
        case .new, .newSelfWritten: return nil
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
    @AppStorage("hasCompletedFirstRecording") private var hasCompletedFirstRecording = false
    /// "Pick up where you left off?" after a relaunch mid-run.
    @State private var showResumeAlert = false
    @State private var pendingResumeStep: OnboardingFlow.ResumeStep?
    @Environment(\.scenePhase) private var scenePhase
    /// "How did your video turn out?", once the user is back after exporting.
    @State private var showAfterExportPrompt = false
    @State private var pendingFounderChat = false
    @State private var showFounderChat = false
    @State private var scriptToRecord: Script?
    /// Injected at the app root; its `state` is nil except on iPhone Duo.
    @Environment(DuoDisplayMonitor.self) private var duoMonitor: DuoDisplayMonitor?
    /// The recording screen is on screen. While it is, unfolding is its own
    /// business (`RecordingView.closeForUnfold`): the cover must not vanish
    /// under a take.
    @State private var recordingPresented = false
    @State private var showFoldToRecordToast = false
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
    /// Set true by `OnboardingView.finishOnboarding` when camera and
    /// microphone were granted. Consumed by either `.onChange(of:
    /// hasSeenOnboarding)` (the primary trigger — fires when the onboarding
    /// cover starts dismissing) or `.onAppear` (defensive backup for cold
    /// launches where the flag persisted across a kill mid-flow). Both
    /// consumers go through `openFlowScriptAfterOnboarding`, which resets it
    /// BEFORE setting `scriptToRecord`, so they don't fight each other.
    @AppStorage(OnboardingFlow.pendingRecordingKey) private var pendingFlowRecording: Bool = false
    /// Observed (not written) here. The flip false → true happens inside
    /// `OnboardingView.finishOnboarding`; ScriptsList watches that flip
    /// to drive the first-take auto-open. `.onAppear` doesn't fire reliably
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

    private var isDuoUnfolded: Bool { duoMonitor?.state?.posture == .unfolded }

    /// iPhone Duo records folded only: a warning tap and a toast, not a
    /// modal in the way of the list.
    private func showFoldToRecord() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        showFoldToRecordToast = true
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
                ScriptEditorView(script: mode.script, offersDraft: mode.id != EditorMode.newSelfWritten.id)
                    // Nearly the whole display on a wide screen (iPhone Duo
                    // unfolded) rather than a small card; the same on a phone.
                    .pageSizedSheet()
            }
            .sheet(isPresented: $showDraftScript, onDismiss: {
                // Closed without an outcome: the user declined the own
                // script, so the guided run is over.
                if !draftOutcomeTaken { OnboardingFlow.abandon(reason: "declined_draft") }
                draftOutcomeTaken = false
            }) {
                DraftScriptView(onFinish: handleDraftOutcome)
                    // Burned once it is really on screen, so an offer that
                    // never got shown is retried.
                    .onAppear {
                        UserDefaults.standard.set(false, forKey: "pendingOwnScriptAfterFirstTake")
                    }
            }
            // iPhone Duo records folded only: unfolded, every way into the
            // camera — card, onboarding auto-open, resume, draft — ends in the
            // fold alert instead (see `onChange` below).
            .fullScreenCover(item: Binding(
                get: { isDuoUnfolded && !recordingPresented ? nil : scriptToRecord },
                set: { scriptToRecord = $0 }
            )) { script in
                RecordingView(
                    script: script,
                    selectedTab: $selectedTab,
                    // After the cover is down, so the toast shows on the list.
                    onClosedByUnfold: {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showFoldToRecord() }
                    }
                )
                    .cardZoomTransition(id: script.id, in: recordZoom)
                    .onPresentationComplete { cardOpener.resetCard() }
                    .onAppear { recordingPresented = true }
                    .onDisappear { recordingPresented = false }
            }
            .onChange(of: scriptToRecord) { _, script in
                if let script, isDuoUnfolded, !recordingPresented {
                    AppAnalytics.log("duo_record_blocked_unfolded", params: [
                        "script_source": script.isDemo ? "demo" : "user"
                    ])
                    scriptToRecord = nil
                    showFoldToRecord()
                    return
                }
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
                PaywallView(
                    source: presentation.source,
                    pillPhrase: presentation.pillPhrase,
                    eyeContact: presentation.eyeContact
                )
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Back from Settings with camera and microphone on: the first take.
            openFlowScriptIfBackFromSettings()
            // Back from posting the video they exported: a good moment to ask.
            offerAfterExportReviewIfDue()
        }
        .sheet(isPresented: $showAfterExportPrompt, onDismiss: {
            // Sequenced, not stacked: the chat waits for this sheet to close.
            guard pendingFounderChat else { return }
            pendingFounderChat = false
            showFounderChat = true
        }) {
            SatisfactionPromptView(
                trigger: .afterExport,
                onRate: {
                    ReviewPromptManager.noteAnsweredYes()
                    ReviewPromptManager.openWriteReviewPage()
                },
                onNo: { pendingFounderChat = true }
            )
            .onAppear {
                ReviewPromptManager.notePresented()
                ReviewPromptManager.clearExport()
                PromptArbiter.shared.didPresent(.reviewPrompt)
            }
            .onDisappear { PromptArbiter.shared.didDismiss() }
        }
        .sheet(isPresented: $showFounderChat) {
            ChatView(pinnedMessage: .satisfactionFollowUp)
        }
        .toast(
            isPresented: $showFoldToRecordToast,
            message: String(localized: "duo.fold_to_record.toast", defaultValue: "Fold your iPhone to record. The text sits under the outer camera.", comment: "Toast on an unfolded iPhone Duo when the user tries to record, or after unfolding closed the camera: recording works folded only."),
            style: .warning,
            duration: 3.5
        )
        .alert(
            String(localized: "onboarding_flow.resume.title", defaultValue: "Pick up where you left off?", comment: "Alert on launch when the guided first run was left unfinished."),
            isPresented: $showResumeAlert
        ) {
            Button(String(localized: "onboarding_flow.resume.no", defaultValue: "No, thanks", comment: "Button: do not resume the guided first run; it will not come back."), role: .cancel) {
                AppAnalytics.log("onboarding_flow_resume_declined")
                OnboardingFlow.abandon(reason: "declined_resume")
                pendingResumeStep = nil
            }
            Button(String(localized: "onboarding_flow.resume.yes", defaultValue: "Continue", comment: "Button: resume the guided first run where it stopped.")) {
                if let step = pendingResumeStep { resume(step) }
                pendingResumeStep = nil
            }
        } message: {
            Text(String(localized: "onboarding_flow.resume.message", defaultValue: "You were setting up your first video.", comment: "Message of the alert offering to resume the guided first run."))
        }
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
            // An unfinished guided run after a relaunch: offer to pick it up.
            // (The cold-start paywall and soft-ask stand down while it is
            // active, so nothing competes with this.)
            if !Self.didResumeFlowThisLaunch, !pendingFlowRecording,
               !UserDefaults.standard.bool(forKey: OnboardingFlow.awaitingSettingsKey) {
                Self.didResumeFlowThisLaunch = true
                offerToResumeFlow()
                offerAfterExportReviewIfDue()
            }
            // Defensive backup auto-open. SwiftUI's `.onAppear` does NOT
            // reliably fire when a fullScreenCover dismisses on top of an
            // already-mounted view, so the primary trigger lives in the
            // `.onChange(of: hasSeenOnboarding)` handler below. This block
            // covers the cold-launch edge case where the flag persisted
            // across a kill mid-flow (rare but possible).
            openFlowScriptAfterOnboarding()
            openFlowScriptIfBackFromSettings()
        }
        .onChange(of: hasSeenOnboarding) { _, newValue in
            // Primary auto-open trigger: fires the moment onboarding
            // completes (`finishOnboarding` flips the AppStorage value to
            // true, after having already set pendingFlowRecording). The
            // outer onboarding cover's dismiss animation runs in parallel
            // with the inner cover's present animation, so by the time
            // the user sees ScriptsList revealed, RecordingView is already
            // sliding up on top of it.
            if newValue { openFlowScriptAfterOnboarding() }
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

    /// No scripts yet (a new user who skipped the script in onboarding, or
    /// someone who deleted them all): the same two ways in as onboarding.
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(String(
                localized: "scripts.empty.first_title",
                defaultValue: "Your first script goes here",
                comment: "Empty state title on the scripts list when the user has no scripts."
            ))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(String(
                localized: "scripts.empty.first_body",
                defaultValue: "Tell us what your video is about and we’ll write it, or paste your own text.",
                comment: "Empty state body on the scripts list: the AI drafts a script from a topic, or the user pastes their own."
            ))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                AppAnalytics.log("scripts_empty_write_tapped")
                showDraftScript = true
            } label: {
                Label(
                    String(localized: "onboarding.script.write", defaultValue: "Write my script", comment: "Primary button on the onboarding script step: the AI writes a script from the topic, or, with no topic, the ready-made sample is used."),
                    systemImage: "sparkles"
                )
                .frame(maxWidth: .infinity)
            }
            .primaryButtonStyle()
            .padding(.top, 8)
            Button {
                AppAnalytics.log("scripts_empty_paste_tapped")
                editorMode = .newSelfWritten
            } label: {
                Text(String(
                    localized: "scripts.empty.paste",
                    defaultValue: "Paste my own text",
                    comment: "Secondary button on the empty scripts list: open an empty script editor to paste or type a script."
                ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
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
                    paywallPresentation = OwnTakePaywall.presentation(scripts: scripts)
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

    /// After a relaunch mid-run: ask whether to continue, then go to the
    /// step it stopped at, or count the run as done. The planned paywall,
    /// if that is all that is left, is shown without asking — a "continue?"
    /// that leads to a paywall would be a trap.
    private func offerToResumeFlow() {
        guard hasSeenOnboarding else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard scriptToRecord == nil, editorMode == nil, paywallPresentation == nil,
                  !showDraftScript, !showBulkImport
            else { return }
            switch OnboardingFlow.resumeStep(hasRecordedAnything: hasCompletedFirstRecording) {
            case .none:
                OnboardingFlow.finish(reason: "nothing_left")
            case .paywall:
                continueOnboardingFlow(after: 0)
            case .some(let step):
                pendingResumeStep = step
                showResumeAlert = true
                AppAnalytics.log("onboarding_flow_resume_offered")
            }
        }
    }

    private func resume(_ step: OnboardingFlow.ResumeStep) {
        AppAnalytics.log("onboarding_flow_resumed")
        switch step {
        case .paywall:
            continueOnboardingFlow(after: 0)
        case .sampleTake:
            if let demo = scripts.first(where: { $0.isDemo }) {
                scriptToRecord = demo
            } else {
                OnboardingFlow.abandon(reason: "sample_missing")
            }
        case .draft:
            UserDefaults.standard.set(true, forKey: "pendingOwnScriptAfterFirstTake")
            showDraftScript = true
        case .ownTake(let id):
            if let script = scripts.first(where: { $0.id == id }) {
                scriptToRecord = script
            } else {
                UserDefaults.standard.set(true, forKey: "pendingOwnScriptAfterFirstTake")
                showDraftScript = true
            }
        }
    }

    /// Onboarding ended with access granted: the camera opens on the script
    /// it saved, for the first take.
    private func openFlowScriptAfterOnboarding() {
        guard pendingFlowRecording else { return }
        pendingFlowRecording = false
        guard let id = OnboardingFlow.flowScriptID,
              let script = scripts.first(where: { $0.id == id })
        else { return }
        // Transient signal consumed by RecordingView's .onAppear to suppress
        // the camera explainer for exactly this one auto-open mount.
        UserDefaults.standard.set(true, forKey: "nextRecordingIsOnboardingAuto")
        scriptToRecord = script
    }

    /// The user went to Settings from onboarding's access-denied screen. Back
    /// with camera and microphone on, the camera opens on their script; back
    /// without, nothing happens and the script waits in the list.
    private func openFlowScriptIfBackFromSettings() {
        let defaults = UserDefaults.standard
        guard hasSeenOnboarding, defaults.bool(forKey: OnboardingFlow.awaitingSettingsKey) else { return }
        guard OnboardingFlow.isActive,
              let id = OnboardingFlow.flowScriptID,
              let script = scripts.first(where: { $0.id == id })
        else {
            defaults.removeObject(forKey: OnboardingFlow.awaitingSettingsKey)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVAudioApplication.shared.recordPermission == .granted,
              scriptToRecord == nil, editorMode == nil, paywallPresentation == nil
        else { return }
        defaults.removeObject(forKey: OnboardingFlow.awaitingSettingsKey)
        AppAnalytics.log("onboarding_back_from_settings_camera_opened")
        UserDefaults.standard.set(true, forKey: "nextRecordingIsOnboardingAuto")
        scriptToRecord = script
    }

    /// The deferred after-export ask (see `ReviewPromptManager`), when it is
    /// due and nothing else is on screen; otherwise it waits for the next
    /// return to the app.
    private func offerAfterExportReviewIfDue() {
        Task { @MainActor in
            // After launch-time prompts have had their turn.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard scenePhase == .active, scriptToRecord == nil, editorMode == nil,
                  paywallPresentation == nil, !showDraftScript, !showBulkImport,
                  !showNotificationSoftAsk, !showResumeAlert, !showAfterExportPrompt,
                  ReviewPromptManager.shouldPresentAfterExport()
            else { return }
            showAfterExportPrompt = true
        }
    }

    /// Where the draft screen hands off, once its sheet is down.
    private func handleDraftOutcome(_ outcome: DraftScriptView.Outcome) {
        draftOutcomeTaken = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            switch outcome {
            case .record(let script):
                // Remembered so a relaunch can resume on this script's take.
                UserDefaults.standard.set(script.id.uuidString, forKey: OnboardingFlow.flowScriptIDKey)
                scriptToRecord = script
            case .insert: break
            case .writeMyself: editorMode = .newSelfWritten
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

private extension View {
    @ViewBuilder func pageSizedSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
