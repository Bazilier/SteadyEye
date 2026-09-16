#if DEV
import Foundation

/// DEV-only in-memory mirror of the `CameraDiagnostic` os.Logger events.
///
/// Exists so a TestFlight tester without a Mac can read and copy the capture
/// diagnostics from Settings. The `os.Logger` calls remain the source of truth
/// and are NOT replaced — every `record(_:)` here sits alongside one.
///
/// Bounded ring buffer. Written from `sampleBufferQueue` and the camera queue,
/// read from the main thread, serialized on its own queue.
enum CameraDiagnosticsLog {
    struct Entry: Sendable {
        let time: Date
        let line: String
    }

    /// Roughly a dozen takes' worth of events; old entries are dropped.
    private static let capacity = 200
    nonisolated private static let queue = DispatchQueue(label: "com.steadyeye.diagnosticslog")
    nonisolated(unsafe) private static var entries: [Entry] = []

    /// Appends one event line. Cheap and non-blocking.
    nonisolated static func record(_ line: String) {
        let entry = Entry(time: Date(), line: line)
        queue.async {
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    nonisolated static func snapshot() -> [Entry] {
        queue.sync { entries }
    }

    nonisolated static func clear() {
        queue.async { entries.removeAll() }
    }
}
#endif
