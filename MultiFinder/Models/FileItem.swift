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
            self.kind = self.isPackage ? "Package" : "Folder"
        } else {
            self.kind = Self.fileKind(for: standardizedURL.pathExtension)
        }
    }

    static func fileKind(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "Swift File"
        case "js": return "JavaScript File"
        case "ts": return "TypeScript File"
        case "py": return "Python File"
        case "html", "htm": return "HTML File"
        case "css": return "CSS File"
        case "json": return "JSON File"
        case "xml": return "XML File"
        case "md": return "Markdown File"
        case "txt": return "Text File"
        case "pdf": return "PDF Document"
        case "png": return "PNG Image"
        case "jpg", "jpeg": return "JPEG Image"
        case "gif": return "GIF Image"
        case "svg": return "SVG Image"
        case "webp": return "WebP Image"
        case "mp3", "aac", "wav", "flac": return "Audio File"
        case "mp4", "mov", "avi", "mkv": return "Video File"
        case "zip", "tar", "gz", "rar", "7z": return "Archive"
        case "dmg": return "Disk Image"
        case "app": return "Application"
        case "sh", "bash", "zsh": return "Shell Script"
        case "c": return "C File"
        case "cpp", "cc", "cxx": return "C++ File"
        case "h", "hpp": return "Header File"
        case "java": return "Java File"
        case "rs": return "Rust File"
        case "go": return "Go File"
        case "rb": return "Ruby File"
        case "php": return "PHP File"
        case "yml", "yaml": return "YAML File"
        case "toml": return "TOML File"
        case "csv": return "CSV File"
        case "doc", "docx": return "Word Document"
        case "xls", "xlsx": return "Excel Spreadsheet"
        case "ppt", "pptx": return "PowerPoint"
        case "sql": return "SQL File"
        case "r": return "R File"
        case "lua": return "Lua File"
        case "dart": return "Dart File"
        case "kt": return "Kotlin File"
        case "vue": return "Vue File"
        case "jsx", "tsx": return "React File"
        default: return ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        }
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
