import Combine
import Foundation

/// Decides whether the user is looking at the lens, from `GazeProbe` readings,
/// with no manual calibration.
///
/// The usable signal is eye OPENING, not the pupil: Vision's pupil landmark
/// barely moves with gaze, but the upper lid drops when the eyes go down to
/// the screen (own face, buttons). Measured on device: opening ~0.32 at the
/// lens, ~0.28 at the own face, ~0.26 at the record button.
///
/// Calibration is automatic. While the prompter plays, the user is reading the
/// pill right under the lens — indistinguishable from the lens itself — so
/// openings sampled then form the "at the lens" baseline: a high percentile of
/// a rolling window, which tracks light, pose and the person. "Away" means the
/// eyes are clearly narrower than that baseline for long enough to rule out a
/// blink or a passing expression, or no face is found.
///
/// Horizontal glances (off the phone, without lowering the eyes) are NOT
/// caught: the pupil signal is dead, and turning away only registers once the
/// face is lost.
@MainActor
final class GazeAttention: ObservableObject {
    enum State: Equatable {
        /// Not tracking yet: no baseline, and the prompter is not playing.
        case idle
        /// No baseline yet, prompter playing: learning the "at the lens" look.
        case calibrating
        case looking
        case away
    }

    @Published private(set) var state: State = .idle
    /// When the current away spell actually began: the first narrowed
    /// reading, backdated by the pipeline's lag. Set together with `.away`, so
    /// a consumer can undo what happened during the confirmation delay.
    private(set) var awayOnset: Date?
    /// Latest raw reading, for the DEV gaze overlay. Published in DEV builds
    /// only: at ~10 Hz it re-renders every observer, the whole recording
    /// screen included.
    #if DEV
    @Published private(set) var reading: GazeProbe.Reading?
    #else
    private(set) var reading: GazeProbe.Reading?
    #endif

    /// Set from the prompter: baseline samples are taken only while it plays.
    /// The probe runs only while it plays or a take records (`updateProbe`):
    /// Vision face landmarks at ~10 Hz cost ~12% of a core on an iPhone 16,
    /// for nothing while the camera merely sits open.
    var isReading = false {
        didSet { if oldValue != isReading { updateProbe() } }
    }
    private var isProbing = false

    /// Eye contact over one take.
    struct TakeSummary: Equatable {
        /// Share of tracked time spent looking at the lens, 0...1. Time before
        /// the baseline exists (idle, calibrating) is not counted.
        var lookingFraction: Double
        /// Each look-away, as seconds into the take from start to end.
        var awaySpans: [ClosedRange<TimeInterval>]
        /// Seconds into the take when tracking began (calibration over). The
        /// share above covers only the take from here on.
        var trackedFrom: TimeInterval
    }

    private var takeStart: Date?
    private var lastTick: Date?
    private var lookingTime: TimeInterval = 0
    private var awayTime: TimeInterval = 0
    private var awaySpans: [ClosedRange<TimeInterval>] = []
    /// Start of the look-away still in progress, seconds into the take.
    private var openAwayStart: TimeInterval?
    /// When the take's first looking or away time was credited.
    private var trackedFrom: TimeInterval?
    /// Below this much tracked time a percentage would mean nothing.
    private static let minimumTrackedTime: TimeInterval = 3

    private weak var probe: GazeProbe?
    /// ~0.3 s median at the probe's ~10 Hz, to drop blinks and single-frame
    /// landmark jumps.
    private var recent: [Double] = []
    private static let smoothingCount = 3
    /// Baseline window: ~25 s of reading-time openings.
    private var baselineSamples: [Double] = []
    private static let baselineCapacity = 250
    /// ~2 s of reading before the baseline is trusted.
    private static let baselineMinimum = 20
    private static let baselinePercentile = 0.8
    /// Away when the opening falls this far below the baseline... Looking at
    /// the own face measured only ~12% below the lens, so 10% missed it; the
    /// record button (~19%) cleared any of these.
    private static let awayDrop = 0.07
    /// ...and back to looking once it recovers to within this (hysteresis).
    private static let returnDrop = 0.04
    /// Away must hold this long before it is reported.
    private static let awayDelay: TimeInterval = 0.7
    /// Capture-to-reading lag: frame age at Vision time plus the median's
    /// one-sample delay at ~10 Hz.
    private static let pipelineLag: TimeInterval = 0.15
    private var awaySince: Date?

    func start(probe: GazeProbe) {
        self.probe = probe
        updateProbe()
    }

