import Foundation
import Combine
import os
import RevenueCat
import FirebaseAnalytics

enum PurchaseOutcome {
    case succeeded(isTrial: Bool)
    case failed(reason: String)
    case userCancelled
}

/// Lifecycle of the paywall data prewarm (offerings + intro-offer eligibility).
/// The paywall reads this to know whether the data it needs is already settled.
enum PrewarmState {
    /// User holds the `access` entitlement, so paywall data is never needed and
    /// no network work was done. NOT a failure.
    case skipped
    /// Nothing attempted yet, or invalidated by an entitlement change.
    case idle
    case loading
    case ready
    case failed(Error)
}

enum PrewarmError: Error {
    /// `loadOfferings()` returned without populating `offerings`.
    case offeringsUnavailable
    /// Offerings loaded but no candidate offering exposed an annual product.
    case noAnnualProducts
}

/// Manages subscription state via RevenueCat.
/// In DEV builds, all features are unlocked without RC calls.
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    static var devMode: Bool {
        #if DEV
        return true
        #else
        return false
        #endif
    }

    /// The actual RevenueCat-derived subscription state. In DEV builds this is
    /// forced to `true` by `configure()`. Use the computed `isSubscribed` for
    /// gating decisions — it consults `devSubscriptionOverride` first.
    @Published private(set) var isSubscribedReal: Bool = false
    @Published var isTrialActive: Bool = false
    @Published var offerings: Offerings?
    @Published var isLoading: Bool = false

    /// Prewarmed intro-offer eligibility, keyed by product identifier. Written
    /// only by `prewarmPaywallData()`; the paywall reads it and falls back to
    /// its own query on a miss.
    @Published private(set) var trialEligibility: [String: IntroEligibilityStatus] = [:]

    /// Single signal the UI reads to know whether paywall data is settled.
    @Published private(set) var prewarmState: PrewarmState = .idle

    /// Last `access` state observed by the customerInfoStream listener. `nil`
    /// until the first observation, so the launch tick is never mistaken for a
    /// held -> not-held transition.
    private var lastObservedEntitlementActive: Bool?

    /// Latch for "the first CustomerInfo has been applied". `isSubscribedReal`
    /// starts `false`, so anything that must not mistake a subscriber for a
    /// free user has to wait for this rather than read the initial value.
    private var hasResolvedEntitlement = false
    private var entitlementWaiters: [CheckedContinuation<Void, Never>] = []

    /// Internal change-detection flag for the customerInfoStream listener.
    /// Compared against the latest customerInfo's trial state on each tick
    /// to detect free→trial and trial→ended transitions, which drive the
    /// trial-related local notifications. Initialized after the first
    /// `checkAccess()` so the listener doesn't false-fire on launch.
    ///
    /// PERSISTED across launches. A trial converts ~7 days after it starts,
    /// while the app is not running, so an in-memory-only flag would read
    /// `false` on the next cold launch and the trial→paid branch would never
    /// fire. Persisting is also what makes `trial_converted` fire at most once:
    /// the flip to `false` survives the process, so a later tick for the same
    /// transition no longer satisfies `wasInTrial`.
    private var lastObservedTrialState: Bool =
        UserDefaults.standard.bool(forKey: SubscriptionManager.trialStateKey)
    {
        didSet {
            UserDefaults.standard.set(lastObservedTrialState, forKey: Self.trialStateKey)
            // Any write — from `checkAccess()`'s first-launch seed or from the
            // stream listener's edge detection — counts as seeded, so the seed
            // can never fire after an observation has already been recorded.
            UserDefaults.standard.set(true, forKey: Self.trialStateSeededKey)
        }
    }

    static let trialStateKey = "lastObservedTrialState"

    /// Marks that `lastObservedTrialState` holds a real observation. Kept
    /// separate from the value because `false` is a legitimate persisted state
    /// and therefore cannot itself signal "never written".
    static let trialStateSeededKey = "lastObservedTrialStateSeeded"

    /// DEV-only escape hatch for testing freemium gating without buying or
    /// cancelling a sandbox subscription. Values: "off", "free", "subscribed".
    /// Ignored entirely in Release builds. Persisted in UserDefaults so the
    /// override survives app restarts during a test session.
    @Published var devSubscriptionOverride: String =
        UserDefaults.standard.string(forKey: "devSubscriptionOverride") ?? "free"
    {
        didSet {
            UserDefaults.standard.set(devSubscriptionOverride, forKey: "devSubscriptionOverride")
        }
    }

    /// Effective subscription state, consulted by every gate. In DEV: respects
    /// the override; "off" falls through to `Self.devMode || isSubscribedReal`
    /// so DEV builds without the override remain fully unlocked. In Release:
    /// always the real RC value.
    var isSubscribed: Bool {
        #if DEV
        switch devSubscriptionOverride {
        case "subscribed": return true
        case "free": return false
        default: return Self.devMode || isSubscribedReal
        }
        #else
        return isSubscribedReal
        #endif
    }

    // MARK: - AI optimization daily limits

    /// Free tier: 1 optimize per calendar day. timeIntervalSince1970 of last use; 0 = never used.
    @Published var lastAIOptimizeDateInterval: Double = UserDefaults.standard.double(forKey: "lastAIOptimizeDate")

    /// Pro tier: 30 optimizes per calendar day.
    static let proOptimizationsPerDay = 30

    /// Pro counter — raw stored count. Reads zero on a new day even before
    /// `recordOptimizationUse()` runs (see `proOptimizationsToday`).
    @Published var proOptimizationsCount: Int = UserDefaults.standard.integer(forKey: "proOptimizationsCount")

    /// Effective Pro count for today. Returns 0 if the stored reset date is
    /// not today, so the view layer always shows the correct remaining quota
    /// even if no use has happened yet on the new day.
    var proOptimizationsToday: Int {
        let storedReset = UserDefaults.standard.double(forKey: "proOptimizationsResetDate")
        let resetDate = Date(timeIntervalSince1970: storedReset)
        if !Calendar.current.isDateInToday(resetDate) {
            return 0
        }
        return proOptimizationsCount
    }

    var canOptimizeAsPro: Bool {
        proOptimizationsToday < Self.proOptimizationsPerDay
    }

    func recordOptimizationUse() {
        if isSubscribed {
            // Pro path: increment the daily counter, resetting if we crossed midnight.
            let today = Calendar.current.startOfDay(for: Date())
            let storedReset = UserDefaults.standard.double(forKey: "proOptimizationsResetDate")
            let resetDate = Date(timeIntervalSince1970: storedReset)
            let newCount: Int
            if !Calendar.current.isDate(resetDate, inSameDayAs: today) {
                UserDefaults.standard.set(today.timeIntervalSince1970, forKey: "proOptimizationsResetDate")
                newCount = 1
            } else {
                newCount = proOptimizationsCount + 1
            }
            proOptimizationsCount = newCount
            UserDefaults.standard.set(newCount, forKey: "proOptimizationsCount")
        } else {
            // Free path: stamp today's date.
            let now = Date().timeIntervalSince1970
            lastAIOptimizeDateInterval = now
            UserDefaults.standard.set(now, forKey: "lastAIOptimizeDate")
        }
    }

    // MARK: - Feature access
    //
    // All gates flow through the computed `isSubscribed` (above), which already
    // folds in `Self.devMode` and `devSubscriptionOverride`. Don't add another
    // `Self.devMode ||` short-circuit here — it would defeat the DEV override.

    /// FREEMIUM: recording is not entitlement-gated. Free users may record
    /// their own scripts, watermarked — the free/paid difference is
    /// `showWatermark` (below), not access. Unchanged from what ships today.
    ///
    /// TRIAL MODE: stricter. Once an install is FROZEN into trial mode, an
    /// inactive entitlement makes recording unavailable entirely — no
    /// watermarked path, no demo path. This covers both a consumed trial and a
    /// declined one; the product treats them alike.
    ///
    /// HYBRID MODE: deliberately NOT matched by the test below, and the test is
    /// `== .trial` rather than `!= .default` precisely to express that.
    /// `.hybrid` presents the same free trial as `.trial`, but once the
    /// entitlement lapses it falls back to FREEMIUM gating — recording stays
    /// available, watermarked. Post-expiry behaviour is the only thing
    /// separating the two modes, so widening this test to `!= .default` would
    /// erase the distinction entirely. The omission is the feature.
    ///
    /// Gated on `persistedMode`, never on `PaywallConfig.mode`: the latter falls
    /// back to a live Remote Config read before the mode is frozen, and the
    /// stricter rules must never bite an install that has not committed to
    /// trial. `nil` (not frozen) therefore behaves as freemium.
    var canRecord: Bool {
        if PaywallConfig.persistedMode == .trial, !isSubscribed { return false }
        return true
    }
    var canOptimizeToday: Bool {
        if isSubscribed {
            return canOptimizeAsPro
        }
        if lastAIOptimizeDateInterval == 0 { return true }
        let lastDate = Date(timeIntervalSince1970: lastAIOptimizeDateInterval)
        return !Calendar.current.isDateInToday(lastDate)
    }
    var canBulkImport: Bool { isSubscribed }
    var canRecord4K: Bool { isSubscribed }
    var canUseStabilization: Bool { isSubscribed }
    var showWatermark: Bool { !isSubscribed }

    private init() {}

    // MARK: - Analytics user property

    /// Sets Firebase's `subscription_state` user property to one of
    /// `free` / `trial` / `subscribed`. Once set, the property attaches
    /// to every subsequent event automatically, so any analytics query
    /// can pivot by sub state without joining a separate user table.
    /// Called from configure-time first resolution (`checkAccess`),
    /// every customerInfoStream tick, and the restore-success path.
    /// No-op in DEV (matches AppAnalytics.log gating).
    private func updateAnalyticsSubscriptionState() {
        #if !DEV
        let state: String
        if isSubscribed {
            state = isTrialActive ? "trial" : "subscribed"
        } else {
            state = "free"
        }
        Analytics.setUserProperty(state, forName: "subscription_state")
        #endif
    }

    // MARK: - Configuration

    func configure() {
        #if DEV
        isSubscribedReal = true
        return
        #else
        Task {
            // Sequenced, not concurrent: `prewarmPaywallData()` must read a
            // resolved entitlement, and `checkAccess()` is the CustomerInfo
            // fetch already in flight — so prewarm waits on that one rather
            // than issuing a second. Offerings are no longer loaded
            // unconditionally here; prewarm loads them, and only for users who
            // can actually see a paywall.
            await checkAccess()
            await prewarmPaywallData()
        }
        // Long-running listener on RC's customerInfoStream. Fires whenever
        // RevenueCat detects an entitlement change — renewal, expiration,
        // refund, family-sharing change, restore from another device.
        // Loop never exits naturally; the singleton lives for the app's
        // lifetime, so the implicit "leak" is intentional. `@MainActor` keeps
        // the @Published writes on main.
        //
        // Skip spawning the listener if Purchases wasn't configured upstream
        // (e.g. missing apiKey in a CI build) — touching customerInfoStream
        // would fatal-error.
        guard Purchases.isConfigured else {
            print("⚠️ customerInfoStream listener skipped — Purchases not configured")
            return
        }
        Task { @MainActor in
            for await customerInfo in Purchases.shared.customerInfoStream {
                let entitlement = customerInfo.entitlements[Self.entitlementID]
                self.isSubscribedReal = entitlement?.isActive == true
                self.isTrialActive = entitlement?.periodType == .trial
                self.updateAnalyticsSubscriptionState()
                // The stream emits RC's CACHED CustomerInfo immediately, so this
                // is usually what resolves the latch first — ahead of
                // `checkAccess()`, which suspends on the network.
                self.markEntitlementResolved()

                // Entitlement transition. Only held -> not-held re-arms the
                // prewarm: expiry, a cancellation taking effect, or a restore
                // onto a lapsed account. `nil` means "not observed yet", so the
                // launch tick cannot be mistaken for a transition and cannot
                // re-run a prewarm that is already `.ready`.
                let nowEntitled = entitlement?.isActive == true
                let wasEntitled = self.lastObservedEntitlementActive
                self.lastObservedEntitlementActive = nowEntitled
                if wasEntitled == true && !nowEntitled {
                    self.invalidatePrewarmForEntitlementChange()
                }

                // Trial-state edge detection. `lastObservedTrialState`
                // is seeded by checkAccess on launch so the very first
                // tick here reflects a real change, not the initial read.
                let nowInTrial = entitlement?.periodType == .trial
                let wasInTrial = self.lastObservedTrialState
                self.lastObservedTrialState = nowInTrial

                if !wasInTrial && nowInTrial {
                    // free/none → trial
                    //
                    // REACHABLE. The trial offering is live in RevenueCat and
                    // approved in App Store Connect, so this branch fires for
                    // real users. The notification scheduling below is
                    // load-bearing — do not delete it.
                    //
                    // No analytics or attribution event fires here, and that is
                    // deliberate. `trial_started` / `af_start_trial` are emitted
                    // from PaywallView's purchase result instead, off
                    // `periodType == .trial`, because that path fires exactly
                    // once per purchase. This branch cannot make that guarantee:
                    // `lastObservedTrialState` is in-memory only and is seeded
                    // by `checkAccess()`, which suspends on a network call while
                    // `customerInfoStream` emits its cached value immediately —
                    // so on a cold launch during an active trial this branch can
                    // re-fire for a trial that started days ago. That race still
                    // affects the notification scheduling below (it may
                    // re-schedule), but no longer any event.
                    // Resolved BEFORE the Task so it is read from the same
                    // CustomerInfo tick that detected the trial. `nil` here is
                    // expected on a cold launch into an existing trial — prewarm
                    // skips for an entitled user, so offerings are never fetched
                    // — and the notification drops its price clause rather than
                    // quoting a figure.
                    let renewalPrice = self.localizedPrice(
                        forProductID: entitlement?.productIdentifier
                    )
                    // `.trialStarted` (60s) and `.trialDay5` (day 5) are no longer
                    // sent — only the day-6 renewal warning is. Their
                    // `NotificationKind` cases and localized strings are kept on
                    // purpose, so re-enabling either is one `schedule` line here
                    // and nothing else; the DEV diagnostics panel still fires
                    // both on demand.
                    Task { @MainActor in
                        await NotificationScheduler.shared.schedule(
                            .trialEnding24h,
                            in: 6 * 24 * 3600,
                            price: renewalPrice
                        )
                    }
                } else if wasInTrial && !nowInTrial {
                    // trial → ended. `isActive` is the discriminator: the
                    // entitlement survives a conversion to paid and lapses on a
                    // cancellation or expiry. Notifications are cancelled either
                    // way.
                    // Only the kind this branch's counterpart schedules. The two
                    // retired kinds are not listed because nothing schedules them
                    // any more; both fired well before trial end anyway, so
                    // cancelling them here never prevented a delivery.
                    NotificationScheduler.shared.cancel(.trialEnding24h)
                    if entitlement?.isActive == true {
                        // trial → paid.
                        //
                        // BEST-EFFORT ONLY. This fires just once the user opens
                        // the app after the conversion renewal lands, which may
                        // be days later or never. RevenueCat's webhooks remain
                        // the authoritative source for conversion accounting —
                        // treat this event as a funnel signal, not as revenue
                        // truth. No revenue parameter is attached for the same
                        // reason, and no attribution call is made here:
                        // RevenueCat's own AppsFlyer integration already
                        // delivers the conversion server-side as `af_subscribe`.
                        AppAnalytics.log("trial_converted", params: [
                            "plan": Self.planName(forProductID: entitlement?.productIdentifier),
                            "product_id": entitlement?.productIdentifier ?? "unknown"
                        ])
                    }
                }
            }
        }
        #endif
    }

    // MARK: - RevenueCat calls

    @MainActor
    func checkAccess() async {
        #if DEV
        isSubscribedReal = true
        #else
        // Every exit path resolves the latch, including the unconfigured and
        // throwing ones — a waiter that never wakes would hang prewarm forever,
        // which is worse than prewarming against a pessimistic `false`.
        defer { markEntitlementResolved() }
        guard Purchases.isConfigured else {
            print("⚠️ checkAccess called before Purchases.configure (missing apiKey?)")
            return
        }
        do {
            let info = try await Purchases.shared.customerInfo()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribedReal = entitlement?.isActive == true
            isTrialActive = entitlement?.periodType == .trial
            // Seed change-detection so the customerInfoStream listener
            // doesn't false-fire its trial→started branch on the first
            // tick (which echoes the values we just read here).
            //
            // FIRST EVER LAUNCH ONLY. After that the persisted value is
            // authoritative and the stream listener owns every further
            // mutation. Seeding unconditionally would overwrite a persisted
            // `true` with the post-conversion `false` read back here, and the
            // trial→paid transition would be gone before the listener could
            // observe it — defeating the persistence on the one path it exists
            // to protect.
            if !UserDefaults.standard.bool(forKey: Self.trialStateSeededKey) {
                lastObservedTrialState = isTrialActive
            }
            updateAnalyticsSubscriptionState()
        } catch {
            // Keep current state on error
        }
        #endif
    }

    /// Re-arms the "we miss you" inactivity push to fire 3 days from now.
    /// Called from the App-level scenePhase observer on every `.active`
    /// and `.background` transition, so the timer effectively resets to
    /// "3 days of true inactivity from the last session boundary." Pro
    /// users skip — they don't need a reactivation push.
    @MainActor
    func rescheduleInactiveReminder() async {
        NotificationScheduler.shared.cancel(.inactive3Days)
        guard !isSubscribed else { return }
        await NotificationScheduler.shared.schedule(.inactive3Days, in: 3 * 24 * 3600)
    }

    /// Returns the offering with the given identifier, or `nil` if not
    /// present. Falls back to `offerings.current` when `id` is `nil`, so
    /// PaywallView callers that don't pass an `offeringId` keep their
    /// existing default-offering behavior. Also falls back to current
    /// when an unknown identifier is passed — degrades gracefully if a
    /// future offering is referenced before the RC dashboard adds it.
    func offering(for id: String?) -> Offering? {
        guard let id else { return offerings?.current }
        return offerings?[id] ?? offerings?.current
    }

    /// StoreKit's localized price string for a product identifier, taken from
    /// the offerings already loaded in this session — correct currency and
    /// formatting for the user's storefront, unlike any literal we could write.
    ///
    /// Returns `nil` rather than a placeholder when offerings are not loaded, so
    /// callers are forced to degrade instead of quoting an amount. Searches
    /// `offerings.all` because the product may sit in the `trial` offering, the
    /// `default` one, or whatever `paywall_offering_id` names.
    func localizedPrice(forProductID id: String?) -> String? {
        guard let id, let offerings else { return nil }
        for offering in offerings.all.values {
            if let package = offering.availablePackages.first(
                where: { $0.storeProduct.productIdentifier == id }
            ) {
                return package.storeProduct.localizedPriceString
            }
        }
        return nil
    }

    // MARK: - Paywall data prewarm

    /// Prewarm diagnostics. Deliberately NOT the bare `print` this file uses for
    /// its `⚠️` lines: those fire once, only on a misconfiguration guard, and are
    /// meant to be impossible to miss. This one is happy-path, runs on every
    /// launch for every non-subscriber, and interpolates the whole eligibility
    /// dictionary — so it is routed through `Logger` at `.debug`, which is not
    /// emitted or persisted in a release install and does not even evaluate its
    /// interpolation unless something is streaming the subsystem.
    private let prewarmLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "Prewarm"
    )

    /// Resolves everything the paywall renders — offerings and intro-offer
    /// eligibility — BEFORE the paywall is opened, so its first paint is its
    /// settled paint. Fire-and-forget; never on a caller's critical path.
    ///
    /// Does ZERO network work for a user holding `access`: they will never see
    /// a paywall, so the data is dead weight.
    @MainActor
    func prewarmPaywallData() async {
        #if DEV
        return
        #else
        // GUARD 1 — entitlement. `isSubscribedReal` starts `false`, so reading
        // it before the first CustomerInfo lands would run the whole prewarm
        // for a paying subscriber. Wait for the resolution that is already in
        // flight instead of firing a second `customerInfo()` fetch.
        await awaitEntitlementResolution()
        guard !isSubscribed else {
            prewarmState = .skipped
            return
        }

        // GUARD 2 — idempotence. Safe against concurrent callers: this check
        // and the `.loading` write below are both on the main actor with no
        // suspension between them, so two callers cannot both pass.
        switch prewarmState {
        case .loading, .ready:
            return
        case .idle, .skipped, .failed:
            break
        }
        prewarmState = .loading

        await loadOfferings()
        guard let offerings else {
            prewarmState = .failed(PrewarmError.offeringsUnavailable)
            return
        }

        // Every offering `PaywallView.paywallResolution` can land on: the
        // `trial` offering, whatever `paywall_offering_id` names, the legacy
        // `default` offering the `paywall_v1` experiment selects, and
        // `offerings.current` as the final fallback. Missing one would leave
        // that cohort on the fallback query and back to today's flicker.
        let candidates: [Offering?] = [
            offerings[PaywallConfig.trialOfferingId],
            offerings[PaywallConfig.offeringId],
            offerings["default"],
            offerings.current
        ]
        // Annual only: the eligibility question is per SUBSCRIPTION GROUP, and
        // the paywall asks it of the annual product alone (PaywallView's
        // `refreshTrialEligibility`). Deduplicated because these offerings
        // routinely share a product.
        var identifiers: [String] = []
        var seen = Set<String>()
        for product in candidates.compactMap({ $0?.annual?.storeProduct })
        where seen.insert(product.productIdentifier).inserted {
            identifiers.append(product.productIdentifier)
        }
        guard !identifiers.isEmpty else {
            prewarmState = .failed(PrewarmError.noAnnualProducts)
            return
        }

        // Batch API — one call for every identifier. Returns
        // `[String: IntroEligibility]`; the cache stores the `.status` the
        // paywall actually compares against.
        let results = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
            productIdentifiers: identifiers
        )
        trialEligibility = results.mapValues(\.status)
        prewarmState = .ready
        prewarmLog.debug("ready — \(identifiers.count) product(s): \(String(describing: self.trialEligibility))")
        #endif
    }

    /// Re-evaluates the prewarm after the `access` entitlement changes.
    /// Subscribed now: drop the cache, mark `.skipped`. Not subscribed: reset
    /// to `.idle` so guard 2 cannot short-circuit, then prewarm again.
    @MainActor
    private func invalidatePrewarmForEntitlementChange() {
        if isSubscribed {
            trialEligibility = [:]
            prewarmState = .skipped
            return
        }
        prewarmState = .idle
        Task { await prewarmPaywallData() }
    }

    /// Wakes anything waiting on the first CustomerInfo. Idempotent.
    @MainActor
    private func markEntitlementResolved() {
        guard !hasResolvedEntitlement else { return }
        hasResolvedEntitlement = true
        let waiters = entitlementWaiters
        entitlementWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the first CustomerInfo has been applied. Returns
    /// immediately once resolved, so it costs nothing after launch.
    @MainActor
    private func awaitEntitlementResolution() async {
        if hasResolvedEntitlement { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entitlementWaiters.append(continuation)
        }
    }

    @MainActor
    func loadOfferings() async {
        #if DEV
        return
        #else
        guard Purchases.isConfigured else {
            print("⚠️ loadOfferings called before Purchases.configure (missing apiKey?)")
            return
        }
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            // Offerings failed — paywall will show fallback prices
        }
        #endif
    }

    @MainActor
    func purchase(_ package: Package) async -> PurchaseOutcome {
        #if DEV
        // DEV builds don't talk to the live store. Today's paywall short-
        // circuits before reaching here (package(for:) returns nil because
        // offerings aren't loaded in DEV), so this is defense-in-depth.
        return .failed(reason: "not_configured")
        #else
        guard Purchases.isConfigured else {
            print("⚠️ purchase called before Purchases.configure")
            return .failed(reason: "not_configured")
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                return .userCancelled
            }
            let entitlement = result.customerInfo.entitlements[Self.entitlementID]
            guard entitlement?.isActive == true else {
                return .failed(reason: "entitlement_inactive")
            }
            let isTrial = entitlement?.periodType == .trial
            isSubscribedReal = true
            isTrialActive = isTrial
            // The user now holds `access`, so the cached eligibility is stale by
            // definition — they just consumed the intro offer it described.
            invalidatePrewarmForEntitlementChange()
            return .succeeded(isTrial: isTrial)
        } catch {
            guard let code = error as? RevenueCat.ErrorCode else {
                return .failed(reason: "unknown")
            }
            switch code {
            case .purchaseCancelledError:
                return .userCancelled
            case .networkError:
                return .failed(reason: "network")
            case .paymentPendingError:
                return .failed(reason: "payment_pending")
            case .productNotAvailableForPurchaseError:
                return .failed(reason: "product_unavailable")
            case .storeProblemError:
                return .failed(reason: "store_problem")
            default:
                return .failed(reason: "unknown")
            }
        }
        #endif
    }

    @MainActor
    func restorePurchases() async -> Bool {
        #if DEV
        // DEV builds never call Purchases.configure(); nothing to restore.
        return false
        #else
        AppAnalytics.log("restore_attempted")
        guard Purchases.isConfigured else {
            print("⚠️ restorePurchases called before Purchases.configure")
            AppAnalytics.log("restore_failed", params: ["error_reason": "not_configured"])
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribedReal = entitlement?.isActive == true
            isTrialActive = entitlement?.periodType == .trial
            AppAnalytics.log("restore_succeeded", params: [
                "had_active_entitlement": isSubscribedReal
            ])
            updateAnalyticsSubscriptionState()
            // Restore can land either way: onto an active entitlement (cache is
            // now dead weight) or onto a lapsed one (cache may be stale for a
            // different Apple ID). Both are handled here.
            invalidatePrewarmForEntitlementChange()
            return isSubscribedReal
        } catch {
            AppAnalytics.log("restore_failed", params: [
                "error_reason": error.localizedDescription
            ])
            return false
        }
        #endif
    }

    /// Presents Apple's offer-code redemption sheet. Successful redemption
    /// updates `customerInfo` automatically via the `customerInfoStream`
    /// listener — there is no synchronous success signal to surface here,
    /// so we only log the open and any error from sheet presentation. A
    /// `redemption_succeeded` event would double-count with the existing
    /// `subscription_state` user-property flip and could fire spuriously
    /// when the user dismissed the sheet without redeeming.
    @MainActor
    func presentCodeRedemption() async {
        AppAnalytics.log("offer_code_redemption_opened")
        #if DEV
        return
        #else
        guard Purchases.isConfigured else {
            AppAnalytics.log("offer_code_redemption_failed", params: [
                "error_reason": "not_configured"
            ])
            return
        }
        do {
            try await Purchases.shared.presentCodeRedemptionSheet()
        } catch {
            AppAnalytics.log("offer_code_redemption_failed", params: [
                "error_reason": String(describing: type(of: error))
            ])
        }
        #endif
    }

    // MARK: - API Key

    private func revenueCatAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["REVENUECAT_API_KEY"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }
}

