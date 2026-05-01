import Foundation
import SwiftData

/// A persisted recording. Files live under `Documents/Recordings/` and
/// `Documents/Thumbnails/`. Only the relative filenames are stored in
/// SwiftData — absolute paths are reconstructed at runtime via the computed
/// `fileURL`/`thumbnailURL` properties. iOS sandbox container UUIDs change
/// between app launches/installs, so persisting absolute URLs would silently
/// invalidate every recording on rebuild.
@Model
final class Recording: Identifiable {
    var id: UUID
    var fileName: String
    var thumbnailFileName: String?
    var scriptTitle: String
    var duration: TimeInterval
    var createdAt: Date
    var hasWatermark: Bool

    init(
        fileName: String,
        thumbnailFileName: String? = nil,
        scriptTitle: String,
        duration: TimeInterval,
        hasWatermark: Bool
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.scriptTitle = scriptTitle
        self.duration = duration
        self.createdAt = Date()
        self.hasWatermark = hasWatermark
    }

    var fileURL: URL {
        Recording.recordingsDirectory.appendingPathComponent(fileName)
    }

    var thumbnailURL: URL? {
        guard let thumbnailFileName else { return nil }
        return Recording.thumbnailsDirectory.appendingPathComponent(thumbnailFileName)
    }

    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var thumbnailsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
