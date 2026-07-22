import Foundation

/// Reads API keys from Secrets.plist (gitignored).
/// Expected keys: ANTHROPIC_API_KEY, REVENUECAT_API_KEY, FACEBOOK_CLIENT_TOKEN, TENJIN_SDK_KEY
enum SecretsManager {
    // The real Tenjin key lives ONLY in Secrets.plist (gitignored); this is the value the plist ships with before configuration — never paste a real key here.
    private static let unconfiguredTenjinKeySentinel = "PASTE_TENJIN_SDK_KEY_HERE"

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

    static func facebookClientToken() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["FACEBOOK_CLIENT_TOKEN"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    static func tenjinSDKKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["TENJIN_SDK_KEY"] as? String,
              key != unconfiguredTenjinKeySentinel,
              !key.isEmpty
        else { return nil }
        return key
    }
}
