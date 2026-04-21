import Foundation
import SwiftData

@Model
final class Script {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var wordCount: Int
    var estimatedReadTime: TimeInterval  // seconds, based on ~150 WPM
    var isDemo: Bool = false

    init(title: String, content: String) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
        let words = content.split(separator: " ").count
        self.wordCount = words
        self.estimatedReadTime = Double(words) / 150.0 * 60.0
    }

    func update(title: String, content: String) {
        self.title = title
        self.content = content
        self.updatedAt = Date()
        let words = content.split(separator: " ").count
        self.wordCount = words
        self.estimatedReadTime = Double(words) / 150.0 * 60.0
    }

    /// Human-readable estimated read time string (e.g. "2 min 30 sec")
    var estimatedReadTimeFormatted: String {
        let minutes = Int(estimatedReadTime) / 60
        let seconds = Int(estimatedReadTime) % 60
        if minutes > 0 {
            return String(
                localized: "script.readTime.minSec",
                defaultValue: "\(minutes) min \(seconds) sec",
                comment: "Estimated read time when ≥ 1 minute. Two cardinal numbers."
            )
        } else {
            return String(
                localized: "script.readTime.secOnly",
                defaultValue: "\(seconds) sec",
                comment: "Estimated read time under one minute."
            )
        }
    }
}
