import Foundation

enum RateLimiter {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var today: String {
        dateFormatter.string(from: Date())
    }

    /// Resets counters if the stored date is not today.
    private static func resetIfNeeded() {
        let stored = UserDefaults.standard.string(forKey: "rateLimitDate") ?? ""
        if stored != today {
            UserDefaults.standard.set(today, forKey: "rateLimitDate")
            UserDefaults.standard.set(0, forKey: "apiCallsToday")
            UserDefaults.standard.set(0, forKey: "bulkImportsToday")
        }
    }

    /// Returns true if an API call is allowed. Increments the counter.
    static func canMakeAPICall() -> Bool {
        resetIfNeeded()
        let count = UserDefaults.standard.integer(forKey: "apiCallsToday")
        guard count < 20 else { return false }
        UserDefaults.standard.set(count + 1, forKey: "apiCallsToday")
        return true
    }

    /// Returns true if a bulk import is allowed. Increments both counters.
    /// Counts as 2 API calls (1 split + 1 batch optimize).
    static func canBulkImport() -> Bool {
        resetIfNeeded()
        let apiCount = UserDefaults.standard.integer(forKey: "apiCallsToday")
        let bulkCount = UserDefaults.standard.integer(forKey: "bulkImportsToday")
        guard apiCount + 2 <= 20, bulkCount < 3 else { return false }
        UserDefaults.standard.set(apiCount + 2, forKey: "apiCallsToday")
        UserDefaults.standard.set(bulkCount + 1, forKey: "bulkImportsToday")
        return true
    }
}
