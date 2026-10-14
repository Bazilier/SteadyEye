import Combine
import Foundation
import SwiftData
import Photos
import UIKit

/// Where a recording's Studio Sound stands. Stored on `Recording` as its raw
/// value, so an attempt survives the app being closed.
enum StudioStatus: String {
    /// Lifting the audio track out of the video.
    case preparing
    case uploading
    /// At the server; the client polls.
    case processing
    /// Fetching the result and checking its length.
    case downloading
    case ready
    case failed

    var isInFlight: Bool {
        switch self {
        case .preparing, .uploading, .processing, .downloading: return true
        case .ready, .failed: return false
        }
    }
}

/// Runs Studio Sound for recordings: extract the audio, upload it, poll the
/// server, download the result and keep it next to the video.
///
/// The recording itself is the source of truth (`studioStatus` and friends),
/// so the list and the preview just observe it, and `resumeAll()` picks an
/// attempt up wherever it stopped — after the app was backgrounded, killed
/// or offline. Polling only runs while the app is active; the server keeps
/// processing either way.
@MainActor
final class StudioSoundManager: ObservableObject {
    static let shared = StudioSoundManager()

    /// The recording that just finished, for the Recordings banner. Cleared
    /// a few seconds later.
    @Published private(set) var lastFinished: Finished?

    struct Finished: Equatable {
        let recordingID: UUID
        let title: String
        let savedToPhotos: Bool
    }

    static let pollInterval: Duration = .seconds(3)
    static let processingTimeout: TimeInterval = 15 * 60
    private static let maxAttempts = 3

    private var context: ModelContext?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Called once the model container exists.
    func attach(_ context: ModelContext) {
        self.context = context
        resumeAll()
    }

    // MARK: - User actions

    /// Starts a new attempt: from scratch, or again after a failure.
    func start(_ recording: Recording) {
        guard recording.studioStatus?.isInFlight != true else { return }
        recording.studioRequestID = UUID().uuidString
        recording.studioJobID = nil
        recording.studioErrorCode = nil
        recording.studioStartedAt = Date()
        recording.studioStatus = .preparing
        save()
        AppAnalytics.log("studio_sound_started", params: [
            "duration_sec": Int(recording.duration.rounded()),
            "is_retry": recording.studioAudioFileName != nil
        ])
        run(recording.id)
    }

    func setEnabled(_ enabled: Bool, for recording: Recording) {
        guard recording.studioEnabled != enabled else { return }
        recording.studioEnabled = enabled
        save()
        AppAnalytics.log("studio_sound_toggled", params: ["enabled": enabled])
    }

    /// Clears a failure without retrying: the button goes back to idle.
    func dismissFailure(_ recording: Recording) {
        guard recording.studioStatus == .failed else { return }
        recording.studioStatus = recording.studioAudioFileName == nil ? nil : .ready
        recording.studioErrorCode = nil
        save()
    }

    /// The recording is being deleted: stop, and remove the audio here and
    /// at the server.
    func forget(_ recording: Recording) {
        tasks[recording.id]?.cancel()
        tasks[recording.id] = nil
        if let url = recording.studioAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let jobID = recording.studioJobID {
            Task { await StudioSoundService.delete(jobID: jobID) }
        }
    }

