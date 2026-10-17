import XCTest
@testable import PromptFlow

/// `////` section breaks: parsing, and the engine's hold / replay / next.
final class SectionBreakTests: XCTestCase {

    // MARK: - splitSections

    func testNoBreakIsOneSection() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("one two three"), ["one two three"])
    }

    func testSplitsAtFourSlashes() {
        let sections = MarkerPreprocessor.splitSections("First part.\n////\nSecond part.")
        XCTAssertEqual(sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                       ["First part.", "Second part."])
    }

    func testFlushBreakSplits() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("one////two"), ["one", "two"])
    }

    func testLongerRunIsOneBreak() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("one //////// two").count, 2)
    }

    func testFullWidthSlashesBreak() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("一つ／／／／二つ"), ["一つ", "二つ"])
    }

    func testEmptySectionsDropped() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("//// one //// //// two ////").count, 2)
    }

    func testThreeSlashesDoNotBreak() {
        XCTAssertEqual(MarkerPreprocessor.splitSections("one /// two").count, 1)
    }

    // MARK: - Neighbouring markers

    /// A `///` run of four used to leave a stray "/" chunk and a pause.
    func testFourSlashesAreNotALongPause() {
        let normalized = MarkerPreprocessor.normalizeMarkers("one //// two")
        XCTAssertEqual(normalized, "one //// two")
    }

    func testLongPauseStillParsesBesideABreak() {
        let sections = MarkerPreprocessor.splitSections("One. /// Two. //// Three.")
        let first = MarkerPreprocessor.splitIntoSegments(sections[0])
        XCTAssertEqual(first.map(\.text), ["One.", "Two."])
        XCTAssertEqual(first[1].extraPauseBefore, MarkerPreprocessor.longPauseSec)
    }

    // MARK: - Engine

    @MainActor
    private func loadedEngine(_ text: String) async -> ChunkPlayerEngine {
        let engine = ChunkPlayerEngine()
        engine.orpEnabled = true
        engine.sliderValue = 1.0
        engine.loadScript(text)
        await engine.loadTask?.value
        return engine
    }

    @MainActor
    private func waitForHold(_ engine: ChunkPlayerEngine) async throws {
        for _ in 0..<300 where engine.heldSection == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testSectionStarts() async {
        let engine = await loadedEngine("alpha beta //// gamma //// delta epsilon")
        XCTAssertEqual(engine.chunks, ["alpha", "beta", "gamma", "delta", "epsilon"])
        XCTAssertEqual(engine.sectionStarts, [0, 2, 3])
        XCTAssertEqual(engine.chunkRange(ofSection: 1), 2..<3)
        XCTAssertEqual(engine.chunkRange(ofSection: 2), 3..<5)
    }

    @MainActor
    func testLastWordOfSectionLingers() async {
        let engine = await loadedEngine("alpha beta //// alpha beta")
        let plain = await loadedEngine("alpha beta")
        let linger = ChunkPlayerEngine.sectionEndLingerSec
        XCTAssertEqual(engine.chunkDuration(at: 1) - plain.chunkDuration(at: 1), linger, accuracy: 0.001)
        XCTAssertEqual(engine.chunkDuration(at: 3) - plain.chunkDuration(at: 1), linger, accuracy: 0.001,
                       "The last section's last word lingers too")
        XCTAssertEqual(engine.chunkDuration(at: 0), plain.chunkDuration(at: 0), accuracy: 0.001)
    }

    @MainActor
    func testScriptWithoutBreaksDoesNotLinger() async {
        let plain = await loadedEngine("alpha beta")
        let other = await loadedEngine("beta alpha")
        XCTAssertEqual(plain.chunkDuration(at: 1), other.chunkDuration(at: 0), accuracy: 0.001)
    }

    @MainActor
    func testBreaksApplyToNonLatinScripts() async {
        let engine = await loadedEngine("مرحبا بكم //// شكرا لكم")
        XCTAssertEqual(engine.sectionCount, 2)
    }

    @MainActor
    func testHoldsOnLastWordOfSection() async throws {
        let engine = await loadedEngine("alpha beta //// gamma delta")
        engine.play()
        try await waitForHold(engine)
        XCTAssertEqual(engine.heldSection, 0)
        XCTAssertEqual(engine.currentChunkIndex, 1)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor
    func testReplayGoesBackAndCountsTakes() async throws {
        let engine = await loadedEngine("alpha beta //// gamma delta")
        engine.play()
        try await waitForHold(engine)

        engine.resolveHold(replay: true)
        XCTAssertNil(engine.heldSection)
        XCTAssertEqual(engine.currentChunkIndex, 0)
        XCTAssertEqual(engine.sectionTake, 2)
        XCTAssertFalse(engine.isPlaying, "Playing is the caller's, after its countdown")

        engine.play()
        try await waitForHold(engine)
        XCTAssertEqual(engine.sectionTake, 2, "A take lasts until the hold is resolved")

        engine.resolveHold(replay: false)
        XCTAssertEqual(engine.currentChunkIndex, 2)
        XCTAssertEqual(engine.sectionTake, 1)
    }

    @MainActor
    func testSeekWithinSectionKeepsTake() async throws {
        let engine = await loadedEngine("alpha beta gamma //// delta")
        engine.play()
        try await waitForHold(engine)
        engine.resolveHold(replay: true)
        engine.seekTo(index: 1)
        XCTAssertEqual(engine.sectionTake, 2)
        engine.seekTo(index: 3)
        XCTAssertEqual(engine.sectionTake, 1)
    }

    @MainActor
    func testPlayDuringHoldGoesOn() async throws {
        let engine = await loadedEngine("alpha beta //// gamma delta")
        engine.play()
        try await waitForHold(engine)
        engine.play()
        XCTAssertNil(engine.heldSection)
        XCTAssertEqual(engine.currentChunkIndex, 2)
        XCTAssertTrue(engine.isPlaying)
    }

    @MainActor
    func testLastSectionHoldsForReplayOnly() async throws {
        let engine = await loadedEngine("alpha //// beta")
        engine.play()
        try await waitForHold(engine)
        engine.resolveHold(replay: false)
        engine.play()
        try await waitForHold(engine)
        XCTAssertEqual(engine.heldSection, 1)
        XCTAssertTrue(engine.isHoldingLastSection)
        XCTAssertEqual(engine.progress, 1)
        XCTAssertFalse(engine.isPlaying)

        engine.resolveHold(replay: false)
        XCTAssertEqual(engine.heldSection, 1, "Nothing to go on to")

        engine.resolveHold(replay: true)
        XCTAssertEqual(engine.currentChunkIndex, 1)
        XCTAssertEqual(engine.sectionTake, 2)
    }

    @MainActor
    func testPlayAtLastHoldStartsOver() async throws {
        let engine = await loadedEngine("alpha //// beta")
        engine.play()
        try await waitForHold(engine)
        engine.resolveHold(replay: false)
        engine.play()
        try await waitForHold(engine)
        engine.play()
        XCTAssertNil(engine.heldSection)
        XCTAssertEqual(engine.currentChunkIndex, 0)
        XCTAssertTrue(engine.isPlaying)
    }

    @MainActor
    func testScriptWithoutBreaksEndsWithoutHold() async throws {
        let engine = await loadedEngine("alpha beta")
        engine.play()
        for _ in 0..<300 where engine.progress < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.progress, 1)
        XCTAssertNil(engine.heldSection)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor
    func testResetClearsHold() async throws {
        let engine = await loadedEngine("alpha beta //// gamma")
        engine.play()
        try await waitForHold(engine)
        engine.reset()
        XCTAssertNil(engine.heldSection)
        XCTAssertEqual(engine.sectionTake, 1)
        XCTAssertEqual(engine.currentChunkIndex, 0)
    }
}
