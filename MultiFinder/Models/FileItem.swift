import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    typealias ID = URL

    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date
    let kind: String
    let isHidden: Bool
    let isSymlink: Bool
    let isPackage: Bool

    init(url: URL) {
        let standardizedURL = url.standardizedFileURL
        self.id = standardizedURL
        self.url = standardizedURL
        self.name = standardizedURL.lastPathComponent

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .isHiddenKey, .isSymbolicLinkKey, .isPackageKey
        ]
        let values = try? standardizedURL.resourceValues(forKeys: Set(keys))

        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate ?? .distantPast
        self.isHidden = values?.isHidden ?? standardizedURL.lastPathComponent.hasPrefix(".")
        self.isSymlink = values?.isSymbolicLink ?? false
        self.isPackage = values?.isPackage ?? false

        if self.isDirectory {
            self.kind = self.isPackage ? L10n.string("Package") : L10n.string("Folder")
        } else {
            self.kind = Self.fileKind(for: standardizedURL.pathExtension)
        }
    }

    static func fileKind(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return L10n.string("Swift File")
        case "js": return L10n.string("JavaScript File")
        case "ts": return L10n.string("TypeScript File")
        case "py": return L10n.string("Python File")
        case "html", "htm": return L10n.string("HTML File")
        case "css": return L10n.string("CSS File")
        case "json": return L10n.string("JSON File")
        case "xml": return L10n.string("XML File")
        case "md": return L10n.string("Markdown File")
        case "txt": return L10n.string("Text File")
        case "pdf": return L10n.string("PDF Document")
        case "png": return L10n.string("PNG Image")
        case "jpg", "jpeg": return L10n.string("JPEG Image")
        case "gif": return L10n.string("GIF Image")
        case "svg": return L10n.string("SVG Image")
        case "webp": return L10n.string("WebP Image")
        case "mp3", "aac", "wav", "flac": return L10n.string("Audio File")
        case "mp4", "mov", "avi", "mkv": return L10n.string("Video File")
        case "zip", "tar", "gz", "rar", "7z": return L10n.string("Archive File")
        case "dmg": return L10n.string("Disk Image")
        case "app": return L10n.string("Application")
        case "sh", "bash", "zsh": return L10n.string("Shell Script")
        case "c": return L10n.string("C File")
        case "cpp", "cc", "cxx": return L10n.string("C++ File")
        case "h", "hpp": return L10n.string("Header File")
        case "java": return L10n.string("Java File")
        case "rs": return L10n.string("Rust File")
        case "go": return L10n.string("Go File")
        case "rb": return L10n.string("Ruby File")
        case "php": return L10n.string("PHP File")
        case "yml", "yaml": return L10n.string("YAML File")
        case "toml": return L10n.string("TOML File")
        case "csv": return L10n.string("CSV File")
        case "doc", "docx": return L10n.string("Word Document")
        case "xls", "xlsx": return L10n.string("Excel Spreadsheet")
        case "ppt", "pptx": return L10n.string("PowerPoint Presentation")
        case "sql": return L10n.string("SQL File")
        case "r": return L10n.string("R File")
        case "lua": return L10n.string("Lua File")
        case "dart": return L10n.string("Dart File")
        case "kt": return L10n.string("Kotlin File")
        case "vue": return L10n.string("Vue File")
        case "jsx", "tsx": return L10n.string("React File")
        default: return ext.isEmpty
            ? L10n.string("File")
            : L10n.format("%@ File", ext.uppercased())
        }
    }

}

enum FileDropSafety {
    private static let protectedHomeDirectoryNames: Set<String> = [
        ".Trash",
        "Applications",
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Movies",
        "Music",
        "Pictures",
        "Public"
    ]

    static func canStartDragging(_ item: FileItem) -> Bool {
        !item.isDirectory || !isProtectedSource(item.url)
    }

    static func isProtectedSource(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let source = url.standardizedFileURL
        let home = homeDirectory.standardizedFileURL
        let root = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL

        if source == root || source == home {
            return true
        }

        if source.deletingLastPathComponent().standardizedFileURL == root {
            return true
        }

        if source.deletingLastPathComponent().standardizedFileURL == home,
           protectedHomeDirectoryNames.contains(source.lastPathComponent) {
            return true
        }

        let volumes = root.appendingPathComponent("Volumes", isDirectory: true).standardizedFileURL
        if source.deletingLastPathComponent().standardizedFileURL == volumes {
            return true
        }

        return false
    }
}

struct FileItemComparator: SortComparator, Hashable, Sendable {
    typealias Compared = FileItem

    var field: SortField
    var order: SortOrder

    init(field: SortField, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory ? .orderedAscending : .orderedDescending
        }

        let primary: ComparisonResult
        switch field {
        case .name:
            primary = lhs.name.localizedStandardCompare(rhs.name)
        case .date:
            primary = Self.compare(lhs.modificationDate, rhs.modificationDate)
        case .size:
            primary = Self.compare(lhs.size, rhs.size)
        case .kind:
            primary = lhs.kind.localizedStandardCompare(rhs.kind)
        }

        if primary != .orderedSame {
            return order == .forward ? primary : primary.reversed
        }

        let nameFallback = lhs.name.localizedStandardCompare(rhs.name)
        if nameFallback != .orderedSame {
            return nameFallback
        }

        return lhs.url.path.compare(rhs.url.path, options: [.literal, .caseInsensitive])
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
