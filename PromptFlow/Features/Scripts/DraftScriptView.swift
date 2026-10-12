import SwiftUI
import SwiftData

/// "What's your video about?" — the bridge from the sample take to the user's
/// own script. A one-line topic becomes a draft written by the AI proxy, and
/// the one thing to do with it is record it. Few decisions on purpose:
/// another version and writing it yourself are quiet links.
struct DraftScriptView: View {
    enum Outcome {
        /// Saved; record it now.
        case record(Script)
        /// Open an empty editor.
        case writeMyself
        /// Free drafts are used up for today.
        case paywall
    }

    let onFinish: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var topic = ""
    @State private var kind: AnthropicService.DraftKind = .short
    @State private var length: AnthropicService.DraftLength = .seconds30
    @State private var draft: String?
    @State private var isDrafting = false
    @State private var errorMessage: String?
    @FocusState private var topicFocused: Bool

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let draft {
                        draftResult(draft)
                    } else {
                        form
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        AppAnalytics.log("draft_script_closed", params: ["had_draft": draft != nil])
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("common.cancel", comment: "Cancel button"))
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { AppAnalytics.log("draft_script_shown") }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(
                    localized: "draft.title",
                    defaultValue: "What’s your video about?",
                    comment: "Title of the screen that drafts the user's own script from a one-line topic."
                ))
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "draft.subtitle",
                    defaultValue: "One line is enough. We’ll draft a script you can read right away.",
                    comment: "Subtitle on the draft-a-script screen."
                ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section(String(localized: "draft.topic.label", defaultValue: "Topic", comment: "Label above the topic field on the draft-a-script screen.")) {
                TextField(
                    String(
                        localized: "draft.topic.placeholder",
                        defaultValue: "e.g. 3 mistakes new runners make",
                        comment: "Placeholder in the topic field on the draft-a-script screen. An example topic."
                    ),
                    text: $topic,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .focused($topicFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(topicFocused ? Theme.accent : .clear, lineWidth: 1.5)
                )
                .onChange(of: topic) { _, new in
                    // The server takes up to 300 characters.
                    if new.count > 300 { topic = String(new.prefix(300)) }
                }
            }

            section(String(localized: "draft.kind.label", defaultValue: "For", comment: "Label above the video-type choices on the draft-a-script screen.")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AnthropicService.DraftKind.allCases) { option in
                            chip(Self.title(for: option), isSelected: kind == option) { kind = option }
                        }
                    }
                }
                .scrollClipDisabled()
            }

            section(String(localized: "draft.length.label", defaultValue: "Length", comment: "Label above the script-length choices on the draft-a-script screen.")) {
                HStack(spacing: 8) {
                    ForEach(AnthropicService.DraftLength.allCases) { option in
                        chip(
                            String(
                                localized: "draft.length.seconds",
                                defaultValue: "\(option.rawValue) sec",
                                comment: "Script length choice on the draft-a-script screen, e.g. '30 sec'."
                            ),
                            isSelected: length == option,
                            fillsWidth: true
                        ) { length = option }
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Result

    private func draftResult(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "draft.result.title",
                defaultValue: "Your script",
                comment: "Title above the AI-drafted script on the draft-a-script screen."
            ))
                .font(.largeTitle.bold())
            Text(trimmedTopic)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let draft {
                Button {
                    AppAnalytics.log("draft_script_record_tapped")
                    finish(.record(save(content: draft)))
                } label: {
                    Label(
                        String(localized: "draft.record", defaultValue: "Record it", comment: "Primary button after a script was drafted: save it and open the camera."),
                        systemImage: "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .disabled(isDrafting)
                quietLink(isDrafting
                    ? String(localized: "draft.drafting", defaultValue: "Writing your script…", comment: "Shown on the draft button while the AI writes the script.")
                    : String(localized: "draft.retry", defaultValue: "Another version", comment: "Button after a script was drafted: draft it again.")
                ) {
                    AppAnalytics.log("draft_script_retry_tapped")
                    requestDraft()
                }
                .disabled(isDrafting)
            } else {
                Button(action: requestDraft) {
                    HStack(spacing: 8) {
                        if isDrafting {
                            ProgressView().tint(.black)
                            Text(String(localized: "draft.drafting", defaultValue: "Writing your script…", comment: "Shown on the draft button while the AI writes the script."))
                        } else {
                            Image(systemName: "sparkles")
                            Text(String(localized: "draft.submit", defaultValue: "Draft my script", comment: "Primary button on the draft-a-script screen: asks the AI for a draft."))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .disabled(trimmedTopic.isEmpty || isDrafting)
                quietLink(String(localized: "draft.write_myself", defaultValue: "Write it myself", comment: "Button on the draft-a-script screen: open an empty script editor.")) {
                    AppAnalytics.log("draft_script_write_myself_tapped")
                    finish(.writeMyself)
                }
                .disabled(isDrafting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func requestDraft() {
        guard !trimmedTopic.isEmpty, !isDrafting else { return }
        topicFocused = false
        errorMessage = nil
        isDrafting = true
        AppAnalytics.log("draft_script_requested", params: ["kind": kind.rawValue, "length_sec": length.rawValue])
        let topic = trimmedTopic, kind = kind, length = length
        Task {
            defer { isDrafting = false }
            do {
                let text = try await AnthropicService.draftScript(topic: topic, length: length, kind: kind)
                AppAnalytics.log("draft_script_succeeded", params: ["kind": kind.rawValue, "length_sec": length.rawValue])
                withAnimation { draft = text }
            } catch AnthropicService.ServiceError.freeQuotaExhausted {
                AppAnalytics.log("draft_script_failed", params: ["reason": "free_quota_exhausted"])
                if OnboardingFlow.isActive {
                    // No paywall in the middle of the guided first run.
                    withAnimation {
                        errorMessage = String(
                            localized: "draft.error.quota",
                            defaultValue: "You’ve used today’s free drafts. Write it yourself, or try again tomorrow.",
                            comment: "Error on the draft-a-script screen when the free daily drafts are used up during onboarding."
                        )
                    }
                } else {
                    finish(.paywall)
                }
            } catch AnthropicService.ServiceError.cannotDraft {
                AppAnalytics.log("draft_script_failed", params: ["reason": "cannot_draft"])
                withAnimation {
                    draft = nil
                    errorMessage = String(
                        localized: "draft.error.topic",
                        defaultValue: "We can’t write about this topic. Try another one.",
                        comment: "Error on the draft-a-script screen when the AI declines the topic."
                    )
                }
            } catch {
                AppAnalytics.log("draft_script_failed", params: ["reason": String(describing: error).prefix(80).description])
                withAnimation {
                    draft = nil
                    errorMessage = String(
                        localized: "draft.error.generic",
                        defaultValue: "Couldn’t write a draft right now. Try again, or write it yourself.",
                        comment: "Error on the draft-a-script screen when drafting fails (network, server)."
                    )
                }
            }
        }
    }

    /// Saves a script titled after the topic, or after its own first words.
    private func save(content: String) -> Script {
        let source = trimmedTopic.isEmpty ? content : trimmedTopic
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        let title = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        let script = Script(title: title, content: content)
        modelContext.insert(script)
        try? modelContext.save()
        AppAnalytics.log("draft_script_saved")
        return script
    }

    private func finish(_ outcome: Outcome) {
        dismiss()
        onFinish(outcome)
    }

    // MARK: - Pieces

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chip(_ title: String, isSelected: Bool, fillsWidth: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))
                .padding(.horizontal, 14)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 40)
                .background(
                    Capsule().fill(isSelected ? Theme.accent.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                )
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quietLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private static func title(for kind: AnthropicService.DraftKind) -> String {
        switch kind {
        case .short: return String(localized: "draft.kind.short", defaultValue: "Reels, TikTok, Shorts", comment: "Video type on the draft-a-script screen: short vertical videos.")
        case .sales: return String(localized: "draft.kind.sales", defaultValue: "Sales or pitch", comment: "Video type on the draft-a-script screen: a sales or pitch video.")
        case .lesson: return String(localized: "draft.kind.lesson", defaultValue: "Lesson", comment: "Video type on the draft-a-script screen: a lesson or course segment.")
        case .other: return String(localized: "draft.kind.other", defaultValue: "Something else", comment: "Video type on the draft-a-script screen: anything else.")
        }
    }
}
