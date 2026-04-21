import SwiftUI
import SwiftData

struct BulkImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var isCancelled = false
    @State private var statusText = ""
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var showRateLimitAlert = false

    private let maxChars = 50000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isProcessing {
                    processingView
                } else {
                    editorView
                }
            }
            .navigationTitle(Text("scripts.import.navTitle", comment: "Bulk import sheet nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if isProcessing {
                            isCancelled = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text(
                            isProcessing ? "scripts.import.stop" : "common.cancel",
                            comment: "Toolbar button: 'scripts.import.stop' while processing, 'common.cancel' otherwise"
                        )
                    }
                }
                if !isProcessing {
                    ToolbarItem(placement: .keyboard) {
                        Button {
                            if let text = UIPasteboard.general.string, !text.isEmpty {
                                inputText = text
                            }
                        } label: {
                            Text("common.pasteFromClipboard", comment: "Keyboard accessory: paste from clipboard")
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isProcessing)
        .alert(
            Text("common.dailyLimit.title", comment: "Daily limit alert title in bulk import"),
            isPresented: $showRateLimitAlert
        ) {
            Button {} label: {
                Text("common.ok", comment: "OK button on daily limit alert")
            }
        } message: {
            Text("common.dailyLimit.message", comment: "Daily limit alert message in bulk import")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(source: "import_gate_row")
        }
    }

    // MARK: - Editor

    private var editorView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $inputText)
                .font(.body)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("scripts.import.placeholder", comment: "Placeholder shown inside the empty bulk import editor")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Text("\(inputText.count.formatted()) / \(maxChars.formatted())")
                        .font(.caption)
                        .foregroundStyle(bulkCharCountColor)
                    Spacer()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    startImport()
                } label: {
                    Label {
                        Text("scripts.import.button", comment: "Primary button on bulk import view")
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 || inputText.count > maxChars)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var bulkCharCountColor: Color {
        if inputText.count >= maxChars { return .red }
        if inputText.count >= 40000 { return .orange }
        return .secondary
    }

    // MARK: - Processing view

    private var processingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: progress)
                .tint(.orange)
                .padding(.horizontal, 40)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    // MARK: - Import logic

    @State private var showPaywall = false

    private func startImport() {
        guard SubscriptionManager.shared.canBulkImport else {
            showPaywall = true
            return
        }
        guard RateLimiter.canBulkImport() else {
            showRateLimitAlert = true
            return
        }
        isProcessing = true
        isCancelled = false
        errorMessage = nil
        progress = 0
        statusText = String(
            localized: "scripts.import.status.splitting",
            defaultValue: "Splitting document...",
            comment: "Status during bulk import splitting phase"
        )

        Task {
            do {
                // Phase 1: Split
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawScripts: [ImportedScript]

                if text.count > 15000 {
                    rawScripts = try await processInChunks(text)
                } else {
                    rawScripts = try await AnthropicService.splitScripts(text)
                }

                guard !rawScripts.isEmpty else {
                    errorMessage = String(
                        localized: "scripts.import.error.noScripts",
                        defaultValue: "No scripts found in the text.",
                        comment: "Bulk import error when AI splitter returns nothing"
                    )
                    isProcessing = false
                    return
                }

                if isCancelled { finishEarly(); return }

                // Phase 2: Optimize each script
                let total = rawScripts.count
                var savedCount = 0

                for (i, item) in rawScripts.enumerated() {
                    if isCancelled { break }

                    statusText = String(
                        localized: "scripts.optimizing.progress",
                        defaultValue: "Optimizing script \(i + 1) of \(total)...",
                        comment: "Progress text during bulk optimization. Two cardinal numbers."
                    )
                    progress = Double(i) / Double(total)

                    var finalContent = item.content
                    do {
                        let optimized = try await AnthropicService.optimizeForReading(item.content)
                        finalContent = ScriptFormatter.cleanUp(optimized)
                    } catch {
                        // Optimization failed — save raw content
                    }

                    let script = Script(title: item.title, content: finalContent)
                    modelContext.insert(script)
                    savedCount += 1
                }

                try? modelContext.save()
                progress = 1.0
                statusText = String(
                    localized: "scripts.imported.count",
                    defaultValue: "\(savedCount) scripts imported",
                    comment: "Completion status after bulk import"
                )

                // Brief pause so user sees completion
                try? await Task.sleep(nanoseconds: 500_000_000)
                dismiss()
            } catch {
                errorMessage = String(
                    localized: "scripts.import.error.processFailed",
                    defaultValue: "Could not process text. Check connection.",
                    comment: "Error when bulk import network call fails"
                )
                isProcessing = false
            }
        }
    }

    private func finishEarly() {
        try? modelContext.save()
        isProcessing = false
        dismiss()
    }

    private func processInChunks(_ text: String) async throws -> [ImportedScript] {
        let chunkSize = 10000
        let overlap = 500
        var allScripts: [ImportedScript] = []
        var offset = text.startIndex

        while offset < text.endIndex {
            if isCancelled { break }
            let end = text.index(offset, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[offset..<end])
            let result = try await AnthropicService.splitScripts(chunk)
            allScripts.append(contentsOf: result)

            let advance = max(chunkSize - overlap, 1)
            offset = text.index(offset, offsetBy: advance, limitedBy: text.endIndex) ?? text.endIndex
        }

        return allScripts
    }
}
