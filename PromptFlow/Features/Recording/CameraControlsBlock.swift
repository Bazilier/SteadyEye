import SwiftUI

/// The 3 action buttons: play/pause, record, reset.
/// Always positioned at bottom center. Play and reset icons rotate in landscape.
struct CameraControlsBlock: View {
    @ObservedObject var player: ChunkPlayerEngine
    let isRecording: Bool
    @Binding var smoothProgress: Double
    let deviceOrientation: UIDeviceOrientation
    let onTogglePlay: () -> Void
    let onToggleRecording: () -> Void
    let onReset: () -> Void

    private var iconRotation: Angle {
        deviceOrientation == .landscapeLeft ? .degrees(90) : .degrees(0)
    }

    var body: some View {
        HStack(spacing: 48) {
            Button { onTogglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .rotationEffect(iconRotation)
                    .animation(.easeInOut(duration: 0.3), value: deviceOrientation.rawValue)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!player.isReady)

            Button { onToggleRecording() } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 72, height: 72)
                    RoundedRectangle(cornerRadius: isRecording ? 6 : 28)
                        .fill(.red)
                        .frame(
                            width: isRecording ? 28 : 52,
                            height: isRecording ? 28 : 52
                        )
                        .animation(.easeInOut(duration: 0.2), value: isRecording)
                }
            }

            Button { onReset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .rotationEffect(iconRotation)
                    .animation(.easeInOut(duration: 0.3), value: deviceOrientation.rawValue)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .onChange(of: player.currentChunkIndex) { _, newIndex in
            guard newIndex < player.chunks.count, player.isPlaying else { return }
            animateProgressForChunk(at: newIndex)
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing && player.currentChunkIndex < player.chunks.count {
                animateProgressForChunk(at: player.currentChunkIndex)
            }
        }
    }

    private func animateProgressForChunk(at index: Int) {
        guard !player.chunks.isEmpty else { return }
        let target = Double(index + 1) / Double(player.chunks.count)
        let duration = player.chunkDuration(player.chunks[index])
        withAnimation(.linear(duration: duration)) {
            smoothProgress = target
        }
    }
}
