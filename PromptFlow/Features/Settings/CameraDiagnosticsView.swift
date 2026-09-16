#if DEV
import SwiftUI
import UIKit

/// DEV-only screen listing the most recent `CameraDiagnostic` events with a
/// Copy button, so a tester without a Mac can paste them into a chat message.
/// Hardcoded English, matching the other developer-only controls.
struct CameraDiagnosticsView: View {
    @State private var entries: [CameraDiagnosticsLog.Entry] = []
    @State private var showCopied = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No events yet. Open the recording screen and record a few seconds, then come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.timeFormatter.string(from: entry.time))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Camera Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Copy") {
                    UIPasteboard.general.string = plainText
                    showCopied = true
                }
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button("Refresh") { reload() }
                    Spacer()
                    Button("Clear", role: .destructive) {
                        CameraDiagnosticsLog.clear()
                        reload()
                    }
                }
            }
        }
        .alert("Copied", isPresented: $showCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(entries.count) events copied. Paste them into the chat.")
        }
        .onAppear { reload() }
    }

    private var plainText: String {
        entries
            .map { "\(Self.timeFormatter.string(from: $0.time)) \($0.line)" }
            .joined(separator: "\n")
    }

    private func reload() {
        entries = CameraDiagnosticsLog.snapshot()
    }
}
#endif
