import Foundation
import AVFoundation
import Combine

/// Owns the `AVPlayer` and its observer lifecycle for the
/// `VideoPreviewView` chrome (scrubber + time labels). Replaces the
/// previously inline state on the View struct so the player layer can
/// stay isolated from the View's other concerns (save, delete, top
/// bar). Pairs with the custom scrubber UI: the periodic time
/// observer drives `currentTime`, KVO on `timeControlStatus` keeps
/// `isPlaying` synced with the SDK's actual state, and `isScrubbing`
/// is the gate that prevents the time observer from fighting the
/// user's drag.
///
/// All public properties are `@Published` so SwiftUI views can bind
/// directly. `player` is exposed `private(set)` so the
/// `CustomVideoPlayer` `UIViewRepresentable` can attach the layer
/// without the View also being able to mutate it.
final class PlaybackController: ObservableObject {
    /// The underlying player. `nil` before `setup(url:initialDuration:)`
    /// runs and after `teardown()` returns. Marked `@Published` so a
    /// View bound to the controller re-renders when the player
    /// becomes available (the `if let player` mount of
    /// `CustomVideoPlayer`).
    @Published private(set) var player: AVPlayer?

    /// Current playhead, in seconds. Updated ~30Hz by the periodic
    /// time observer while `isScrubbing` is false. While the user
    /// drags the scrubber thumb the View drives a local scrub-state
    /// that mirrors this, so we don't write here mid-drag.
    ///
    /// Not published here: at 30 Hz it re-rendered the whole preview
    /// screen. The scrubber and the time readout observe `clock`.
    var currentTime: Double = 0 {
        didSet { if clock.time != currentTime { clock.time = currentTime } }
    }
    /// `currentTime`, published on its own for the views that show it.
    let clock = PlaybackClock()

    /// Total length of the recording, in seconds — what the scrubber
    /// maps its track to and what the total-time readout displays.
    ///
    /// Seeded at `setup` from the caller's `initialDuration` and then
    /// replaced by the asset's own duration as soon as `load(.duration)`
    /// resolves. The seed is wall-clock recording time, which overstates
    /// the file: the interval starts when the user taps record, before
    /// the writer is built and before the first frame lands. It is kept
    /// only as a safe non-zero denominator for the brief load window
    /// (and as the fallback if the asset can't report a usable
    /// duration) — it is not the answer.
    @Published var duration: Double = 0

    /// Mirrors `player.timeControlStatus == .playing`. Driven by KVO
    /// so it stays accurate across all paths: manual toggle,
    /// end-of-item pause, scrub-induced pause, audio-interruption
    /// pause, etc.
    @Published var isPlaying: Bool = false

    /// True while the user is actively dragging the scrubber thumb.
    /// Set/cleared by `beginScrubbing()` / `endScrubbing()`. Read by
    /// the periodic time observer to suppress `currentTime` writes
    /// during a drag.
    @Published var isScrubbing: Bool = false
    /// True once the take has played through to its last frame — the
    /// moment the user has actually watched it.
    @Published private(set) var didPlayToEnd: Bool = false
    /// True while the user holds the video and it plays at
    /// `fastForwardRate`.
    @Published private(set) var isFastForwarding: Bool = false
    private var wasPlayingBeforeFastForward: Bool = false

    static let fastForwardRate: Float = 2

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// In-flight asset-duration load started by `setup`. Cancelled on
    /// re-`setup` and in `teardown` so a dismissed preview doesn't leave
    /// a task holding the asset.
    private var durationLoadTask: Task<Void, Never>?
    /// Captured at `beginScrubbing()` so `endScrubbing()` can decide
    /// whether to resume playback. If the user paused before
    /// dragging, we leave the player paused after release.
    private var wasPlayingBeforeScrub: Bool = false

    // MARK: - Lifecycle

    /// Creates the player, attaches observers, and starts playback.
    /// Idempotent only insofar as the caller pairs each `setup` with
    /// a `teardown` — calling twice without teardown leaks observers.
    func setup(url: URL, initialDuration: TimeInterval) {
        setup(item: AVPlayerItem(url: url), initialDuration: initialDuration)
    }

    /// Same as `setup(url:initialDuration:)` for a prepared item — the
    /// Studio Sound composition, which carries both soundtracks.
    func setup(item: AVPlayerItem, initialDuration: TimeInterval) {
        didPlayToEnd = false
        duration = initialDuration
        currentTime = 0
        isPlaying = false

        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        // Periodic time observer drives `currentTime` for the
        // scrubber UI. ~30Hz refresh — fast enough that the thumb
        // moves smoothly, slow enough that the publish overhead is
        // negligible. Skipped while scrubbing so we don't fight the
        // user's drag with stale player positions.
        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = CMTimeGetSeconds(time)
        }

        observeEnd(of: item)

