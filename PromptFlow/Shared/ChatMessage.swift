import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case inbound
        case outbound
    }

    let id: Int
    let text: String
    let direction: Direction
    let createdAt: Date

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
    }

    /// Optimistic local insert, before the backend assigns a real id. Negative
    /// ids never collide with backend ids (which start at 1) — letting the
    /// merge step replace them when the canonical row arrives.
    init(localId: Int, text: String) {
        self.id = localId
        self.text = text
        self.direction = .inbound
        self.createdAt = Date()
    }

    var isLocal: Bool { id < 0 }
}
