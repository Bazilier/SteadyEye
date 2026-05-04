import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    /// Tap-to-retry handler. Only invoked from the failed-status row of an
    /// inbound bubble. Outbound bubbles never receive a retry path.
    var onRetry: (() -> Void)? = nil

    private var isInbound: Bool { message.direction == .inbound }
    private var isFailed: Bool { isInbound && message.sendStatus == .failed }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isInbound { Spacer(minLength: 40) }

            VStack(alignment: isInbound ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(isInbound ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        bubbleShape
                            // Color.orange (literal) instead of Color.accentColor:
                            // sheets don't inherit the parent TabView's
                            // .tint(.orange), so accentColor flickers from system
                            // default → orange on first frame inside a sheet.
                            .fill(isInbound ? Color.orange : Color(.secondarySystemBackground))
                    )
                    .opacity(isFailed ? 0.7 : 1.0)
                    .textSelection(.enabled)

                statusOrTimestampLine
            }

            if !isInbound { Spacer(minLength: 40) }
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
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
