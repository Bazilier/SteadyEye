import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allRecordings: [Recording]

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var nextLocalId: Int = -1

    private static let pollInterval: UInt64 = 10 * 1_000_000_000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                inputBar
            }
            .navigationTitle(Text("chat.header.title", comment: "Chat header — founder name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("chat.header.title", comment: "Chat header — founder name")
                            .font(.headline)
                        Text("chat.header.subtitle", comment: "Chat header — founder role")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            messages = ChatStorage.load()
            AppAnalytics.log("chat_opened", params: ["message_count": messages.count])
            await fetchAndMerge()
            startPolling()
        }
        .onDisappear {
            stopPolling()
            ChatStorage.save(messages)
            ChatBadgeState.shared.markAllRead()
        }
    }

    // MARK: - List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    welcomeMessage
                        .padding(.top, 12)

                    if messages.isEmpty {
                        Text("chat.empty", comment: "Empty-state hint when there are no messages yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }

                    ForEach(messages) { message in
                        ChatBubbleView(
                            message: message,
                            onRetry: message.sendStatus == .failed
                                ? { Task { await retry(messageId: message.id) } }
                                : nil
                        )
                        .id(message.id)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .refreshable { await fetchAndMerge() }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var welcomeMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("chat.welcome", comment: "Pinned welcome message at the top of the chat from the founder")
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                String(
                    localized: "chat.input.placeholder",
                    defaultValue: "Type a message…",
                    comment: "Placeholder in the chat input field"
                ),
                text: $inputText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Button {
                Task { await send() }
            } label: {
                if isSending {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        // Color.orange literal — matches the inbound bubble
                        // (ChatBubbleView). Color.accentColor doesn't work
                        // here because sheets don't inherit the TabView's
                        // .tint(.orange), so it would render system blue.
                        .foregroundStyle(canSend ? Color.orange : Color.secondary.opacity(0.5))
                }
            }
            .disabled(!canSend || isSending)
            .accessibilityLabel(Text("chat.input.send", comment: "Accessibility label for the send button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let localId = nextLocalId
        nextLocalId -= 1
        let optimistic = ChatMessage(localId: localId, text: text)
        messages.append(optimistic)
        ChatStorage.save(messages)

        inputText = ""
        isSending = true

        AppAnalytics.log("chat_message_sent", params: ["text_length": text.count])

        let recordingsCount = allRecordings.count
        do {
            _ = try await ChatService.sendMessage(text: text, recordingsCount: recordingsCount)
            await fetchAndMerge(removingLocalId: localId)
        } catch {
            markFailed(messageId: localId)
            AppAnalytics.log("chat_message_send_failed", params: [
                "error_reason": Self.reason(for: error)
            ])
            AppAnalytics.log("chat_message_failed_displayed", params: [
                "text_length": text.count
            ])
        }
        isSending = false
    }

    /// Re-attempt a previously-failed inbound send. Flips status to `.sending`
    /// while the request is in flight, then back to `.failed` if it errors out
    /// again. On success the next fetch swaps the optimistic local row for the
    /// canonical server one (same path as a fresh send).
    private func retry(messageId: Int) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let text = messages[idx].text

        AppAnalytics.log("chat_message_retry_tapped", params: ["original_status": "failed"])

        messages[idx].sendStatus = .sending
        ChatStorage.save(messages)

        let recordingsCount = allRecordings.count
        do {
            _ = try await ChatService.sendMessage(text: text, recordingsCount: recordingsCount)
            AppAnalytics.log("chat_message_retry_succeeded")
            await fetchAndMerge(removingLocalId: messageId)
        } catch {
            markFailed(messageId: messageId)
            AppAnalytics.log("chat_message_retry_failed", params: [
                "error_reason": Self.reason(for: error)
            ])
        }
    }

    private func markFailed(messageId: Int) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx].sendStatus = .failed
        ChatStorage.save(messages)
    }

    private func fetchAndMerge(removingLocalId: Int? = nil) async {
        do {
            let remote = try await ChatService.fetchMessages()
            let knownLocals: [ChatMessage] = {
                if let removingLocalId {
                    return messages.filter { $0.isLocal && $0.id != removingLocalId }
                }
                return messages.filter(\.isLocal)
            }()

            // Merge: server is the source of truth for non-local rows; locals
            // (pending optimistic messages) stay until their canonical row
            // arrives from the server.
            let merged = (remote + knownLocals).sorted { $0.createdAt < $1.createdAt }
            let newCount = merged.count - messages.filter { !$0.isLocal }.count
            messages = merged
            ChatStorage.save(messages)
                ChatBadgeState.shared.recalculate()

            if newCount > 0 {
                AppAnalytics.log("chat_replies_fetched", params: ["new_count": newCount])
            }
        } catch {
            // Polling failures are silent — don't spam the banner. A failed
            // send already shows its own error indicator on the bubble.
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                if Task.isCancelled { break }
                await fetchAndMerge()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func reason(for error: Error) -> String {
        if let svc = error as? ChatService.ServiceError {
            switch svc {
            case .networkError: return "network"
            case .httpError(let code): return "http_\(code)"
            case .decodingError: return "decoding"
            case .emptyResponse: return "empty"
            }
        }
        return "unknown"
    }
}
