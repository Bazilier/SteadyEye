import SwiftUI
import SwiftData
import FirebaseCrashlytics

struct ScriptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    let script: Script?
    /// False when the user just chose to write it themselves instead.
    var offersDraft = true

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var showingDiscardAlert = false
    @State private var isOptimizing = false
    @State private var optimizeError: String?
    @State private var showRateLimitAlert = false
    @State private var paywallPresentation: PaywallPresentation?
    @State private var showProDailyLimitAlert = false
    @State private var showEditorTip = false
    /// "What's your video about?" in insert mode, for an empty editor.
    @State private var showDraftSheet = false
    /// The optimize tip: shown once, the first time the editor holds the
    /// user's own text (see `scheduleOptimizeTip`).
    @AppStorage("hasSeenEditorTip") private var hasSeenEditorTip = false
    @State private var optimizeTipTask: Task<Void, Never>?
    /// A number from the user's own text and its spelled-out form, as the
    /// tip's example.
    @State private var optimizeTipExample: (digits: String, words: String)?
    /// The text came from an AI draft, which is already written to be said.
    @State private var contentIsDraft = false
    @State private var didLogOpen = false
    @AppStorage("hasSavedFirstScript") private var hasSavedFirstScript = false
    @FocusState private var contentFocused: Bool
    @FocusState private var titleFocused: Bool

    private let maxChars = 5000

    private var isNew: Bool { script == nil }

    private var hasChanges: Bool {
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

                Divider()

                // Content editor
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .focused($contentFocused)
                    .onChange(of: content) { _, text in scheduleOptimizeTip(for: text) }

                Divider()

                // Stats bar
                statsBar

                // Large bottom CTA. Visual style matches BulkImportView's
                // Import & Optimize button. With nothing to optimize yet,
                // it offers to draft the script instead.
                if showsDraftCTA {
                    draftCTA
                } else {
                    optimizeCTA
                }
            }
            .navigationTitle(Text(
                isNew ? "scripts.new" : "scripts.editor.title.edit",
                comment: "Editor nav title — 'scripts.new' for new script, 'scripts.editor.title.edit' for existing"
            ))
            // Lives here, not on the CTA: filling the editor removes the CTA.
            .sheet(isPresented: $showDraftSheet) {
                DraftScriptView(purpose: .insert) { outcome in
                    switch outcome {
                    case .insert(let draftTitle, let text):
                        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            title = draftTitle
                        }
                        contentIsDraft = true
                        content = text
                    case .paywall:
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            paywallPresentation = PaywallPresentation(source: "ai_draft")
                        }
                    case .record, .writeMyself:
                        break
                    }
                }
            }
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
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .keyboard) {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Text("common.pasteFromClipboard", comment: "Keyboard accessory: paste from clipboard")
                    }
                    .font(.caption)
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
                contentFocused = true
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
        }
        .onDisappear { optimizeTipTask?.cancel() }
        .coachSheet(
            isPresented: $showEditorTip,
            icon: "wand.and.stars",
            title: Text(String(
                localized: "editor.optimize_tip.title",
                defaultValue: "Make it easy to say",
                comment: "Title of the tip shown the first time the editor holds the user's own text: what Optimize does."
            )),
            message: Text(optimizeTipMessage),
            buttonLabel: Text("scripts.editor.optimize", comment: "Optimize button label — large bottom CTA in the editor."),
            onDismiss: { hasSeenEditorTip = true },
            onPrimary: {
                AppAnalytics.log("optimize_tip_optimize_tapped")
                handleOptimizeTap()
            }
        )
    }

    // MARK: - Optimize tip

    /// Offers Optimize once, the first time the editor holds the user's own
    /// text: enough of it to be worth optimizing, after a short pause in
    /// typing or right after a paste. Not for an AI draft (already written
    /// to be said) or the sample script.
    private func scheduleOptimizeTip(for text: String) {
        optimizeTipTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cleared: whatever comes next is the user's own again.
        if trimmed.isEmpty { contentIsDraft = false }
        guard !hasSeenEditorTip, !contentIsDraft, script?.isDemo != true,
              !isOptimizing, trimmed.count >= 100, text.count <= maxChars
        else { return }
        optimizeTipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, !showDraftSheet, paywallPresentation == nil, !hasSeenEditorTip
            else { return }
            optimizeTipExample = Self.numberExample(in: content)
            contentFocused = false
            titleFocused = false
            showEditorTip = true
            AppAnalytics.log("optimize_tip_shown", params: ["has_example": optimizeTipExample != nil])
        }
    }

    private var optimizeTipMessage: String {
        var lines = [String(
            localized: "editor.optimize_tip.body",
            defaultValue: "Optimize prepares your text for reading aloud: numbers become words, abbreviations are spelled out, long sentences get shorter.",
            comment: "Body of the tip shown the first time the editor holds the user's own text."
        )]
        if let example = optimizeTipExample {
            lines.append(String(
                localized: "editor.optimize_tip.example",
                defaultValue: "For example, “\(example.digits)” becomes “\(example.words)”.",
                comment: "Example line in the optimize tip, taken from the user's own text. First placeholder: a number as digits; second: the same number spelled out in words."
            ))
        }
        lines.append(String(
            localized: "editor.optimize_tip.pause",
            defaultValue: "Tip: type // where you want a pause.",
            comment: "Last line of the optimize tip: how to add a pause marker."
        ))
        return lines.joined(separator: "\n\n")
    }

    /// The first whole number in `text` (up to six digits, not part of a
    /// decimal or a longer token) and its spelled-out form in the app's
    /// language.
    private static func numberExample(in text: String) -> (digits: String, words: String)? {
        // NSRegularExpression: Swift Regex has no lookbehind.
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\d.,])\d{1,6}(?!\d|[.,]\d)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let value = Int(text[range])
        else { return nil }
        let digits = String(text[range])
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        guard let words = formatter.string(from: NSNumber(value: value)) else { return nil }
        return (digits, words)
    }

    // MARK: - Stats bar

    private var charCountColor: Color {
        if content.count >= maxChars { return .red }
        if content.count >= 4000 { return Theme.warning }
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
            // The optimize allowance; beside the draft button it would read
            // as the draft's.
            if !showsDraftCTA { aiOptimizeCaption }
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

    // MARK: - Draft CTA

    /// Too little text to optimize: draft instead.
    private var showsDraftCTA: Bool {
        offersDraft && content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
    }

    private var draftCTA: some View {
        Button {
            AppAnalytics.log("editor_draft_tapped")
            contentFocused = false
            titleFocused = false
            showDraftSheet = true
        } label: {
            Label {
                Text(String(
                    localized: "scripts.editor.draft",
                    defaultValue: "Draft with AI",
                    comment: "Large bottom button in an empty script editor: drafts the script from a topic."
                ))
            } icon: {
                Image(systemName: "sparkles")
            }
            .frame(maxWidth: .infinity)
        }
        .primaryButtonStyle()
        .tint(Theme.accent)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    // MARK: - Optimize CTA

    /// Large bottom-of-editor primary action. Visual style mirrors
    /// BulkImportView's "Import & Optimize" button. Free-tier cap / Pro daily
    /// limit / paywall / real AnthropicService call.
    @ViewBuilder
    private var optimizeCTA: some View {
        Button(action: handleOptimizeTap) {
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
                    Text("scripts.editor.optimize", comment: "Optimize button label — large bottom CTA in the editor.")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .opacity(isOptimizing ? 0 : 1)

                ProgressView()
                    .controlSize(.small)
                    .opacity(isOptimizing ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        }
        .primaryButtonStyle()
        .tint(Theme.accent)
        .disabled(isOptimizing || content.count > maxChars || content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private func handleOptimizeTap() {
        // Optimizing on their own means they found it: no tip needed.
        hasSeenEditorTip = true
        optimizeTipTask?.cancel()
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
    }

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
        }
        dismiss()
    }

    private func optimizeForReading() {
        // Defence-in-depth, mirroring `handleOptimizeTap`.
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
                let svc = error as? AnthropicService.ServiceError
                let reason: String
                if let svc {
                    switch svc {
                    case .missingAPIKey: reason = "missing_api_key"
                    case .networkError: reason = "network"
                    case .httpError: reason = "http_error"
                    case .decodingError: reason = "decoding"
                    case .emptyResponse: reason = "empty_response"
                    case .subscriptionRequired: reason = "subscription_required"
                    case .freeQuotaExhausted: reason = "free_quota_exhausted"
                    case .rateLimited: reason = "rate_limited"
                    case .aiDisabled: reason = "ai_disabled"
                    case .inputTooLong: reason = "input_too_long"
                    case .cannotDraft: reason = "cannot_draft"
                    }
                } else {
                    reason = String(describing: type(of: error))
                }
                AppAnalytics.log("ai_optimize_failed", params: [
                    "error_reason": reason,
                    "duration_ms": Int(Date().timeIntervalSince(startTime) * 1000)
                ])
                // The proxy's quota/entitlement answers are product states, not
                // failures: route them to the surfaces the CTA already uses and
                // keep them out of Crashlytics, which should stay a signal of
                // things actually going wrong.
                switch svc {
                case .some(.freeQuotaExhausted), .some(.subscriptionRequired):
                    paywallPresentation = PaywallPresentation(source: "ai_optimize")
                case .some(.rateLimited):
                    showRateLimitAlert = true
                default:
                    #if !DEV
                    Crashlytics.crashlytics().record(error: error)
                    #endif
                    optimizeError = String(
                        localized: "scripts.editor.error.formatFailed",
                        defaultValue: "Could not format script. Check connection.",
                        comment: "User-facing error when AI optimization fails. Wraps the underlying ServiceError which is developer-only."
                    )
                }
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
