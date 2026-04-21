import SwiftUI
import AVKit
import Photos
import FirebaseAnalytics

struct VideoPreviewView: View {
    let videoURL: URL
    let onRetake: () -> Void
    let onSaved: () -> Void

    @AppStorage("hasCompletedFirstRecording") private var hasCompletedFirstRecording = false

    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var showSavedCheck = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // Bottom controls
            VStack {
                Spacer()

                // Retake / Save buttons
                HStack(spacing: 60) {
                    Button {
                        player?.pause()
                        discardAndRetake()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(.white.opacity(0.15), in: Circle())
                            Text("video.preview.retake", comment: "Button label that discards the recording and returns to the recording screen")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    Button {
                        saveToPhotos()
                    } label: {
                        VStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 60, height: 60)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 60, height: 60)
                                    .background(
                                        showSavedCheck
                                            ? Color.green.opacity(0.5)
                                            : Color(red: 0.2, green: 0.78, blue: 0.35),
                                        in: Circle()
                                    )
                            }
                            Text("common.save", comment: "Save-to-Photos button label in the recorded video preview")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .disabled(isSaving || showSavedCheck)
                }
                .padding(.bottom, 20)

                // Scrubber with timestamps
                VStack(spacing: 6) {
                    Slider(
                        value: $currentTime,
                        in: 0...max(0.01, duration)
                    ) { editing in
                        isScrubbing = editing
                        if editing {
                            player?.pause()
                        } else {
                            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                            player?.play()
                        }
                    }
                    .tint(.white)

                    HStack {
                        Text(formatTime(currentTime))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(formatTime(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            let avPlayer = AVPlayer(url: videoURL)
            self.player = avPlayer

            // Get duration
            if let item = avPlayer.currentItem {
                Task {
                    if let dur = try? await item.asset.load(.duration) {
                        await MainActor.run {
                            duration = CMTimeGetSeconds(dur)
                        }
                    }
                }
            }

            // Periodic time observer
            timeObserver = avPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [self] time in
                guard !isScrubbing else { return }
                currentTime = CMTimeGetSeconds(time)
            }

            // Loop playback
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }

            avPlayer.play()
        }
        .onChange(of: currentTime) { _, newTime in
            if isScrubbing {
                player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onDisappear {
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
            }
            player?.pause()
            player = nil
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func saveToPhotos() {
        isSaving = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                isSaving = false
                if success {
                    showSavedCheck = true
                    try? FileManager.default.removeItem(at: videoURL)
                    if !hasCompletedFirstRecording {
                        hasCompletedFirstRecording = true
                        MetaAnalytics.logFirstRecordingCompleted()
                        #if !DEV
                        Analytics.logEvent("first_recording_completed", parameters: [
                            "duration_sec": Int(duration)
                        ])
                        #endif
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onSaved()
                    }
                } else {
                    UISaveVideoAtPathToSavedPhotosAlbum(videoURL.path, nil, nil, nil)
                    try? FileManager.default.removeItem(at: videoURL)
                    onSaved()
                }
            }
        }
    }

    private func discardAndRetake() {
        try? FileManager.default.removeItem(at: videoURL)
        onRetake()
    }
}
