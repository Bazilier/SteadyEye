import SwiftUI
import SwiftData

struct ScriptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let script: Script?

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var showingDiscardAlert = false
    @State private var isOptimizing = false
    @State private var optimizeError: String?
    @State private var showRateLimitAlert = false
    @State private var showPaywall = false
    @State private var showEditorTip = false
    @AppStorage("hasSeenEditorTip") private var hasSeenEditorTip = false
    @FocusState private var contentFocused: Bool

    private let maxChars = 5000

    private var isNew: Bool { script == nil }

    private var hasChanges: Bool {
        guard let script else { return !title.isEmpty || !content.isEmpty }
        return title != script.title || content != script.content
    }

    private var wordCount: Int {
        content.split(separator: " ").count
    }

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
            .sheet(isPresented: $showPaywall) {
                PaywallView()
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

    private var statsBar: some View {
        let sub = SubscriptionManager.shared
        return VStack(spacing: 4) {
            HStack(spacing: 20) {
                Label {
                    Text(String(
                        localized: "script.wordCount",
                        defaultValue: "\(wordCount) words",
                        comment: "Word count display in the editor stats bar"
                    ))
                } icon: {
                    Image(systemName: "text.word.spacing")
                }
                Text("\(content.count.formatted()) / \(maxChars.formatted())")
                    .foregroundStyle(charCountColor)
                Spacer()
                Button {
                    if sub.canOptimize {
                        optimizeForReading()
                    } else {
                        showPaywall = true
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
                            .foregroundStyle(sub.canOptimize ? .orange : .gray)
                    }
                }
                .disabled(isOptimizing || content.count > maxChars || content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
            }
            if !sub.isSubscribed && sub.canOptimize {
                Text(String(
                    localized: "script.optimizationsRemaining",
                    defaultValue: "\(sub.freeOptimizationsRemaining) free optimizations left",
                    comment: "Footer showing the number of free AI optimizations the user has left this lifetime"
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func save() {
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
        }
        dismiss()
    }

    private func optimizeForReading() {
        guard SubscriptionManager.shared.canOptimize else {
            showPaywall = true
            return
        }
        guard RateLimiter.canMakeAPICall() else {
            showRateLimitAlert = true
            return
        }
        isOptimizing = true
        Task {
            do {
                let aiResult = try await AnthropicService.optimizeForReading(content)
                let cleaned = ScriptFormatter.cleanUp(aiResult)
                content = cleaned
                SubscriptionManager.shared.recordOptimizationUse()
            } catch {
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
        if let text = UIPasteboard.general.string, !text.isEmpty {
            if content.isEmpty {
                content = text
            } else {
                content += "\n\n" + text
            }
        }
    }
}
