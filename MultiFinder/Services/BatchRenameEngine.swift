import Foundation

enum BatchRenameMode: Sendable {
    case findReplace(find: String, replace: String, useRegex: Bool, caseSensitive: Bool)
    case addText(prefix: String, suffix: String)
    case sequence(format: String, start: Int, padding: Int)
}

struct BatchRenamePreviewRow: Identifiable, Sendable {
    let id: URL
    let source: URL
    let originalName: String
    let newName: String
    let issue: String?

    var isNoOp: Bool { newName == originalName }
    var isRenamed: Bool { !isNoOp && issue == nil }
}

enum BatchRenameEngine {
    static func configurationIssue(for mode: BatchRenameMode) -> String? {
        switch mode {
        case .findReplace(let find, _, let useRegex, let caseSensitive):
            if useRegex, !find.isEmpty, regularExpression(for: find, caseSensitive: caseSensitive) == nil {
                return L10n.string("The regular expression is invalid.")
            }
            return nil
        case .addText:
            return nil
        case .sequence(_, let start, let padding):
            if start < 0 {
                return L10n.string("The start number cannot be negative.")
            }
            if !(1...10).contains(padding) {
                return L10n.string("Padding must be between 1 and 10 digits.")
            }
            return nil
        }
    }

    static func newName(for originalName: String, index: Int, mode: BatchRenameMode) -> String {
        switch mode {
        case .findReplace(let find, let replace, let useRegex, let caseSensitive):
            guard !find.isEmpty else { return originalName }
            if useRegex {
                guard let regex = regularExpression(for: find, caseSensitive: caseSensitive) else {
                    return originalName
                }
                let range = NSRange(originalName.startIndex..., in: originalName)
                return regex.stringByReplacingMatches(
                    in: originalName,
                    range: range,
                    withTemplate: replace
                )
            }
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return originalName.replacingOccurrences(of: find, with: replace, options: options)

        case .addText(let prefix, let suffix):
            guard !prefix.isEmpty || !suffix.isEmpty else { return originalName }
            let fileExtension = (originalName as NSString).pathExtension
            if fileExtension.isEmpty {
                return prefix + originalName + suffix
            }
            let stem = (originalName as NSString).deletingPathExtension
            return prefix + stem + suffix + "." + fileExtension

        case .sequence(let format, let start, let padding):
            let number = String(format: "%0\(max(1, min(padding, 10)))d", start + index)
            let stem = format.contains("{n}")
                ? format.replacingOccurrences(of: "{n}", with: number)
                : format + number
            let fileExtension = (originalName as NSString).pathExtension
            return fileExtension.isEmpty ? stem : stem + "." + fileExtension
        }
    }

    static func preview(
        urls: [URL],
        mode: BatchRenameMode,
        existingNames: Set<String>
    ) -> [BatchRenamePreviewRow] {
        let lowercasedExisting = Set(existingNames.map { $0.lowercased() })
        let newNames = urls.enumerated().map { index, url in
            newName(for: url.lastPathComponent, index: index, mode: mode)
        }
        var targetCounts: [String: Int] = [:]
        for name in newNames {
            targetCounts[name.lowercased(), default: 0] += 1
        }

        return zip(urls, newNames).map { url, newName in
            let originalName = url.lastPathComponent
            let issue: String?
            if newName == originalName {
                issue = nil
            } else if let validationError = FileOperationService.validationError(forFileName: newName) {
                issue = validationError
            } else if targetCounts[newName.lowercased(), default: 0] > 1 {
                issue = L10n.format("Multiple items would be renamed to “%@”.", newName)
            } else if lowercasedExisting.contains(newName.lowercased()),
                      newName.lowercased() != originalName.lowercased() {
                issue = L10n.format("An item named “%@” already exists.", newName)
            } else {
                issue = nil
            }
            return BatchRenamePreviewRow(
                id: url,
                source: url,
                originalName: originalName,
                newName: newName,
                issue: issue
            )
        }
    }

    static func canApply(_ rows: [BatchRenamePreviewRow], mode: BatchRenameMode) -> Bool {
        configurationIssue(for: mode) == nil
            && rows.allSatisfy { $0.issue == nil }
            && rows.contains { $0.isRenamed }
    }

    private static func regularExpression(for pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
}
