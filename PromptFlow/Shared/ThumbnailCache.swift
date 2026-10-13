import UIKit

/// Recording thumbnails, read and decoded off the main thread and kept in
/// memory, so the Recordings grid neither reads files nor decodes JPEGs on
/// the main thread while it scrolls.
enum ThumbnailCache {
    private nonisolated(unsafe) static let cache = NSCache<NSURL, UIImage>()

    /// A thumbnail already decoded, or nil.
    nonisolated static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Reads and decodes the thumbnail in the background; nil when the file
    /// is missing or unreadable.
    nonisolated static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
