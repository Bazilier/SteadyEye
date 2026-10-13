import SwiftUI
import SwiftData
import Photos
import UIKit

struct RecordingsView: View {
    @Binding var selectedTab: AppTab
    /// Set when this list shares the screen with the scripts list (iPhone Duo
    /// unfolded): a settings button takes the crown's place — the scripts
    /// list keeps the crown — and the empty state does not send the user to
    /// a scripts tab that is already beside it.
    var onOpenSettings: (() -> Void)? = nil
    @ObservedObject private var chatBadgeState = ChatBadgeState.shared
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]

    @State private var searchText: String = ""
    @State private var playingRecording: Recording?
    @State private var deleteTarget: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showSavedToast = false
    @State private var missingRecording: Recording?
    @State private var showMissingFileAlert = false
    @State private var showPaywall = false
    /// Opens a card's preview after its press shrink (see `CardPressStyle`).
    @State private var cardOpener = CardOpener()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// As many columns as fit at 150 pt: two on every phone, as before; more
    /// on a wide pane (iPhone Duo unfolded), so cards don't grow to one per row.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    /// Zoom from a card into the preview (iOS 18+).
    @Namespace private var previewZoom

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty { return allRecordings }
        return allRecordings.filter {
            $0.scriptTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// `filteredRecordings` split into runs that share a calendar day of
    /// `createdAt`. The query is already newest-first, so each day's
    /// recordings are contiguous and days with no matches drop out.
    private var recordingsByDay: [(day: Date, recordings: [Recording])] {
        let calendar = Calendar.current
        var groups: [(day: Date, recordings: [Recording])] = []
        for recording in filteredRecordings {
            let day = calendar.startOfDay(for: recording.createdAt)
            if groups.last?.day == day {
                groups[groups.count - 1].recordings.append(recording)
            } else {
                groups.append((day, [recording]))
            }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            Group {
                if allRecordings.isEmpty {
                    emptyState
                } else if filteredRecordings.isEmpty {
                    noSearchResultsState
                } else {
                    grid
                }
            }
            .navigationTitle(Text("recordings.tabTitle", comment: "Recordings tab label / nav title."))
            .searchable(
                text: $searchText,
                prompt: Text(
                    "recordings.search.prompt",
                    comment: "Search bar placeholder above the recordings grid."
                )
            )
            .toolbar {
                // Free-tier upgrade entry point — hidden for Pro users.
                ToolbarItem(placement: .topBarLeading) {
                    if let onOpenSettings {
                        Button(action: onOpenSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .overlay(alignment: .topTrailing) {
                                    if chatBadgeState.unreadCount > 0 {
                                        Circle().fill(.red).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                    }
                                }
                        }
                        .accessibilityLabel(Text("settings.title", comment: "Settings tab label / nav title"))
                    } else if !subscriptionManager.isSubscribed {
                        Button(action: {
                            showPaywall = true
                        }) {
                            Image(systemName: "crown.fill")
                                .foregroundColor(Theme.accent)
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if showSavedToast {
                    Text(String(
                        localized: "recordings.toast.savedToCameraRoll",
                        defaultValue: "Saved to Camera Roll",
                        comment: "Toast shown after a recording is exported to the Photos library."
                    ))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            Text(String(
                localized: "recordings.delete.title",
                defaultValue: "Delete recording?",
                comment: "Title of the delete-confirmation alert in the Recordings tab and finished view."
            )),
            isPresented: $showDeleteConfirmation
        ) {
            Button(role: .cancel) { deleteTarget = nil } label: {
                Text("common.cancel", comment: "Cancel button on the recording delete-confirmation alert.")
            }
            Button(role: .destructive) {
                if let target = deleteTarget {
                    RecordingPersistence.delete(target, modelContext: modelContext)
                }
                deleteTarget = nil
            } label: {
                Text(String(
                    localized: "recordings.delete.confirm",
                    defaultValue: "Delete",
                    comment: "Destructive button on the recording delete-confirmation alert."
                ))
            }
        } message: {
            Text(String(
                localized: "recordings.delete.message",
                defaultValue: "This action cannot be undone.",
                comment: "Body of the recording delete-confirmation alert."
            ))
        }
        .alert(
            Text(String(
                localized: "recordings.missing.title",
                defaultValue: "This recording is no longer available",
                comment: "Title of the alert shown when the user taps a recording whose underlying file is missing on disk."
            )),
            isPresented: $showMissingFileAlert
        ) {
            Button(role: .cancel) { missingRecording = nil } label: {
                Text("common.cancel", comment: "Cancel button on the missing-recording alert.")
            }
            Button(role: .destructive) {
                if let target = missingRecording {
                    RecordingPersistence.delete(target, modelContext: modelContext)
                }
                missingRecording = nil
            } label: {
                Text(String(
                    localized: "recordings.missing.delete",
                    defaultValue: "Delete",
                    comment: "Destructive button on the missing-recording alert that removes the orphaned entity."
                ))
            }
        } message: {
            Text(String(
                localized: "recordings.missing.message",
                defaultValue: "The video file couldn't be found. Remove this recording from your library?",
                comment: "Body of the alert shown when a recording's underlying file is missing on disk."
            ))
        }
        .fullScreenCover(item: $playingRecording) { recording in
            VideoPreviewView(
                recording: recording,
                onDismiss: { playingRecording = nil },
                // The same file the card shows; read, not regenerated.
                poster: recording.thumbnailURL.flatMap { UIImage(contentsOfFile: $0.path) }
            )
            .cardZoomTransition(id: recording.id, in: previewZoom)
            .onPresentationComplete { cardOpener.resetCard() }
        }
        .onChange(of: playingRecording) { _, recording in
            // Closed before the presentation completed.
            if recording == nil { cardOpener.resetCard() }
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(source: "recordings_crown")
        }
    }

    // MARK: - No-search-results state

    private var noSearchResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text(String(
                localized: "recordings.search.noResults",
                defaultValue: "No recordings match \"\(searchText)\"",
                comment: "Shown above the recordings grid when the search text returns no matches. %@ is the search query the user typed."
            ))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.6))
            VStack(spacing: 8) {
                Text(String(
                    localized: "recordings.empty.title",
                    defaultValue: "No recordings yet",
                    comment: "Empty-state title in the Recordings tab when the user has no saved recordings."
                ))
                    .font(.title3.bold())
                Text(String(
                    localized: "recordings.empty.body",
                    defaultValue: "Pick a script and hit record to make your first video.",
                    comment: "Empty-state body in the Recordings tab encouraging the user to start recording."
                ))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if onOpenSettings == nil {
            Button {
                selectedTab = .scripts
            } label: {
                Text(String(
                    localized: "recordings.empty.cta",
                    defaultValue: "Go to Scripts",
                    comment: "Empty-state CTA button on the Recordings tab that switches to the Scripts tab."
                ))
                    .padding(.horizontal, 32)
            }
            .primaryButtonStyle(fullWidth: false)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recordingsByDay.enumerated()), id: \.element.day) { index, group in
                    // Same header as the script list; lines up with the
                    // cards' text, scrolls with the content.
                    Text(DayTitle.string(for: group.day))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.top, index == 0 ? 0 : 20)
                        .padding(.bottom, 8)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(group.recordings) { recording in
                            Button {
                                if FileManager.default.fileExists(atPath: recording.fileURL.path) {
                                    cardOpener.open(recording.id, reduceMotion: reduceMotion) {
                                        playingRecording = recording
                                    }
                                } else {
                                    missingRecording = recording
                                    showMissingFileAlert = true
                                }
                            } label: {
                                // The zoom source sits inside the press scale,
                                // so the zoom starts from the pressed frame.
                                RecordingThumbnailCard(recording: recording)
                                    .cardZoomSource(id: recording.id, in: previewZoom)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(CardPressStyle(id: recording.id, opener: cardOpener))
                            .contextMenu {
                                Button {
                                    saveToCameraRoll(recording)
                                } label: {
                                    Label {
                                        Text(String(
                                            localized: "recordings.action.saveToCameraRoll",
                                            defaultValue: "Save to Camera Roll",
                                            comment: "Recordings context-menu action that exports the recording to the Photos library."
                                        ))
                                    } icon: {
                                        menuIcon("photo", accent: true)
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deleteTarget = recording
                                    showDeleteConfirmation = true
                                } label: {
                                    Label {
                                        Text(String(
                                            localized: "recordings.action.delete",
                                            defaultValue: "Delete",
                                            comment: "Recordings context-menu destructive action that removes the recording."
                                        ))
                                    } icon: {
                                        menuIcon("trash", accent: false)
                                    }
                                }
                            }
                            .disabled(cardOpener.pendingID != nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .cancelsPendingCardOpen(cardOpener)
        .onDisappear { cardOpener.cancelPending() }
    }

    /// Context-menu icons are drawn by UIKit, whose tint is system blue: the
    /// AccentColor asset and the SwiftUI `.tint` don't reach it. Pre-coloured
    /// images keep their colour (accent, or red for the destructive item).
    private func menuIcon(_ systemName: String, accent: Bool) -> Image {
        let color = accent ? (UIColor(named: "AccentColor") ?? .tintColor) : .systemRed
        guard let image = UIImage(systemName: systemName) else { return Image(systemName: systemName) }
        return Image(uiImage: image.withTintColor(color, renderingMode: .alwaysOriginal))
    }

    // MARK: - Actions

    private func saveToCameraRoll(_ recording: Recording) {
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: recording.fileURL)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    AppAnalytics.log("recording_exported_to_camera_roll", params: [
                        "duration_sec": Int(recording.duration.rounded()),
                        "had_watermark": recording.hasWatermark,
                        "via": "context_menu"
                    ])
                    withAnimation { showSavedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { showSavedToast = false }
                    }
                } else {
                    AppAnalytics.log("recording_export_failed", params: [
                        "duration_sec": Int(recording.duration.rounded()),
                        "had_watermark": recording.hasWatermark,
                        "via": "context_menu",
                        "error_reason": error?.localizedDescription ?? "unknown"
                    ])
                }
            }
        }
    }
}

// MARK: - Thumbnail card

struct RecordingThumbnailCard: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.black
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { thumbnailImage }
                    .clipped()
                Text(formatDuration(recording.duration))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.scriptTitle.isEmpty
                    ? String(
                        localized: "recordings.card.untitled",
                        defaultValue: "Recording",
                        comment: "Fallback title shown on a recording card when the source script has no title."
                    )
                    : recording.scriptTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same card as the script list rows; the thumbnail is clipped by it.
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbURL = recording.thumbnailURL,
           FileManager.default.fileExists(atPath: thumbURL.path),
           let uiImage = UIImage(contentsOfFile: thumbURL.path) {
            // No explicit aspect ratio here — `resizable()` + `aspectRatio(contentMode: .fill)`
            // preserves the source image's natural ratio (portrait 9:16) and scales it to
            // fully cover the surrounding square frame. Overflow on top/bottom is clipped
            // by the outer `.clipped()` in the caller. Adding an explicit `aspectRatio(1, ...)`
            // here would override the source ratio and squeeze the pixels.
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "video")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
