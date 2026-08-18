import Foundation

/// Reads API keys from Secrets.plist (gitignored).
/// Expected keys: ANTHROPIC_API_KEY, REVENUECAT_API_KEY, APPSFLYER_DEV_KEY
enum SecretsManager {
    // The real AppsFlyer dev key lives ONLY in Secrets.plist (gitignored); this is the value the plist ships with before configuration — never paste a real key here.
    private static let unconfiguredAppsFlyerKeySentinel = "PASTE_APPSFLYER_DEV_KEY_HERE"

    static func anthropicAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["ANTHROPIC_API_KEY"] as? String,
              key != "YOUR_API_KEY_HERE",
              !key.isEmpty
        else { return nil }
        return key
    }

    static func revenueCatAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["REVENUECAT_API_KEY"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    static func appsFlyerDevKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["APPSFLYER_DEV_KEY"] as? String,
              key != unconfiguredAppsFlyerKeySentinel,
              !key.isEmpty
        else { return nil }
        return key
    }
}
