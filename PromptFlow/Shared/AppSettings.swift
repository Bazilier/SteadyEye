import Foundation
import SwiftData
import AVFoundation

enum CameraPositionPreference: String, Codable {
    case front
    case back
}

@Model
final class AppSettings {
    /// Scroll speed as words-per-minute (e.g. 150)
    var scrollSpeed: Double
    /// Font size in points
    var fontSize: CGFloat
    /// Countdown before recording starts (0, 3, 5, or 10 seconds)
    var countdownDuration: Int
    /// Default camera to use
    var cameraPosition: CameraPositionPreference
    /// Whether eye contact mode is enabled (Phase 2 feature)
    var eyeContactModeEnabled: Bool

    init() {
        self.scrollSpeed = 150
        self.fontSize = 28
        self.countdownDuration = 3
        self.cameraPosition = .front
        self.eyeContactModeEnabled = false
    }
}
