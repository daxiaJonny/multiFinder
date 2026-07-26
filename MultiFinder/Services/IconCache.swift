import AppKit

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2000
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: key)
        return icon
    }

    func clear() {
        cache.removeAllObjects()
    }
}
