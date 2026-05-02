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
                BulkImportView()
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(source: paywallSource)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
            print("📋 ScriptsList .onAppear at \(CFAbsoluteTimeGetCurrent())")
            #endif
            // Defensive backup auto-open. SwiftUI's `.onAppear` does NOT
            // reliably fire when a fullScreenCover dismisses on top of an
            // already-mounted view, so the primary trigger lives in the
            // `.onChange(of: hasSeenOnboarding)` handler below. This block
            // covers the cold-launch edge case where the flag persisted
            // across a kill mid-flow (rare but possible).
            if pendingDemoRecording {
                pendingDemoRecording = false
                if let demo = scripts.first(where: { $0.isDemo }) {
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
                    scriptToRecord = demo
                }
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
                if SubscriptionManager.shared.canBulkImport {
                    showBulkImport = true
                } else {
                    paywallSource = "import_gate_empty"
                    showPaywall = true
                }
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

            Button {
                if SubscriptionManager.shared.canBulkImport {
                    showBulkImport = true
                } else {
                    paywallSource = "import_gate_list"
                    showPaywall = true
                }
            } label: {
                Label {
                    Text("scripts.import.title", comment: "Import Multiple Scripts button label")
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func deleteScript(_ script: Script) {
        modelContext.delete(script)
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
            HStack(spacing: 12) {
                Label {
                    Text(String(
                        localized: "script.wordCount",
                        defaultValue: "\(script.wordCount) words",
                        comment: "Word count display in script row and editor stats bar"
                    ))
                } icon: {
                    Image(systemName: "text.word.spacing")
                }
                Label(script.estimatedReadTimeFormatted, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
