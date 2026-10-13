import AVFoundation
import CoreImage
import Metal
import UIKit
import SwiftUI
import Combine
import FirebaseCrashlytics
import os

final class CameraManager: NSObject, ObservableObject {
    static let shared = CameraManager()

    // MARK: - Public state
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var cameraPosition: AVCaptureDevice.Position = .front
    @Published var lastRecordedURL: URL?
    @Published var saveDirectlyOnStop = false
    @Published var isSessionReady = false
    @Published var isAudioReady = false
    /// Whether the camera preview should be visible.
    ///
    /// PRESENTATION ONLY — nothing in the capture path consults this. Portrait
    /// sets it the moment the session starts, exactly as before. Landscape holds
    /// it until the landscape angle is pinned, because the session necessarily
    /// runs briefly on the provisional angle first (the residue is not knowable
    /// until a buffer arrives) and the user would otherwise see a portrait frame
    /// flip to landscape.
    @Published var isPreviewRevealed = false
    @Published var audioSourceName: String = String(
        localized: "camera.audio.iPhoneMic",
        defaultValue: "iPhone Microphone",
        comment: "Default audio source name in the recording HUD."
    )
    @Published var audioRouteToast: String?
    /// The video device of the current session configuration, published on
    /// main once the session is configured. The preview uses it to follow the
    /// interface's rotation on iPhone Duo.
    @Published private(set) var activeVideoDevice: AVCaptureDevice?

    // MARK: - Private
    private static let cameraQueue = DispatchQueue(label: "com.steadyeye.camera", qos: .userInitiated)
    /// Single serial queue for both video and audio data outputs. Apple
    /// requires AVAssetWriter appends to be serialized; sharing the queue
    /// across both outputs guarantees that without explicit locking.
    private static let sampleBufferQueue = DispatchQueue(label: "com.steadyeye.samplebuffers", qos: .userInitiated)
    let session = AVCaptureSession()
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    /// Optional fan-out for audio sample buffers on `sampleBufferQueue`.
    /// Set by `RecordingView` when Follow-My-Voice is active so the FMV
    /// service can compute RMS + feed SFSpeechRecognizer without spinning
    /// up a separate AVAudioEngine. Called AFTER the asset writer has
    /// consumed the buffer so the file's audio track is unaffected.
    /// Read concurrently across `sampleBufferQueue` and the main thread
    /// (when set/cleared) — the `ifNotNil` check tolerates the race.
    var audioBufferBroadcast: ((CMSampleBuffer) -> Void)?
    /// DEV gaze prototype. Fed every video frame; idle (one lock check per
    /// frame) unless a `GazeProbeOverlay` has started it.
    nonisolated let gazeProbe = GazeProbe()
    /// iPhone Duo diagnostics: which way is up in the delivered buffers.
    /// Armed for a few frames per session configuration, buffer shape change,
    /// posture change and take; idle otherwise.
    nonisolated let faceProbe = FaceOrientationProbe()
    private var assetWriterRecorder: AssetWriterRecorder?
    private var watermarkComposer: RealtimeWatermarkComposer?
    /// Writer geometry frozen at record start by `startWriterPipeline`. Read on
    /// `sampleBufferQueue` by the orientation correction in `captureOutput`.
    private var recordingWriterAngle: CGFloat = 90
    private var recordingWriterSize: CGSize = .zero
    /// What the video connection actually held at record start, frozen for the
    /// take. The correction rotates by the difference against
    /// `recordingHorizonAngle`, never by the desired angle alone.
    private var recordingConnectionAngle: CGFloat = 90
    /// RotationCoordinator's horizon-level angle at record start, frozen for
    /// the take. The backstop's target: Apple's correction is this minus the
    /// connection angle (Developer Forums thread 813548).
    private var recordingHorizonAngle: CGFloat = 90
    /// Whether the video connection mirrored its buffers at record start. A
    /// mirrored buffer has no reliable rotation correction (see
    /// `CaptureRotationGeometry.correctionDegrees`).
    private var recordingConnectionMirrored = false
    /// Orientation mode frozen at record start. The canvas is fixed then, so a
    /// mid-take change must not reach the pipeline.
    private var recordingOrientationMode: RecordingOrientation = .portrait

    /// Orientation mode this session was CONFIGURED with. Read once in
    /// `setupSession` so a change made while the recording screen is open does
    /// not alter a running session — it takes effect the next time the session
    /// is configured.
    private var sessionOrientationMode: RecordingOrientation = .portrait
    /// Whether this session configuration crops sideways portrait takes (see
    /// `cropsSidewaysToPortrait`). Read in `setupSession` alongside
    /// `sessionOrientationMode`, and like it, fixed for the configuration.
    private var sessionCropsSideways = false

    /// Portrait takes with the device on its side: accept the RotationCoordinator's
    /// level-horizon angle, which then delivers a LANDSCAPE buffer, and record
    /// its vertical middle 9:16 at full height — instead of keeping a portrait
    /// angle, which records the scene tipped over by a quarter turn.
    ///
    /// Product default is off on every iPhone, iPhone Duo included: a phone
    /// held sideways records a portrait frame with the scene turned, never a
    /// crop. Kept behind the DEV switch only.
    private static var cropsSidewaysToPortrait: Bool {
        #if DEV
        return UserDefaults.standard.bool(forKey: "dev_crop_sideways_to_portrait")
        #else
        return false
        #endif
    }
    /// Landscape candidates and the chosen angle from the most recent selection,
    /// carried into `rotation_selected` / `recording_start` so one device run
    /// shows which of the two was picked and what the alternative was.
    private var lastLandscapeCandidates: [Int] = []
    /// When the landscape preview warmup began, for `landscape_warmup`'s
    /// `elapsed_ms`, and the token identifying which warmup a scheduled timeout
    /// belongs to. Dated just before `startRunning()`, so it measures the whole
    /// wait the user sees. Nil outside a warmup — which is what makes a timeout
    /// still in flight inert once the warmup resolved or the session stopped.
    private var landscapeWarmupStartedAt: Date?
    /// One-shot guard so the warmup resolves exactly once per session
    /// configuration — whichever of the pin or the timeout gets there first.
    /// Cleared in `resetLandscapeWarmup()` and nowhere else: clearing it at the
    /// arm instead would re-arm a warmup the pin had already resolved.
    private var landscapeWarmupResolved = false
    /// Ceiling on how long the preview stays hidden waiting for the pin.
    ///
    /// 1.2s: this screen already assumes the camera is up well inside a second
    /// (`RecordingView` stages its own UI at 0.5s, `ContentView` waits 0.5s for
    /// the session to settle), so this is roughly double that headroom for a
    /// cold session on an older device — while short enough that a camera that
    /// never delivers a buffer does not strand the user on a dark screen.
    /// `elapsed_ms` in the log is what should replace this estimate with a
    /// measured value.
    private static let landscapeWarmupTimeout: TimeInterval = 1.2

    /// The landscape angle pinned for the life of this session configuration.
    ///
    /// Landscape is a FIXED orientation, not a gravity-following one: the angle
    /// is derived once — from this device's own basis, which differs between
    /// generations and so cannot be hardcoded — and then held. Without the pin,
    /// rotating the device changed the output orientation even though the
    /// setting had not. Cleared in `setupSession`; never consulted in portrait.
    private var pinnedLandscapeAngle: CGFloat?

    /// A buffer the video connection actually delivered, with the connection
    /// state it was delivered under. The single source of truth for which
    /// connection angles yield a portrait buffer on this device and for the
    /// writer canvas size — the active format's dimensions cannot answer either
    /// (on iPhone 17 front cameras the format reads 1920x1080 while a connection
    /// at 90 delivers 1920x1080 and portrait is 0).
    private struct ObservedBuffer {
        let width: Int
        let height: Int
        let connectionAngle: CGFloat
        let mirrored: Bool
        let connection: ObjectIdentifier
    }
    /// Latest `ObservedBuffer`. Written on `sampleBufferQueue` only when the
    /// dimensions or the connection change (a half-turn keeps dimensions, and
    /// every derivation from it is taken mod 180, so a stale half-turn in the
    /// stored angle is harmless). Read on the camera queue and main. `nil` until
    /// the first buffer of a session configuration arrives.
    private let observedBuffer = OSAllocatedUnfairLock<ObservedBuffer?>(initialState: nil)
    /// Last horizon-level angle the RotationCoordinator reported. Main queue
    /// and camera queue (configuration), matching `appliedRotationAngle`.
    private var lastReportedHorizonAngle: CGFloat?
    /// Created on the first mis-oriented buffer only — never allocated on the
    /// normal path. Touched only on `sampleBufferQueue`.
    private var orientationCIContext: CIContext?
    /// `orientation_corrected` fires once per recording; reset at record start.
    private var orientationCorrectionLogged = false
    /// `sideways_cropped` fires once per recording; reset at record start.
    /// Touched only on `sampleBufferQueue` and at record start, like the flag above.
    private var sidewaysCropLogged = false
    /// Whether this take has handed at least one canvas-shaped frame to the
    /// writer. Only frames BEFORE that can be leftovers from the previous
    /// configuration, so the leading-frame drop is confined to them. Touched
    /// only on `sampleBufferQueue`; reset when a new recorder is first seen.
    private var recordingHasAppendedVideo = false
    /// Leading mis-shaped frames dropped in this take. Touched only on
    /// `sampleBufferQueue`; reset when a new recorder is first seen.
    private var droppedLeadingMismatchCount = 0
    /// The recorder the two counters above belong to. They reset when a
    /// different recorder is first seen on `sampleBufferQueue`, so a take's
    /// state is keyed to its own recorder object rather than published as
    /// separate stores from the camera queue — which is what let the previous
    /// take's values describe this one.
    private var currentTakeRecorder: ObjectIdentifier?
    /// Ceiling on leading frames dropped for shape. The stale window is the
    /// buffers already in flight when the take began — one or two, with
    /// `alwaysDiscardsLateVideoFrames` keeping the queue shallow. Past this
    /// ceiling a shape disagreement is no longer a stale leftover but a canvas
    /// that is wrong for the whole take, and dropping every frame would leave an
    /// empty file; those fall through to the backstop and are reported exactly
    /// as before.
    private static let maxLeadingMismatchDrops = 3
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private(set) var lastRecordingDuration: TimeInterval = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var routeChangeObserver: NSObjectProtocol?
    /// Session and device notifications mirrored into the camera diagnostics,
    /// installed once per process (see `observeSessionEventsOnce`).
    private var sessionEventObservers: [NSObjectProtocol] = []

    // MARK: iPhone Duo camera state

