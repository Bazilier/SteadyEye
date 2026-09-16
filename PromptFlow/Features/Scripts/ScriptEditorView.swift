import SwiftUI
import SwiftData
import FirebaseCrashlytics

struct ScriptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    let script: Script?

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var showingDiscardAlert = false
    @State private var isOptimizing = false
    @State private var optimizeError: String?
    @State private var showRateLimitAlert = false
    @State private var paywallPresentation: PaywallPresentation?
    @State private var showProDailyLimitAlert = false
    @State private var showEditorTip = false
    @AppStorage("hasSeenEditorTip") private var hasSeenEditorTip = false
    @State private var didLogOpen = false
    @AppStorage("hasSavedFirstScript") private var hasSavedFirstScript = false
    @FocusState private var contentFocused: Bool
    @FocusState private var titleFocused: Bool

    /// Editor demo gate. False until the user completes the demo at
    /// least once (either via the fake-optimize finish or by saving
    /// the demo content as a script).
    @AppStorage("hasSeenEditorDemo") private var hasSeenEditorDemo: Bool = false
    /// Set true on .onAppear when this open is a fresh, eligible demo
    /// run (new script + flag still false). Used in performSave for
    /// editor_demo_saved analytics, in the Optimize button to route
    /// to the fake pipeline, and in .onDisappear to detect cancellation.
    @State private var isDemoMode: Bool = false
    /// Drives the spinner state on the Optimize button while the fake
    /// pipeline is in-flight. Distinct from `isOptimizing` (real path)
    /// so the disabled/spinner conditions can union cleanly.
    @State private var isFakeOptimizing: Bool = false
    /// True only during the read-only window of the demo — between the
    /// first .onAppear that pre-fills "Before" content and the moment
    /// the fake-optimize finishes swapping in "After". While locked:
    /// title field, content editor, paste accessory, and Save button
    /// are all disabled so the user can't edit the mock. Cancel and
    /// Optimize stay active. Flips false at the end of
    /// `fakeOptimizeForDemo` to unlock for normal editing of the
    /// optimized text.
    @State private var isDemoLocked: Bool = false

    private let maxChars = 5000

    private var isNew: Bool { script == nil }

    private var hasChanges: Bool {
        // While the demo is locked, the prefilled "Before" text isn't
        // a user change — it's seed data the user can't even modify.
        // Treat it as "no changes" so Cancel dismisses immediately
        // without firing the discard-changes alert. Once the demo
        // unlocks (post-Optimize), normal dirty-tracking resumes.
        if isDemoLocked { return false }
        guard let script else { return !title.isEmpty || !content.isEmpty }
        return title != script.title || content != script.content
    }

    private var wordCount: Int { content.wordCount }

    private var estimatedReadTime: String {
        let seconds = Double(wordCount) / 150.0 * 60.0
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return String(
                localized: "script.readTime.minSec",
                defaultValue: "\(minutes) min \(secs) sec",
                comment: "Estimated read time when ≥ 1 minute. Two cardinal numbers."
            )
        }
        return String(
            localized: "script.readTime.secOnly",
            defaultValue: "\(secs) sec",
            comment: "Estimated read time under one minute."
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Title field
                TextField(
                    String(localized: "scripts.editor.titleField", defaultValue: "Script title", comment: "Placeholder for the script title text field"),
                    text: $title
                )
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .focused($titleFocused)
                    .disabled(isDemoLocked)

                Divider()

                // Content editor
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .focused($contentFocused)
                    .disabled(isDemoLocked)

                Divider()

                // Stats bar
                statsBar

                // Large bottom CTA. Always visible — both demo and
                // normal flows. Visual style matches BulkImportView's
                // Import & Optimize button.
                optimizeCTA
            }
            .navigationTitle(Text(
                isNew ? "scripts.new" : "scripts.editor.title.edit",
                comment: "Editor nav title — 'scripts.new' for new script, 'scripts.editor.title.edit' for existing"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if hasChanges {
                            showingDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text("common.cancel", comment: "Cancel button in script editor toolbar")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("common.save", comment: "Save button in script editor toolbar")
                    }
                    .bold()
                    .disabled(isDemoLocked || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !isDemoLocked {
                    ToolbarItem(placement: .keyboard) {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Text("common.pasteFromClipboard", comment: "Keyboard accessory: paste from clipboard")
                        }
                        .font(.caption)
                    }
                }
            }
            .alert(
                Text("scripts.editor.discardAlert.title", comment: "Title of discard-changes alert"),
                isPresented: $showingDiscardAlert
            ) {
                Button(role: .destructive) { dismiss() } label: {
                    Text("scripts.editor.discardAlert.discard", comment: "Destructive button on discard-changes alert")
                }
                Button(role: .cancel) {} label: {
                    Text("scripts.editor.discardAlert.keepEditing", comment: "Cancel button on discard-changes alert")
                }
            }
            .alert(
                Text("scripts.editor.optimizeFailed.title", comment: "Optimization failed alert title"),
                isPresented: .init(
                    get: { optimizeError != nil },
                    set: { if !$0 { optimizeError = nil } }
                )
            ) {
                Button {
                    optimizeError = nil
                } label: {
                    Text("common.ok", comment: "OK button on optimization-failed alert")
                }
            } message: {
                Text(optimizeError ?? "")
            }
            .alert(
                Text("common.dailyLimit.title", comment: "Daily limit alert title in editor"),
                isPresented: $showRateLimitAlert
            ) {
                Button {} label: {
                    Text("common.ok", comment: "OK button on daily limit alert")
                }
            } message: {
                Text("common.dailyLimit.message", comment: "Daily limit alert message in editor")
            }
            .fullScreenCover(item: $paywallPresentation) { presentation in
                PaywallView(source: presentation.source)
            }
            .alert(
                Text(String(
                    localized: "ai.proDailyLimit.title",
                    defaultValue: "Daily limit reached",
                    comment: "Title of the alert shown to Pro users when they hit the 30/day AI optimization limit."
                )),
                isPresented: $showProDailyLimitAlert
            ) {
                Button {} label: {
                    Text("common.ok", comment: "OK button on the Pro AI daily-limit alert.")
                }
            } message: {
                Text(String(
                    localized: "ai.proDailyLimit.body",
                    defaultValue: "Try again tomorrow.",
                    comment: "Body of the Pro AI daily-limit alert."
                ))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let script {
                title = script.title
                content = script.content
            } else {
                // New-script open. Pre-fill demo "Before" content on
                // the first eligible mount; otherwise leave the editor
                // blank as before.
                if !hasSeenEditorDemo {
                    isDemoMode = true
                    isDemoLocked = true
                    content = DemoContent.load("DemoEditorBefore", subdirectory: "EditorDemo")
                    title = String(
                        localized: "scripts.editor.demo.title",
                        comment: "Mock title pre-filled into the editor's title field during the demo flow. Read-only until the user taps Optimize, then editable."
                    )
                    AppAnalytics.log("editor_demo_shown")
                }
                // Only auto-focus the editor (raises the keyboard)
                // when the first-run tip won't show. Otherwise the
                // explainer overlay would render on top of a
                // half-screen layout. Focus is deferred to the
                // explainer's onDismiss in that case.
                if hasSeenEditorTip {
                    contentFocused = true
                }
            }
            if !didLogOpen {
                didLogOpen = true
                let source: String
                if let script {
                    source = script.isDemo ? "demo" : "user"
                } else {
                    source = "new"
                }
                AppAnalytics.log("script_opened", params: [
                    "source": source
                ])
            }
            if !hasSeenEditorTip {
                showEditorTip = true
            }
        }
        .onDisappear {
            // Funnel signal: any editor close while still in demo mode
            // (i.e. before the user tapped Optimize OR Save) counts as
            // a cancelled demo. Both Optimize-completion and Save flip
            // `hasSeenEditorDemo` to true, so successful end-states
            // short-circuit this branch.
            if isDemoMode && !hasSeenEditorDemo {
                AppAnalytics.log("editor_demo_cancelled")
            }
        }
        .overlay {
            if showEditorTip {
                ExplainerOverlay(
                    isPresented: $showEditorTip,
                    icon: "lightbulb",
                    title: "common.tip.title",
                    message: "scripts.editor.tip.body",
                    buttonLabel: "common.tip.gotIt",
                    onDismiss: {
                        hasSeenEditorTip = true
                        // Focus the editor on the next runloop tick so
                        // SwiftUI's overlay-unmount commit doesn't
                        // collide with the focus state change. New
                        // scripts (no `script`) are the only opens
                        // that benefit; existing-script edits don't
                        // auto-focus content in either branch.
                        if isNew {
                            Task { @MainActor in
                                contentFocused = true
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Stats bar

    private var charCountColor: Color {
        if content.count >= maxChars { return .red }
        if content.count >= 4000 { return .orange }
        return .secondary
    }

    @ViewBuilder
    private var aiOptimizeCaption: some View {
        if subscriptionManager.isSubscribed {
            let remaining = SubscriptionManager.proOptimizationsPerDay - subscriptionManager.proOptimizationsToday
            if remaining > 0 && remaining <= 5 {
                Text(String(
                    localized: "script.aiProRemainingCaption",
                    defaultValue: "\(remaining) optimizations left today",
                    comment: "Footer in the editor stats bar shown to Pro users when they have 5 or fewer AI optimizations left in their 30/day daily quota. %1$lld is the remaining count."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(String(
                localized: "scripts.editor.freeIndicator",
                defaultValue: "Free: 1 / day",
                comment: "Compact free-tier optimization indicator on the trailing side of the editor stats bar. Vertically centered against the two-row counters VStack."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.word.spacing")
                .foregroundStyle(.secondary)
            // All users (free and paid) share the same 5000-char cap; there is
            // no word limit.
            Text(String(
                localized: "script.charCount",
                defaultValue: "\(content.count.formatted()) / \(maxChars.formatted()) chars",
                comment: "Character count display in the editor stats bar. %1$@ is the current count, %2$@ is the limit (5000), both pre-formatted via Int.formatted() for locale-appropriate digit grouping."
            ))
                .foregroundStyle(charCountColor)
            Spacer()
            aiOptimizeCaption
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// TRIAL MODE, entitlement inactive: AI optimisation is unavailable
    /// entirely and the freemium once-per-day allowance does not apply.
    ///
    /// HYBRID MODE is deliberately excluded, which is why this reads
    /// `== .trial` and not `!= .default`. A lapsed `.hybrid` install falls back
    /// to freemium gating and keeps its one optimisation per calendar day;
    /// matching it here would take that away and make `.hybrid` indistinguish-
    /// able from `.trial`. Mirrors `SubscriptionManager.canRecord`.
    ///
    /// Evaluated at the call sites rather than folded into
    /// `SubscriptionManager.canOptimizeToday`, because that property is what
    /// freemium depends on and it also backs a DEV diagnostics readout — a third
    /// arm inside it would change both. Gated on the FROZEN mode, so an install
    /// that has not committed to trial behaves as freemium.
    private var trialRestrictionsApply: Bool {
        PaywallConfig.persistedMode == .trial && !subscriptionManager.isSubscribed
    }

    // MARK: - Optimize CTA

    /// Large bottom-of-editor primary action. Visual style mirrors
    /// BulkImportView's "Import & Optimize" button so the two demo
    /// flows share a CTA family. Tap behavior is unchanged from the
    /// previous in-stats-bar small button: demo path → fake pipeline,
    /// real path → free-tier cap / Pro daily limit / paywall / real
    /// AnthropicService call.
    @ViewBuilder
    private var optimizeCTA: some View {
        Button {
            if isDemoMode {
                fakeOptimizeForDemo()
                return
            }
            // Checked BEFORE `canOptimizeToday` so the freemium daily allowance
            // is never consulted, let alone granted, under trial restrictions.
            if trialRestrictionsApply {
                paywallPresentation = PaywallPresentation(source: "ai_optimize")
            } else if !subscriptionManager.canOptimizeToday {
                if subscriptionManager.isSubscribed {
                    showProDailyLimitAlert = true
                } else {
                    paywallPresentation = PaywallPresentation(source: "ai_optimize")
                }
            } else {
                optimizeForReading()
            }
        } label: {
            // Keep both states in the layout via opacity-only swap so
            // the button's intrinsic frame stays anchored to the
            // larger Label state. Switching the rendered subtree
            // (`if/else`) caused the button to shrink ~6-8pt when the
            // spinner showed, because ProgressView(.small) has a
            // smaller intrinsic height than Label(text+icon). ZStack
            // takes the size of its largest child (the Label), so the
            // bordered background never recomputes mid-tap.
            ZStack {
                Label {
                    Text("scripts.editor.optimize", comment: "Optimize button label — large bottom CTA in the editor. Reused for both the real Anthropic-call flow and the demo's fake-optimize flow.")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .opacity((isOptimizing || isFakeOptimizing) ? 0 : 1)

                ProgressView()
                    .controlSize(.small)
                    .opacity((isOptimizing || isFakeOptimizing) ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(isOptimizing || isFakeOptimizing || content.count > maxChars || content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private func save() {
        performSave()
    }

    private func performSave() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let untitled = String(
            localized: "script.untitled",
            defaultValue: "Untitled Script",
            comment: "Fallback title used when the user saves a script without a title"
        )
        let finalTitle = trimmedTitle.isEmpty ? untitled : trimmedTitle

        if let script {
            script.update(title: finalTitle, content: trimmedContent)
        } else {
            let newScript = Script(title: finalTitle, content: trimmedContent)
            modelContext.insert(newScript)
            if !hasSavedFirstScript {
                AppAnalytics.log("first_script_saved")
                hasSavedFirstScript = true
            }
            // Saving while still in demo mode counts as completing
            // the demo (the user kept the content, even if they
            // skipped the fake-optimize step). Flip the gate so the
            // demo doesn't re-pre-fill on the next "+" tap, and
            // suppress the .onDisappear cancelled-funnel event.
            if isDemoMode {
                hasSeenEditorDemo = true
                AppAnalytics.log("editor_demo_saved")
            }
        }
        dismiss()
    }

    /// Demo-mode replacement for `optimizeForReading()`. Runs a fixed
    /// ~1.8s sleep matching the typical real-call latency, then swaps
    /// the editor's content with the localized "After" text. No
    /// network call, no rate-limit accounting, doesn't decrement the
    /// free-tier 3-lifetime AI counter.
    private func fakeOptimizeForDemo() {
        AppAnalytics.log("editor_demo_optimize_tapped")
        isFakeOptimizing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            content = DemoContent.load("DemoEditorAfter", subdirectory: "EditorDemo")
            isFakeOptimizing = false
            // Lift the read-only lock so the user can edit the
            // optimized text, name it, and save it. `isDemoMode`
            // stays true so performSave still flips
            // `hasSeenEditorDemo` and logs `editor_demo_saved`.
            isDemoLocked = false
            // Mark demo seen BEFORE any subsequent dismiss so the
            // .onDisappear handler doesn't false-fire the cancelled
            // event for users who completed Optimize then closed
            // without saving.
            hasSeenEditorDemo = true
            AppAnalytics.log("editor_demo_completed")
            // Intentionally NOT setting `titleFocused = true` here —
            // the user just tapped Optimize and is reading the result,
            // not ready to type. Tapping the title or content fields
            // afterward raises the keyboard via standard SwiftUI focus
            // tracking. The `@FocusState`/`.focused(...)` plumbing
            // remains so future code can target focus deliberately.
        }
    }

    private func optimizeForReading() {
        // Defence-in-depth, mirroring the CTA branch above.
        guard !trialRestrictionsApply else {
            paywallPresentation = PaywallPresentation(source: "ai_optimize")
            return
        }
        guard subscriptionManager.canOptimizeToday else {
            paywallPresentation = PaywallPresentation(source: "ai_optimize")
            return
        }
        guard RateLimiter.canMakeAPICall() else {
            showRateLimitAlert = true
            return
        }
        AppAnalytics.log("ai_optimize_tapped", params: [
            "is_subscribed": subscriptionManager.isSubscribed
        ])
        isOptimizing = true
        Task {
            let startTime = Date()
            do {
                let aiResult = try await AnthropicService.optimizeForReading(content)
                let cleaned = ScriptFormatter.cleanUp(aiResult)
                content = cleaned
                subscriptionManager.recordOptimizationUse()
                AppAnalytics.log("ai_optimize_succeeded", params: [
                    "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000)
                ])
            } catch {
                let reason: String
                if let svc = error as? AnthropicService.ServiceError {
                    switch svc {
                    case .missingAPIKey: reason = "missing_api_key"
                    case .networkError: reason = "network"
                    case .httpError: reason = "http_error"
                    case .decodingError: reason = "decoding"
                    case .emptyResponse: reason = "empty_response"
                    }
                } else {
                    reason = String(describing: type(of: error))
                }
                AppAnalytics.log("ai_optimize_failed", params: [
                    "error_reason": reason,
                    "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000)
                ])
                #if !DEV
                Crashlytics.crashlytics().record(error: error)
                #endif
                optimizeError = String(
                    localized: "scripts.editor.error.formatFailed",
                    defaultValue: "Could not format script. Check connection.",
                    comment: "User-facing error when AI optimization fails. Wraps the underlying ServiceError which is developer-only."
                )
            }
            isOptimizing = false
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if content.isEmpty {
            content = text
        } else {
            content += "\n\n" + text
        }
    }
}
