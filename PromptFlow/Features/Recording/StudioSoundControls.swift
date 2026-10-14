import SwiftUI

// Studio Sound UI pieces: the toggle next to "Save to Camera Roll" in the
// preview, the hints around it, the save-while-processing sheet, and the
// banner and card badges of the Recordings list.

// MARK: - Toggle button

/// 56 pt circle left of the save button. Idle and failed: tap to enhance.
/// In flight: a progress ring. Ready: a toggle, filled when Studio Sound
/// plays, glass with a dot when the original does.
struct StudioSoundButton: View {
    let recording: Recording
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isInFlight {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ring(progress: StudioSoundManager.shared.progress(for: recording, now: context.date))
                    }
                }
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isInFlight ? Theme.accent : .white)
            }
            .frame(width: 56, height: 56)
            .background {
                if isOn {
                    Circle().fill(Theme.accent)
                } else {
                    Color.clear.modifier(GlassCircleModifier())
                }
            }
            .overlay(alignment: .topTrailing) { badge }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var status: StudioStatus? { recording.studioStatus }
    private var isInFlight: Bool { status?.isInFlight == true }
    private var isOn: Bool { recording.usesStudioAudio }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.8), value: progress)
        }
        .padding(1.5)
    }

    @ViewBuilder
    private var badge: some View {
        if status == .failed {
            Text(verbatim: "!")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.red, in: Circle())
                .overlay(Circle().stroke(Color.black, lineWidth: 2))
        } else if status == .ready && !recording.studioEnabled {
            Circle()
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                .padding(2)
        }
    }

    private var accessibilityLabel: String {
        if isOn {
            return String(
                localized: "studio.button.on",
                defaultValue: "Studio Sound on",
                comment: "VoiceOver label of the Studio Sound toggle while the enhanced audio plays."
            )
        }
        if status == .ready {
            return String(
                localized: "studio.chip.original",
                defaultValue: "Original sound",
                comment: "Chip over the preview video, and VoiceOver label of the toggle, when the original (not enhanced) audio plays."
            )
        }
        return String(
            localized: "studio.button.enhance",
            defaultValue: "Enhance sound",
            comment: "VoiceOver label of the Studio Sound button before the audio has been enhanced."
        )
    }
}

// MARK: - Hints

/// Small card floating above the preview's controls.
struct StudioHintCard: View {
    enum Kind { case processing, failed }

    let kind: Kind
    var message: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .processing ? "sparkles" : "exclamationmark.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(kind == .processing ? Theme.accent : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message ?? defaultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var title: String {
        switch kind {
        case .processing:
            return String(
                localized: "studio.hint.processing.title",
                defaultValue: "Enhancing sound · about a minute",
                comment: "Title of the hint above the preview controls while Studio Sound processes."
            )
        case .failed:
            return String(
                localized: "studio.hint.failed.title",
                defaultValue: "Couldn't enhance the sound",
                comment: "Title of the hint above the preview controls, and of the Recordings banner, when Studio Sound failed."
            )
        }
    }

    private var defaultMessage: String {
        String(
            localized: "studio.hint.processing.body",
            defaultValue: "You can close this screen. We'll keep the result.",
            comment: "Body of the hint above the preview controls while Studio Sound processes."
        )
    }
}

/// One-time explainer pointing at the Studio Sound button.
struct StudioCoachBubble: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                localized: "studio.coach.title",
                defaultValue: "Studio sound",
                comment: "Title of the one-time tip above the Studio Sound button."
            ))
            .font(.subheadline.weight(.semibold))
            Text(String(
                localized: "studio.coach.body",
                defaultValue: "Removes noise and echo, evens out the volume",
                comment: "Body of the one-time tip above the Studio Sound button."
            ))
            .font(.footnote)
            .foregroundStyle(Color(white: 0.24))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .offset(x: 21, y: 6)
        }
    }
}