    /// Posture the recording screen last reported. Main. Nil until known, and
    /// always nil on other iPhones.
    private var duoPosture: DuoDisplayState.Posture?
    /// Posture the current session configuration was built for. Camera queue.
    private var sessionDuoPosture: DuoDisplayState.Posture?
    /// The iPhone Duo camera the current configuration runs on; nil on the
    /// standard path. Written in `setupSession` on the camera queue, read on
    /// main by the rotation handler — the same discipline as the other
    /// rotation state.
    private var sessionDuoCamera: DuoCameraChoice?
    /// The dynamic aspect ratio the Duo camera outputs now; changes on a turn
    /// (`switchDuoAspect`). Nil on a fixed format and on the standard path.
    private var sessionDuoAspect: String?
    /// Bumped per session configuration, so a delayed check knows whether the
    /// configuration it was scheduled for is still the current one.
    private var configurationGeneration = 0
    /// Face readings in a row asking for the same correction. Main.
    private var duoCalibrationStreak: (rotation: Int, count: Int)?
    /// Readings in a row needed before a Duo camera's angle is corrected.
    private static let duoCalibrationReadings = 3
    /// Duo cameras whose format axes were already flipped in this process —
    /// one try each, so a camera that never delivers portrait cannot loop.
    private var duoAxesFlippedThisProcess: Set<String> = []
    /// Angle corrections learned per Duo camera in this process. Capped, so
    /// readings that keep disagreeing cannot rebuild the session forever.
    private var duoCorrectionsThisProcess: [String: Int] = [:]
    private static let maxDuoCorrectionsPerProcess = 2
    /// Pending rebuild after the device turned (`rebuildDuoIfTurned`), so a
    /// turn in progress rebuilds once, after it settles.
    private var duoTurnRebuild: DispatchWorkItem?
    /// Duo cameras that fell back to a forced portrait angle in this process:
    /// their formats do not follow the angle, so turning rebuilds nothing.
    private var duoTurnRebuildDisabled: Set<String> = []
    /// Added to the preview's level angle on a Duo camera: the same learned
    /// correction the capture connection gets.
    @Published private(set) var previewAngleCorrection: CGFloat = 0

