import SwiftUI
import SwiftData

/// Onboarding's "What's your video about?": the user's first script, with as
/// few choices as possible. A topic becomes an AI draft; no topic gets a
/// ready-made sample, so nobody is stuck for an idea; or they paste their own
/// text. The script is saved and handed on, and the camera records it once
/// access is granted.
struct OnboardingScriptView: View {
    let onScript: (Script) -> Void
    let onSkip: () -> Void

    @Environment(\.modelContext) private var modelContext

    private enum Mode { case topic, result, paste }

    @State private var mode: Mode = .topic
    @State private var topic = ""
    @State private var draft = ""
    @State private var draftIsSample = false
    @State private var pasted = ""
    @State private var isDrafting = false
    @State private var errorMessage: String?
    @FocusState private var topicFocused: Bool
    @FocusState private var pasteFocused: Bool

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPaste: String { pasted.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch mode {
            case .topic:
                scrolling { topicContent }
            case .result:
                scrolling { resultContent }
            case .paste:
                pasteContent
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .animation(.easeInOut(duration: 0.2), value: mode)
        .onAppear { AppAnalytics.log("onboarding_script_shown") }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if mode != .topic {
                Button {
                    errorMessage = nil
                    mode = .topic
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                }
                .disabled(isDrafting)
                .accessibilityLabel(Text(String(localized: "common.back", defaultValue: "Back", comment: "Back button.")))
            }
            Spacer()
            if mode == .topic {
                Button {
                    AppAnalytics.log("onboarding_script_skipped")
                    onSkip()
                } label: {
                    Text(String(
                        localized: "onboarding.script.skip",
                        defaultValue: "Skip",
                        comment: "Quiet button at the top of the onboarding script step: leave onboarding without writing a script."
                    ))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                }
                .disabled(isDrafting)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Topic

    private var topicContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(
                title: String(
                    localized: "draft.title",
                    defaultValue: "What’s your video about?",
                    comment: "Title of the screen that drafts the user's own script from a one-line topic."
                ),
                subtitle: String(
                    localized: "onboarding.script.subtitle",
                    defaultValue: "One line is enough. We’ll write a 30-second script you can read right away.",
                    comment: "Subtitle on the onboarding script step, under 'What's your video about?'."
                )
            )

            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    String(
                        localized: "draft.topic.placeholder",
                        defaultValue: "e.g. 3 mistakes new runners make",
                        comment: "Placeholder in the topic field on the draft-a-script screen. An example topic."
                    ),
                    text: $topic,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused($topicFocused)
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(topicFocused ? Theme.accent : .clear, lineWidth: 1.5)
                )
                .onChange(of: topic) { _, new in
                    // The server takes up to 300 characters.
                    if new.count > 300 { topic = String(new.prefix(300)) }
                }

                Label {
                    Text(String(
                        localized: "onboarding.script.empty_hint",
                        defaultValue: "No idea yet? Leave it empty and we’ll give you a sample script to try.",
                        comment: "Hint under the topic field on the onboarding script step: an empty topic gets a ready-made sample script."
                    ))
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            }

            errorLabel
        }
    }