// MARK: - Product IDs
extension SubscriptionManager {
    enum ProductID {
        static let weekly = "steadyeye_weekly"
        static let monthly = "steadyeye_monthly"
        static let annual = "steadyeye_annual"
        static let lifetime = "steadyeye_lifetime"

        /// The `trial` offering's annual SKU. A SEPARATE App Store product from
        /// `annual`, not the same product with an offer attached — both ship at
        /// once and the prewarm reports them side by side
        /// (`steadyeye_annual: noIntroOfferExists`, `steadyeye_annual_trial:
        /// eligible`). It is the product a converting trial reports, so
        /// `planName(forProductID:)` must map it or every `trial_converted`
        /// lands in an "unknown" bucket.
        static let annualTrial = "steadyeye_annual_trial"

        /// Suffix marking a trial-offering variant of a base product.
        static let trialSuffix = "_trial"
    }

    static let entitlementID = "access"

    /// Plan label for a product identifier, in the SAME vocabulary
    /// `purchase_succeeded` reports — the cases return `PaywallPlan` raw values
    /// verbatim rather than re-spelling them, so `trial_converted` can be
    /// pivoted against the purchase funnel without a second naming scheme.
    ///
    /// A trial-offering SKU reports the SAME plan as its base product
    /// (`steadyeye_annual_trial` → `annual`), so a converted trial pivots
    /// against `purchase_succeeded` instead of splitting into a parallel
    /// "…_trial" bucket.
    ///
    /// All five App Store SKUs are mapped, `steadyeye_weekly` included — it is
    /// provisioned but not currently sold, and is handled here so that shipping
    /// it needs no code change. `"unknown"` therefore now means a genuinely
    /// unrecognised identifier: a product added to App Store Connect without a
    /// matching `ProductID` constant, which is worth investigating rather than
    /// silently bucketing under a guessed plan.
    static func planName(forProductID id: String?) -> String {
        switch id {
        case ProductID.annual, ProductID.annualTrial:
            return PaywallPlan.annual.rawValue
        case ProductID.monthly:
            return PaywallPlan.monthly.rawValue
        case ProductID.weekly:
            return PaywallPlan.weekly.rawValue
        case ProductID.lifetime:
            return PaywallPlan.lifetime.rawValue
        default:
            // Any trial variant beyond the one named above — a
            // `steadyeye_monthly_trial`, a future `steadyeye_weekly_trial` —
            // resolves through its base SKU. This only ever succeeds when that
            // base is itself a known constant, so an unrecognised product still
            // reports "unknown" rather than being filed under a guessed plan.
            guard let id, id.hasSuffix(ProductID.trialSuffix) else { return "unknown" }
            return planName(forProductID: String(id.dropLast(ProductID.trialSuffix.count)))
        }
    }
}
