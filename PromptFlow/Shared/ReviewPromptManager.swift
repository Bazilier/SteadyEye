import Foundation
import UIKit

/// Eligibility and side effects for the satisfaction pre-prompt shown after
/// the first Camera Roll save of a recording made from a user-written script.
///
/// Replaces the native `SKStoreReviewController` prompt. Apple's review
/// guidelines discourage putting a pre-prompt in front of the system dialog,
/// so the Yes branch opens a `?action=write-review` URL instead: no
/// three-per-year cap, no silent no-op, and it works in TestFlight.
///
/// The prompt itself is `SatisfactionPromptView`; the arbiter is wired at the
/// call site in `VideoPreviewView`, matching the soft-ask.
@MainActor
enum ReviewPromptManager {
    /// Count of successful (finished + saved) recordings. Still maintained —
    /// it is a usage signal in its own right — but it no longer gates the
    /// prompt, whose trigger is now the first own-script Camera Roll save.
    private static let successfulRecordingCountKey = "successful_recording_count"

    /// Burned once the user answers Yes: they have been sent to the App Store
    /// and the prompt never returns. Deliberately NOT
    /// `postFirstOwnRecordingPaywallShown`, which is written only when the
    /// paywall actually appears and so is always false for subscribers.
    /// Codebase convention is unprefixed camelCase (see `installDate`,
    /// `notificationSoftAskShown`).
    private static let answeredYesKey = "satisfactionPromptAnsweredYes"

    /// `timeIntervalSince1970` of the last time the sheet actually reached the
    /// screen — written from its `onAppear`, not when it merely became
    /// eligible.
    private static let lastShownKey = "satisfactionPromptLastShownAt"

    /// Re-ask window after a No or a silent dismissal. Both are treated the
    /// same: neither is a yes, and neither is a reason to never ask again.
    private static let retryInterval: TimeInterval = 14 * 86400

    /// App Store ID 6761066976 — see `AppsFlyerAttributionProvider.appleAppID`.
    private static let writeReviewURL = URL(
        string: "https://apps.apple.com/app/id6761066976?action=write-review"
    )

    /// Call once per SUCCESSFUL recording (finished + saved). Counting only —
    /// never presents.
    static func recordSuccessfulRecording() {
        let newCount = UserDefaults.standard.integer(forKey: successfulRecordingCountKey) + 1
        UserDefaults.standard.set(newCount, forKey: successfulRecordingCountKey)
    }

    /// Remote Config gate for the whole satisfaction flow. Off by default, so
    /// a fresh install with no fetched config — and any install under App
    /// Store review — behaves as if the feature does not exist. There is no
    /// fallback when off: the native prompt is gone and is not coming back,
    /// and the post-save slot simply does nothing.
    ///
    /// Modelled on `chat_enabled_for` (see `ExperimentManager`): a live,
    /// non-sticky read of a string parameter whose default is declared in
    /// `RemoteConfigManager.defaults`, so flipping it in the console takes
    /// effect without an app update.
    ///
    /// One deliberate inversion from that model. The chat gate falls through
    /// to PERMISSIVE on an unrecognised value, so a console typo cannot hide
    /// a shipped feature. This gate falls through to CLOSED: its entire
    /// purpose is to keep the prompt off during review, so anything we cannot
    /// positively read as "on" must mean off.
    ///
    /// Canonical value is `"on"`; `"true"` is accepted so a plausible console
    /// entry is not a silent no-op. Everything else — the seeded `"off"`, an
    /// empty value, a typo — leaves the prompt disabled.
    static var isSatisfactionPromptEnabled: Bool {
        let raw = RemoteConfigManager.shared
            .string("review_prompt_enabled")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "on" || raw == "true"
    }

    /// Asked immediately before presenting the satisfaction sheet.
    ///
    /// `isUserWrittenScript` is the origin bit — `!isDemo && !isSample`,
    /// the same definition the first-own-recording paywall uses. It arrives as
    /// its own parameter rather than being inferred, because the only other
    /// carrier of it (`shouldShowPaywallAfterSave`) fuses it with subscription
    /// state and the paywall's one-shot flag.
    ///
    /// A `false` answer means the caller must NOT present and must NOT burn
    /// any flag — the prompt tries again at its next natural opportunity.
    static func shouldPresentSatisfactionPrompt(isUserWrittenScript: Bool) -> Bool {
        guard isSatisfactionPromptEnabled else { return false }
        guard isUserWrittenScript else { return false }
        guard !UserDefaults.standard.bool(forKey: answeredYesKey) else { return false }

        if let lastShown = lastShownTimestamp() {
            let windowStart = retryWindowStart(lastShown: lastShown)
            guard (Date().timeIntervalSince1970 - windowStart) >= retryInterval else { return false }
        }

        return PromptArbiter.shared.canPresent(.reviewPrompt)
    }

    /// Records that the sheet reached the screen. Called from its `onAppear`.
    static func notePresented() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastShownKey)
    }

    /// Records a Yes. The prompt never shows again on this install.
    static func noteAnsweredYes() {
        UserDefaults.standard.set(true, forKey: answeredYesKey)
    }

    static func openWriteReviewPage() {
        guard let writeReviewURL else { return }
        UIApplication.shared.open(writeReviewURL)
    }

    private static func lastShownTimestamp() -> Double? {
        let value = UserDefaults.standard.double(forKey: lastShownKey)
        return value > 0 ? value : nil
    }

    /// The moment the 14-day re-ask window counts from.
    ///
    /// Normally the last time the sheet appeared. But if the user answered No,
    /// landed in the founder chat and has written since, the window restarts
    /// from that message — re-asking someone who is mid-conversation reads as
    /// not listening.
    ///
    /// Read from `ChatStorage`, the on-device cache the chat already keeps, so
    /// this costs NO network call and cannot block or fail. `.inbound` is the
    /// user's own side of the thread (see `ChatUnreadTracker`). A message the
    /// cache has not caught up with yet only ever delays the next prompt, and
    /// only until the chat is next opened.
    private static func retryWindowStart(lastShown: Double) -> Double {
        let lastUserMessage = ChatStorage.load()
            .filter { $0.direction == .inbound }
            .map { $0.createdAt.timeIntervalSince1970 }
            .max()
        guard let lastUserMessage, lastUserMessage > lastShown else { return lastShown }
        return lastUserMessage
    }
}