/// Which soundtrack plays, shown for a moment at the top of the preview.
struct StudioChip: View {
    let isStudio: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isStudio {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text(verbatim: "Studio Sound")
            } else {
                Text(String(
                    localized: "studio.chip.original",
                    defaultValue: "Original sound",
                    comment: "Chip over the preview video, and VoiceOver label of the toggle, when the original (not enhanced) audio plays."
                ))
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Save while processing

struct StudioSaveSheet: View {
    let onSaveWhenReady: () -> Void
    let onSaveOriginal: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accentTint, in: Circle())
                .padding(.bottom, 14)
            Text(String(
                localized: "studio.sheet.title",
                defaultValue: "Sound is still being enhanced",
                comment: "Title of the sheet shown when the user saves a recording while Studio Sound is still processing."
            ))
            .font(.title2.bold())
            .padding(.bottom, 6)
            Text(String(
                localized: "studio.sheet.body",
                defaultValue: "About a minute left. We can save the video to your Camera Roll as soon as the sound is ready.",
                comment: "Body of the sheet shown when the user saves a recording while Studio Sound is still processing."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            Button(action: onSaveWhenReady) {
                Text(String(
                    localized: "studio.sheet.saveWhenReady",
                    defaultValue: "Save when ready",
                    comment: "Sheet button: save the recording to Camera Roll automatically once Studio Sound finishes."
                ))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Theme.accent, in: Capsule())
            }
            .padding(.bottom, 10)

            Button(action: onSaveOriginal) {
                Text(String(
                    localized: "studio.sheet.saveOriginal",
                    defaultValue: "Save with original sound",
                    comment: "Sheet button: save the recording to Camera Roll now, with its original audio."
                ))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white.opacity(0.1), in: Capsule())
            }

            Button(action: onCancel) {
                Text("common.cancel", comment: "Generic Cancel button used in alerts and toolbars.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(white: 0.11))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Recordings list

/// Banner above the Recordings grid: what Studio Sound is doing.
struct StudioBanner: View {
    enum Content {
        case processing(Recording)
        case finished(StudioSoundManager.Finished)
        case failed(Recording)
    }

    let content: Content
    let onOpen: (UUID) -> Void
    let onRetry: (Recording) -> Void
    let onDismiss: (Recording) -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .processing(let recording) = content {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ProgressView(value: StudioSoundManager.shared.progress(for: recording, now: context.date))
                            .tint(Theme.accent)
                            .animation(.easeInOut(duration: 0.8), value: context.date)
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        let (name, color): (String, Color) = {
            switch content {
            case .processing: return ("sparkles", Theme.accent)
            case .finished: return ("checkmark", .green)
            case .failed: return ("exclamationmark", .red)
            }
        }()
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.16), in: Circle())
    }

    private var title: String {
        switch content {
        case .processing:
            return String(
                localized: "studio.banner.processing",
                defaultValue: "Enhancing sound",
                comment: "Recordings banner title while Studio Sound processes a recording."
            )
        case .finished:
            return String(
                localized: "studio.banner.done",
                defaultValue: "Sound enhanced",
                comment: "Recordings banner title when Studio Sound has finished."
            )
        case .failed:
            return String(
                localized: "studio.hint.failed.title",
                defaultValue: "Couldn't enhance the sound",
                comment: "Title of the hint above the preview controls, and of the Recordings banner, when Studio Sound failed."
            )
        }
    }

    private var subtitle: String {
        switch content {
        case .processing:
            return String(
                localized: "studio.banner.background",
                defaultValue: "You can minimize the app",
                comment: "Recordings banner subtitle while Studio Sound processes: leaving the app is fine."
            )
        case .finished(let finished):
            if finished.savedToPhotos {
                return String(
                    localized: "studio.banner.savedToPhotos",
                    defaultValue: "Saved to Camera Roll",
                    comment: "Recordings banner subtitle when Studio Sound finished and the video was saved to Camera Roll automatically."
                )
            }
            return finished.title
        case .failed(let recording):
            return StudioSoundManager.failureMessage(for: recording.studioErrorCode)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch content {
        case .processing:
            EmptyView()
        case .finished(let finished):
            Button {
                onOpen(finished.recordingID)
            } label: {
                Text(String(
                    localized: "studio.banner.open",
                    defaultValue: "Open",
                    comment: "Recordings banner button that opens the recording whose sound was just enhanced."
                ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
            }
        case .failed(let recording):
            HStack(spacing: 4) {
                Button {
                    onRetry(recording)
                } label: {
                    Text(String(
                        localized: "studio.banner.retry",
                        defaultValue: "Retry",
                        comment: "Recordings banner button that retries Studio Sound after a failure."
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                Button {
                    onDismiss(recording)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                }
                .accessibilityLabel(Text(String(
                    localized: "studio.banner.dismiss",
                    defaultValue: "Dismiss",
                    comment: "VoiceOver label of the button that hides the Studio Sound failure banner in Recordings."
                )))
            }
        }
    }
}

/// Studio Sound state on a recording's card thumbnail.
struct StudioCardOverlay: View {
    let recording: Recording

    var body: some View {
        switch recording.studioStatus {
        case .preparing, .uploading, .processing, .downloading:
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let progress = StudioSoundManager.shared.progress(for: recording, now: context.date)
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 3.5)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.8), value: progress)
                        }
                        .frame(width: 36, height: 36)
                    }
                    Text(String(
                        localized: "studio.card.processing",
                        defaultValue: "Enhancing…",
                        comment: "Label over a recording card's thumbnail while Studio Sound processes it."
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                }
            }
        case .ready where recording.studioEnabled:
            badge(icon: "sparkles", tint: Theme.accent, text: "Studio", textColor: .white)
        case .failed:
            badge(
                icon: "exclamationmark.circle",
                tint: .red,
                text: String(
                    localized: "studio.card.failed",
                    defaultValue: "Error",
                    comment: "Badge on a recording card's thumbnail when Studio Sound failed."
                ),
                textColor: Color(red: 1, green: 0.41, blue: 0.38)
            )
        default:
            EmptyView()
        }
    }

    private func badge(icon: String, tint: Color, text: String, textColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .foregroundStyle(textColor)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6), in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
