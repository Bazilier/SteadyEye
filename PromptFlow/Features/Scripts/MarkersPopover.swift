import SwiftUI

/// Explains the three slash markers and inserts the one tapped. Shown from
/// the editor's "//" buttons.
struct MarkersPopover: View {
    let onInsert: (ScriptMarker) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("editor.markers.title", comment: "Title of the popover in the script editor that explains the // /// //// markers.")
                        .font(.title3.bold())
                    Text("editor.markers.subtitle", comment: "Subtitle of the markers popover.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel(Text("common.close", comment: "Close button of the markers popover in the script editor"))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            ForEach(ScriptMarker.allCases) { marker in
                row(marker)
            }

            Text("editor.markers.hint", comment: "Footer of the markers popover: tapping a row inserts that marker at the cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 360)
    }

    private func row(_ marker: ScriptMarker) -> some View {
        let isSection = marker == .section
        return Button { onInsert(marker) } label: {
            HStack(spacing: 12) {
                Text(verbatim: marker.rawValue)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSection ? Theme.onAccent : Theme.accent)
                    .frame(width: 64, height: 44)
                    .background(
                        isSection ? Theme.accent : Theme.accentTint,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        title(marker)
                            .font(.callout.weight(.semibold))
                        if isSection {
                            Text("editor.markers.new", comment: "Badge on the newest marker (////) in the markers popover.")
                                .font(.caption2.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    summary(marker)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    preview(marker)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSection ? Theme.accent : .secondary)
            }
            .padding(12)
            .background(
                isSection ? Theme.accent.opacity(0.14) : Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                if isSection {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func title(_ marker: ScriptMarker) -> Text {
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
        case .section: Text("editor.markers.section.body", comment: "Markers popover: what //// does — the prompter stops at the end of the section and offers Repeat or Next, while recording continues.")
        }
    }

    /// A word, the gap the marker makes, and the next word; for a section,
    /// the Repeat and Next buttons the prompter stops on.
    @ViewBuilder
    private func preview(_ marker: ScriptMarker) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(.secondary)
                .frame(width: 40, height: 6)
            switch marker {
            case .shortPause, .longPause:
                Line()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4]))
                    .frame(width: marker == .shortPause ? 12 : 40, height: 2)
                Capsule()
                    .fill(.secondary)
                    .frame(width: 30, height: 6)
            case .section:
                previewButton("arrow.counterclockwise", ringed: false)
                previewButton("play.fill", ringed: true)
            }
        }
        .accessibilityHidden(true)
    }

    private func previewButton(_ systemName: String, ringed: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color(.systemGray3), in: Circle())
            .overlay {
                if ringed { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
            }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}
