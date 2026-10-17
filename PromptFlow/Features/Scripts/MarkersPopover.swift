import SwiftUI

/// Explains the three slash markers, from the "i" at the end of the
/// editor's markers row (which inserts them). A grouped list, as in
/// Settings: each row is the marker as it is typed and what it does.
struct MarkersPopover: View {
    let onClose: () -> Void

    /// The popover's own surface, as the app's sheets (`CoachSheet`).
    static let background = Color(white: 0.11)
    /// The grouped rows on it.
    private static let groupFill = Color(white: 0.17)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rows
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 352)
        // Its whole height, or the system squeezes it and text spills out.
        .fixedSize(horizontal: false, vertical: true)
        .presentationBackground(Self.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(verbatim: "//")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            Text("editor.markers.title", comment: "Title of the popover in the script editor that explains the // /// //// markers.")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(white: 0.17), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.close", comment: "Close button of the markers popover in the script editor"))
        }
        .padding(.horizontal, 4)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(ScriptMarker.allCases.enumerated()), id: \.element) { index, marker in
                if index > 0 {
                    // Inset to the text, as a grouped list divides its rows.
                    Rectangle()
                        .fill(Color(white: 0.24))
                        .frame(height: 0.5)
                        .padding(.leading, 80)
                }
                row(marker)
            }
        }
        .background(Self.groupFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous))
    }

    private func row(_ marker: ScriptMarker) -> some View {
        HStack(spacing: 12) {
            // The marker as it is typed, on the prompter's black.
            Text(verbatim: marker.rawValue)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .kerning(-1)
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 54, minHeight: 32)
                .padding(.horizontal, 2)
                .background(Color.black, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Self.title(marker)
                    .font(.body.weight(.medium))
                summary(marker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// The marker's name on its button in the editor's markers row.
    static func buttonLabel(_ marker: ScriptMarker) -> Text {
        switch marker {
        case .shortPause: Text("editor.markers.short.button", comment: "Button in the script editor's markers row that inserts //. Short: it sits beside two others under the text.")
        case .longPause: Text("editor.markers.long.button", comment: "Button in the script editor's markers row that inserts ///. Short: it sits beside two others under the text.")
        case .section: Text("editor.markers.section.button", comment: "Button in the script editor's markers row that inserts ////, a section break. Short: it sits beside two others under the text.")
        }
    }

    static func title(_ marker: ScriptMarker) -> Text {
        switch marker {
        case .shortPause: Text("editor.markers.short.title", comment: "Markers popover: name of the // marker.")
        case .longPause: Text("editor.markers.long.title", comment: "Markers popover: name of the /// marker.")
        case .section: Text("editor.markers.section.title", comment: "Markers popover: name of the //// marker, which splits the script into sections the prompter stops after.")
        }
    }

    private func summary(_ marker: ScriptMarker) -> Text {
        switch marker {
        case .shortPause: Text("editor.markers.short.body", comment: "Markers popover: what // does.")
        case .longPause: Text("editor.markers.long.body", comment: "Markers popover: what /// does — about one second of silence.")
        case .section: Text("editor.markers.section.body", comment: "Markers popover: what //// does — the prompter stops at the end of the section and offers Repeat or Next (use the same words as those buttons), and the pauses are cut from the video afterwards.")
        }
    }
}
