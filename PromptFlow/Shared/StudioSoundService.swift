import Foundation

/// Client for the backend's Auphonic proxy, `/api/v1/audio/enhance/`.
///
/// The server holds the Auphonic key and every processing setting; this
/// client only moves the audio track up and the processed one back down.
/// Identity is the same `X-App-User-Id` the AI proxy uses, checked against
/// RevenueCat for the "access" entitlement.
enum StudioSoundService {

    private static let baseURL = "https://web-production-49244.up.railway.app/api/v1/audio/enhance/"
    private static let quotaURL = "https://web-production-49244.up.railway.app/api/v1/audio/quota/"

    /// Overridable so tests can install a `URLProtocol` stub.
    static var session: URLSession = .shared

    enum ServiceError: Error, Equatable {
        case network
        case subscriptionRequired
        /// The one free try is used.
        case freeLimit
        /// This month's allowance is used up.
        case monthlyLimit
        /// The trial's allowance is used up.
        case trialLimit
        /// A server-wide or per-network ceiling; later is fine.
        case rateLimited
        case disabled
        case tooLong
        case invalidAudio
        case notFound
        case gone
        case http(Int)

        /// Worth retrying as-is: the request may well succeed a moment later.
        var isTransient: Bool {
            switch self {
            case .network: return true
            case .http(let code): return code >= 500
            default: return false
            }
        }

        /// Stable code stored on the recording and sent to analytics.
        var code: String {
            switch self {
            case .network: return "network"
            case .subscriptionRequired: return "subscription_required"
            case .freeLimit: return "free_limit"
            case .monthlyLimit: return "monthly_limit"
            case .trialLimit: return "trial_limit"
            case .rateLimited: return "rate_limited"
            case .disabled: return "disabled"
            case .tooLong: return "too_long"
            case .invalidAudio: return "invalid_audio"
            case .notFound: return "not_found"
            case .gone: return "gone"
            case .http(let code): return "http_\(code)"
            }
        }
    }

    enum JobStatus: String, Decodable {
        case processing, done, error
    }

    struct Job: Decodable {
        let id: String
        let status: JobStatus
        /// Sent with a newly started job.
        let quota: Quota?
    }

    /// The caller's allowance, from `GET /audio/quota/` and with each start.
    struct Quota: Decodable, Equatable {
        enum Tier: String, Decodable {
            case free, trial, paid
        }
        let tier: Tier
        let limit: Int
        let used: Int
        let remaining: Int
        /// "yyyy-MM-dd" of the next month, paid only.
        let resetsAt: String?
        /// For "with a subscription: N a month".
        let paidMonthlyLimit: Int

        enum CodingKeys: String, CodingKey {
            case tier, limit, used, remaining
            case resetsAt = "resets_at"
            case paidMonthlyLimit = "paid_monthly_limit"
        }

        var resetDate: Date? {
            guard let resetsAt else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: resetsAt)
        }
    }

    static func quota() async throws -> Quota {
        var request = URLRequest(url: URL(string: quotaURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        addIdentity(to: &request)
        let data = try await send(request)
        return try decode(Quota.self, from: data)
    }

    /// Uploads an `.m4a` and starts processing. `requestID` makes a retry
    /// safe: the server answers a repeated id with the job it already made.
    static func start(audioFileURL: URL, requestID: String) async throws -> Job {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"request_id\"\r\n\r\n")
        body.append("\(requestID)\r\n")
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: audioFileURL))
        body.append("\r\n--\(boundary)--\r\n")

        var request = makeRequest(path: "", method: "POST")
        request.timeoutInterval = 90
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try await send(request, uploading: body)
        return try decode(Job.self, from: data)
    }

    static func status(jobID: String) async throws -> JobStatus {
        let data = try await send(makeRequest(path: "\(jobID)/", method: "GET"))
        return try decode(Job.self, from: data).status
    }

    /// Downloads the processed audio (lossless ALAC in an .m4a) to a
    /// temporary file the caller owns.
    static func downloadResult(jobID: String) async throws -> URL {
        var request = makeRequest(path: "\(jobID)/result/", method: "GET")
        request.timeoutInterval = 120
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch {
            throw ServiceError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw error(for: status, data: Data())
        }
        // The system deletes `tempURL` when this call returns; move it first.
        let ownedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-\(jobID).m4a")
        try? FileManager.default.removeItem(at: ownedURL)
        try FileManager.default.moveItem(at: tempURL, to: ownedURL)
        return ownedURL
    }

    /// Deletes the user's audio at Auphonic. Best effort.
    static func delete(jobID: String) async {
        _ = try? await send(makeRequest(path: "\(jobID)/", method: "DELETE"))
    }

    // MARK: - Transport

    private static func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        addIdentity(to: &request)
        return request
    }

    private static func addIdentity(to request: inout URLRequest) {
        request.setValue(AnthropicService.appUserId(), forHTTPHeaderField: "X-App-User-Id")
        request.setValue(DeviceIdentity.id, forHTTPHeaderField: "X-Device-Id")
    }

    private static func send(_ request: URLRequest, uploading body: Data? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw ServiceError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw error(for: status, data: data)
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServiceError.http(200)
        }
    }

    private static func error(for status: Int, data: Data) -> ServiceError {
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch code {
        case "subscription_required": return .subscriptionRequired
        case "free_limit": return .freeLimit
        case "monthly_limit": return .monthlyLimit
        case "trial_limit": return .trialLimit
        case "rate_limited": return .rateLimited
        case "audio_disabled": return .disabled
        case "input_too_long", "input_too_large": return .tooLong
        case "invalid_audio": return .invalidAudio
        case "not_found": return .notFound
        case "gone": return .gone
        default:
            switch status {
            case 404: return .notFound
            case 410: return .gone
            default: return .http(status)
            }
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
