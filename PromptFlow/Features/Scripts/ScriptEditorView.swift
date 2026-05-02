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
    @State private var showPaywall = false
    @State private var paywallSource: String = "ai_optimize"
    @State private var showWordLimitAlert = false
    @State private var showPasteLimitAlert = false
    @State private var showProDailyLimitAlert = false
    @State private var pendingPasteText: String = ""
    @State private var pendingPasteWordCount: Int = 0
    @State private var showEditorTip = false
    @AppStorage("hasSeenEditorTip") private var hasSeenEditorTip = false
    @State private var didLogOpen = false
    @AppStorage("hasSavedFirstScript") private var hasSavedFirstScript = false
    @FocusState private var contentFocused: Bool

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

                Divider()

                // Content editor
                TextEditor(text: $content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .focused($contentFocused)

                Divider()

                // Stats bar
                statsBar
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
            .alert(
                Text(String(
                    localized: "scripts.editor.wordLimit.title",
                    defaultValue: "Script too long",
                    comment: "Title of the alert shown to free users on Save when their script exceeds 50 words."
                )),
                isPresented: $showWordLimitAlert
            ) {
                Button {
                    content = content.trimmedToFirstWords(50)
                    performSave()
                } label: {
                    Text(String(
                        localized: "scripts.editor.wordLimit.trim",
                        defaultValue: "Trim to 50 words",
                        comment: "Word-limit alert primary action: trim the script to its first 50 words and save."
                    ))
                }
                Button {
                    paywallSource = "word_limit"
                    showPaywall = true
                } label: {
                    Text(String(
                        localized: "scripts.editor.wordLimit.upgrade",
                        defaultValue: "Upgrade",
                        comment: "Word-limit alert action that opens the paywall."
                    ))
                }
                Button(role: .cancel) {} label: {
                    Text("common.cancel", comment: "Cancel button on word-limit alert")
                }
            } message: {
                Text(String(
                    localized: "scripts.editor.wordLimit.body",
                    defaultValue: "Your script is \(content.wordCount) words. Free version supports up to 50 words. Trim to 50 words or upgrade for unlimited length.",
                    comment: "Body of the word-limit alert. %1$lld is the current word count of the script."
                ))
            }
            .alert(
                Text(String(
                    localized: "scripts.editor.pasteLimit.title",
                    defaultValue: "Pasted text too long",
                    comment: "Title of the alert shown to free users when pasting text would exceed the 50-word limit."
                )),
                isPresented: $showPasteLimitAlert
            ) {
                Button {
                    let appended = (content.isEmpty ? "" : content + "\n\n") + pendingPasteText
                    content = appended.trimmedToFirstWords(50)
                    pendingPasteText = ""
                } label: {
                    Text(String(
                        localized: "scripts.editor.pasteLimit.useFirst50",
                        defaultValue: "Use first 50 words",
                        comment: "Paste-limit alert primary action: trim the combined existing+pasted text to 50 words."
                    ))
                }
                Button {
                    paywallSource = "word_limit"
                    showPaywall = true
                } label: {
                    Text(String(
                        localized: "scripts.editor.wordLimit.upgrade",
                        defaultValue: "Upgrade",
                        comment: "Paste-limit alert action that opens the paywall."
                    ))
                }
                Button(role: .cancel) {
                    pendingPasteText = ""
                } label: {
                    Text("common.cancel", comment: "Cancel button on paste-limit alert")
                }
            } message: {
                Text(String(
                    localized: "scripts.editor.pasteLimit.body",
                    defaultValue: "Pasted text is \(pendingPasteWordCount) words. Free version supports up to 50. Use first 50 words or upgrade?",
                    comment: "Body of the paste-limit alert. %1$lld is the word count of the pasted text."
                ))
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(source: paywallSource)
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
            if !hasSeenEditorTip {
                showEditorTip = true
            }
        }
        .alert(
            Text("common.tip.title", comment: "First-run tip alert title in editor"),
            isPresented: $showEditorTip
        ) {
            Button {
                hasSeenEditorTip = true
            } label: {
                Text("common.tip.gotIt", comment: "Got it button dismissing the editor tip")
            }
        } message: {
            Text("scripts.editor.tip.body", comment: "Editor first-run tip body — references the Optimize button and the // pause-marker syntax")
        }
    }

    // MARK: - Stats bar

    private var charCountColor: Color {
        if content.count >= maxChars { return .red }
        if content.count >= 4000 { return .orange }
        return .secondary
    }

    private var wordCountColor: Color {
        if subscriptionManager.isSubscribed { return .secondary }
        if wordCount >= 50 { return .red }
        if wordCount >= 40 { return .orange }
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
                localized: "script.aiDailyCaption",
                defaultValue: "Free: 1 optimization per day",
                comment: "Footer in the editor stats bar telling free users they get one AI optimization per calendar day."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statsBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 20) {
                Label {
                    if subscriptionManager.isSubscribed {
                        Text(String(
                            localized: "script.wordCount",
                            defaultValue: "\(wordCount) words",
                            comment: "Word count display in the editor stats bar"
                        ))
                    } else {
                        Text(String(
                            localized: "script.wordCountLimited",
                            defaultValue: "\(wordCount) / 50 words",
                            comment: "Word count display in the editor stats bar with the free-tier 50-word limit. %1$lld is the current word count; 50 is the cap."
                        ))
                            .foregroundStyle(wordCountColor)
                    }
                } icon: {
                    Image(systemName: "text.word.spacing")
                }
                Text("\(content.count.formatted()) / \(maxChars.formatted())")
                    .foregroundStyle(charCountColor)
                Spacer()
                Button {
                    if !subscriptionManager.canOptimizeToday {
                        if subscriptionManager.isSubscribed {
                            showProDailyLimitAlert = true
                        } else {
                            paywallSource = "ai_optimize"
                            showPaywall = true
                        }
                    } else {
                        optimizeForReading()
                    }
                } label: {
                    if isOptimizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label {
                            Text("scripts.editor.optimize", comment: "Optimize button label in editor stats bar")
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(isOptimizing || content.count > maxChars || content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
            }
            aiOptimizeCaption
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func save() {
        if content.wordCount > subscriptionManager.maxScriptWords {
            showWordLimitAlert = true
            return
        }
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
        guard subscriptionManager.canOptimizeToday else {
            paywallSource = "ai_optimize"
            showPaywall = true
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
        let combined = (content.isEmpty ? "" : content + "\n\n") + text
        if combined.wordCount > subscriptionManager.maxScriptWords {
            pendingPasteText = text
            pendingPasteWordCount = text.wordCount
            showPasteLimitAlert = true
            return
        }
        if content.isEmpty {
            content = text
        } else {
            content += "\n\n" + text
        }
    }
}
