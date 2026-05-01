import Foundation
import SwiftData
import AVFoundation
import UIKit

/// File and SwiftData management for `Recording` entities. Owns the lifecycle
/// of auto-save (move + thumbnail + insert) plus delete. Directory layout
/// lives on `Recording` so the model can resolve relative filenames to
/// current absolute URLs at runtime.
///
/// Watermark burn-in happens at recording time via the realtime composer in
/// CameraManager — by the time `persist` runs, the file on disk already
/// contains burned-in pixels (free) or no watermark (Pro). The
/// `Recording.hasWatermark` field is informational only (analytics).
enum RecordingPersistence {
    /// Auto-save a fresh recording: move to permanent location, generate
    /// thumbnail, insert SwiftData entity. Calls `completion` on the main
    /// queue. The whole pipeline runs in well under a second.
    ///
    /// `hasWatermark` is computed from `SubscriptionManager.shared.showWatermark`
    /// at persist time and stored on the entity for analytics
    /// (`recording_exported_to_camera_roll` reports it). The realtime
    /// composer in CameraManager makes the same decision at recording
    /// start, so the stored flag matches what's actually in the file.
    @MainActor
    static func persist(
        sourceURL: URL,
        scriptTitle: String,
        duration: TimeInterval,
        modelContext: ModelContext,
        completion: @escaping (Result<Recording, Error>) -> Void
    ) {
        let recordingID = UUID()
        let recordingFileName = "\(recordingID.uuidString).mov"
        let finalURL = Recording.recordingsDirectory.appendingPathComponent(recordingFileName)
        let hasWatermark = SubscriptionManager.shared.showWatermark

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
        } catch {
            completion(.failure(error))
            return
        }

        generateThumbnail(forVideoAt: finalURL, recordingID: recordingID) { thumbResult in
            let thumbnailFileName: String?
            switch thumbResult {
            case .success(let name): thumbnailFileName = name
            case .failure: thumbnailFileName = nil
            }
            Task { @MainActor in
                let recording = Recording(
                    fileName: recordingFileName,
                    thumbnailFileName: thumbnailFileName,
                    scriptTitle: scriptTitle,
                    duration: duration,
                    hasWatermark: hasWatermark
                )
                modelContext.insert(recording)
                try? modelContext.save()
                completion(.success(recording))
            }
        }
    }

    /// Remove file, thumbnail, and SwiftData entity. Failures on file removal
    /// (e.g. file deleted externally) are tolerated — the entity is still
    /// removed so the UI cleans up.
    @MainActor
    static func delete(_ recording: Recording, modelContext: ModelContext) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        if let thumbURL = recording.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        modelContext.delete(recording)
        try? modelContext.save()
    }

    private static func generateThumbnail(
        forVideoAt videoURL: URL,
        recordingID: UUID,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)

            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                let cgImage = result.image
                let uiImage = UIImage(cgImage: cgImage)
                guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
                    completion(.failure(NSError(
                        domain: "RecordingPersistence",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"]
                    )))
                    return
                }
                let thumbnailFileName = "\(recordingID.uuidString).jpg"
                let thumbURL = Recording.thumbnailsDirectory
                    .appendingPathComponent(thumbnailFileName)
                try jpegData.write(to: thumbURL)
                completion(.success(thumbnailFileName))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
