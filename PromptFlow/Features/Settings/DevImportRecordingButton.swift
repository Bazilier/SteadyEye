#if DEV
import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// DEV: puts any video from Photos into the Recordings library through the
/// same path a take takes (`RecordingPersistence`), so the library and the
/// video preview can be looked at where there is no camera — the Simulator,
/// iPhone Duo's included. In the Simulator, add a video to Photos first:
/// `xcrun simctl addmedia booted <file>`.
struct DevImportRecordingButton: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selection: PhotosPickerItem?
    @State private var status: String?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .videos) {
            Text(verbatim: "Import video as a recording")
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            selection = nil
            status = "Importing…"
            Task { await importVideo(item) }
        }
        if let status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                status = "Could not load the video."
                return
            }
            let duration = (try? await AVURLAsset(url: movie.url).load(.duration).seconds) ?? 0
            RecordingPersistence.persist(
                sourceURL: movie.url,
                scriptTitle: "Mock take",
                duration: duration,
                modelContext: modelContext
            ) { result in
                switch result {
                case .success: status = "Added to Recordings."
                case .failure(let error): status = "Failed: \(error.localizedDescription)"
                }
            }
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }
}

/// The picked video, copied out of the picker's sandbox into a temporary file
/// that `RecordingPersistence` then moves into the library.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
#endif
