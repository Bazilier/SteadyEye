import Foundation
import UIKit

enum ChatService {
    private static let baseURL = "https://web-production-49244.up.railway.app/api/v1"

    enum ServiceError: LocalizedError {
        case networkError(Error)
        case httpError(Int)
        case decodingError
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .networkError(let e): return e.localizedDescription
            case .httpError(let code): return "Server returned status \(code)."
            case .decodingError: return "Could not parse response."
            case .emptyResponse: return "Empty response from API."
            }
        }
    }

    /// Sends a user message to the backend. The view layer supplies
    /// `recordingsCount` because the SwiftData container is provided via the
    /// SwiftUI environment, not a static singleton — keeping the count out of
    /// this file leaves it free of UI/SwiftData wiring.
    static func sendMessage(text: String, recordingsCount: Int) async throws -> Int {
        let url = URL(string: "\(baseURL)/messages/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let metadata = await buildMetadata(recordingsCount: recordingsCount)
        let body: [String: Any] = [
            "user_uuid": UserIdentity.uuid,
            "text": text,
            "metadata": metadata
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw ServiceError.decodingError }
        guard http.statusCode == 200 else { throw ServiceError.httpError(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = json["message_id"] as? Int else {
            throw ServiceError.decodingError
        }
        return messageId
    }

    static func fetchMessages(since: Date? = nil) async throws -> [ChatMessage] {
        var components = URLComponents(string: "\(baseURL)/messages/")!
        var items = [URLQueryItem(name: "user_uuid", value: UserIdentity.uuid)]
        if let since {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw ServiceError.decodingError }
        guard http.statusCode == 200 else { throw ServiceError.httpError(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = json["messages"] as? [[String: Any]] else {
            throw ServiceError.decodingError
        }

        return rawMessages.compactMap { ChatMessage(rawJSON: $0) }
    }

    @MainActor
    private static func buildMetadata(recordingsCount: Int) -> [String: Any] {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        let language = Locale.preferredLanguages.first ?? "en"

        let sub = SubscriptionManager.shared
        let subscriptionStatus: String = sub.isSubscribed
            ? (sub.isTrialActive ? "trial" : "subscribed")
            : "free"

        return [
            "app_version": appVersion,
            "ios_version": iosVersion,
            "device_model": deviceModel,
            "subscription_status": subscriptionStatus,
            "recordings_count": recordingsCount,
            "language": language
        ]
    }
}
