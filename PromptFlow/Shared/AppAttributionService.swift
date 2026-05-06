import Foundation
import FirebaseAnalytics
import RevenueCat

/// Bridges ASA attribution from RevenueCat into Firebase Analytics user
/// properties so GA4 can segment users by traffic source / campaign /
/// keyword.
///
/// Flow:
///   1. iOS reads `Purchases.shared.appUserID` (RC anonymous or UUID).
///   2. POSTs it to our Django backend `/api/v1/attribution/fetch/`,
///      which calls RevenueCat's REST API with the secret key (the
///      iOS SDK only exposes attribute *setters*, not readers).
///   3. Maps the four ASA fields to Firebase user properties.
///   4. Logs a one-shot `attribution_synced` event for funnel analysis.
///
/// Persistence model:
///   - `asa_attribution_synced_v1` (Bool) — once true, the service
///     short-circuits forever for this install. Reset only by a fresh
///     install / data-cleared device.
///   - `asa_attribution_attempt_count` (Int) — incremented per
///     successful "unknown" response from the backend. Apple's ASA
///     attribution can take 24-48h to resolve, so we tolerate up to
///     5 cold-start retries before declaring the user organic and
///     sealing the synced flag.
///
/// DEV note: every public method body is wrapped in `#if !DEV` to
/// match the `AppAnalytics` pattern. DEV builds compile but do
/// nothing — no network, no Firebase writes.
enum AppAttributionService {
    private static let backendURL = URL(
        string: "https://web-production-49244.up.railway.app/api/v1/attribution/fetch/"
    )!
    private static let requestTimeoutSeconds: TimeInterval = 10
    private static let maxAttemptsBeforeGivingUp = 5

    private static let syncedFlagKey = "asa_attribution_synced_v1"
    private static let attemptCountKey = "asa_attribution_attempt_count"

    /// Backend response shape — mirrors `attribution/views.py`.
    private struct AttributionResponse: Decodable {
        let trafficSource: String
        let campaign: String?
        let adGroup: String?
        let keyword: String?

        enum CodingKeys: String, CodingKey {
            case trafficSource = "traffic_source"
            case campaign
            case adGroup = "ad_group"
            case keyword
        }
    }

    private enum SyncFailureKind: String, Error {
        case network
        case decode
        case server
    }

    /// Fetch attribution from the backend and propagate it to Firebase.
    /// Idempotent across the synced flag — safe to call on every cold
    /// start. Caller is expected to add a brief `Task.sleep` before
    /// calling on first launch so RevenueCat's SDK has time to round-
    /// trip the AdServices token to Apple.
    static func syncToFirebase() async {
        #if !DEV
        if UserDefaults.standard.bool(forKey: syncedFlagKey) {
            return
        }

        let appUserID = Purchases.shared.appUserID
        guard !appUserID.isEmpty else { return }

        let response: AttributionResponse
        do {
            response = try await fetch(appUserID: appUserID)
        } catch let kind as SyncFailureKind {
            // Diagnostic event only — don't seal the flag, don't bump
            // the attempt counter. Next cold start retries cleanly.
            Analytics.logEvent("attribution_sync_failed", parameters: [
                "error_kind": kind.rawValue
            ])
            return
        } catch {
            Analytics.logEvent("attribution_sync_failed", parameters: [
                "error_kind": SyncFailureKind.network.rawValue
            ])
            return
        }

        switch response.trafficSource {
        case "asa":
            writeASAUserProperties(from: response)
            Analytics.logEvent("attribution_synced", parameters: [
                "traffic_source": "asa",
                "has_campaign": response.campaign != nil ? "true" : "false",
                "has_keyword": response.keyword != nil ? "true" : "false"
            ])
            UserDefaults.standard.set(true, forKey: syncedFlagKey)

        case "unknown":
            let prior = UserDefaults.standard.integer(forKey: attemptCountKey)
            let next = prior + 1
            if next >= maxAttemptsBeforeGivingUp {
                // Apple has had ~5 cold starts to resolve; treat as organic.
                Analytics.setUserProperty("unknown", forName: "traffic_source")
                Analytics.logEvent("attribution_synced", parameters: [
                    "traffic_source": "unknown",
                    "has_campaign": "false",
                    "has_keyword": "false"
                ])
                UserDefaults.standard.set(true, forKey: syncedFlagKey)
            } else {
                UserDefaults.standard.set(next, forKey: attemptCountKey)
            }

        default:
            // Forward-compat: future server-side traffic_source values
            // ("meta_ads", "tiktok", etc.) — store as user property,
            // seal flag. No retries since the server has given a
            // definitive answer.
            Analytics.setUserProperty(response.trafficSource, forName: "traffic_source")
            Analytics.logEvent("attribution_synced", parameters: [
                "traffic_source": response.trafficSource,
                "has_campaign": response.campaign != nil ? "true" : "false",
                "has_keyword": response.keyword != nil ? "true" : "false"
            ])
            UserDefaults.standard.set(true, forKey: syncedFlagKey)
        }
        #endif
    }

    #if !DEV
    private static func fetch(appUserID: String) async throws -> AttributionResponse {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["app_user_id": appUserID]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncFailureKind.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncFailureKind.server
        }
        guard http.statusCode == 200 else {
            throw SyncFailureKind.server
        }

        do {
            return try JSONDecoder().decode(AttributionResponse.self, from: data)
        } catch {
            throw SyncFailureKind.decode
        }
    }

    private static func writeASAUserProperties(from response: AttributionResponse) {
        Analytics.setUserProperty("asa", forName: "traffic_source")
        if let campaign = response.campaign {
            Analytics.setUserProperty(campaign, forName: "asa_campaign")
        }
        if let adGroup = response.adGroup {
            Analytics.setUserProperty(adGroup, forName: "asa_ad_group")
        }
        if let keyword = response.keyword {
            Analytics.setUserProperty(keyword, forName: "asa_keyword")
        }
    }
    #endif
}

