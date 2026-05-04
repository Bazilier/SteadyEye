import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    let hasError: Bool

    private var isInbound: Bool { message.direction == .inbound }

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
                            .fill(isInbound ? Color.accentColor : Color(.secondarySystemBackground))
                    )
                    .textSelection(.enabled)

                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 16))
                    .padding(.bottom, 18)
            }

            if !isInbound { Spacer(minLength: 40) }
        }
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        // Same-day messages get just time; older ones get a relative date.
        if Calendar.current.isDateInToday(message.createdAt) {
            return formatter.string(from: message.createdAt)
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: message.createdAt, relativeTo: Date())
    }
}
