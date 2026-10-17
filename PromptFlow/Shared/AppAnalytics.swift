import Foundation
import FirebaseAnalytics

enum AppAnalytics {
    static func log(_ event: String, params: [String: Any]? = nil) {
        #if !DEV
        Analytics.logEvent(event, parameters: params)
        #endif
    }

    /// Stable `error_reason` value: the NSError domain and code. Never
    /// `localizedDescription` (four locales split one failure into four
    /// buckets) or `String(describing:)` (free text, cut at 100 chars).
    static func errorReason(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code)"
    }
}