    // MARK: - Result

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                title: String(
                    localized: "draft.result.title",
                    defaultValue: "Your script",
                    comment: "Title above the AI-drafted script on the draft-a-script screen."
                ),
                subtitle: draftIsSample
                    ? String(
                        localized: "onboarding.script.sample_label",
                        defaultValue: "A sample to try. Your own topic next time.",
                        comment: "Line under 'Your script' on the onboarding script step when the user left the topic empty and got the ready-made sample."
                    )
                    : trimmedTopic
            )
            Text(draft)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            errorLabel
        }
    }

    // MARK: - Paste

    private var pasteContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(
                title: String(
                    localized: "onboarding.script.paste_title",
                    defaultValue: "Paste your script",
                    comment: "Title of the onboarding step where the user pastes or types their own script."
                ),
                subtitle: String(
                    localized: "onboarding.script.paste_subtitle",
                    defaultValue: "Any length. You can fix it later.",
                    comment: "Subtitle on the onboarding paste-your-script step."
                )
            )
            TextEditor(text: $pasted)
                .focused($pasteFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxHeight: .infinity)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(pasteFocused ? Theme.accent : .clear, lineWidth: 1.5)
                )
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text(String(
                            localized: "onboarding.script.paste_placeholder",
                            defaultValue: "Paste or type what you’ll say",
                            comment: "Placeholder in the text area on the onboarding paste-your-script step."
                        ))
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch mode {
            case .topic:
                Button(action: writeTapped) {
                    HStack(spacing: 8) {
                        if isDrafting {
                            ProgressView().tint(.black)
                            Text(String(localized: "draft.drafting", defaultValue: "Writing your script…", comment: "Shown on the draft button while the AI writes the script."))
                        } else {
                            Image(systemName: "sparkles")
                            Text(String(
                                localized: "onboarding.script.write",
                                defaultValue: "Write my script",
                                comment: "Primary button on the onboarding script step: the AI writes a script from the topic, or, with no topic, the ready-made sample is used."
                            ))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .disabled(isDrafting)

                Button {
                    AppAnalytics.log("onboarding_script_paste_tapped")
                    errorMessage = nil
                    mode = .paste
                    pasteFocused = true
                } label: {
                    Text(String(
                        localized: "onboarding.script.paste",
                        defaultValue: "I have my own text",
                        comment: "Secondary button on the onboarding script step: paste or type an own script instead of the AI."
                    ))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDrafting)

            case .result:
                recordButton(enabled: !isDrafting) {
                    save(
                        content: draft,
                        title: draftIsSample ? Self.sampleTitle : title(from: trimmedTopic),
                        source: draftIsSample ? "sample" : "ai"
                    )
                }
                if !draftIsSample {
                    quietLink(isDrafting
                        ? String(localized: "draft.drafting", defaultValue: "Writing your script…", comment: "Shown on the draft button while the AI writes the script.")
                        : String(localized: "draft.retry", defaultValue: "Another version", comment: "Button after a script was drafted: draft it again.")
                    ) {
                        AppAnalytics.log("onboarding_script_retry_tapped")
                        requestDraft()
                    }
                    .disabled(isDrafting)
                }

            case .paste:
                recordButton(enabled: !trimmedPaste.isEmpty) {
                    save(content: trimmedPaste, title: title(from: trimmedPaste), source: "pasted")
                }
                quietLink(String(
                    localized: "onboarding.script.paste_back_ai",
                    defaultValue: "Write it with AI instead",
                    comment: "Quiet link on the onboarding paste-your-script step: back to the topic for the AI."
                )) {
                    mode = .topic
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func recordButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(
                String(localized: "draft.record", defaultValue: "Record it", comment: "Primary button after a script was drafted: save it and open the camera."),
                systemImage: "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .primaryButtonStyle()
        .disabled(!enabled)
    }

    // MARK: - Actions

    private func writeTapped() {
        topicFocused = false
        errorMessage = nil
        guard !trimmedTopic.isEmpty else {
            AppAnalytics.log("onboarding_script_sample_used")
            draft = Self.sampleContent
            draftIsSample = true
            mode = .result
            return
        }
        requestDraft()
    }

    private func requestDraft() {
        guard !trimmedTopic.isEmpty, !isDrafting else { return }
        errorMessage = nil
        isDrafting = true
        let topic = trimmedTopic
        let kind = AnthropicService.DraftKind.short
        let length = AnthropicService.DraftLength.seconds30
        AppAnalytics.log("draft_script_requested", params: ["kind": kind.rawValue, "length_sec": length.rawValue, "purpose": "onboarding"])
        Task {
            defer { isDrafting = false }
            do {
                let text = try await AnthropicService.draftScript(topic: topic, length: length, kind: kind)
                AppAnalytics.log("draft_script_succeeded", params: ["kind": kind.rawValue, "length_sec": length.rawValue])
                draft = text
                draftIsSample = false
                mode = .result
            } catch AnthropicService.ServiceError.freeQuotaExhausted {
                AppAnalytics.log("draft_script_failed", params: ["reason": "free_quota_exhausted"])
                // No paywall in the middle of onboarding.
                errorMessage = String(
                    localized: "onboarding.script.error.quota",
                    defaultValue: "You’ve used today’s free drafts. Leave the topic empty for a sample, or paste your own text.",
                    comment: "Error on the onboarding script step when the free daily AI drafts are used up."
                )
            } catch AnthropicService.ServiceError.cannotDraft {
                AppAnalytics.log("draft_script_failed", params: ["reason": "cannot_draft"])
                errorMessage = String(
                    localized: "draft.error.topic",
                    defaultValue: "We can’t write about this topic. Try another one.",
                    comment: "Error on the draft-a-script screen when the AI declines the topic."
                )
            } catch {
                AppAnalytics.log("draft_script_failed", params: ["reason": String(describing: error).prefix(80).description])
                errorMessage = String(
                    localized: "draft.error.generic",
                    defaultValue: "Couldn’t write a draft right now. Try again, or write it yourself.",
                    comment: "Error on the draft-a-script screen when drafting fails (network, server)."
                )
            }
        }
    }

    private func save(content: String, title: String, source: String) {
        let script = Script(title: title, content: content)
        modelContext.insert(script)
        try? modelContext.save()
        AppAnalytics.log("onboarding_script_saved", params: [
            "source": source,
            "script_length_words": content.split(separator: " ").count
        ])
        onScript(script)
    }

    /// The first line of `source`, kept short, as the script's title.
    private func title(from source: String) -> String {
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Pieces

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: - Sample

    static var sampleTitle: String {
        String(
            localized: "onboarding.sample.title",
            defaultValue: "My first take",
            comment: "Title of the ready-made sample script a new user gets when they leave the topic empty in onboarding."
        )
    }

    /// Written to be read aloud on a first take: short, about the camera,
    /// and true for anyone.
    static var sampleContent: String {
        String(
            localized: "onboarding.sample.content",
            defaultValue: "Hi! This is my first take with SteadyEye. The words appear right under the lens, so I can read and still look you in the eye. No notes, no looking down. Just me and the camera.",
            comment: "Ready-made sample script a new user records in onboarding when they have no topic yet. Read aloud on camera, first person; keep it short and natural."
        )
    }
}
