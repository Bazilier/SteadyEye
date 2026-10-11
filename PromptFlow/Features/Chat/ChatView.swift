import SwiftUI
import SwiftData

struct ChatView: View {
    /// Which pinned founder message sits at the top of the thread. The chat is
    /// reached from two places that want to open on different words.
    enum PinnedMessage {
        /// Settings — the standing welcome.
        case welcome
        /// The satisfaction prompt's No branch — Kirill asking what went wrong.
        case satisfactionFollowUp
    }

    /// Defaults to `.welcome` so the Settings call site stays unchanged.
    var pinnedMessage: PinnedMessage = .welcome

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allRecordings: [Recording]

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var nextLocalId: Int = -1
    /// Height of the input bar, and how far the end of the thread sits below
    /// the visible list. Together they keep the last message in view while
    /// the composer grows, without moving a list the user scrolled up.
    @State private var composerHeight: CGFloat = 0
    @State private var distanceFromBottom: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var isBottomMarkerLoaded = false
    @State private var wasNearBottom = false

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
            AppAnalytics.log("chat_opened", params: [
                "message_count": messages.count,
                "source": pinnedMessage == .welcome ? "settings" : "satisfaction_prompt"
            ])
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
                LazyVStack(alignment: .leading, spacing: 6) {
                    pinnedBubble
                        .padding(.top, 12)

                    if messages.isEmpty {
                        Text("chat.empty", comment: "Empty-state hint when there are no messages yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        ChatBubbleView(
                            message: message,
                            onRetry: message.sendStatus == .failed
                                ? { Task { await retry(messageId: message.id) } }
                                : nil
                        )
                        // 6 pt inside a run from one sender, 12 pt when the
                        // sender changes (the pinned bubble counts as founder).
                        .padding(.top, senderChanged(at: index) ? 6 : 0)
                        .id(message.id)
                    }

                    Color.clear.frame(height: 1)
                        .onGeometryChange(for: CGFloat.self) { geo in
                            geo.frame(in: .named("chatList")).maxY
                        } action: { bottomY in
                            distanceFromBottom = bottomY - listHeight
                        }
                        // The lazy stack unloads the marker once it is far off
                        // screen; its last position is stale from then on.
                        .onAppear { isBottomMarkerLoaded = true }
                        .onDisappear { isBottomMarkerLoaded = false }
                        // Outermost, so the lazy stack can scroll to it before
                        // it has been rendered.
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .coordinateSpace(name: "chatList")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .refreshable { await fetchAndMerge() }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // "Near the bottom" is decided when the text changes, before the
            // composer re-lays out: once the list's height changes, the lazy
            // stack re-measures rows above the viewport and positions read
            // afterwards are off. Near = the end of the thread loaded and
            // within 44 pt of the list's bottom edge.
            .onChange(of: inputText) { _, _ in
                wasNearBottom = isBottomMarkerLoaded && distanceFromBottom <= 44
            }
            .onChange(of: composerHeight) { old, _ in
                guard old > 0, wasNearBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Pinned founder message. Rendered through `ChatBubbleSurface`, the same
    /// surface a real message uses, and laid out like an outbound (founder →
    /// user) row so it reads as an incoming message rather than a card. No
    /// timestamp line: it is static copy, not a dated message.
    private var pinnedBubble: some View {
        ChatBubbleRow(trailing: false) {
            ChatBubbleSurface(content: pinnedText, isInbound: false)
        }
    }

    private func senderChanged(at index: Int) -> Bool {
        let previous = index > 0 ? messages[index - 1].direction : .outbound
        return messages[index].direction != previous
    }

    private var pinnedText: Text {
        switch pinnedMessage {
        case .welcome:
            return Text("chat.welcome", comment: "Pinned welcome message at the top of the chat from the founder")
        case .satisfactionFollowUp:
            return Text("chat.pinned.feedback", comment: "Pinned message at the top of the chat when it is opened from the satisfaction prompt's No branch. The founder introduces himself by name and asks what went wrong. Keep it short, personal and first-person.")
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            let placeholder = String(
                localized: "chat.input.placeholder",
                defaultValue: "Type a message…",
                comment: "Placeholder in the chat input field"
            )
            TextField(
                text: $inputText,
                // Explicit color: a hierarchical `.secondary` here is applied on
                // top of the system placeholder dimming and nearly vanishes.
                prompt: Text(placeholder).foregroundColor(Color(.secondaryLabel)),
                axis: .vertical
            ) {
                Text(placeholder)
            }
            .lineLimit(1...5)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background {
                // Capsule while one line; the medium card radius once it grows.
                GeometryReader { geo in
                    let shape = geo.size.height > 44.5
                        ? AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                        : AnyShape(Capsule())
                    shape.fill(Color(.secondarySystemGroupedBackground))
                }
            }

            Button {
                Task { await send() }
            } label: {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(Theme.onAccent)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend || isSending)
            // The circle sits outside `.disabled`: inside it, iOS 17/18 grey
            // out `Theme.accent` (the accent color). Explicit Theme.accent —
            // sheets don't inherit the TabView's .tint.
            .background {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 36, height: 36)
            }
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel(Text("chat.input.send", comment: "Accessibility label for the send button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
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
