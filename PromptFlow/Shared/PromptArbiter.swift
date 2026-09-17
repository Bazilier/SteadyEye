import Foundation

/// Single gatekeeper for AUTOMATIC prompts — the ones the app decides to show
/// on its own: the cold-start paywall, the first-own-recording paywall, the
/// notification soft-ask and the App Store review prompt.
///
/// User-initiated surfaces (crown taps, Settings rows, the record-button
/// paywall) are never blocked; they only report themselves through
/// `noteExternalPresentation(isPaywall:)` so the gap and the
/// "a paywall already happened this session" rule stay accurate.
@MainActor
final class PromptArbiter {
    static let shared = PromptArbiter()
    private init() {}

    enum PromptKind {
        case coldStartPaywall
        case firstOwnRecordingPaywall
        case notificationSoftAsk
        case reviewPrompt

        var isPaywall: Bool {
            switch self {
            case .coldStartPaywall, .firstOwnRecordingPaywall: return true
            case .notificationSoftAsk, .reviewPrompt: return false
            }
        }
    }

    /// Timestamp of the last prompt of any kind, persisted so the gap survives
    /// a relaunch.
    private static let lastPromptAtKey = "lastAutoPromptAt"
    /// Minimum spacing between two prompts, of any kind.
    private static let minimumGap: TimeInterval = 60

    /// True between `didPresent` and `didDismiss`. In memory only.
    private(set) var isPromptVisible = false
    /// True once any paywall has been shown in this process. In memory only:
    /// the review prompt yields to a paywall for the rest of the session, and
    /// the slate is clean on the next launch.
    private(set) var paywallShownThisSession = false

    private var lastPromptAt: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: Self.lastPromptAtKey)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastPromptAtKey)
        }
    }

    /// Asked immediately before presenting. A `false` answer means the caller
    /// must NOT present and must NOT burn any one-shot flag — the prompt is
    /// expected to try again at its next natural opportunity.
    func canPresent(_ kind: PromptKind) -> Bool {
        if isPromptVisible {
            log("deny \(kind) — another prompt is visible")
            return false
        }
        if let last = lastPromptAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < Self.minimumGap {
                log("deny \(kind) — only \(Int(elapsed))s since the last prompt")
                return false
            }
        }
        if kind == .reviewPrompt, paywallShownThisSession {
            log("deny reviewPrompt — a paywall was shown this session")
            return false
        }
        log("allow \(kind)")
        return true
    }

    func didPresent(_ kind: PromptKind) {
        isPromptVisible = true
        lastPromptAt = Date()
        if kind.isPaywall { paywallShownThisSession = true }
        log("present \(kind)")
    }

    func didDismiss() {
        isPromptVisible = false
        log("dismiss")
    }

    /// Reports a surface the arbiter did not gate — a user-initiated paywall or
    /// the ATT dialog — so it still counts toward the gap. Never blocks.
    func noteExternalPresentation(isPaywall: Bool) {
        lastPromptAt = Date()
        if isPaywall { paywallShownThisSession = true }
        log("external presentation (paywall=\(isPaywall))")
    }

    private func log(_ message: String) {
        #if DEBUG
        print("PROMPT-ARBITER \(message)")
        #endif
    }
}
