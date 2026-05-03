import SwiftUI
import SwiftData

struct BulkImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Where the sheet was opened from. Logged on `bulk_import_opened`
    /// so funnel analysis can attribute by entry surface (toolbar vs
    /// empty-state). Set by ScriptListView at tap time.
    let entryPoint: String

    /// Demo gate. False until the user successfully completes a fake
    /// import (3 mock scripts inserted). Until then, every open uses
    /// demo mode regardless of subscription.
    @AppStorage("hasSeenBulkImportDemo") private var hasSeenBulkImportDemo: Bool = false
    /// Explainer gate. Decoupled from the demo flag so a user who
    /// dismisses the entire sheet without tapping OK on the explainer
    /// sees the explainer again next time.
    @AppStorage("hasSeenBulkImportExplainer") private var hasSeenBulkImportExplainer: Bool = false

    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var isCancelled = false
    @State private var statusText = ""
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var showRateLimitAlert = false
    @State private var showExplainer = false

    private let maxChars = 50000

    /// True until the demo has been completed at least once. Drives the
    /// editor pre-fill, hides the char-count and paste-clipboard chrome,
    /// and routes `startImport()` to the fake pipeline.
    private var isDemoMode: Bool { !hasSeenBulkImportDemo }

    /// Loads the three mock scripts inserted by the demo from the
    /// localized `BulkImportDemo/<locale>.lproj/DemoScriptN.txt`
    /// bundle resources, paired with the `scripts.import.demo.scriptN.title`
    /// String Catalog keys. Computed (not stored) because Bundle's
    /// locale-aware lookup should reflect the user's current preferred
    /// localization at the moment the demo runs. Empty content from a
    /// missing resource is silently passed through to the inserted
    /// `Script` — the demo never crashes on a bundling regression.
    private var demoScripts: [(title: String, content: String)] {
        [
            (
                String(
                    localized: "scripts.import.demo.script1.title",
                    comment: "Title of the first hardcoded mock script inserted at the end of the bulk-import demo. Short label used as the Script row title in the Scripts list. Title-Case in English."
                ),
                DemoContent.load("DemoScript1", subdirectory: "BulkImportDemo")
            ),
            (
                String(
                    localized: "scripts.import.demo.script2.title",
                    comment: "Title of the second hardcoded mock script inserted at the end of the bulk-import demo. Short label used as the Script row title in the Scripts list. Title-Case in English."
                ),
                DemoContent.load("DemoScript2", subdirectory: "BulkImportDemo")
            ),
            (
                String(
                    localized: "scripts.import.demo.script3.title",
                    comment: "Title of the third hardcoded mock script inserted at the end of the bulk-import demo. Short label used as the Script row title in the Scripts list. Title-Case in English. The literal '100' stays as digits across all locales."
                ),
                DemoContent.load("DemoScript3", subdirectory: "BulkImportDemo")
            )
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    if isProcessing {
                        processingView
                    } else {
                        editorView
                    }
                }

                if showExplainer {
                    ExplainerOverlay(
                        isPresented: $showExplainer,
                        icon: "doc.on.doc",
                        title: "scripts.import.explainer.title",
                        message: "scripts.import.explainer.body",
                        buttonLabel: "scripts.import.explainer.button",
                        onDismiss: {
                            hasSeenBulkImportExplainer = true
                            AppAnalytics.log("bulk_import_explainer_dismissed")
                        }
                    )
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
                if !isProcessing && !isDemoMode {
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
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(source: "import_gate_row")
        }
        .onAppear(perform: handleAppear)
        .onDisappear {
            // Funnel signal: any sheet close while still in demo mode
            // (i.e. before `hasSeenBulkImportDemo` flipped) counts as a
            // cancelled demo. The flag flip happens inside the fake
            // pipeline right before its own dismiss(), so successful
            // completions short-circuit this branch.
            if isDemoMode {
                AppAnalytics.log("bulk_import_demo_cancelled")
            }
        }
    }

    // MARK: - Editor

    private var editorView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $inputText)
                .font(.body)
                .padding(.horizontal, 12)
                // Read-only during the demo: the prefill is mock copy
                // the user shouldn't edit. Keyboard never rises, no
                // cursor, no selection. Lifts automatically once the
                // demo completes (sheet dismisses) or for the real
                // (Pro) flow where isDemoMode is false.
                .disabled(isDemoMode)
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
                if !isDemoMode {
                    HStack {
                        Text("\(inputText.count.formatted()) / \(maxChars.formatted())")
                            .font(.caption)
                            .foregroundStyle(bulkCharCountColor)
                        Spacer()
                    }
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

    /// Sheet-level `.onAppear` handler. Logs the open event, and in
    /// demo mode pre-fills the editor and conditionally raises the
    /// explainer overlay. Real-mode opens are a no-op past analytics.
    private func handleAppear() {
        AppAnalytics.log("bulk_import_opened", params: [
            "mode": isDemoMode ? "demo" : "real",
            "entry_point": entryPoint
        ])
        guard isDemoMode else { return }
        if inputText.isEmpty {
            inputText = DemoContent.load("DemoPrefillText", subdirectory: "BulkImportDemo")
        }
        if !hasSeenBulkImportExplainer {
            showExplainer = true
            AppAnalytics.log("bulk_import_explainer_shown")
        }
    }

    private func startImport() {
        if isDemoMode {
            startFakeImport()
        } else {
            startRealImport()
        }
    }

    /// Fake pipeline used during the demo onboarding pass. Cycles
    /// through the same status texts as the real flow on a Task.sleep
    /// timeline (~2.5s end-to-end), then inserts three hardcoded
    /// `Script` entities into the model context. No network calls, no
    /// rate-limit accounting.
    private func startFakeImport() {
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
            // Phase 1: fake split (~0.5s)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isCancelled { isProcessing = false; dismiss(); return }
            progress = 0.25

            // Resolve titles + bundle-loaded content once per demo run
            // so locale changes between phases don't yield a mixed-locale
            // batch.
            let mocks = demoScripts
            let total = mocks.count

            // Phase 2: fake per-script optimize (~0.5s × N)
            for i in 0..<total {
                statusText = String(
                    localized: "scripts.optimizing.progress",
                    defaultValue: "Optimizing script \(i + 1) of \(total)...",
                    comment: "Progress text during bulk optimization. Two cardinal numbers."
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isCancelled { isProcessing = false; dismiss(); return }
                progress = Double(i + 2) / Double(total + 1)
            }
            progress = 1.0

            // Insert mocks as real Script entities. They get fresh
            // createdAt timestamps and land at the top of the
            // @Query-sorted list alongside any other user scripts.
            for mock in mocks {
                let script = Script(title: mock.title, content: mock.content)
                modelContext.insert(script)
            }
            try? modelContext.save()

            // Mark demo seen BEFORE dismiss() so the .onDisappear
            // handler observes the flipped flag and skips the
            // cancelled-funnel event for successful completions.
            hasSeenBulkImportDemo = true
            statusText = String(
                localized: "scripts.imported.count",
                defaultValue: "\(total) scripts imported",
                comment: "Completion status after bulk import"
            )
            AppAnalytics.log("bulk_import_demo_completed")

            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        }
    }

    /// Real (Pro) pipeline. Identical to the pre-demo behavior — the
    /// `import_gate_row` defensive paywall fallback and rate-limit
    /// guard are preserved.
    private func startRealImport() {
        guard SubscriptionManager.shared.canBulkImport else {
            showPaywall = true
            return
        }
        guard RateLimiter.canBulkImport() else {
            showRateLimitAlert = true
            return
        }
        AppAnalytics.log("bulk_import_real_started")
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
                AppAnalytics.log("bulk_import_real_completed", params: ["scripts_count": savedCount])

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
