import Foundation

struct AISearchMatcher: Sendable {
    let criteria: AISearchCriteria

    var isRecursive: Bool { criteria.recursive ?? true }

    func matches(_ item: FileItem) -> Bool {
        matches(
            name: item.name,
            size: item.isDirectory ? nil : item.size,
            modificationDate: item.modificationDate
        )
    }

    func matches(name: String, size: Int64?, modificationDate: Date?) -> Bool {
        if let fragments = criteria.nameContains, !fragments.isEmpty {
            let matchesAnyFragment = fragments.contains { fragment in
                !fragment.isEmpty && name.range(of: fragment, options: [.caseInsensitive]) != nil
            }
            if !matchesAnyFragment { return false }
        }

        if let extensions = criteria.extensions, !extensions.isEmpty {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            let allowed = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            if !allowed.contains(fileExtension) || fileExtension.isEmpty { return false }
        }

        if let after = criteria.modifiedAfter {
            guard let modificationDate, modificationDate >= after else { return false }
        }
        if let before = criteria.modifiedBefore {
            guard let modificationDate, modificationDate <= before else { return false }
        }

        if let minSize = criteria.minSize, minSize > 0 {
            guard let size, size >= minSize else { return false }
        }
        if let maxSize = criteria.maxSize, maxSize > 0 {
            guard let size, size <= maxSize else { return false }
        }

        return true
    }
}
