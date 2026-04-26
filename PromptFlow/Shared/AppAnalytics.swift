import Foundation
import FirebaseAnalytics

enum AppAnalytics {
    static func log(_ event: String, params: [String: Any]? = nil) {
        #if !DEV
        Analytics.logEvent(event, parameters: params)
        #endif
    }
}
