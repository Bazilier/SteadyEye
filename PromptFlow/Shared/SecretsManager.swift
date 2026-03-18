import Foundation

enum SecretsManager {
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
}