    // MARK: - Rotation (RotationCoordinator-driven)
    /// Retained for the lifetime of the session so its KVO keeps firing.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Rotation angle the video connection actually holds (read back after
    /// every assignment). Portrait-producing once a buffer has been observed —
    /// 90/270 on most devices, 0/180 on iPhone 17 front cameras. Frozen while
    /// recording is active.
    private var appliedRotationAngle: CGFloat = 90
    /// True between record start and stop. While true the RotationCoordinator
    /// KVO handler logs but does NOT apply angle changes — the writer's
    /// videoSize is fixed at record start and buffer dimensions must not change.
    private var isRecordingActive = false
    /// A portrait angle reported while recording was active (therefore
    /// suppressed); applied after recording stops.
    private var pendingRotationAngle: CGFloat?
    private let camLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "CameraDiagnostic"
    )

    #if DEV
    /// DEV-ONLY hook (does not exist in release builds). When non-nil, the
    /// video connection's rotation angle is forced to this raw value, bypassing
    /// the RotationCoordinator result and the portrait clamp, while
    /// `appliedRotationAngle` is left untouched. The writer canvas is sized from
    /// delivered buffers, so forcing a landscape-producing angle now records a
    /// landscape canvas; it no longer reproduces the old portrait-canvas /
    /// landscape-buffer mismatch. Useful for checking what the connection
    /// delivers at a given angle (`first_buffer`). Default nil (off). Flip in
    /// code only: no UI, no settings, no remote config.
    static var debugForcedRotationAngle: CGFloat?

    /// DIAGNOSTIC BUILD ONLY — the product default is `false`. When true,
    /// `captureOutput` skips the orientation backstop entirely: a mis-oriented
    /// buffer goes to the composer as delivered, so a failure of the PRIMARY
    /// rotation path is visible in the recorded video instead of being silently
    /// rescued. `orientation_backstop_skipped` is still logged with the fields
    /// the correction would have produced.
    ///
    /// Flip to `true` only for a build whose purpose is to expose a
    /// primary-path failure, and set it back afterwards. Never ship it enabled
    /// on the release branch.
    static var disableOrientationBackstopForDiagnostics = false
    #endif

    /// Hardware model identifier (e.g. "iPhone16,1") for diagnostics.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// Residue (0 or 90) shared by the connection angles that yield a portrait
    /// buffer on this device, learned from a delivered buffer. `nil` until the
    /// first buffer of the current session configuration has arrived.
    private var observedPortraitResidue: Int? {
        observedBuffer.withLock { $0 }.map {
            CaptureRotationGeometry.portraitResidue(
                bufferWidth: $0.width,
                bufferHeight: $0.height,
                connectionAngle: $0.connectionAngle
            )
        }
    }

    /// Applies the RotationCoordinator's `reported` horizon-level angle to
    /// `connection`, updating `appliedRotationAngle`. The coordinator's angle is
    /// already in the connection's basis — including the rotated sensor on
    /// iPhone 17 front cameras, where portrait is 0 — so it is applied as-is.
    ///
    /// Portrait-locked product: once a buffer has been observed, an angle that
    /// would deliver a landscape buffer is not applied (the angle already in use
    /// is kept). Before any buffer exists nothing is known about this sensor, so
    /// the coordinator's angle is trusted. If an angle isn't supported, the
    /// connection keeps its current angle. Returns the angle the connection
    /// actually holds afterwards.
    @discardableResult
    private func applyClampedRotation(reported: CGFloat, to connection: AVCaptureConnection) -> CGFloat {
        lastReportedHorizonAngle = reported
        #if DEV
        // DEV-only override: force the connection to a raw angle and leave
        // `appliedRotationAngle` (hence the writer's videoSize) unchanged, so a
        // forced value of 0 delivers landscape buffers into a portrait writer.
        // The mismatch guard downstream still fires — this only changes what is
        // applied to the connection, not the diagnostics.
        if let forced = Self.debugForcedRotationAngle {
            let unchanged = Int(appliedRotationAngle)
            let supported = connection.isVideoRotationAngleSupported(forced)
            if supported {
                connection.videoRotationAngle = forced
            }
            camLog.notice("event=rotation_debug_override forced=\(Int(forced)) applied_unchanged=\(unchanged) supported=\(supported)")
            return appliedRotationAngle
        }
        #endif
        // Whether `reported` yields a portrait buffer is decided by a buffer
        // this connection actually delivered — never by the active format,
        // whose dimensions are landscape on iPhone 17 front cameras even though
        // portrait is 0 there.
        let residue = observedPortraitResidue
        let wantsLandscape = sessionOrientationMode.wantsLandscapeBuffer
        var candidates: [Int] = []
        let accepted: Bool
        let target: CGFloat
        // Whether this evaluation set the pin, held one set earlier, or ran
        // before any buffer made the residue knowable. Portrait leaves it "none".
        var pinState = "none"
        if wantsLandscape {
            // Landscape is a fixed orientation. The angle is derived ONCE and
            // then held for the life of this session configuration: gravity must
            // not move it, or rotating the device would change the output
            // orientation while the setting stayed the same.
            if let pinned = pinnedLandscapeAngle {
                target = pinned
                accepted = true
                pinState = "held"
                if let residue {
                    candidates = CaptureRotationGeometry.landscapeCandidates(portraitResidue: residue)
                }
            } else if let residue {
                // First evaluation with a delivered buffer in hand: the residue
                // makes landscape-left derivable on this device's own basis.
                candidates = CaptureRotationGeometry.landscapeCandidates(portraitResidue: residue)
                let derived = CGFloat(CaptureRotationGeometry.landscapeLeftAngle(
                    horizonAngle: reported, portraitResidue: residue
                ))
                pinnedLandscapeAngle = derived
                target = derived
                accepted = true
                pinState = "set"
            } else {
                // No buffer yet, so the residue — and with it which angle is
                // landscape-left — is unknowable. Apply the coordinator's angle
                // provisionally WITHOUT pinning; the first delivered buffer
                // re-evaluates and pins, rather than guessing here.
                target = reported
                accepted = true
                pinState = "provisional"
            }
        } else {
            let producesPortrait = residue.map {
                CaptureRotationGeometry.producesPortrait(angle: reported, portraitResidue: $0)
            } ?? true
            // Cropping sideways takes: a landscape-producing level angle is
            // wanted too — the take records its vertical middle.
            accepted = producesPortrait || sessionCropsSideways
            target = accepted ? reported : connection.videoRotationAngle
        }
        lastLandscapeCandidates = candidates
        let supported = connection.isVideoRotationAngleSupported(target)
        if supported {
            connection.videoRotationAngle = target
        } else {
            camLog.error("event=rotation_unsupported requested=\(Int(target)) kept=\(Int(connection.videoRotationAngle))")
        }
        // Cache what the connection ACTUALLY holds, not what was intended: a
        // skipped assignment must not leave the cache lying about the buffers
        // the writer is going to receive.
        appliedRotationAngle = connection.videoRotationAngle
        let dims = currentCamera.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let observed = observedBuffer.withLock { $0 }
        let observedField = observed.map { "\($0.width)x\($0.height)@\(Int($0.connectionAngle))" } ?? "none"
        let residueField = residue.map(String.init) ?? "unknown"
        // Both landscape candidates and the pick, so a single device run shows
        // which was chosen and what the alternative was if the video comes out
        // rotated the wrong way. Empty in portrait.
        let candidatesField = candidates.isEmpty ? "none" : candidates.map(String.init).joined(separator: "/")
        // `pin=held` is the proof the angle did not follow the device: a
        // rotation report arrived and changed nothing.
        let pinnedField = pinnedLandscapeAngle.map { String(Int($0)) } ?? "none"
        camLog.notice(
            "event=rotation_selected mode=\(self.sessionOrientationMode.rawValue, privacy: .public) reported=\(Int(reported)) selected=\(Int(target)) accepted=\(accepted) pin=\(pinState, privacy: .public) pinned_angle=\(pinnedField, privacy: .public) landscape_candidates=\(candidatesField, privacy: .public) connection_angle_after=\(Int(connection.videoRotationAngle)) portrait_residue=\(residueField, privacy: .public) observed_buffer=\(observedField, privacy: .public) mirrored=\(connection.isVideoMirrored) active_format=\(dims?.width ?? -1)x\(dims?.height ?? -1) supported=\(supported)"
        )
        CameraDiagnosticsLog.record("event=rotation_selected mode=\(self.sessionOrientationMode.rawValue) reported=\(Int(reported)) selected=\(Int(target)) accepted=\(accepted) pin=\(pinState) pinned_angle=\(pinnedField) landscape_candidates=\(candidatesField) connection_angle_after=\(Int(connection.videoRotationAngle)) portrait_residue=\(residueField) observed_buffer=\(observedField) mirrored=\(connection.isVideoMirrored) active_format=\(dims?.width ?? -1)x\(dims?.height ?? -1) supported=\(supported)")
        return appliedRotationAngle
    }

    /// Landscape only. The first delivered buffer is what establishes
    /// `portraitResidue`, and with it which angle is landscape-left on this
    /// device. Session configuration runs before any buffer exists, so it
    /// applied the coordinator's angle provisionally without pinning; this
    /// re-evaluates once and pins.
    ///
    /// Guarded against running mid-take: the writer canvas is fixed at record
    /// start, so a connection angle that changed under it would contradict the
    /// canvas. In practice buffers flow from session start and a take needs a
    /// deliberate tap, so the pin is long since set by then.
    private func pinLandscapeAngleAfterFirstBuffer() {
        guard sessionOrientationMode.wantsLandscapeBuffer,
              pinnedLandscapeAngle == nil,
              !isRecordingActive,
              let connection = videoDataOutput?.connection(with: .video),
              let reported = lastReportedHorizonAngle else { return }
        applyClampedRotation(reported: reported, to: connection)
        // The connection now holds the landscape angle, so what the preview
        // shows from here on is the orientation the file will have.
        resolveLandscapeWarmup(outcome: "pinned")
    }

    // MARK: - Landscape preview warmup (presentation only)

    /// Clears the warmup state for a session configuration that is about to be
    /// built. Called on main from `start` / `switchCamera`, before any camera
    /// work is dispatched, so it can never race the pin of the configuration it
    /// is resetting.
    private func resetLandscapeWarmup() {
        landscapeWarmupResolved = false
        landscapeWarmupStartedAt = nil
    }

    /// Starts the window during which the landscape preview stays hidden. Does
    /// not delay `startRunning`, the pin, or anything in the capture path — the
    /// preview layer stays mounted and fed throughout, only invisible.
    ///
    /// `startedAt` is dated on the camera queue just before `startRunning()`, so
    /// the window covers the whole wait rather than only the part after the
    /// session came up.
    private func beginLandscapePreviewWarmup(startedAt: Date) {
        // Already resolved means this configuration's pin got here first, which
        // the arm-before-`startRunning` ordering rules out. Arming anyway would
        // hide a preview that is already showing the pinned orientation and
        // leave a second timeout live to fire against it — exactly the double
        // `landscape_warmup` this guard exists to prevent.
        guard !landscapeWarmupResolved else { return }
        landscapeWarmupStartedAt = startedAt
        isPreviewRevealed = false
        // Deadline measured from `startedAt`, so the preview is never hidden for
        // longer than the constant however long the session took to come up, and
        // a timeout's `elapsed_ms` reads at the constant rather than past it.
        let remaining = max(0, Self.landscapeWarmupTimeout - Date().timeIntervalSince(startedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            // A timeout resolves only the warmup that armed it. `resolve` and
            // `stop` clear the token and a later configuration mints a new one,
            // so a stale timeout finds no match and does nothing.
            guard let self, self.landscapeWarmupStartedAt == startedAt else { return }
            self.resolveLandscapeWarmup(outcome: "timeout")
        }
    }

    /// Reveals the preview and logs the outcome, exactly once per session
    /// configuration — whichever of the pin or the timeout arrives first.
    private func resolveLandscapeWarmup(outcome: String) {
        guard !landscapeWarmupResolved else { return }
        landscapeWarmupResolved = true
        // The token is minted before the session runs, so it is always present
        // for a landscape configuration. -1 would mean a warmup resolved without
        // ever having been armed, which the ordering in `setupSession` rules out.
        let elapsedMs = landscapeWarmupStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        landscapeWarmupStartedAt = nil
        isPreviewRevealed = true
        camLog.notice(
            "event=landscape_warmup outcome=\(outcome, privacy: .public) elapsed_ms=\(elapsedMs)"
        )
        CameraDiagnosticsLog.record("event=landscape_warmup outcome=\(outcome) elapsed_ms=\(elapsedMs)")
    }

    /// RotationCoordinator KVO handler. Freezes the applied angle while a
    /// recording is active (logs suppressed=true, stashes a pending portrait
    /// angle); otherwise applies the clamped angle immediately.
    private func handleRotationChange(_ coordinator: AVCaptureDevice.RotationCoordinator) {
        let reported = duoCorrected(coordinator.videoRotationAngleForHorizonLevelCapture)
        guard let connection = videoDataOutput?.connection(with: .video) else { return }
        let old = appliedRotationAngle
        if isRecordingActive {
            // Same portrait test as `applyClampedRotation` — a legitimate
            // mid-take value is stashed, not discarded; only the APPLICATION
            // stays frozen until the take ends. A buffer has always been
            // observed by the time a take is running.
            // Same shape test as `applyClampedRotation`, in whichever mode this
            // session was configured for — a legitimate mid-take value is
            // stashed, not discarded; only the APPLICATION stays frozen until
            // the take ends.
            let wantsLandscape = sessionOrientationMode.wantsLandscapeBuffer
            let shapeMatches = observedPortraitResidue.map { residue in
                wantsLandscape
                    ? CaptureRotationGeometry.producesLandscape(angle: reported, portraitResidue: residue)
                    : CaptureRotationGeometry.producesPortrait(angle: reported, portraitResidue: residue)
                        || sessionCropsSideways
            } ?? false
            pendingRotationAngle = shapeMatches ? reported : old
            camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=true")
            CameraDiagnosticsLog.record("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=true device_orientation=\(UIDevice.current.orientation.rawValue)")
            return
        }
        if sessionDuoCamera != nil {
            rebuildDuoIfTurned()
        }
        applyClampedRotation(reported: reported, to: connection)
        camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=false")
        CameraDiagnosticsLog.record("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=false device_orientation=\(UIDevice.current.orientation.rawValue)")
    }

    private override init() {
        super.init()
        faceProbe.setResultHandler { [weak self] reading in
            Task { @MainActor [weak self] in self?.handleFaceReading(reading) }
        }
    }

    // MARK: - Chromakey background mode (DEV)

    /// Single source of truth for chromakey mockup mode. When true, the
    /// camera preview renders a solid #00B140 fill and the capture session
    /// is not started — used for recording UI mockup videos where real
    /// footage is composited behind the SteadyEye interface in post.
    /// Read once per view lifecycle; toggle changes require re-entering RecordingView.
    static var isChromakeyActive: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        #if DEV
        return UserDefaults.standard.bool(forKey: "dev_chromakey_enabled")
        #else
        return false
        #endif
        #endif
    }

    // MARK: - Start / Stop

    func start(position: AVCaptureDevice.Position = .front) {
        cameraPosition = position
        observeSessionEventsOnce()
        // On main, before any camera work is dispatched — and so before any
        // buffer, and any pin, can exist for the configuration about to be
        // built. That ordering is what lets the arm treat an already-resolved
        // warmup as this configuration's own and leave it alone.
        resetLandscapeWarmup()
        if Self.isChromakeyActive {
            // No real camera (Simulator) or chromakey mockup mode — mark
            // session ready immediately so UI is fully interactive. No buffers
            // will ever arrive, so the preview is revealed outright.
            isSessionReady = true
            isAudioReady = true
            isPreviewRevealed = true
            return
        }
        #if !targetEnvironment(simulator)
        let duoPosture = self.duoPosture
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            // A running session built for another Duo posture (or before the
            // posture was known, e.g. pre-warmed by onboarding) is rebuilt;
            // everywhere else both are nil and this is the early return as before.
            if self.session.isRunning, self.sessionDuoPosture == duoPosture {
                DispatchQueue.main.async { self.isSessionReady = true }
                return
            }
            self.setupSession(position: position, duoPosture: duoPosture)
        }
        #endif
    }

    func stop() {
        if Self.isChromakeyActive {
            isSessionReady = false
            isAudioReady = false
            return
        }
        #if !targetEnvironment(simulator)
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        // Tear down the RotationCoordinator KVO so no observation survives a
        // session stop (there is no deinit).
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                self.isSessionReady = false
                self.isAudioReady = false
                // The next session configuration decides afresh whether to gate;
                // a pending warmup must not reveal against a torn-down session.
                // Clearing the token is what neutralises a timeout still in
                // flight. `landscapeWarmupResolved` is deliberately NOT set here:
                // this block can land after a rapid re-entry has already called
                // `start`, and setting it would suppress the new gate.
                self.isPreviewRevealed = false
                self.landscapeWarmupStartedAt = nil
            }
        }
        #endif
    }

    // MARK: - iPhone Duo camera

    /// The camera an iPhone Duo session runs on, chosen by posture.
    private struct DuoCameraChoice {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        /// The RotationCoordinator's level angle when chosen, before correction.
        let horizonAngle: Int
        /// Degrees added to every RotationCoordinator angle for this camera:
        /// 0 unless a face showed the coordinator wrong (`handleFaceReading`).
        let correction: Int
        /// Whether the format's axes are the opposite of what the angle
        /// suggests, learned from a delivered buffer (`validateDuoBufferShape`).
        let axesSwapped: Bool
        /// On a square format: the dynamic aspect ratio (9:16 or 16:9, raw
        /// value) set at configuration. A quarter turn then switches it live
        /// instead of rebuilding the session. Nil on a fixed format.
        let aspectRatio: String?
    }

    /// The recording screen reports the posture; a change rebuilds the session
    /// on the other display's camera while no take is running (a fold during a
    /// take has already stopped it, and the rebuild queues behind the writer).
    func setDuoPosture(_ posture: DuoDisplayState.Posture?) {
        guard let posture, posture != duoPosture else { return }
        duoPosture = posture
        reconfigureDuoCamera(reason: "posture_\(posture.rawValue)", force: false)
    }

    /// Rebuilds a running session for the current posture. `force` rebuilds
    /// even when the posture is unchanged, after learning a correction.
    private func reconfigureDuoCamera(reason: String, force: Bool) {
        #if !targetEnvironment(simulator)
        guard !Self.isChromakeyActive, !isRecording, !isRecordingActive, cameraPosition == .front else { return }
        let posture = duoPosture
        resetLandscapeWarmup()
        Self.cameraQueue.async { [weak self] in
            guard let self, self.session.isRunning,
                  force || self.sessionDuoPosture != posture else { return }
            CameraDiagnosticsLog.record("event=duo_reconfigure reason=\(reason)")
            self.setupSession(position: .front, duoPosture: posture)
        }
        #endif
    }

    /// The RotationCoordinator's angle with this Duo camera's learned
    /// correction. Unchanged on the standard path.
    private func duoCorrected(_ angle: CGFloat) -> CGFloat {
        guard let correction = sessionDuoCamera?.correction, correction != 0 else { return angle }
        return CGFloat((Int(angle.rounded()) + correction) % 360)
    }

    /// Outer ultra wide when folded, inner when unfolded, with an 8-bit 4:2:0
    /// format whose delivered buffer will be portrait at full resolution —
    /// no crop. Nil when there is no posture, no such camera or no such format:
    /// the standard front camera then runs exactly as before.
    nonisolated private static func duoCamera(
        for posture: DuoDisplayState.Posture?,
        want4K: Bool,
        targetFPS: Int
    ) -> DuoCameraChoice? {
        var device: AVCaptureDevice?
        if let posture, #available(iOS 27.1, *) {
            let type: AVCaptureDevice.DeviceType = posture == .folded
                ? .builtInOuterUltraWideCamera
                : .builtInInnerUltraWideCamera
            device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [type], mediaType: .video, position: .unspecified
            ).devices.first
        }
        #if DEV
        // Calibration test on any iPhone: the standard front camera through
        // this path, starting from the deliberately wrong correction the
        // Settings switch stored.
        if device == nil, posture == nil, UserDefaults.standard.bool(forKey: "dev_duo_calibration_test") {
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        #endif
        guard let device else { return nil }
        let typeKey = device.deviceType.rawValue
        let correction = UserDefaults.standard.integer(forKey: correctionKey(typeKey))
        let axesSwapped = UserDefaults.standard.bool(forKey: axesKey(typeKey))
        let horizon = Int(AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            .videoRotationAngleForHorizonLevelCapture.rounded())
        // A quarter turn swaps the axes, so at 0/180 the format itself must be
        // portrait and at 90/270 landscape — as standard front cameras record
        // portrait from landscape formats at 90. Some sensors do not follow
        // their format's axes (iPhone 17 front cameras), hence `axesSwapped`.
        let quarterTurn = ((horizon + correction) % 180) != 0
        let portraitFormat = quarterTurn == axesSwapped
        func format(long: Int32, short: Int32, subtype: OSType) -> AVCaptureDevice.Format? {
            device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let sizeMatches = portraitFormat
                    ? dims.width == short && dims.height == long
                    : dims.width == long && dims.height == short
                return sizeMatches
                    && CMFormatDescriptionGetMediaSubType(format.formatDescription) == subtype
                    && format.videoSupportedFrameRateRanges.contains { Int($0.maxFrameRate) >= targetFPS }
            }
        }
        func format(long: Int32, short: Int32) -> AVCaptureDevice.Format? {
            format(long: long, short: short, subtype: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ?? format(long: long, short: short, subtype: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
        // Preferred: a square format with live 9:16 / 16:9, so a quarter turn
        // switches the aspect ratio without rebuilding the session (Duo's front
        // sensors are square; these formats are 30 fps only).
        if #available(iOS 26.0, *), let square = (want4K ? squareFormat(of: device, side: 3840, targetFPS: targetFPS) : nil)
            ?? squareFormat(of: device, side: 1920, targetFPS: targetFPS) {
            let ratio: AVCaptureDevice.AspectRatio = portraitFormat ? .ratio9x16 : .ratio16x9
            return DuoCameraChoice(
                device: device, format: square, horizonAngle: horizon,
                correction: correction, axesSwapped: axesSwapped, aspectRatio: ratio.rawValue
            )
        }
        guard let chosen = (want4K ? format(long: 3840, short: 2160) : nil) ?? format(long: 1920, short: 1080) else {
            return nil
        }
        return DuoCameraChoice(
            device: device, format: chosen, horizonAngle: horizon,
            correction: correction, axesSwapped: axesSwapped, aspectRatio: nil
        )
    }

    /// A side x side 8-bit 4:2:0 format offering both 9:16 and 16:9 as
    /// dynamic aspect ratios at `targetFPS`.
    @available(iOS 26.0, *)
    nonisolated private static func squareFormat(of device: AVCaptureDevice, side: Int32, targetFPS: Int) -> AVCaptureDevice.Format? {
        let subtypes = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        for subtype in subtypes {
            let match = device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let ratios = format.supportedDynamicAspectRatios
                return dims.width == side && dims.height == side
                    && CMFormatDescriptionGetMediaSubType(format.formatDescription) == subtype
                    && ratios.contains(.ratio9x16) && ratios.contains(.ratio16x9)
                    && format.videoSupportedFrameRateRanges.contains { Int($0.maxFrameRate) >= targetFPS }
            }
            if let match { return match }
        }
        return nil
    }

    nonisolated private static func correctionKey(_ type: String) -> String { "duo_angle_correction.\(type)" }
    nonisolated private static func axesKey(_ type: String) -> String { "duo_format_axes_swapped.\(type)" }

    /// Forgets every learned Duo camera correction.
    nonisolated static func resetDuoCalibration() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("duo_angle_correction.") || key.hasPrefix("duo_format_axes_swapped.") {
            defaults.removeObject(forKey: key)
        }
    }

    #if DEV
    /// Starts the DEV calibration test: the standard front camera through the
    /// Duo path with a half-turn error the face reading has to find and undo.
    nonisolated static func armDuoCalibrationTest() {
        resetDuoCalibration()
        UserDefaults.standard.set(180, forKey: correctionKey(AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue))
    }
    #endif

    /// An iPhone Duo session must deliver portrait. A landscape buffer from a
    /// Duo camera means its format axes run the other way: one rebuild with
    /// them swapped. Failing that — or on the standard front camera, whose
    /// level angle on Duo is landscape — the connection takes a portrait angle:
    /// the frame stays portrait and the scene records turned, exactly as on any
    /// iPhone held sideways. Never a landscape file, never a crop.
    private func validateDuoBufferShape(generation: Int) {
        guard generation == configurationGeneration,
              !sessionOrientationMode.wantsLandscapeBuffer,
              let observed = observedBuffer.withLock({ $0 }),
              observed.width > observed.height else { return }
        let buffer = "\(observed.width)x\(observed.height)"
        if let choice = sessionDuoCamera {
            let type = choice.device.deviceType.rawValue
            if !duoAxesFlippedThisProcess.contains(type) {
                duoAxesFlippedThisProcess.insert(type)
                UserDefaults.standard.set(!choice.axesSwapped, forKey: Self.axesKey(type))
                CameraDiagnosticsLog.record("event=duo_landscape_buffer type=\(type) buffer=\(buffer) action=swap_axes")
                reconfigureDuoCamera(reason: "axes_swapped", force: true)
                return
            }
        }
        guard !isRecordingActive,
              let connection = videoDataOutput?.connection(with: .video),
              let reported = lastReportedHorizonAngle else { return }
        let portraitAngle = CGFloat((Int(reported.rounded()) + 90) % 360)
        if let type = sessionDuoCamera?.device.deviceType.rawValue {
            duoTurnRebuildDisabled.insert(type)
        }
        CameraDiagnosticsLog.record("event=duo_landscape_buffer type=\(sessionDuoCamera?.device.deviceType.rawValue ?? "standard") buffer=\(buffer) action=portrait_angle angle=\(Int(portraitAngle))")
        applyClampedRotation(reported: portraitAngle, to: connection)
    }

    /// iPhone Duo, however it is held: a level portrait take at full size. The
    /// front sensors are square and offer both portrait and landscape formats,
    /// so when the device turns a quarter, the session is rebuilt on the other
    /// one (`duoCamera` picks it by the level angle) instead of recording the
    /// scene turned. Never mid-take — the take keeps its start configuration,
    /// and `stopRecording` calls this again — and once the turn settles.
    private func rebuildDuoIfTurned() {
        duoTurnRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let choice = self.sessionDuoCamera,
                  !self.duoTurnRebuildDisabled.contains(choice.device.deviceType.rawValue),
                  !self.isRecording, !self.isRecordingActive,
                  let coordinator = self.rotationCoordinator,
                  let residue = self.observedPortraitResidue else { return }
            let angle = self.duoCorrected(coordinator.videoRotationAngleForHorizonLevelCapture)
            guard !CaptureRotationGeometry.producesPortrait(angle: angle, portraitResidue: residue) else { return }
            if self.sessionDuoAspect != nil, self.switchDuoAspect(to: angle, on: choice) { return }
            self.reconfigureDuoCamera(reason: "turned_\(Int(angle))", force: true)
        }
        duoTurnRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The live alternative to a rebuild on a square format: the other
    /// dynamic aspect ratio and the new level angle together give a portrait
    /// buffer again, with no session reconfiguration and so no blank preview.
    /// Returns false when the switch could not be made (the caller rebuilds).
    private func switchDuoAspect(to angle: CGFloat, on choice: DuoCameraChoice) -> Bool {
        guard #available(iOS 26.0, *), let current = sessionDuoAspect,
              let connection = videoDataOutput?.connection(with: .video) else { return false }
        let next: AVCaptureDevice.AspectRatio = current == AVCaptureDevice.AspectRatio.ratio9x16.rawValue
            ? .ratio16x9 : .ratio9x16
        do {
            try choice.device.lockForConfiguration()
            choice.device.setDynamicAspectRatio(next, completionHandler: nil)
            choice.device.unlockForConfiguration()
        } catch {
            return false
        }
        sessionDuoAspect = next.rawValue
        // What was observed belonged to the other aspect ratio: the next
        // buffer is this shape's first, and the angle is applied unclamped.
        observedBuffer.withLock { $0 = nil }
        applyClampedRotation(reported: angle, to: connection)
        CameraDiagnosticsLog.record("event=duo_aspect_switched to=\(next.rawValue) angle=\(Int(angle))")
        let generation = configurationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.validateDuoBufferShape(generation: generation)
        }
        return true
    }

    /// Self-correction for a Duo camera whose RotationCoordinator angle turns
    /// out wrong for its native format: when several face readings in a row
    /// agree the buffer needs turning, that turn is added to the camera's
    /// angle for good. Only on a Duo camera, never mid-take, only with a
    /// clearly upright head (|roll| < 30) and a reading taken at the angle the
    /// connection holds now, on a buffer of the shape it delivers now; a
    /// reading with no face changes nothing.
    private func handleFaceReading(_ reading: FaceOrientationProbe.Result) {
        guard let choice = sessionDuoCamera,
              !isRecording, !isRecordingActive,
              !reading.mirrored,
              reading.connectionAngle == Int(appliedRotationAngle),
              // A buffer of another shape than the connection now delivers was
              // captured before its angle was applied.
              let observed = observedBuffer.withLock({ $0 }),
              reading.bufferWidth == observed.width, reading.bufferHeight == observed.height,
              let rotation = reading.uprightRotation,
              let roll = reading.roll, abs(roll) < 30 else { return }
        guard rotation != 0 else {
            duoCalibrationStreak = nil
            return
        }
        let type = choice.device.deviceType.rawValue
        guard duoCorrectionsThisProcess[type, default: 0] < Self.maxDuoCorrectionsPerProcess else { return }
        let count = duoCalibrationStreak?.rotation == rotation ? (duoCalibrationStreak?.count ?? 0) + 1 : 1
        guard count >= Self.duoCalibrationReadings else {
            duoCalibrationStreak = (rotation, count)
            faceProbe.arm(context: "calibration", delay: 0.3)
            return
        }
        duoCalibrationStreak = nil
        duoCorrectionsThisProcess[type, default: 0] += 1
        let corrected = (choice.correction + rotation) % 360
        UserDefaults.standard.set(corrected, forKey: Self.correctionKey(type))
        let line = "event=duo_angle_corrected type=\(type) upright_cw=\(rotation) roll=\(Int(roll.rounded())) correction_before=\(choice.correction) correction_after=\(corrected)"
        camLog.notice("\(line, privacy: .public)")
        CameraDiagnosticsLog.record(line)
        reconfigureDuoCamera(reason: "angle_corrected", force: true)
    }

    // MARK: - Session events (diagnostics)

    /// Interruptions, runtime errors, start/stop and camera (dis)connection,
    /// into the camera diagnostics. On iPhone Duo they show what a fold does to
    /// a running session — an interruption, a device swap, or nothing — which
    /// no simulator reproduces. Observation only: nothing here reacts.
    private func observeSessionEventsOnce() {
        guard sessionEventObservers.isEmpty else { return }
        let log = camLog
        func observe(_ name: Notification.Name, object: Any?, describe: @escaping @Sendable (Notification) -> String) {
            sessionEventObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { note in
                    let line = describe(note)
                    log.notice("\(line, privacy: .public)")
                    CameraDiagnosticsLog.record(line)
                }
            )
        }
        observe(AVCaptureSession.wasInterruptedNotification, object: session) { note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            return "event=session_interrupted reason=\(reason)"
        }
        observe(AVCaptureSession.interruptionEndedNotification, object: session) { _ in
            "event=session_interruption_ended"
        }
        observe(AVCaptureSession.runtimeErrorNotification, object: session) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            return "event=session_runtime_error domain=\(error?.domain ?? "?") code=\(error?.code ?? 0)"
        }
        observe(AVCaptureSession.didStartRunningNotification, object: session) { _ in
            "event=session_started"
        }
        observe(AVCaptureSession.didStopRunningNotification, object: session) { _ in
            "event=session_stopped"
        }
        observe(AVCaptureDevice.wasConnectedNotification, object: nil) { note in
            "event=device_connected \(Self.deviceLabel(note.object))"
        }
        observe(AVCaptureDevice.wasDisconnectedNotification, object: nil) { note in
            "event=device_disconnected \(Self.deviceLabel(note.object))"
        }
    }

    nonisolated private static func deviceLabel(_ object: Any?) -> String {
        guard let device = object as? AVCaptureDevice else { return "device=?" }
        return "type=\(device.deviceType.rawValue) id=\(device.uniqueID.suffix(12)) video=\(device.hasMediaType(.video))"
    }

    // MARK: - Phase 1: Video + audio with built-in mic (instant)

    #if !targetEnvironment(simulator)
    private func setupSession(position: AVCaptureDevice.Position, duoPosture: DuoDisplayState.Posture?) {
        session.automaticallyConfiguresApplicationAudioSession = false
        configurationGeneration += 1
        let generation = configurationGeneration

        // Audio session with built-in mic only (no Bluetooth yet — instant)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try? audioSession.setActive(true)

        let resolution = UserDefaults.standard.string(forKey: "videoResolution") ?? "1080p"
        let fps = UserDefaults.standard.integer(forKey: "videoFPS")
        let targetFPS = fps > 0 ? fps : 30

        session.beginConfiguration()

        let want4K = resolution == "4k"
        let allow4K = SubscriptionManager.shared.canRecord4K
        if want4K && allow4K && session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // iPhone Duo: the camera for this posture with a native format, or nil
        // for the standard front camera (always nil on other iPhones).
        sessionDuoPosture = duoPosture
        let duoChoice = position == .front
            ? Self.duoCamera(for: duoPosture, want4K: want4K && allow4K, targetFPS: targetFPS)
            : nil
        sessionDuoCamera = duoChoice
        sessionDuoAspect = duoChoice?.aspectRatio

        // Video input
        guard let videoDevice = duoChoice?.device ?? AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.notAvailable",
                    defaultValue: "Camera not available.",
                    comment: "Shown when the requested camera is not available on this device."
                )
            }
            return
        }

        do {
            let vInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(vInput) { session.addInput(vInput) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.failedToAccess",
                    defaultValue: "Failed to access camera: \(error.localizedDescription)",
                    comment: "Camera access failure with system-localized error description."
                )
            }
            return
        }

        // Frame rate
        do {
            try videoDevice.lockForConfiguration()
            // Duo format first: setting a format resets the frame durations
            // set below. It also turns the preset into `.inputPriority`, which
            // nothing later in this configuration overrides.
            if let duoChoice {
                videoDevice.activeFormat = duoChoice.format
                if #available(iOS 26.0, *), let raw = duoChoice.aspectRatio {
                    videoDevice.setDynamicAspectRatio(AVCaptureDevice.AspectRatio(rawValue: raw), completionHandler: nil)
                }
            }
            let desiredFPS = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            let supported = videoDevice.activeFormat.videoSupportedFrameRateRanges.contains {
                Int($0.maxFrameRate) >= targetFPS
            }
            if supported {
                videoDevice.activeVideoMinFrameDuration = desiredFPS
                videoDevice.activeVideoMaxFrameDuration = desiredFPS
            } else {
                let fallback = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMinFrameDuration = fallback
                videoDevice.activeVideoMaxFrameDuration = fallback
            }
            videoDevice.unlockForConfiguration()
        } catch {}

        // Audio input (built-in mic — instant, no BT negotiation)
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(aInput) {
            session.addInput(aInput)
        }

        // Outputs: video data + audio data. Sample buffers go through the
        // realtime watermark composer and into AVAssetWriter via
        // AssetWriterRecorder. Both delegates fire on `sampleBufferQueue`
        // so writer appends are naturally serialized.
        videoDataOutput = nil
        audioDataOutput = nil

        let videoData = AVCaptureVideoDataOutput()
        videoData.alwaysDiscardsLateVideoFrames = true
        videoData.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoData.setSampleBufferDelegate(self, queue: Self.sampleBufferQueue)
        if session.canAddOutput(videoData) {
            session.addOutput(videoData)
            videoDataOutput = videoData
        }

        let audioData = AVCaptureAudioDataOutput()
        audioData.setSampleBufferDelegate(self, queue: Self.sampleBufferQueue)
        if session.canAddOutput(audioData) {
            session.addOutput(audioData)
            audioDataOutput = audioData
        }

        session.commitConfiguration()

        // Stabilization + portrait orientation on the video data output's
        // connection. Set BEFORE startRunning to avoid a crop jump.
        let stabilizePref = UserDefaults.standard.object(forKey: "stabilizationEnabled") as? Bool ?? true
        let stabilize = stabilizePref && canUseStabilization
        // Tear down any coordinator/observation from a previous configuration
        // (e.g. switchCamera re-entry) before building a new one.
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        // A new output (and possibly a different camera, whose sensor may be
        // mounted differently) — nothing observed so far applies to it.
        observedBuffer.withLock { $0 = nil }
        // The orientation mode is read HERE and nowhere else in the session's
        // life: a change made while the recording screen is open reaches the
        // next configuration, never the running one.
        sessionOrientationMode = RecordingOrientation.current()
        sessionCropsSideways = !sessionOrientationMode.wantsLandscapeBuffer && Self.cropsSidewaysToPortrait
        // A new configuration (or a different camera, whose sensor may be
        // mounted differently) must re-derive the landscape angle rather than
        // inherit a pin that belonged to the previous one.
        pinnedLandscapeAngle = nil
        if let connection = videoDataOutput?.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilize ? .cinematic : .off
            }
            // Drive rotation from the horizon-level capture angle via
            // RotationCoordinator instead of a single-shot 90° assignment. No
            // buffer exists yet, so this first application trusts the
            // coordinator's angle; the first delivered buffer then establishes
            // which angles are portrait on this sensor.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: nil)
            rotationCoordinator = coordinator
            applyClampedRotation(reported: duoCorrected(coordinator.videoRotationAngleForHorizonLevelCapture), to: connection)
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.new]
            ) { [weak self] coord, _ in
                // KVO delivered on the main queue.
                self?.handleRotationChange(coord)
            }
        }

        // Diagnostic: session configuration complete.
        if let connection = videoDataOutput?.connection(with: .video) {
            let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            camLog.notice(
                "event=session_config_complete device_model=\(Self.deviceModelIdentifier, privacy: .public) active_format=\(dims.width)x\(dims.height) preset=\(self.session.sessionPreset.rawValue, privacy: .public) rotation_angle=\(Int(connection.videoRotationAngle)) angle_supported=\(connection.isVideoRotationAngleSupported(connection.videoRotationAngle))"
            )
            CameraDiagnosticsLog.record("event=session_config_complete device_model=\(Self.deviceModelIdentifier) active_format=\(dims.width)x\(dims.height) preset=\(self.session.sessionPreset.rawValue) rotation_angle=\(Int(connection.videoRotationAngle)) angle_supported=\(connection.isVideoRotationAngleSupported(connection.videoRotationAngle))")
        }
        if let duoChoice {
            let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            let line = "event=duo_camera type=\(videoDevice.deviceType.rawValue) position=\(videoDevice.position.rawValue) format=\(dims.width)x\(dims.height) horizon_angle=\(duoChoice.horizonAngle) correction=\(duoChoice.correction) axes_swapped=\(duoChoice.axesSwapped) aspect=\(duoChoice.aspectRatio ?? "fixed") posture=\(duoPosture?.rawValue ?? "none") preset=\(session.sessionPreset.rawValue)"
            camLog.notice("\(line, privacy: .public)")
            CameraDiagnosticsLog.record(line)
        } else if duoPosture != nil, position == .front {
            CameraDiagnosticsLog.record("event=duo_camera_unavailable posture=\(duoPosture?.rawValue ?? "none")")
        }

        // Arm the landscape gate BEFORE the session runs. Two reasons: the wait
        // the user experiences starts here, so `elapsed_ms` measures all of it;
        // and this block reaches the main queue before any buffer exists, so the
        // pin cannot resolve a warmup that has not been armed yet — the ordering
        // that previously produced `elapsed_ms=-1` and then a stray timeout.
        if sessionOrientationMode.wantsLandscapeBuffer {
            let warmupStartedAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.beginLandscapePreviewWarmup(startedAt: warmupStartedAt)
            }
        }

        session.startRunning()

        // Exposure needs a running session
        let exposure = UserDefaults.standard.double(forKey: "exposureCompensation")
        if exposure != 0 { setExposureCompensation(Float(exposure)) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewAngleCorrection = CGFloat(duoChoice?.correction ?? 0)
            self.activeVideoDevice = videoDevice
            self.isSessionReady = true
            // A few frames in, past any buffer still in flight from the
            // previous configuration: is the Duo camera delivering portrait?
            if duoChoice != nil || DuoDisplayMonitor.deviceHasHinge {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.validateDuoBufferShape(generation: generation)
                }
            }
            // Portrait reveals exactly as it always has: its angle is right from
            // the first frame, so gating would cost startup time for nothing.
            // Landscape is already gated by the warmup armed above.
            if !self.sessionOrientationMode.wantsLandscapeBuffer {
                self.isPreviewRevealed = true
            }
        }
        // Phase 2: enable Bluetooth audio routing (non-blocking, no session reconfig)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.enableBluetoothAudio()
        }
    }

    // MARK: - Phase 2: Bluetooth audio routing (no capture session changes)

    private func enableBluetoothAudio() {
        // BT off by default — AirPods etc. force HFP profile (16kHz mono,
        // telephony-grade) when used as input, often worse than the built-in
        // mic. User opt-in via Settings → "Allow Bluetooth microphones".
        // Wired/USB mics (DJI, Rode, Shure) are unaffected by this flag —
        // they win via iOS default routing priority regardless.
        let useBluetoothMic = UserDefaults.standard.bool(forKey: "useBluetoothMic")
        let audioSession = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = useBluetoothMic
            ? [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            : [.defaultToSpeaker]
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: options)

        // Prefer Bluetooth if available — only when the user has opted in.
        if useBluetoothMic, let btInput = audioSession.availableInputs?.first(where: {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .bluetoothA2DP
        }) {
            try? audioSession.setPreferredInput(btInput)
        }

        // Route change observer
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                self.updateAudioSourceName()
                guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                if self.isRecording {
                    switch reason {
                    case .oldDeviceUnavailable:
                        self.audioRouteToast = String(
                            localized: "camera.audio.toast.switchedToBuiltin",
                            defaultValue: "Switched to iPhone microphone",
                            comment: "Toast when audio route falls back to the built-in mic."
                        )
                    case .newDeviceAvailable:
                        self.audioRouteToast = String(
                            localized: "camera.audio.toast.newMicDetected",
                            defaultValue: "New mic detected. Will use on next recording.",
                            comment: "Toast when a new external mic is connected."
                        )
                    default: break
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.isAudioReady = true
            self?.updateAudioSourceName()
        }
    }
    #endif // !targetEnvironment(simulator)

    // MARK: - Exposure & Stabilization

    private var currentCamera: AVCaptureDevice? {
        session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.video) })
    }

    func setExposureCompensation(_ value: Float) {
        #if !targetEnvironment(simulator)
        guard let device = currentCamera else { return }
        let clamped = max(device.minExposureTargetBias, min(value, device.maxExposureTargetBias))
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped) { _ in }
            device.unlockForConfiguration()
        } catch {}
        #endif
    }

    /// Mirrors `SubscriptionManager.canUseStabilization` so the camera setup
    /// sites have a local short-name. Stabilization is paid-only.
    private var canUseStabilization: Bool {
        SubscriptionManager.shared.isSubscribed
    }

    func setStabilization(_ enabled: Bool) {
        #if !targetEnvironment(simulator)
        guard currentCamera != nil else { return }
        let allowed = enabled && canUseStabilization
        if let connection = videoDataOutput?.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = allowed ? .auto : .off
        }
        #endif
    }

    func applySavedSettings() {
        let exposure = UserDefaults.standard.double(forKey: "exposureCompensation")
        setExposureCompensation(Float(exposure))
        let stabilization = UserDefaults.standard.object(forKey: "stabilizationEnabled") as? Bool ?? true
        setStabilization(stabilization)
    }

    // MARK: - Camera switching

    func switchCamera() {
        #if !targetEnvironment(simulator)
        let newPosition: AVCaptureDevice.Position = (cameraPosition == .front) ? .back : .front
        cameraPosition = newPosition
        // Same reset as `start`: this reconfigures the session, so warmup state
        // from the previous configuration must not carry into the new one.
        resetLandscapeWarmup()
        let duoPosture = self.duoPosture
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(position: newPosition, duoPosture: duoPosture)
        }
        #endif
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        if Self.isChromakeyActive {
            // Fake recording: flip UI state and start the duration timer — no AVCapture calls.
            #if DEV
            print("[chromakey] recording skipped — chromakey mode active")
            #endif
            recordingStartTime = Date()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
            isRecording = true
            return
        }

        #if !targetEnvironment(simulator)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        // Freeze the rotation angle for the duration of the take before any
        // buffers can reach a writer whose videoSize is fixed at start.
        isRecordingActive = true
        // Snapshot on main, where the coordinator's KVO updates it.
        let horizonAngle = lastReportedHorizonAngle

        Self.cameraQueue.async { [weak self] in
            self?.startWriterPipeline(outputURL: outputURL, horizonAngle: horizonAngle)
        }
        // After the writer is set up, so the face is read off a take's frames.
        if DuoReportService.readsFaceOrientation { faceProbe.arm(context: "take", delay: 0.5) }

        recordingStartTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        isRecording = true
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Allocates the writer and composer, hooks the writer's pixel buffer
    /// pool into the composer, and starts the writer (encoder allocation).
    /// After this returns, the AVCaptureVideoDataOutput /
    /// AVCaptureAudioDataOutput delegate methods can deliver sample
    /// buffers to the recorder via the composer.
    private func startWriterPipeline(outputURL: URL, horizonAngle: CGFloat?) {
        // Writer canvas = the dimensions the connection is actually delivering,
        // taken from an observed buffer and mapped to the connection's current
        // angle (a quarter turn since the observation swaps the axes). No angle
        // is interpreted, so the canvas cannot disagree with the buffers the way
        // an active-format derivation did on iPhone 17 front cameras. The angle
        // is captured into a local constant here (frozen for the take).
        let recordingAngle = appliedRotationAngle
        let connection = videoDataOutput?.connection(with: .video)
        let connectionAngle = connection?.videoRotationAngle ?? recordingAngle
        var videoSize: CGSize
        var writerSizeSource: String
        if let observed = observedBuffer.withLock({ $0 }) {
            let expected = CaptureRotationGeometry.expectedDimensions(
                observedWidth: observed.width,
                observedHeight: observed.height,
                observedAngle: observed.connectionAngle,
                targetAngle: connectionAngle
            )
            videoSize = CGSize(width: expected.width, height: expected.height)
            writerSizeSource = "observed_buffer"
        } else if let dims = currentCamera.map({ CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }) {
            // No buffer yet (not expected: frames flow from session start).
            // Portrait canvas from the format's long/short sides; the backstop
            // reports any disagreement.
            let w = CGFloat(dims.width)
            let h = CGFloat(dims.height)
            videoSize = CGSize(width: min(w, h), height: max(w, h))
            writerSizeSource = "active_format_fallback"
        } else {
            // Defensive fallback: preserve prior preset-based behavior.
            switch session.sessionPreset {
            case .hd4K3840x2160:
                videoSize = CGSize(width: 2160, height: 3840)
            default:
                videoSize = CGSize(width: 1080, height: 1920)
            }
            writerSizeSource = "preset_fallback"
        }
        // A sideways take in a cropping session: the connection delivers
        // landscape buffers, and the canvas is their vertical middle.
        // `captureOutput` cuts each frame to it.
        if sessionCropsSideways, videoSize.width > videoSize.height {
            videoSize = CaptureRotationGeometry.portraitCrop(of: videoSize)
            writerSizeSource += "_sideways_crop"
        }
        let fps = UserDefaults.standard.integer(forKey: "videoFPS")
        let targetFPS = fps > 0 ? fps : 30

        let isPro = !SubscriptionManager.shared.showWatermark
        let composer = RealtimeWatermarkComposer(renderSize: videoSize, isPro: isPro)
        let recorder = AssetWriterRecorder()

        do {
            // `composerPath` tells the recorder which composer path is active
            // so a sampled dimension mismatch can be logged as pro (unrecoverable —
            // encoder rescales) vs free. Mirrors the composer's `isPro` branch.
            try recorder.startRecording(to: outputURL, videoSize: videoSize, fps: targetFPS, composerPath: isPro ? "pro" : "free")
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.recordingError",
                    defaultValue: "Recording error: \(error.localizedDescription)",
                    comment: "Recording session error with system-localized error description."
                )
            }
            return
        }

        // Diagnostic: recording start. Active format is re-read here because it
        // can diverge from the config-time format after startRunning.
        let quality = (session.sessionPreset == .hd4K3840x2160) ? "4K" : "1080p"
        let recDims = currentCamera.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let stabMode = connection?.preferredVideoStabilizationMode
        let mirrored = connection?.isVideoMirrored ?? false
        let candidatesField = lastLandscapeCandidates.isEmpty
            ? "none"
            : lastLandscapeCandidates.map(String.init).joined(separator: "/")
        // No coordinator report yet (not expected): target the connection's own
        // angle, so the backstop computes a zero correction rather than a guess.
        let frozenHorizonAngle = horizonAngle ?? connectionAngle
        camLog.notice(
            "event=recording_start mode=\(self.sessionOrientationMode.rawValue, privacy: .public) landscape_candidates=\(candidatesField, privacy: .public) writer_size=\(Int(videoSize.width))x\(Int(videoSize.height)) writer_size_source=\(writerSizeSource, privacy: .public) applied_angle=\(Int(recordingAngle)) connection_angle=\(Int(connectionAngle)) horizon_angle=\(Int(frozenHorizonAngle)) mirrored=\(mirrored) quality=\(quality, privacy: .public) active_format=\(recDims?.width ?? -1)x\(recDims?.height ?? -1) preset=\(self.session.sessionPreset.rawValue, privacy: .public) stabilization=\(stabMode?.rawValue ?? -1)"
        )
        CameraDiagnosticsLog.record("event=recording_start mode=\(self.sessionOrientationMode.rawValue) landscape_candidates=\(candidatesField) writer_size=\(Int(videoSize.width))x\(Int(videoSize.height)) writer_size_source=\(writerSizeSource) applied_angle=\(Int(recordingAngle)) connection_angle=\(Int(connectionAngle)) horizon_angle=\(Int(frozenHorizonAngle)) mirrored=\(mirrored) quality=\(quality) active_format=\(recDims?.width ?? -1)x\(recDims?.height ?? -1) preset=\(self.session.sessionPreset.rawValue) stabilization=\(stabMode?.rawValue ?? -1)")

        if let pool = recorder.pixelBufferPool {
            composer.setPixelBufferPool(pool)
        }

        // Assigned before the recorder so the first frame of the take sees the
        // new writer geometry.
        self.recordingConnectionAngle = connectionAngle
        self.recordingHorizonAngle = frozenHorizonAngle
        self.recordingConnectionMirrored = mirrored
        self.recordingWriterAngle = recordingAngle
        self.recordingWriterSize = videoSize
        // Frozen for the take: the canvas is fixed now, so a mode change from
        // Settings mid-recording cannot reach the pipeline.
        self.recordingOrientationMode = self.sessionOrientationMode
        self.orientationCorrectionLogged = false
        self.sidewaysCropLogged = false
        // The leading-drop counters are deliberately NOT reset here. Publishing
        // them from this queue is what made them unreliable: `sampleBufferQueue`
        // could see the new recorder before these stores landed. They reset
        // instead on that queue, the first time it sees a new recorder.

        self.watermarkComposer = composer
        self.assetWriterRecorder = recorder
    }
    #endif

    func stopRecording() {
        guard isRecording else { return }

        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        lastRecordingDuration = elapsed
        AppAnalytics.log("recording_stopped", params: [
            "duration_sec": Int(elapsed.rounded()),
            "display_mode": UserDefaults.standard.string(forKey: "teleprompterMode") ?? "wbw"
        ])

        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false
        recordingDuration = 0
        recordingStartTime = nil

        // Recording is no longer active — unfreeze rotation and apply any
        // angle change that arrived (and was suppressed) mid-take.
        isRecordingActive = false
        if let pending = pendingRotationAngle {
            pendingRotationAngle = nil
            if let connection = videoDataOutput?.connection(with: .video) {
                let old = appliedRotationAngle
                applyClampedRotation(reported: pending, to: connection)
                camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(pending)) suppressed=false")
            }
        }
        // Turned during the take: the other format now gives the level portrait.
        if sessionDuoCamera != nil {
            rebuildDuoIfTurned()
        }

        if Self.isChromakeyActive {
            // No file to write — nothing to do. lastRecordedURL stays nil so VideoPreviewView is not triggered.
            return
        }

        #if !targetEnvironment(simulator)
        // Register background task so the video file finishes writing even if app is backgrounded
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        Self.cameraQueue.async { [weak self] in
            self?.stopWriterPipeline()
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Marks the writer's inputs as finished, finalizes the file, and hops
    /// to main with the resulting URL. Honors the
    /// `lastRecordedURL` / `saveDirectlyOnStop` contract that downstream
    /// consumers (RecordingView, scenePhase autosave) rely on.
    private func stopWriterPipeline() {
        guard let recorder = assetWriterRecorder else {
            DispatchQueue.main.async { [weak self] in self?.endBackgroundTask() }
            return
        }
        recorder.stopRecording { [weak self] result in
            // Don't nil out assetWriterRecorder / watermarkComposer here —
            // sampleBufferQueue may still hold a reference and clearing it
            // mid-flight can race with concurrent reads. The recorder's
            // internal state machine (`.finishing` / `.finished`) silently
            // drops late appends, and the next startWriterPipeline
            // replaces both properties wholesale.
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.endBackgroundTask() }
                switch result {
                case .success(let url):
                    if self.saveDirectlyOnStop {
                        self.handleSaveDirectlyOnStop(url: url)
                    } else {
                        self.lastRecordedURL = url
                    }
                case .failure(let error):
                    // Writer-level failure (AVAssetWriter status != .completed).
                    // This path never sets `lastRecordedURL`, so RecordingView's
                    // persist flow — and its own `recording_failed` — is never
                    // reached. Without this the take is invisible to analytics:
                    // `recording_stopped` fires either way, so a failed write
                    // looks exactly like a user stopping after a second.
                    // Same parameter shape as `recording_stopped` above;
                    // `error_reason` is the NSError domain/code rather than
                    // `localizedDescription`, which would fragment across the
                    // app's four locales.
                    let nsError = error as NSError
                    AppAnalytics.log("recording_failed", params: [
                        "duration_sec": Int(self.lastRecordingDuration.rounded()),
                        "display_mode": UserDefaults.standard.string(forKey: "teleprompterMode") ?? "wbw",
                        "error_reason": "\(nsError.domain)/\(nsError.code)"
                    ])
                    self.errorMessage = String(
                        localized: "camera.error.recordingError",
                        defaultValue: "Recording error: \(error.localizedDescription)",
                        comment: "Recording session error with system-localized error description."
                    )
                    #if !DEV
                    Crashlytics.crashlytics().record(error: error)
                    #endif
                }
            }
        }
    }

    /// Autosave path for scenePhase-while-recording. The file already has
    /// the watermark burned in (or doesn't, for Pro users) by the realtime
    /// pipeline, so no post-process step is needed — direct hand-off to
    /// PhotoKit.
    @MainActor
    private func handleSaveDirectlyOnStop(url: URL) {
        saveDirectlyOnStop = false
        let durationSec = Int(lastRecordingDuration.rounded())
        let wasFirst = UserDefaults.standard.bool(forKey: "hasCompletedFirstRecording")
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        AppAnalytics.log("recording_saved", params: [
            "duration_sec": durationSec,
            "was_first": wasFirst,
            "via": "background_autosave"
        ])
    }
    #endif

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - iPhone Duo diagnostics

    /// The current capture configuration, for an iPhone Duo report
    /// (`DuoReportService`). Reads the same state the rotation logs do.
    func duoDiagnostics() -> [String: Any] {
        var info: [String: Any] = [
            "session_ready": isSessionReady,
            "preset": session.sessionPreset.rawValue,
            "orientation_mode": sessionOrientationMode.rawValue,
            "crops_sideways": sessionCropsSideways,
            "applied_angle": appliedRotationAngle,
            "chromakey": Self.isChromakeyActive,
        ]
        if let horizon = lastReportedHorizonAngle { info["horizon_angle"] = horizon }
        if let connection = videoDataOutput?.connection(with: .video) {
            info["connection_angle"] = connection.videoRotationAngle
            info["mirrored"] = connection.isVideoMirrored
            info["stabilization"] = connection.activeVideoStabilizationMode.rawValue
        }
        if let observed = observedBuffer.withLock({ $0 }) {
            info["observed_buffer"] = "\(observed.width)x\(observed.height)@\(Int(observed.connectionAngle))"
            info["portrait_residue"] = observedPortraitResidue ?? -1
        }
        if let device = currentCamera {
            info["device"] = DuoReportService.describe(device, formats: false)
        }
        if let face = faceProbe.lastResult { info["face"] = face.report }
        if let duo = sessionDuoCamera {
            info["duo_camera"] = [
                "type": duo.device.deviceType.rawValue,
                "horizon_angle": duo.horizonAngle,
                "correction": duo.correction,
                "axes_swapped": duo.axesSwapped,
                "aspect": sessionDuoAspect ?? "fixed",
            ]
        } else {
            info["duo_camera"] = "standard"
        }
        info["face_pending"] = faceProbe.isPending
        return info
    }

    private func updateAudioSourceName() {
        #if !targetEnvironment(simulator)
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        audioSourceName = input?.portName ?? String(
            localized: "camera.audio.iPhoneMic",
            defaultValue: "iPhone Microphone",
            comment: "Default audio source name in the recording HUD."
        )
        #endif
    }
}

