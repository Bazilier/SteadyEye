import Foundation
import Security

/// A random id for this device, kept in the Keychain so it survives a
/// reinstall (UserDefaults and RevenueCat's anonymous id do not). Sent as
/// `X-Device-Id` to the Studio Sound backend, which ties the one free try to
/// the device as well as to the app user. Not the IDFV and not tracking: it
/// identifies nothing outside this app's own backend.
enum DeviceIdentity {
    private static let service = "com.steadyeye.device-identity"
    private static let account = "device-id"

    static let id: String = {
        if let existing = read() { return existing }
        let new = UUID().uuidString
        write(new)
        return new
    }()

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil
        else { return nil }
        return value
    }

    private static func write(_ value: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(item as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
    }
}
