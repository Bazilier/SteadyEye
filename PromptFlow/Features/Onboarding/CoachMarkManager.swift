import SwiftUI
import Combine

/// Manages 3-step coach mark onboarding across editor and recording screens.
final class CoachMarkManager: ObservableObject {
    static let shared = CoachMarkManager()

    @Published var currentStep: Int = 0
    @Published var isActive: Bool = false
    @Published var spotlightFrames: [Int: CGRect] = [:]

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    private init() {}

    func startIfNeeded() {
        if !hasSeenOnboarding {
            currentStep = 1
            isActive = true
        }
    }

    func advance() {
        currentStep += 1
    }

    func complete() {
        isActive = false
        hasSeenOnboarding = true
    }

    func registerFrame(_ frame: CGRect, for step: Int) {
        spotlightFrames[step] = frame
    }

    var currentTooltip: CoachTooltip? {
        CoachTooltip.all[currentStep]
    }
}

struct CoachTooltip {
    let text: String
    let buttonText: String
    let position: Position
    let screen: Screen

    enum Position { case above, below }
    enum Screen { case editor, recording }

    static let all: [Int: CoachTooltip] = [
        1: CoachTooltip(
            text: "AI cleans up your script for the teleprompter",
            buttonText: "Next", position: .above, screen: .editor),
        2: CoachTooltip(
            text: "Drag left and right to position under your camera",
            buttonText: "Next", position: .below, screen: .recording),
        3: CoachTooltip(
            text: "Long press and drag up or down\nto fine-tune text height",
            buttonText: "Done", position: .below, screen: .recording),
    ]
}
