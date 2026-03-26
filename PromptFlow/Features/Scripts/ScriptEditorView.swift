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
        if minutes > 0 { return "\(minutes) min \(secs) sec" }
        return "\(secs) sec"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Title field
                TextField("Script title", text: $title)
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
            .navigationTitle(isNew ? "New Script" : "Edit Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            showingDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .bold()
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Paste from Clipboard") {
                        pasteFromClipboard()
                    }
                    .font(.caption)
                }
            }
            .alert("Discard Changes?", isPresented: $showingDiscardAlert) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Optimization Failed", isPresented: .init(
                get: { optimizeError != nil },
                set: { if !$0 { optimizeError = nil } }
            )) {
                Button("OK") { optimizeError = nil }
            } message: {
                Text(optimizeError ?? "")
            }
            .alert("Daily limit reached", isPresented: $showRateLimitAlert) {
                Button("OK") {}
            } message: {
                Text("Try again tomorrow.")
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
        .alert("Tip", isPresented: $showEditorTip) {
            Button("Got it") { hasSeenEditorTip = true }
        } message: {
            Text("Tap \"Optimize\" to let AI clean up your script for reading aloud.\n\nUse // to add a pause between sections.")
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
                Label("\(wordCount) words", systemImage: "text.word.spacing")
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
                        Label("Optimize", systemImage: "wand.and.stars")
                            .foregroundStyle(sub.canOptimize ? .orange : .gray)
                    }
                }
                .disabled(isOptimizing || content.count > maxChars || content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
            }
            if !sub.isSubscribed && sub.canOptimize {
                Text("\(sub.freeOptimizationsRemaining) free optimization\(sub.freeOptimizationsRemaining == 1 ? "" : "s") left")
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
        let finalTitle = trimmedTitle.isEmpty ? "Untitled Script" : trimmedTitle

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
                optimizeError = "Could not format script. Check connection."
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
