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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]

    @State private var searchText = ""
    @State private var editorMode: EditorMode?
    @State private var scriptToRecord: Script?
    @State private var showBulkImport = false
    @State private var showPaywall = false

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
            .navigationTitle("Scripts")
            .searchable(text: $searchText, prompt: "Search scripts")
            .toolbar {
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
                RecordingView(script: script)
            }
            .sheet(isPresented: $showBulkImport) {
                BulkImportView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Scripts Yet")
                .font(.title2.bold())
            Text("Create a script to start recording with a teleprompter.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                editorMode = .new
            } label: {
                Label("New Script", systemImage: "plus")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button {
                showBulkImport = true
            } label: {
                Label("Import Multiple Scripts", systemImage: "doc.on.doc")
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
                        if SubscriptionManager.shared.canUseCamera {
                            scriptToRecord = script
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        Image(systemName: "video.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.red, in: Circle())
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    editorMode = .edit(script)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteScript(script)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                showBulkImport = true
            } label: {
                Label("Import Multiple Scripts", systemImage: "doc.on.doc")
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
            Text(script.title.isEmpty ? "Untitled Script" : script.title)
                .font(.headline)
            Text(script.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Label("\(script.wordCount) words", systemImage: "text.word.spacing")
                Label(script.estimatedReadTimeFormatted, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
