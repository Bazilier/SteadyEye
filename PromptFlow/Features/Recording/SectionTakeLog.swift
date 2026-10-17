import CoreMedia

/// The takes of a recording's `////` sections, on the capture clock, and
/// the parts of the file to keep: the last take of each section.
struct SectionTakeLog {
    struct Take: Equatable {
        let section: Int
        let start: CMTime
        var end: CMTime?
    }

    private(set) var takes: [Take] = []

    /// Speech starts a little after the first word appears; a take is kept
    /// from this long before it began.
    static let leadInSec: Double = 0.3

    var hasOpenTake: Bool { takes.last.map { $0.end == nil } ?? false }

    /// A new take of `section`. One still open ends here: it was cut short.
    mutating func begin(section: Int, at time: CMTime) {
        end(at: time)
        takes.append(Take(section: section, start: time))
    }

    mutating func end(at time: CMTime) {
        guard hasOpenTake else { return }
        takes[takes.count - 1].end = time
    }

    /// The last take of each section, in recording order, in seconds of the
    /// file whose first frame is at `firstFrame`. A take still open runs to
    /// `fileEnd`. Nil when nothing was taken.
    func keptRanges(firstFrame: CMTime, fileEnd: Double) -> [ClosedRange<Double>]? {
        var lastBySection: [Int: Take] = [:]
        for take in takes { lastBySection[take.section] = take }
        let kept = lastBySection.values.sorted { CMTimeCompare($0.start, $1.start) < 0 }

        var ranges: [ClosedRange<Double>] = []
        for take in kept {
            let start = max(0, CMTimeSubtract(take.start, firstFrame).seconds - Self.leadInSec)
            let end = min(take.end.map { CMTimeSubtract($0, firstFrame).seconds } ?? fileEnd, fileEnd)
            // Never back into the previous kept part.
            let from = max(start, ranges.last?.upperBound ?? 0)
            guard end > from else { continue }
            ranges.append(from...end)
        }
        return ranges.isEmpty ? nil : ranges
    }
}
