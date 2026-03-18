import SwiftUI
import AVKit
import Photos

struct VideoPreviewView: View {
    let videoURL: URL
    let onRetake: () -> Void
    let onSaved: () -> Void

    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var showSavedCheck = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video player
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // Top controls
            VStack {
                HStack {
                    Button {
                        player?.pause()
                        discardAndRetake()
                    } label: {
                        Text("Retake")
                            .font(.body.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    Button {
                        saveToPhotos()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 44, height: 44)
                        } else {
                            Image(systemName: showSavedCheck ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.title2.bold())
                                .foregroundStyle(showSavedCheck ? .green : .white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .disabled(isSaving || showSavedCheck)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)

                Spacer()
            }
        }
        .onAppear {
            let avPlayer = AVPlayer(url: videoURL)
            self.player = avPlayer
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
        .onDisappear {
            player?.pause()
            player = nil
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
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
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: videoURL)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onSaved()
                    }
                } else {
                    // Fallback: try legacy save
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
