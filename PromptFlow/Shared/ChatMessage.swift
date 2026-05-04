import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case inbound
        case outbound
    }

    /// Delivery state for inbound (user → founder) optimistic sends.
    /// Outbound (founder → user) messages always carry `.sent` since
    /// the user's device never originates them locally.
    enum SendStatus: String, Codable {
        case sending
        case sent
        case failed
    }

    let id: Int
    let text: String
    let direction: Direction
    let createdAt: Date
    var sendStatus: SendStatus

    private enum CodingKeys: String, CodingKey {
        case id, text, direction, createdAt, sendStatus
    }

    init?(rawJSON: [String: Any]) {
        guard let id = rawJSON["id"] as? Int,
              let text = rawJSON["text"] as? String,
              let directionRaw = rawJSON["direction"] as? String,
              let direction = Direction(rawValue: directionRaw),
              let createdAtString = rawJSON["created_at"] as? String else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: createdAtString)
            ?? {
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                return fallback.date(from: createdAtString)
            }()
        guard let createdAt = parsed else { return nil }

        self.id = id
        self.text = text
        self.direction = direction
        self.createdAt = createdAt
        self.sendStatus = .sent
    }

    /// Optimistic local insert, before the backend assigns a real id. Negative
    /// ids never collide with backend ids (which start at 1) — letting the
    /// merge step replace them when the canonical row arrives.
    init(localId: Int, text: String) {
        self.id = localId
        self.text = text
        self.direction = .inbound
        self.createdAt = Date()
        self.sendStatus = .sending
    }

    /// Custom decode for backward compatibility with on-device caches written
    /// before `sendStatus` existed — those rows decode with `.sent` so older
    /// confirmed messages don't suddenly look pending.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        direction = try c.decode(Direction.self, forKey: .direction)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sendStatus = try c.decodeIfPresent(SendStatus.self, forKey: .sendStatus) ?? .sent
    }

    var isLocal: Bool { id < 0 }
}
