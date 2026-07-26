import Foundation

struct OperationIssue: Sendable, Equatable {
    let message: String
}

struct OperationValidation: Identifiable, Sendable, Equatable {
    let id: Int
    let operation: AIPlanOperation
    let issues: [OperationIssue]

    var isConflicted: Bool { !issues.isEmpty }
}

struct PlanValidationResult: Sendable, Equatable {
    let operations: [OperationValidation]

    var isExecutable: Bool {
        !operations.isEmpty && operations.allSatisfy { $0.issues.isEmpty }
    }

    var conflictedOperations: [OperationValidation] {
        operations.filter(\.isConflicted)
    }
}

struct PlanValidationError: LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? { message }
}

enum PlanValidator {
    static let maximumOperationCount = 500

    static func validate(
        _ plan: AIPlan,
        scopeRoot: URL,
        fileManager: FileManager = .default
    ) throws -> PlanValidationResult {
        try validate(plan.operations ?? [], scopeRoot: scopeRoot, fileManager: fileManager)
    }

    static func validate(
        _ operations: [AIPlanOperation],
        scopeRoot: URL,
        fileManager: FileManager = .default
    ) throws -> PlanValidationResult {
        guard operations.count <= maximumOperationCount else {
            throw PlanValidationError(
                message: "The plan contains \(operations.count) operations; the limit is \(maximumOperationCount)."
            )
        }

        let root = scopeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = try operations.map { try resolve($0, in: root) }

        var destinationCounts: [String: Int] = [:]
        for item in resolved {
            if let destination = item.destination {
                destinationCounts[pathKey(destination), default: 0] += 1
            }
        }

        var createdPaths: Set<String> = []
        var removedPaths: Set<String> = []
        var results: [OperationValidation] = []

        for (index, item) in resolved.enumerated() {
            var issues: [OperationIssue] = []

            if let source = item.source {
                let key = pathKey(source)
                let existsOnDisk = fileManager.fileExists(atPath: source.path) && !removedPaths.contains(key)
                if !existsOnDisk && !createdPaths.contains(key) {
                    issues.append(OperationIssue(message: "“\(item.sourceDisplay ?? source.lastPathComponent)” does not exist."))
                }
            }

            if item.isCreateFolder, let destination = item.destination {
                let parent = destination.deletingLastPathComponent()
                let parentKey = pathKey(parent)
                let parentOnDisk = fileManager.fileExists(atPath: parent.path) && !removedPaths.contains(parentKey)
                if parent.path != root.path && !parentOnDisk && !createdPaths.contains(parentKey) {
                    issues.append(OperationIssue(
                        message: "The parent folder for “\(item.destinationDisplay ?? destination.lastPathComponent)” does not exist."
                    ))
                }
            }

            if let destination = item.destination {
                let key = pathKey(destination)
                let display = item.destinationDisplay ?? destination.lastPathComponent
                if destinationCounts[key, default: 0] > 1 {
                    issues.append(OperationIssue(message: "Multiple operations target “\(display)”."))
                }
                let isCaseOnlySelfTarget = item.source.map { pathKey($0) == key } ?? false
                let occupiedOnDisk = fileManager.fileExists(atPath: destination.path) && !removedPaths.contains(key)
                if !isCaseOnlySelfTarget && (occupiedOnDisk || createdPaths.contains(key)) {
                    issues.append(OperationIssue(message: "An item named “\(display)” already exists."))
                }
            }

            switch item.operation {
            case .createFolder:
                if let destination = item.destination {
                    createdPaths.insert(pathKey(destination))
                }
            case .move, .rename:
                if let source = item.source {
                    createdPaths.remove(pathKey(source))
                    removedPaths.insert(pathKey(source))
                }
                if let destination = item.destination {
                    createdPaths.insert(pathKey(destination))
                    removedPaths.remove(pathKey(destination))
                }
            case .copy:
                if let destination = item.destination {
                    createdPaths.insert(pathKey(destination))
                    removedPaths.remove(pathKey(destination))
                }
            case .trash:
                if let source = item.source {
                    createdPaths.remove(pathKey(source))
                    removedPaths.insert(pathKey(source))
                }
            }

            results.append(OperationValidation(id: index, operation: item.operation, issues: issues))
        }

        return PlanValidationResult(operations: results)
    }

    private struct ResolvedOperation {
        let operation: AIPlanOperation
        let source: URL?
        let sourceDisplay: String?
        let destination: URL?
        let destinationDisplay: String?
        let isCreateFolder: Bool
    }

    private static func resolve(_ operation: AIPlanOperation, in root: URL) throws -> ResolvedOperation {
        switch operation {
        case .createFolder(let path):
            return ResolvedOperation(
                operation: operation,
                source: nil,
                sourceDisplay: nil,
                destination: try resolvePath(path, in: root),
                destinationDisplay: path,
                isCreateFolder: true
            )
        case .move(let source, let destination), .copy(let source, let destination):
            return ResolvedOperation(
                operation: operation,
                source: try resolveSourcePath(source, in: root),
                sourceDisplay: source,
                destination: try resolvePath(destination, in: root),
                destinationDisplay: destination,
                isCreateFolder: false
            )
        case .rename(let source, let newName):
            if let nameIssue = FileOperationService.validationError(forFileName: newName) {
                throw PlanValidationError(message: nameIssue)
            }
            let resolvedSource = try resolveSourcePath(source, in: root)
            return ResolvedOperation(
                operation: operation,
                source: resolvedSource,
                sourceDisplay: source,
                destination: resolvedSource.deletingLastPathComponent().appendingPathComponent(newName),
                destinationDisplay: newName,
                isCreateFolder: false
            )
        case .trash(let source):
            return ResolvedOperation(
                operation: operation,
                source: try resolveSourcePath(source, in: root),
                sourceDisplay: source,
                destination: nil,
                destinationDisplay: nil,
                isCreateFolder: false
            )
        }
    }

    private static func resolveSourcePath(_ relativePath: String, in root: URL) throws -> URL {
        let resolved = try resolvePath(relativePath, in: root)
        guard resolved.path != root.path else {
            throw PlanValidationError(message: "The plan may not operate on the current folder itself.")
        }
        return resolved
    }

    private static func resolvePath(_ relativePath: String, in root: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlanValidationError(message: "The plan contains an operation with an empty path.")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw PlanValidationError(
                message: "“\(trimmed)” is an absolute path; only paths inside the current folder are allowed."
            )
        }
        guard !trimmed.split(separator: "/").contains("..") else {
            throw PlanValidationError(message: "“\(trimmed)” points outside the current folder.")
        }
        let resolved = root.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw PlanValidationError(message: "“\(trimmed)” escapes the current folder.")
        }
        return resolved
    }

    private static func pathKey(_ url: URL) -> String {
        url.path.lowercased()
    }
}
