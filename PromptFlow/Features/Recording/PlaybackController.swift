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
    @Published var currentTime: Double = 0

    /// Total length of the recording, in seconds. Seeded from
    /// `Recording.duration` at `setup` time so the scrubber's max
    /// bound is correct on the first frame (no async wait on
    /// `currentItem.duration`).
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

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// Captured at `beginScrubbing()` so `endScrubbing()` can decide
    /// whether to resume playback. If the user paused before
    /// dragging, we leave the player paused after release.
    private var wasPlayingBeforeScrub: Bool = false

    // MARK: - Lifecycle

    /// Creates the player, attaches observers, and starts playback.
    /// Idempotent only insofar as the caller pairs each `setup` with
    /// a `teardown` — calling twice without teardown leaks observers.
    func setup(url: URL, initialDuration: TimeInterval) {
        duration = initialDuration
        currentTime = 0
        isPlaying = false

        let avPlayer = AVPlayer(url: url)
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

        // Pause at the last frame on end-of-item. Does NOT seek to
        // zero and does NOT resume playback — the user explicitly
        // chose this over the previous auto-loop behavior. Tapping
        // play after end will seek to zero (handled in
        // togglePlayPause).
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.pause()
        }

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

        avPlayer.play()
    }

    /// Removes observers and pauses the player. Safe to call when
    /// `setup` was never invoked.
    func teardown() {
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