    /// Picks up every unfinished attempt. Called on attach and whenever the
    /// app becomes active.
    func resumeAll() {
        guard let context else { return }
        let inFlight = [StudioStatus.preparing, .uploading, .processing, .downloading].map(\.rawValue)
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { recording in
                recording.studioStatusRaw != nil
            }
        )
        let recordings = (try? context.fetch(descriptor)) ?? []
        for recording in recordings where inFlight.contains(recording.studioStatusRaw ?? "") {
            run(recording.id)
        }
    }

    // MARK: - Saving

    /// The file PhotoKit should save: the video itself, or a temporary copy
    /// carrying the processed audio when the toggle is on. Delete it after
    /// saving when `isTemporary`.
    struct SaveFile {
        let url: URL
        let isTemporary: Bool
    }

    func fileForSaving(_ recording: Recording) async throws -> SaveFile {
        guard recording.usesStudioAudio, let studioURL = recording.studioAudioURL else {
            return SaveFile(url: recording.fileURL, isTemporary: false)
        }
        let url = try await StudioSoundAudio.exportWithStudioAudio(
            videoURL: recording.fileURL, studioAudioURL: studioURL
        )
        return SaveFile(url: url, isTemporary: true)
    }

    // MARK: - Progress

    /// A rough 0...1 for the progress ring and bar. The server reports no
    /// progress, so processing is estimated from the recording's length.
    func progress(for recording: Recording, now: Date = Date()) -> Double {
        switch recording.studioStatus {
        case .preparing: return 0.05
        case .uploading: return 0.12
        case .processing:
            let expected = 40 + recording.duration * 0.6
            let elapsed = now.timeIntervalSince(recording.studioStartedAt ?? now)
            return 0.15 + 0.75 * min(1, max(0, elapsed / expected))
        case .downloading: return 0.93
        case .ready: return 1
        case .failed, nil: return 0
        }
    }

    // MARK: - Pipeline

    private func run(_ id: UUID) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            await self?.drive(id)
            self?.tasks[id] = nil
        }
    }

    private func drive(_ id: UUID) async {
        while !Task.isCancelled,
              let recording = fetch(id),
              let status = recording.studioStatus,
              status.isInFlight {
            switch status {
            case .preparing, .uploading:
                await withBackgroundTime { await self.upload(recording) }
            case .processing:
                // Resumed by `resumeAll()` once the app is active again.
                guard UIApplication.shared.applicationState == .active else { return }
                await poll(recording)
            case .downloading:
                await withBackgroundTime { await self.download(recording) }
            case .ready, .failed:
                return
            }
        }
    }

    private func upload(_ recording: Recording) async {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-upload-\(recording.id.uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try await StudioSoundAudio.extractAudio(from: recording.fileURL, to: audioURL)
        } catch {
            fail(recording, code: "extract_failed")
            return
        }

        recording.studioStatus = .uploading
        save()
        let requestID = recording.studioRequestID ?? UUID().uuidString
        recording.studioRequestID = requestID

        let result = await withRetries {
            try await StudioSoundService.start(audioFileURL: audioURL, requestID: requestID)
        }
        guard isAlive(recording) else { return }
        switch result {
        case .success(let job):
            recording.studioJobID = job.id
            recording.studioStartedAt = Date()
            recording.studioStatus = .processing
            save()
        case .failure(let error):
            fail(recording, code: error.code)
        }
    }

    private func poll(_ recording: Recording) async {
        guard let jobID = recording.studioJobID else {
            // Lost the job somehow: start the upload over (same request id).
            recording.studioStatus = .uploading
            save()
            return
        }
        if let started = recording.studioStartedAt,
           Date().timeIntervalSince(started) > Self.processingTimeout {
            fail(recording, code: "timeout")
            return
        }
        do {
            let status = try await StudioSoundService.status(jobID: jobID)
            guard isAlive(recording) else { return }
            switch status {
            case .done:
                recording.studioStatus = .downloading
                save()
                return
            case .error:
                fail(recording, code: "processing_failed")
                return
            case .processing:
                break
            }
        } catch let error as StudioSoundService.ServiceError where !error.isTransient {
            fail(recording, code: error.code)
            return
        } catch {
            // Offline or a hiccup: the job is safe at the server, ask again.
        }
        try? await Task.sleep(for: Self.pollInterval)
    }

    private func download(_ recording: Recording) async {
        guard let jobID = recording.studioJobID else {
            fail(recording, code: "no_job")
            return
        }
        let result = await withRetries {
            try await StudioSoundService.downloadResult(jobID: jobID)
        }
        guard isAlive(recording) else {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard case .success(let downloadedURL) = result else {
            if case .failure(let error) = result { fail(recording, code: error.code) }
            return
        }
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let fileName = "\(recording.id.uuidString).studio.m4a"
        let outputURL = Recording.recordingsDirectory.appendingPathComponent(fileName)
        do {
            try await StudioSoundAudio.finishProcessedAudio(
                downloadedURL: downloadedURL, videoURL: recording.fileURL, to: outputURL
            )
        } catch StudioSoundAudio.AudioError.lengthMismatch(let original, let processed) {
            AppAnalytics.log("studio_sound_length_mismatch", params: [
                "original_ms": Int(original * 1000),
                "processed_ms": Int(processed * 1000)
            ])
            fail(recording, code: "length_mismatch")
            return
        } catch {
            fail(recording, code: "finish_failed")
            return
        }
        guard isAlive(recording) else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }

        recording.studioAudioFileName = fileName
        recording.studioEnabled = true
        recording.studioErrorCode = nil
        recording.studioStatus = .ready
        let elapsed = recording.studioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recording.studioStartedAt = nil
        save()
        AppAnalytics.log("studio_sound_ready", params: [
            "duration_sec": Int(recording.duration.rounded()),
            "processing_sec": Int(elapsed.rounded())
        ])
        Task { await StudioSoundService.delete(jobID: jobID) }

        var savedToPhotos = false
        if recording.studioSaveWhenReady {
            recording.studioSaveWhenReady = false
            save()
            savedToPhotos = await saveToPhotos(recording)
        }
        announce(Finished(
            recordingID: recording.id, title: recording.scriptTitle, savedToPhotos: savedToPhotos
        ))
    }

    /// The "save when ready" path. Photos access was checked when the user
    /// asked for it.
    private func saveToPhotos(_ recording: Recording) async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited,
              let file = try? await fileForSaving(recording) else { return false }
        defer {
            if file.isTemporary { try? FileManager.default.removeItem(at: file.url) }
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.url)
            }
            AppAnalytics.log("recording_exported_to_camera_roll", params: [
                "duration_sec": Int(recording.duration.rounded()),
                "had_watermark": recording.hasWatermark,
                "via": "studio_when_ready",
                "studio_sound": true
            ])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func fail(_ recording: Recording, code: String) {
        guard isAlive(recording) else { return }
        recording.studioStatus = .failed
        recording.studioErrorCode = code
        recording.studioSaveWhenReady = false
        save()
        AppAnalytics.log("studio_sound_failed", params: ["reason": code])
        if let jobID = recording.studioJobID {
            Task { await StudioSoundService.delete(jobID: jobID) }
        }
    }

    private func announce(_ finished: Finished) {
        lastFinished = finished
        Task {
            try? await Task.sleep(for: .seconds(5))
            if lastFinished == finished { lastFinished = nil }
        }
    }

    /// Retries transient failures (offline, 5xx) with a growing pause.
    private func withRetries<T>(
        _ operation: () async throws -> T
    ) async -> Result<T, StudioSoundService.ServiceError> {
        var lastError = StudioSoundService.ServiceError.network
        for attempt in 0..<Self.maxAttempts where !Task.isCancelled {
            do {
                return .success(try await operation())
            } catch let error as StudioSoundService.ServiceError {
                lastError = error
                guard error.isTransient else { break }
            } catch {
                lastError = .network
            }
            if attempt < Self.maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(2 << attempt))
            }
        }
        return .failure(lastError)
    }

    /// Asks iOS for time to finish a step if the app goes to the background
    /// mid-way (an upload is a few seconds; this covers the user swiping
    /// home right after tapping).
    private func withBackgroundTime(_ work: () async -> Void) async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "StudioSound") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        await work()
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    /// False once the recording was deleted (`forget` cancels its task):
    /// a model that is gone must not be written to.
    private func isAlive(_ recording: Recording) -> Bool {
        !Task.isCancelled && !recording.isDeleted && recording.modelContext != nil
    }

    private func fetch(_ id: UUID) -> Recording? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        try? context?.save()
    }

    // MARK: - Copy

    /// What to tell the user about a failure, by `studioErrorCode`.
    static func failureMessage(for code: String?) -> String {
        switch code {
        case "monthly_limit":
            return String(
                localized: "studio.error.monthlyLimit",
                defaultValue: "This month's enhancements are used up. New ones arrive on the 1st.",
                comment: "Studio Sound failed because the subscriber's monthly allowance is used up; it renews on the 1st of the month."
            )
        case "trial_limit":
            return String(
                localized: "studio.error.trialLimit",
                defaultValue: "You've used the enhancements included in the trial.",
                comment: "Studio Sound failed because the free trial's small allowance is used up."
            )
        case "rate_limited":
            return String(
                localized: "studio.error.busy",
                defaultValue: "Studio Sound is busy right now. Try again later.",
                comment: "Studio Sound failed because of a server-wide limit; trying later works."
            )
        case "too_long":
            return String(
                localized: "studio.error.tooLong",
                defaultValue: "Videos up to 15 minutes can be enhanced.",
                comment: "Studio Sound failed because the recording is longer than the 15-minute cap."
            )
        case "subscription_required":
            return String(
                localized: "studio.error.subscription",
                defaultValue: "Studio Sound is part of the subscription.",
                comment: "Studio Sound failed because the user has no active subscription."
            )
        case "network", "timeout":
            return String(
                localized: "studio.error.network",
                defaultValue: "Check your connection and tap the button again.",
                comment: "Studio Sound failed for a network reason; tapping the sparkles button retries."
            )
        default:
            return String(
                localized: "studio.error.generic",
                defaultValue: "Something went wrong. Tap the button to try again.",
                comment: "Studio Sound failed for an unspecified reason; tapping the sparkles button retries."
            )
        }
    }
}
