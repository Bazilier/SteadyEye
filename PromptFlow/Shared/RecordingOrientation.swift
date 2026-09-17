import Foundation

/// How the capture pipeline is oriented for a take.
///
/// Persisted as a raw string under `appStorageKey`, matching the other user
/// settings in this app (`videoResolution`, `videoFPS`). A planned third mode —
/// a hardware-remote prompter — is one case here plus one picker row, with no
/// restructuring: nothing switches exhaustively on this type outside
/// `wantsLandscapeBuffer`.
///
/// Read once when the capture session is configured and frozen again at record
/// start. A change made while the recording screen is open does not reach the
/// running session, and a change mid-take cannot alter the writer canvas.
enum RecordingOrientation: String, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    /// UserDefaults / `@AppStorage` key. Unprefixed camelCase, as with the
    /// other recording settings.
    static let appStorageKey = "recordingOrientation"

    /// Portrait is the shipped behaviour and the fallback for any unset or
    /// unrecognised value — an unknown string must never silently change how
    /// capture is configured.
    static let fallback: RecordingOrientation = .portrait

    var id: String { rawValue }

    /// Reads the persisted mode. Used by the capture pipeline, which has no
    /// SwiftUI environment of its own.
    static func current(_ defaults: UserDefaults = .standard) -> RecordingOrientation {
        defaults.string(forKey: appStorageKey)
            .flatMap(RecordingOrientation.init(rawValue:)) ?? fallback
    }

    /// True when the connection should be driven to an angle that delivers a
    /// landscape-shaped buffer, and the writer canvas sized to match.
    var wantsLandscapeBuffer: Bool {
        switch self {
        case .portrait: return false
        case .landscape: return true
        }
    }
}