        // KVO on `timeControlStatus`: single source of truth for
        // `isPlaying`. Catches every transition path (manual toggle,
        // end-of-item, scrub pause, system audio interruption,
        // backgrounding) without needing to mirror state in each
        // call site. KVO callback fires on whichever thread the SDK
        // chose, so we hop to main before touching the @Published
        // property.
        statusObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let nowPlaying = (player.timeControlStatus == .playing)
            DispatchQueue.main.async {
                self?.isPlaying = nowPlaying
            }
        }

        // Replace the wall-clock seed with what the file actually
        // contains. The synchronous `AVAsset.duration` is deprecated on
        // this deployment target, so this goes through the async
        // `load(.duration)` property — the same pattern VideoPreviewView
        // already uses to read `naturalSize` / `preferredTransform`.
        //
        // Runs on the main actor (inherited from this type's isolation),
        // which is where the `@Published` write has to happen anyway.
        // If the load fails, or reports a non-numeric or non-positive
        // time, the seeded value stands — a slightly long duration beats
        // 0 or NaN.
        durationLoadTask?.cancel()
        durationLoadTask = Task { [weak self] in
            guard let item = avPlayer.currentItem,
                  let loaded = try? await item.asset.load(.duration),
                  loaded.isNumeric,
                  loaded.seconds > 0 else { return }
            // A late completion must not clobber a newer presentation:
            // only write if this is still the player we loaded for.
            guard let self, self.player === avPlayer else { return }
            self.duration = loaded.seconds
        }

        avPlayer.play()
    }

    /// Pause at the last frame on end-of-item. Does NOT seek to
    /// zero and does NOT resume playback — the user explicitly
    /// chose this over the previous auto-loop behavior. Tapping
    /// play after end will seek to zero (handled in
    /// togglePlayPause).
    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player?.pause()
            self.didPlayToEnd = true
            // The periodic observer above ticks at 1/30s, so its last
            // tick before the end can land just short of `duration` and
            // leave the thumb inside the track on a finished video.
            // Snap it so "played to the end" reads as played to the end.
            self.currentTime = self.duration
        }
    }

    /// Swaps in a new item for the same video — Studio Sound becoming ready
    /// while the preview is open — keeping the playhead and play state.
    func replaceItem(with item: AVPlayerItem) {
        guard let player else { return }
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    /// Switches the soundtrack of the current item without a pause.
    func setAudioMix(_ mix: AVAudioMix?) {
        player?.currentItem?.audioMix = mix
    }

    /// Removes observers and pauses the player. Safe to call when
    /// `setup` was never invoked.
    func teardown() {
        durationLoadTask?.cancel()
        durationLoadTask = nil

        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        statusObservation?.invalidate()
        statusObservation = nil

        isFastForwarding = false

        player?.pause()
        player = nil
    }

    // MARK: - Playback control

    /// Toggles between play and pause. If the playhead is at the end
    /// (within a small epsilon of `duration`), seeks to zero before
    /// playing — replaces the previous auto-loop behavior with a
    /// user-initiated restart.
    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    // MARK: - Hold to speed up

    /// Plays at `fastForwardRate` while the video is held — from a pause
    /// too, and from the start once it has played to the end.
    func beginFastForward() {
        guard let player, !isFastForwarding else { return }
        wasPlayingBeforeFastForward = player.timeControlStatus == .playing
        if currentTime >= duration - 0.05 {
            player.seek(to: .zero)
        }
        isFastForwarding = true
        player.rate = Self.fastForwardRate
    }

    /// Back to normal speed on release, or back to the pause it started
    /// from. One that ran to the end stays there.
    func endFastForward() {
        guard let player, isFastForwarding else { return }
        isFastForwarding = false
        if wasPlayingBeforeFastForward, currentTime < duration - 0.05 {
            player.rate = 1
        } else {
            player.pause()
        }
    }

    // MARK: - Scrubbing

    /// Called on the first `.onChanged` of the scrubber's drag
    /// gesture. Pauses the player and remembers whether playback was
    /// active so `endScrubbing` can decide whether to resume.
    func beginScrubbing() {
        guard let player else { return }
        wasPlayingBeforeScrub = (player.timeControlStatus == .playing)
        player.pause()
        isScrubbing = true
    }

    /// Seeks to the given second offset without resuming playback.
    /// Uses zero tolerance so the displayed frame matches the
    /// scrubber thumb position exactly — slightly more expensive
    /// than tolerant seeks but feels precise during drag.
    func scrub(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, seconds)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Called on `.onEnded` of the scrubber drag. Clears the
    /// scrubbing flag and resumes playback iff the user was playing
    /// when they started the drag.
    func endScrubbing() {
        isScrubbing = false
        if wasPlayingBeforeScrub {
            player?.play()
        }
    }
}

/// The playhead alone, so only the views that show it re-render at the
/// periodic observer's rate (see `PlaybackController.currentTime`).
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}