    /// Runs the probe while the prompter plays or a take records, and parks
    /// it otherwise. The baseline survives a pause; the state goes idle, as
    /// there is nothing to track.
    private func updateProbe() {
        guard let probe else { return }
        let wanted = isReading || takeStart != nil
        guard wanted != isProbing else { return }
        isProbing = wanted
        if wanted {
            probe.start { [weak self] reading in
                Task { @MainActor in self?.ingest(reading) }
            }
        } else {
            probe.stop()
            recent.removeAll()
            awaySince = nil
            closeAwaySpan()
            setState(.idle)
        }
    }

    func beginTake() {
        takeStart = Date()
        lastTick = takeStart
        lookingTime = 0
        awayTime = 0
        awaySpans = []
        openAwayStart = nil
        trackedFrom = nil
        updateProbe()
    }

    /// Ends the take; nil when too little of it was tracked to summarise.
    func endTake() -> TakeSummary? {
        tick()
        closeAwaySpan()
        defer { takeStart = nil; lastTick = nil; updateProbe() }
        let tracked = lookingTime + awayTime
        guard takeStart != nil, tracked >= Self.minimumTrackedTime else { return nil }
        return TakeSummary(
            lookingFraction: lookingTime / tracked,
            awaySpans: awaySpans,
            trackedFrom: trackedFrom ?? 0
        )
    }

    /// Credits the time since the last reading to the state it was spent in.
    private func tick() {
        guard let takeStart, let last = lastTick else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        lastTick = now
        if trackedFrom == nil, state == .looking || state == .away {
            trackedFrom = last.timeIntervalSince(takeStart)
        }
        switch state {
        case .looking: lookingTime += elapsed
        case .away: awayTime += elapsed
        case .idle, .calibrating: break
        }
    }

    func stop() {
        probe?.stop()
        probe = nil
        isProbing = false
        recent.removeAll()
        awaySince = nil
        awayOnset = nil
        reading = nil
        setState(.idle)
    }

    /// `@Published` announces every assignment, equal or not: only a real
    /// change may re-render observers.
    private func setState(_ new: State) {
        if state != new { state = new }
    }

    private func ingest(_ reading: GazeProbe.Reading?) {
        tick()
        self.reading = reading
        guard let reading, reading.eyeOpen > 0 else {
            recent.removeAll()
            update(isNarrow: true, isRecovered: false)
            return
        }

        recent.append(reading.eyeOpen)
        if recent.count > Self.smoothingCount { recent.removeFirst() }
        let opening = Self.median(recent)

        // Away readings are learned too. A real glance down is short, so it
        // barely moves a high percentile of ~25 s; but a baseline set too high
        // in the first seconds (wide eyes at the start of a take) would
        // otherwise hold the user "away" for the rest of it, as the window
        // could never relearn their normal reading look.
        if isReading {
            baselineSamples.append(opening)
            if baselineSamples.count > Self.baselineCapacity { baselineSamples.removeFirst() }
        }

        guard baselineSamples.count >= Self.baselineMinimum else {
            setState(isReading ? .calibrating : .idle)
            return
        }
        let baseline = Self.percentile(baselineSamples, Self.baselinePercentile)
        update(
            isNarrow: opening < baseline * (1 - Self.awayDrop),
            isRecovered: opening >= baseline * (1 - Self.returnDrop)
        )
    }

    private func update(isNarrow: Bool, isRecovered: Bool) {
        guard baselineSamples.count >= Self.baselineMinimum else {
            setState(isReading ? .calibrating : .idle)
            return
        }
        if isNarrow {
            let since = awaySince ?? Date()
            awaySince = since
            if state != .away, Date().timeIntervalSince(since) >= Self.awayDelay {
                let onset = since.addingTimeInterval(-Self.pipelineLag)
                awayOnset = onset
                if let start = takeStart {
                    openAwayStart = max(0, onset.timeIntervalSince(start))
                }
                // Credit the confirmation delay to away, not looking.
                if takeStart != nil {
                    let delay = Date().timeIntervalSince(onset)
                    let moved = min(delay, lookingTime)
                    lookingTime -= moved
                    awayTime += moved
                }
                setState(.away)
            }
        } else {
            awaySince = nil
            if isRecovered || state != .away {
                if state == .away { closeAwaySpan() }
                setState(.looking)
            }
        }
    }

    /// Ends the look-away in progress, if any, at the current moment.
    private func closeAwaySpan() {
        guard let start = openAwayStart, let takeStart else { return }
        openAwayStart = nil
        let end = max(start, Date().timeIntervalSince(takeStart))
        awaySpans.append(start...end)
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }
}
