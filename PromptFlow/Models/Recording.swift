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

    // Studio Sound (StudioSoundManager). All optional or defaulted, so
    // SwiftData migrates existing stores without a schema version.
    /// `StudioStatus` raw value; nil until the user first taps the button.
    var studioStatusRaw: String?
    /// The backend job, once the upload went through.
    var studioJobID: String?
    /// One enhance attempt; a retried upload reuses it so the server never
    /// starts (and bills) the same attempt twice.
    var studioRequestID: String?
    var studioStartedAt: Date?
    /// Why the last attempt failed (`StudioSoundService.ServiceError.code`
    /// or an audio step's code).
    var studioErrorCode: String?
    /// The processed audio, AAC, next to the video in `recordingsDirectory`.
    var studioAudioFileName: String?
    /// The toggle: play and save the processed audio (true) or the original.
    var studioEnabled: Bool = true
    /// Save to Camera Roll as soon as processing finishes.
    var studioSaveWhenReady: Bool = false

    // Section cuts (`SectionTakeLog`). Optional or defaulted, like Studio
    // Sound's fields, so existing stores migrate as they are.
    /// The parts of the file to keep, in seconds: the last take of each
    /// `////` section. JSON `[[start, end], …]`; nil for a take without
    /// sections.
    var sectionCutsData: Data?
    /// The toggle: play and save the cut version (true) or the whole take.
    var sectionCutsEnabled: Bool = true
    /// The cut (`sectionCutsData`) the Studio Sound attempt in flight sent
    /// to be processed, alone; nil when it sent the whole take. Set at
    /// upload, moved to `studioCutData` when the result is in.
    var studioJobCutData: Data?
    /// The cut the processed audio covers, on the cut's own timeline; nil
    /// when it covers the whole take.
    var studioCutData: Data?

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

    var studioStatus: StudioStatus? {
        get { studioStatusRaw.flatMap(StudioStatus.init(rawValue:)) }
        set { studioStatusRaw = newValue?.rawValue }
    }

    var studioAudioURL: URL? {
        guard let studioAudioFileName else { return nil }
        return Recording.recordingsDirectory.appendingPathComponent(studioAudioFileName)
    }

    var sectionCuts: [ClosedRange<Double>]? {
        get { Self.decodeCuts(sectionCutsData) }
        set {
            sectionCutsData = newValue.flatMap { try? JSONEncoder().encode($0.map { [$0.lowerBound, $0.upperBound] }) }
        }
    }

    /// Kept ranges from `sectionCutsData`-shaped JSON.
    static func decodeCuts(_ data: Data?) -> [ClosedRange<Double>]? {
        guard let data, let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { return nil }
        let ranges = pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        return ranges.isEmpty ? nil : ranges
    }

    /// Cuts exist and the toggle is on.
    var usesSectionCuts: Bool {
        sectionCutsEnabled && sectionCuts != nil
    }

    /// What the take runs to once cut, or as recorded.
    var displayDuration: TimeInterval {
        guard usesSectionCuts, let sectionCuts else { return duration }
        return min(duration, sectionCuts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
    }

    /// Processed audio exists, the toggle is on, and it fits what plays:
    /// audio processed for the cut only plays with that cut.
    var usesStudioAudio: Bool {
        studioStatus == .ready && studioEnabled && studioAudioURL != nil && studioFitsPlayback
    }

    var studioFitsPlayback: Bool {
        guard let studioCutData else { return true }
        return usesSectionCuts && sectionCutsData == studioCutData
    }

    /// Studio Sound counts one unit per started 3 minutes of audio sent
    /// (as the server does: Auphonic's minimum per production).
    static func studioUnits(forSeconds seconds: Double) -> Int {
        max(1, Int((seconds / 180).rounded(.up)))
    }

    /// Send only the kept parts when that costs fewer units than the whole
    /// take. Otherwise the whole take goes: the same price, and it keeps
    /// Studio Sound for both versions and gives the denoiser the room tone
    /// in the pauses.
    var studioSendsCutOnly: Bool {
        usesSectionCuts
            && Self.studioUnits(forSeconds: displayDuration) < Self.studioUnits(forSeconds: duration)
    }

    /// What starting Studio Sound now costs.
    var studioUnitsToSend: Int {
        Self.studioUnits(forSeconds: studioSendsCutOnly ? displayDuration : duration)
    }

    var thumbnailURL: URL? {
        guard let thumbnailFileName else { return nil }
        return Recording.thumbnailsDirectory.appendingPathComponent(thumbnailFileName)
    }

    /// Resolved and created once per process, not on every `fileURL` /
    /// `thumbnailURL` read (each list cell reads them in its body).
    static let recordingsDirectory: URL = directory(named: "Recordings")
    static let thumbnailsDirectory: URL = directory(named: "Thumbnails")

    private static func directory(named name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
