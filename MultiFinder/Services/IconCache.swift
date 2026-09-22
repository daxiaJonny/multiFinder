import AppKit
import UniformTypeIdentifiers

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2000
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isDirectory && !item.isPackage {
            return folderIcon
        }
        return icon(for: item.url.path)
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = iconWithoutStat(for: path) ?? NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: key)
        return icon
    }

    private var folderIcon: NSImage {
        let key = "__folder__" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = (NSWorkspace.shared.icon(for: .folder).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: key)
        return icon
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// `icon(forFile:)` stats the path. Skip that for ordinary extensions.
    /// No extension covers folders and extensionless files; `.app` icons differ per bundle.
    private func iconWithoutStat(for path: String) -> NSImage? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, ext.caseInsensitiveCompare("app") != .orderedSame else {
            return nil
        }
        guard let type = UTType(filenameExtension: ext) else {
            return nil
        }
        return NSWorkspace.shared.icon(for: type)
    }
}
