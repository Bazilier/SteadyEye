import Foundation

enum UserIdentity {
    private static let userDefaultsKey = "steadyeye.user_uuid"

    static var uuid: String {
        if let existing = UserDefaults.standard.string(forKey: userDefaultsKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: userDefaultsKey)
        return new
    }
}
