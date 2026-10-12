import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    /// Tap-to-retry handler. Only invoked from the failed-status row of an
    /// inbound bubble. Outbound bubbles never receive a retry path.
    var onRetry: (() -> Void)? = nil

    private var isInbound: Bool { message.direction == .inbound }
    private var isFailed: Bool { isInbound && message.sendStatus == .failed }

    var body: some View {
        ChatBubbleRow(trailing: isInbound) {
            VStack(alignment: isInbound ? .trailing : .leading, spacing: 4) {
                ChatBubbleSurface(content: Text(message.text), isInbound: isInbound)
                    .opacity(isFailed ? 0.7 : 1.0)

                statusOrTimestampLine
            }
        }
    }

    @ViewBuilder
    private var statusOrTimestampLine: some View {
        if isInbound {
            switch message.sendStatus {
            case .sending:
                Text("chat.status.sending", comment: "Caption shown under an outgoing chat bubble while the send is in flight to the backend.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            case .sent:
                timestampView
            case .failed:
                Button {
                    onRetry?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                        Text("chat.status.failed", comment: "Tappable caption shown under a failed outgoing chat bubble. Tapping retries the send.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onRetry == nil)
            }
        } else {
            timestampView
        }
    }

    private var timestampView: some View {
        Text(timestampText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        if Calendar.current.isDateInToday(message.createdAt) {
            return formatter.string(from: message.createdAt)
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: message.createdAt, relativeTo: Date())
    }
}

/// The bubble surface itself — text on a rounded, direction-tinted ground.
///
/// Extracted from `ChatBubbleView` so the pinned founder message at the top of
/// `ChatView` renders as a real incoming bubble rather than a card of its own.
/// Takes a `Text` rather than a `String` so a caller can pass a localized
/// literal straight through and keep it visible to the String Catalog
/// extractor.
struct ChatBubbleSurface: View {
    let content: Text
    let isInbound: Bool

    var body: some View {
        content
            .font(.body)
            .foregroundStyle(isInbound ? Theme.onAccent : Color.primary)
            // Links: on-accent over the user's accent bubble, accent otherwise.
            .tint(isInbound ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    // Explicit Theme.accent rather than the inherited tint:
                    // sheets don't inherit the parent TabView's .tint.
                    .fill(isInbound ? Theme.accent : Color(.secondarySystemGroupedBackground))
            )
            .textSelection(.enabled)
    }
}

/// One chat row: its content is offered at most `maxFraction` of the row's
/// width and sits against the leading or trailing edge.
struct ChatBubbleRow: Layout {
    var trailing: Bool
    var maxFraction: CGFloat = 0.78

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let rowWidth = proposal.width
        let size = content.sizeThatFits(ProposedViewSize(width: rowWidth.map { $0 * maxFraction }, height: nil))
        return CGSize(width: rowWidth ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width * maxFraction, height: nil))
        let x = trailing ? bounds.maxX - size.width : bounds.minX
        content.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}