// MARK: - Video + audio data output delegates

#if !targetEnvironment(simulator)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Delivered on `sampleBufferQueue` (set in setupSession). Both
        // outputs share this queue so AVAssetWriter's serialization
        // contract is satisfied without explicit locking.
        if output is AVCaptureAudioDataOutput {
            assetWriterRecorder?.appendAudio(sampleBuffer)
            audioBufferBroadcast?(sampleBuffer)
            return
        }
        guard var pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === videoDataOutput {
            gazeProbe.submit(pixelBuffer)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        var bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        // Record what the connection actually delivers. This is what decides
        // portrait angles and the writer canvas. Straggler buffers from an
        // output that a reconfiguration already replaced are ignored. Normal
        // case: an uncontended lock and a comparison; the connection's
        // properties are read only when the dimensions or connection change.
        if output === videoDataOutput {
            let connectionID = ObjectIdentifier(connection)
            let change: (observation: ObservedBuffer, previous: ObservedBuffer?)? = observedBuffer.withLock { state in
                if let current = state,
                   current.width == bufferWidth,
                   current.height == bufferHeight,
                   current.connection == connectionID {
                    return nil
                }
                let previous = state
                let observation = ObservedBuffer(
                    width: bufferWidth,
                    height: bufferHeight,
                    connectionAngle: connection.videoRotationAngle,
                    mirrored: connection.isVideoMirrored,
                    connection: connectionID
                )
                state = observation
                return (observation, previous)
            }
            if let change, change.previous == nil {
                logFirstBuffer(change.observation)
                // The residue is now known, so landscape-left is derivable.
                // Pin it once, on main where the angle state lives.
                Task { @MainActor [weak self] in
                    self?.pinLandscapeAngleAfterFirstBuffer()
                }
                // After a pause: right after a reconfiguration the first buffer
                // can still carry the previous connection angle.
                if DuoReportService.readsFaceOrientation { faceProbe.arm(context: "preview", delay: 0.3) }
            } else if let change, let previous = change.previous {
                // Same configuration, different shape: an applied rotation, or
                // on iPhone Duo a fold moving the session to another sensor.
                logBufferShapeChanged(from: previous, to: change.observation)
                if DuoReportService.readsFaceOrientation { faceProbe.arm(context: "shape_change") }
            }
            faceProbe.submit(pixelBuffer, connectionAngle: connection.videoRotationAngle, mirrored: connection.isVideoMirrored)
        }
        // Orientation correction. Runs before the watermark composer so it
        // covers both the free path and the pro path (where the composer
        // passes buffers through untouched). Normal case: a comparison, no
        // allocation. Triggered purely on dimensions: a buffer that does not
        // match the writer canvas is rotated into it first, so the watermark is
        // still drawn in canvas coordinates. The canvas is sized from delivered
        // buffers, so this fires only if the delivered shape changes mid-take.
        // Leading-frame drop. Every fact it needs — whether a take is running,
        // that take's canvas, and whether this is its first frame — is read off
        // the recorder object, so none of them can disagree with the others.
        //
        // It previously tested against `recordingWriterSize`, which
        // `startWriterPipeline` publishes in a different store from the one that
        // makes the recorder visible, on the camera queue, with nothing ordering
        // them against this queue. So this queue could see the NEW recorder
        // beside the PREVIOUS take's canvas — and a buffer left in flight by a
        // mode switch has exactly the previous take's shape, so the test read
        // "match" and skipped the block entirely, drop and backstop alike. That
        // is why a sideways first frame reached the writer with no
        // `stale_leading_frame_dropped` and no `orientation_uncorrectable`.
        // `configuredVideoSize` is set inside `startRecording`, before the
        // recorder is published, so it is right the instant the recorder exists.
        // THE single read of `assetWriterRecorder` for this invocation, and the
        // only one any decision below is allowed to use.
        //
        // Measured, not reasoned: reading this property twice in one invocation
        // returned DIFFERENT objects — `take_id=11dffc9c0` (the previous take,
        // already `finished`) when the shape was checked, against
        // `append_take_id=11d950a80` (the new take) when the frame was appended.
        // The frame was therefore validated against one take and written into
        // another, and because the first read was `finished` the check resolved
        // `takeCanvas` to nil and was skipped entirely. Every consumer below —
        // canvas, identity reset, drop decision, append, has-appended — now reads
        // this one value.
        let takeRecorder = assetWriterRecorder
        let liveTake: AssetWriterRecorder?
        let takeCanvas: CGSize?
        if let recorder = takeRecorder, case .recording = recorder.state {
            let takeID = ObjectIdentifier(recorder)
            if currentTakeRecorder != takeID {
                // Still required with a single read, and doing different work
                // from it: the single read fixes WHICH recorder is consulted,
                // this fixes WHEN the per-take counters start over. It remains
                // the only signal on this queue that the take changed, since the
                // camera queue's own stores cannot be ordered against it.
                currentTakeRecorder = takeID
                droppedLeadingMismatchCount = 0
                recordingHasAppendedVideo = false
            }
            liveTake = recorder
            takeCanvas = recorder.configuredVideoSize
        } else {
            liveTake = nil
            takeCanvas = nil
        }
        // Sideways take (`cropsSidewaysToPortrait`): the canvas is the vertical
        // middle of the landscape buffers delivered, at their full height. Cut
        // it out first, so every check below sees a canvas-shaped frame. Only
        // that exact geometry qualifies — a landscape buffer exactly as tall as
        // a narrower portrait canvas — which no other mode's canvas has, so
        // nothing else changes; a stale portrait buffer still fails the shape
        // test below and is dropped.
        if let canvas = takeCanvas, let recorder = liveTake,
           bufferWidth > bufferHeight,
           canvas.height > canvas.width,
           bufferHeight == Int(canvas.height),
           bufferWidth > Int(canvas.width),
           let cropped = sidewaysCropped(pixelBuffer, bufferWidth: bufferWidth, canvas: canvas, recorder: recorder) {
            pixelBuffer = cropped
            bufferWidth = Int(canvas.width)
            bufferHeight = Int(canvas.height)
        }
        if let canvas = takeCanvas,
           bufferWidth != Int(canvas.width) || bufferHeight != Int(canvas.height),
           !recordingHasAppendedVideo,
           droppedLeadingMismatchCount < Self.maxLeadingMismatchDrops {
            // A buffer contradicting the canvas at the very start of a take was
            // captured under the previous configuration and was still in flight
            // when this one was fixed — in either direction, since a mode switch
            // changes the delivered shape both ways. Nothing describes that
            // buffer's own orientation: the connection angle it would be
            // attributed to has already moved, and shape alone cannot separate
            // two angles a half turn apart. The direction is unknowable, so the
            // frame is dropped rather than written sideways. The writer starts
            // its session on the first frame it actually receives, so this costs
            // one frame time. A mismatch later in the take is a different
            // condition and still goes to the backstop below.
            droppedLeadingMismatchCount += 1
            logStaleLeadingFrameDropped(
                bufferWidth: bufferWidth, bufferHeight: bufferHeight, canvas: canvas
            )
            return
        }
        // Same canvas the drop just used, so the two cannot contradict each
        // other. Without this the backstop would keep reading the property that
        // can lag: inside that window a CORRECTLY shaped buffer matches the real
        // canvas — so it is not dropped — yet looks mismatched against the stale
        // value, and would be handed to a correction it does not need. Identical
        // to the previous behaviour everywhere else: outside a take `takeCanvas`
        // is nil, and once the stores land the two values are equal. The
        // backstop's own refusal conditions are untouched.
        let writerSize = takeCanvas ?? recordingWriterSize
        if writerSize.width > 0,
           bufferWidth != Int(writerSize.width) || bufferHeight != Int(writerSize.height) {
            #if DEV
            if Self.disableOrientationBackstopForDiagnostics {
                logBackstopSkipped(bufferWidth: bufferWidth, bufferHeight: bufferHeight)
            } else {
                pixelBuffer = orientedToWriter(
                    pixelBuffer, bufferWidth: bufferWidth, bufferHeight: bufferHeight, recorder: liveTake
                )
            }
            #else
            pixelBuffer = orientedToWriter(
                pixelBuffer, bufferWidth: bufferWidth, bufferHeight: bufferHeight, recorder: liveTake
            )
            #endif
        }
        let processed = watermarkComposer?.process(pixelBuffer) ?? pixelBuffer
        // Appended through the SAME object every check above used. When that read
        // yielded no live take the frame belongs to no take that has validated
        // it, and it is not written at all — where previously a second read found
        // the newly published recorder and wrote it in unchecked.
        //
        // Refusing it is correct: `appendVideo` starts the writer's session on
        // the first frame it actually receives, so the session simply begins at
        // the next frame's PTS, and `appendAudio` withholds audio until that
        // session exists, so the tracks stay aligned. The cost is one frame time
        // and no truncation. The window is narrow in any case — before the camera
        // queue publishes the new recorder BOTH reads returned the finished one,
        // and an append to a finished recorder was already a no-op.
        if let recorder = liveTake {
            recorder.appendVideo(processed, pts: pts)
            // Only a frame that actually reached the writer ends the leading run.
            recordingHasAppendedVideo = true
        }
    }

    /// One line per session configuration: the first buffer the connection
    /// delivered and the portrait residue it implies. Together with
    /// `rotation_selected` this pins which connection angle produced which
    /// buffer shape on the tester's device.
    nonisolated private func logFirstBuffer(_ observation: ObservedBuffer) {
        let residue = CaptureRotationGeometry.portraitResidue(
            bufferWidth: observation.width,
            bufferHeight: observation.height,
            connectionAngle: observation.connectionAngle
        )
        let candidatesField = CaptureRotationGeometry.landscapeCandidates(portraitResidue: residue)
            .map(String.init).joined(separator: "/")
        camLog.notice(
            "event=first_buffer mode=\(self.sessionOrientationMode.rawValue, privacy: .public) buffer_w=\(observation.width) buffer_h=\(observation.height) connection_angle=\(Int(observation.connectionAngle)) mirrored=\(observation.mirrored) portrait_residue=\(residue) landscape_candidates=\(candidatesField, privacy: .public)"
        )
        CameraDiagnosticsLog.record("event=first_buffer mode=\(self.sessionOrientationMode.rawValue) buffer_w=\(observation.width) buffer_h=\(observation.height) connection_angle=\(Int(observation.connectionAngle)) mirrored=\(observation.mirrored) portrait_residue=\(residue) landscape_candidates=\(candidatesField)")
    }

    /// A buffer shape change within one session configuration. With the
    /// connection angle changed it is an applied rotation; with the angle
    /// unchanged the device or its sensor changed underneath (iPhone Duo fold).
    nonisolated private func logBufferShapeChanged(from previous: ObservedBuffer, to current: ObservedBuffer) {
        let line = "event=buffer_shape_changed from=\(previous.width)x\(previous.height)@\(Int(previous.connectionAngle)) to=\(current.width)x\(current.height)@\(Int(current.connectionAngle)) same_connection=\(previous.connection == current.connection)"
        camLog.notice("\(line, privacy: .public)")
        CameraDiagnosticsLog.record(line)
    }

    /// Slow path of the orientation correction in `captureOutput`: rotates
    /// `pixelBuffer` into the writer canvas and renders it into a buffer from
    /// the writer's pool. Returns the input unchanged when no writer is
    /// recording, allocation fails, or no reliable direction exists — a
    /// degraded frame beats a dropped one or an upside-down one, and the
    /// recorder reports it as `frame_dims_mismatch_uncorrected`.
    nonisolated private func orientedToWriter(
        _ pixelBuffer: CVPixelBuffer,
        bufferWidth: Int,
        bufferHeight: Int,
        recorder: AssetWriterRecorder?
    ) -> CVPixelBuffer {
        // `recorder` is the SAME object the single read in `captureOutput`
        // validated, passed in rather than re-read here. This was the last
        // independent read of `assetWriterRecorder` on the video path: it could
        // return a different recorder than the one the append targeted, so the
        // correction rendered into one take's pixel buffer pool while the frame
        // was written into another's.
        //
        // The state check that stood here is not relaxed, only moved: `liveTake`
        // is non-nil precisely when `case .recording` already held at the single
        // read. Nil means no live take, exactly as a failed state check meant
        // before — return the buffer untouched and log nothing. Every refusal
        // condition below (mirrored, quarter-turn, `orientation_uncorrectable`)
        // is unchanged.
        guard let recorder, let pool = recorder.pixelBufferPool else { return pixelBuffer }

        // Rotate by Apple's correction: the coordinator's horizon-level angle
        // minus what the connection already applied, both frozen at record
        // start. Never by an angle the app derived for itself — on iPhone 17
        // that yielded 90 - 90 = 0 for a landscape buffer in a portrait canvas.
        let difference = CaptureRotationGeometry.correctionDegrees(
            horizonAngle: recordingHorizonAngle,
            connectionAngle: recordingConnectionAngle
        )
        // The shape mismatch needs a quarter turn. A correction of 0 or 180
        // cannot produce one, and a mirrored buffer reverses a rotation's
        // sense in a way the API does not let us determine. In either case
        // the direction is unknown: pass the buffer through and say so.
        let needsQuarterTurn = (bufferWidth > bufferHeight) != (recordingWriterSize.width > recordingWriterSize.height)
        let quarterTurn = difference % 180 != 0
        guard !recordingConnectionMirrored, needsQuarterTurn == quarterTurn,
              let orientation = CaptureRotationGeometry.orientation(forClockwiseDegrees: difference) else {
            logOrientationUncorrectable(bufferWidth: bufferWidth, bufferHeight: bufferHeight, difference: difference)
            return pixelBuffer
        }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let outputBuffer = output else { return pixelBuffer }

        let context = correctionCIContext()

        let rotated = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        // Pin the rotated extent to the origin so the render fills the buffer.
        let pinned = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
        context.render(pinned, to: outputBuffer)

        if !orientationCorrectionLogged {
            orientationCorrectionLogged = true
            let writerSize = recordingWriterSize
            camLog.error(
                "event=orientation_corrected buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) recording_angle=\(Int(self.recordingWriterAngle)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) mirrored=\(self.recordingConnectionMirrored) difference=\(difference)"
            )
            CameraDiagnosticsLog.record("event=orientation_corrected buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) recording_angle=\(Int(self.recordingWriterAngle)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) mirrored=\(self.recordingConnectionMirrored) difference=\(difference)")
        }
        return outputBuffer
    }

    /// Created on the first frame that needs re-rendering — an orientation
    /// correction or a sideways crop — never on the normal path.
    nonisolated private func correctionCIContext() -> CIContext {
        if let existing = orientationCIContext { return existing }
        // Same construction as RealtimeWatermarkComposer's context.
        let context: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: nil)
        }
        orientationCIContext = context
        return context
    }

    /// The horizontally centred, full-height `canvas`-sized part of a
    /// landscape `pixelBuffer`, rendered into a buffer from the take's writer
    /// pool. Nil when no buffer can be allocated: the frame then goes on
    /// uncut and the checks after it treat it as any mismatched frame.
    nonisolated private func sidewaysCropped(
        _ pixelBuffer: CVPixelBuffer,
        bufferWidth: Int,
        canvas: CGSize,
        recorder: AssetWriterRecorder
    ) -> CVPixelBuffer? {
        guard let pool = recorder.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let outputBuffer = output else { return nil }
        let x = ((CGFloat(bufferWidth) - canvas.width) / 2).rounded(.down)
        let cut = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: CGRect(x: x, y: 0, width: canvas.width, height: canvas.height))
            .transformed(by: CGAffineTransform(translationX: -x, y: 0))
        correctionCIContext().render(cut, to: outputBuffer)
        if !sidewaysCropLogged {
            sidewaysCropLogged = true
            camLog.notice(
                "event=sideways_cropped buffer_w=\(bufferWidth) canvas_w=\(Int(canvas.width)) canvas_h=\(Int(canvas.height)) connection_angle=\(Int(self.recordingConnectionAngle)) horizon_angle=\(Int(self.recordingHorizonAngle))"
            )
            CameraDiagnosticsLog.record("event=sideways_cropped buffer_w=\(bufferWidth) canvas_w=\(Int(canvas.width)) canvas_h=\(Int(canvas.height)) connection_angle=\(Int(self.recordingConnectionAngle)) horizon_angle=\(Int(self.recordingHorizonAngle))")
        }
        return outputBuffer
    }

    /// Once per recording: a buffer contradicted the canvas and no reliable
    /// rotation direction existed, so it was written uncorrected.
    nonisolated private func logOrientationUncorrectable(bufferWidth: Int, bufferHeight: Int, difference: Int) {
        guard !orientationCorrectionLogged else { return }
        orientationCorrectionLogged = true
        let writerSize = recordingWriterSize
        let reason = recordingConnectionMirrored ? "mirrored" : "no_quarter_turn"
        camLog.error(
            "event=orientation_uncorrectable reason=\(reason, privacy: .public) buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) difference=\(difference)"
        )
        CameraDiagnosticsLog.record("event=orientation_uncorrectable reason=\(reason) buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) difference=\(difference)")
    }

    /// A leading frame whose shape contradicted the canvas was dropped rather
    /// than written sideways. One line per dropped frame, so at most
    /// `maxLeadingMismatchDrops` per take — the count is the point, since it
    /// says how deep the in-flight window actually was on this device.
    /// `canvas` is the recorder's own `configuredVideoSize` — the size the drop
    /// actually tested against. `writer_size` is the separate
    /// `recordingWriterSize` property: logged alongside it precisely so the two
    /// can be compared on device. Whenever they differ, this queue was holding a
    /// stale canvas, which is the condition that let a sideways frame through.
    nonisolated private func logStaleLeadingFrameDropped(bufferWidth: Int, bufferHeight: Int, canvas: CGSize) {
        let writerSize = recordingWriterSize
        camLog.error(
            "event=stale_leading_frame_dropped mode=\(self.recordingOrientationMode.rawValue, privacy: .public) buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) canvas_w=\(Int(canvas.width)) canvas_h=\(Int(canvas.height)) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) dropped=\(self.droppedLeadingMismatchCount) connection_angle=\(Int(self.recordingConnectionAngle)) horizon_angle=\(Int(self.recordingHorizonAngle))"
        )
        CameraDiagnosticsLog.record("event=stale_leading_frame_dropped mode=\(self.recordingOrientationMode.rawValue) buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) canvas_w=\(Int(canvas.width)) canvas_h=\(Int(canvas.height)) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) dropped=\(self.droppedLeadingMismatchCount) connection_angle=\(Int(self.recordingConnectionAngle)) horizon_angle=\(Int(self.recordingHorizonAngle))")
    }

    #if DEV
    /// DIAGNOSTIC BUILD ONLY. Emits exactly what `orientedToWriter` would have
    /// logged, without correcting the buffer, so a primary-path failure shows
    /// up in the recorded video rather than being silently rescued. Once per
    /// recording, sharing the correction's own guard flag.
    nonisolated private func logBackstopSkipped(bufferWidth: Int, bufferHeight: Int) {
        guard !orientationCorrectionLogged else { return }
        orientationCorrectionLogged = true
        let difference = CaptureRotationGeometry.correctionDegrees(
            horizonAngle: recordingHorizonAngle,
            connectionAngle: recordingConnectionAngle
        )
        let writerSize = recordingWriterSize
        camLog.error(
            "event=orientation_backstop_skipped buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) recording_angle=\(Int(self.recordingWriterAngle)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) mirrored=\(self.recordingConnectionMirrored) difference=\(difference)"
        )
        CameraDiagnosticsLog.record("event=orientation_backstop_skipped buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) writer_w=\(Int(writerSize.width)) writer_h=\(Int(writerSize.height)) recording_angle=\(Int(self.recordingWriterAngle)) horizon_angle=\(Int(self.recordingHorizonAngle)) connection_angle=\(Int(self.recordingConnectionAngle)) mirrored=\(self.recordingConnectionMirrored) difference=\(difference)")
    }
    #endif
}
#endif
