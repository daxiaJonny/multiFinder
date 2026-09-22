import Foundation
import Combine
import Darwin

enum FileConflictResolution: String, Sendable {
    case replace
    case skip
    case keepBoth
    case cancel
}

enum NewFileTemplate: String, CaseIterable, Sendable {
    case text
    case markdown
    case json

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .json: return "json"
        }
    }

    var baseName: String { L10n.string("untitled") }

    var contents: String {
        switch self {
        case .text, .markdown: return ""
        case .json: return "{}\n"
        }
    }

    var menuTitle: String {
        switch self {
        case .text: return L10n.string("Text File")
        case .markdown: return L10n.string("Markdown File")
        case .json: return L10n.string("JSON File")
        }
    }
}

enum FileConflictPolicy: String, Sendable {
    case ask
    case replace
    case skip
    case keepBoth
}

enum FileOperationKind: String, Sendable {
    case copy = "Copy"
    case move = "Move"
    case trash = "Move to Trash"
    case rename = "Rename"
    case createFolder = "New Folder"
    case createFile = "New File"
    case batchRename = "Batch Rename"
    case compress = "Compress"
    case extract = "Extract"
    case aiOrganize = "AI Organize"

    var localizedName: String {
        switch self {
        case .copy: return L10n.string("Copy")
        case .move: return L10n.string("Move")
        case .trash: return L10n.string("Move to Trash")
        case .rename: return L10n.string("Rename")
        case .createFolder: return L10n.string("New Folder")
        case .createFile: return L10n.string("New File")
        case .batchRename: return L10n.string("Batch Rename")
        case .compress: return L10n.string("Compress")
        case .extract: return L10n.string("Extract")
        case .aiOrganize: return L10n.string("AI Organize")
        }
    }
}

struct BatchRenamePair: Hashable, Sendable {
    let source: URL
    let destination: URL
}

enum FileOperationStatus: String, Sendable {
    case completed
    case partial
    case failed
    case cancelled
    case undone

    var localizedName: String {
        switch self {
        case .completed: return L10n.string("Completed")
        case .partial: return L10n.string("Partially Completed")
        case .failed: return L10n.string("Failed")
        case .cancelled: return L10n.string("Cancelled")
        case .undone: return L10n.string("Undone")
        }
    }
}

enum FileItemOperationStatus: String, Sendable {
    case completed
    case skipped
    case failed
    case cancelled
}

struct FileItemOperationOutcome: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL?
    let status: FileItemOperationStatus
    let errorMessage: String?
}

struct FileOperationResult: Sendable {
    let status: FileOperationStatus
    let outcomes: [FileItemOperationOutcome]
    let errorMessage: String?

    var completedOutcomes: [FileItemOperationOutcome] {
        outcomes.filter { $0.status == .completed }
    }

    var skippedOutcomes: [FileItemOperationOutcome] {
        outcomes.filter { $0.status == .skipped }
    }

    var failedOutcomes: [FileItemOperationOutcome] {
        outcomes.filter { $0.status == .failed }
    }

    var unresolvedSourceURLs: [URL] {
        outcomes.compactMap { outcome in
            outcome.status == .completed ? nil : outcome.source
        }
    }
}

struct FileOperationProgress: Identifiable, Sendable {
    let id: UUID
    let kind: FileOperationKind
    let totalUnitCount: Int
    var completedUnitCount: Int

    var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return Double(completedUnitCount) / Double(totalUnitCount)
    }
}

struct FileConflict: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL
    let kind: FileOperationKind
}

struct FileOperationRecord: Identifiable, Sendable {
    let id: UUID
    let kind: FileOperationKind
    let date: Date
    var status: FileOperationStatus
    let itemCount: Int
    let errorMessage: String?
    let outcomes: [FileItemOperationOutcome]

    fileprivate let request: FileOperationRequest
    fileprivate let retryRequest: FileOperationRequest?
    fileprivate let changes: [FileOperationChange]
}

struct FileOperationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

fileprivate enum FileOperationRequest: Sendable {
    case copy(sources: [URL], destination: URL, policy: FileConflictPolicy)
    case move(sources: [URL], destination: URL, policy: FileConflictPolicy)
    case trash(urls: [URL])
    case rename(source: URL, destination: URL, policy: FileConflictPolicy)
    case createFolder(parent: URL, baseName: String)
    case createFile(parent: URL, baseName: String, fileExtension: String, contents: String)
    case batchRename(pairs: [BatchRenamePair])
    case compress(sources: [URL])
    case extract(archives: [URL])
    case aiOrganize(operations: [AIPlanOperation], scopeRoot: URL)

    var kind: FileOperationKind {
        switch self {
        case .copy: return .copy
        case .move: return .move
        case .trash: return .trash
        case .rename: return .rename
        case .createFolder: return .createFolder
        case .createFile: return .createFile
        case .batchRename: return .batchRename
        case .compress: return .compress
        case .extract: return .extract
        case .aiOrganize: return .aiOrganize
        }
    }

    var itemCount: Int {
        switch self {
        case .copy(let sources, _, _), .move(let sources, _, _): return sources.count
        case .trash(let urls): return urls.count
        case .rename, .createFolder, .createFile: return 1
        case .batchRename(let pairs): return pairs.count
        case .compress(let sources): return sources.isEmpty ? 0 : 1
        case .extract(let archives): return archives.count
        case .aiOrganize(let operations, _): return operations.count
        }
    }

    func retryingFailedItems(from outcomes: [FileItemOperationOutcome]) -> FileOperationRequest? {
        let failedSources = Set(
            outcomes.lazy
                .filter { $0.status == .failed }
                .map { $0.source.standardizedFileURL }
        )
        guard !failedSources.isEmpty else { return nil }

        switch self {
        case .copy(let sources, let destination, let policy):
            let failed = sources.filter { failedSources.contains($0.standardizedFileURL) }
            return failed.isEmpty ? nil : .copy(sources: failed, destination: destination, policy: policy)
        case .move(let sources, let destination, let policy):
            let failed = sources.filter { failedSources.contains($0.standardizedFileURL) }
            return failed.isEmpty ? nil : .move(sources: failed, destination: destination, policy: policy)
        case .trash(let urls):
            let failed = urls.filter { failedSources.contains($0.standardizedFileURL) }
            return failed.isEmpty ? nil : .trash(urls: failed)
        case .rename, .createFolder, .createFile, .compress:
            return self
        case .batchRename(let pairs):
            let failed = pairs.filter { failedSources.contains($0.source.standardizedFileURL) }
            return failed.isEmpty ? nil : .batchRename(pairs: failed)
        case .extract(let archives):
            let failed = archives.filter { failedSources.contains($0.standardizedFileURL) }
            return failed.isEmpty ? nil : .extract(archives: failed)
        case .aiOrganize(let operations, let scopeRoot):
            let failed = operations.filter { operation in
                failedSources.contains(
                    FileOperationService.aiOperationSource(operation, scopeRoot: scopeRoot).standardizedFileURL
                )
            }
            return failed.isEmpty ? nil : .aiOrganize(operations: failed, scopeRoot: scopeRoot)
        }
    }
}

fileprivate struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

fileprivate enum FileOperationChange: Sendable {
    case created(URL, identity: FileIdentity)
    case moved(from: URL, to: URL, identity: FileIdentity)
    case trashed(original: URL, trashed: URL, identity: FileIdentity)

    var currentURL: URL {
        switch self {
        case .created(let url, _): return url
        case .moved(_, let to, _): return to
        case .trashed(_, let trashed, _): return trashed
        }
    }
}

private enum ArchiveEntryKind: Sendable, Equatable {
    case directory
    case regular
    case symbolicLink
    case hardLink
}

private struct ArchiveEntry: Sendable {
    let path: String
    let kind: ArchiveEntryKind
    let linkTarget: String?
}

@MainActor
final class FileOperationService: ObservableObject {
    static let shared = FileOperationService()

    @Published private(set) var activeOperation: FileOperationProgress?
    @Published private(set) var pendingConflict: FileConflict?
    @Published private(set) var history: [FileOperationRecord] = []
    @Published private(set) var queuedOperationCount = 0

    var canUndo: Bool { activeTask == nil && queue.isEmpty && !undoStack.isEmpty }
    var canRedo: Bool { activeTask == nil && queue.isEmpty && !redoStack.isEmpty }

    private struct QueuedOperation {
        enum Origin {
            case normal
            case retry
            case redo(FileOperationRecord)
        }

        let id: UUID
        let request: FileOperationRequest
        let origin: Origin
        let completion: ((FileOperationResult) -> Void)?
    }

    private struct ExecutionResult {
        let status: FileOperationStatus
        let changes: [FileOperationChange]
        let outcomes: [FileItemOperationOutcome]
        let errorMessage: String?

        var publicResult: FileOperationResult {
            FileOperationResult(status: status, outcomes: outcomes, errorMessage: errorMessage)
        }
    }

    private struct TransferResult: Sendable {
        let destination: URL
        let changes: [FileOperationChange]
        let skipped: Bool
    }

    private struct WorkerFailure: LocalizedError, Sendable {
        let message: String
        let changes: [FileOperationChange]

        var errorDescription: String? { message }
    }

    private var queue: [QueuedOperation] = []
    private var activeTask: Task<Void, Never>?
    private var conflictContinuation: CheckedContinuation<FileConflictResolution, Never>?
    private var applyToAllResolution: FileConflictResolution?
    private var undoStack: [FileOperationRecord] = []
    private var redoStack: [FileOperationRecord] = []
    private let replacementInstallHook: (@Sendable () throws -> Void)?
    private let volumeIdentifierProvider: (@Sendable (URL) throws -> UInt64)?

    init(
        replacementInstallHook: (@Sendable () throws -> Void)? = nil,
        volumeIdentifierProvider: (@Sendable (URL) throws -> UInt64)? = nil
    ) {
        self.replacementInstallHook = replacementInstallHook
        self.volumeIdentifierProvider = volumeIdentifierProvider
    }

    func copy(
        _ sources: [URL],
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(
            .copy(sources: sources, destination: destination, policy: conflictPolicy),
            completion: legacyCompletion(completion)
        )
    }

    func copyDetailed(
        _ sources: [URL],
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.copy(sources: sources, destination: destination, policy: conflictPolicy), completion: completion)
    }

    func move(
        _ sources: [URL],
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(
            .move(sources: sources, destination: destination, policy: conflictPolicy),
            completion: legacyCompletion(completion)
        )
    }

    func moveDetailed(
        _ sources: [URL],
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.move(sources: sources, destination: destination, policy: conflictPolicy), completion: completion)
    }

    func trash(
        _ urls: [URL],
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(.trash(urls: urls), completion: legacyCompletion(completion))
    }

    func trashDetailed(
        _ urls: [URL],
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.trash(urls: urls), completion: completion)
    }

    func rename(
        _ source: URL,
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(
            .rename(source: source, destination: destination, policy: conflictPolicy),
            completion: legacyCompletion(completion)
        )
    }

    func renameDetailed(
        _ source: URL,
        to destination: URL,
        conflictPolicy: FileConflictPolicy = .ask,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.rename(source: source, destination: destination, policy: conflictPolicy), completion: completion)
    }

    func createFolder(
        in parent: URL,
        baseName: String = L10n.string("untitled folder"),
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(
            .createFolder(parent: parent, baseName: baseName),
            completion: legacyCompletion(completion)
        )
    }

    func createFolderDetailed(
        in parent: URL,
        baseName: String = L10n.string("untitled folder"),
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.createFolder(parent: parent, baseName: baseName), completion: completion)
    }

    func createFileDetailed(
        in parent: URL,
        template: NewFileTemplate,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(
            .createFile(
                parent: parent,
                baseName: template.baseName,
                fileExtension: template.fileExtension,
                contents: template.contents
            ),
            completion: completion
        )
    }

    func batchRenameDetailed(
        _ pairs: [BatchRenamePair],
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.batchRename(pairs: pairs), completion: completion)
    }

    func compressDetailed(
        _ sources: [URL],
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.compress(sources: sources), completion: completion)
    }

    func extractDetailed(
        _ archives: [URL],
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.extract(archives: archives), completion: completion)
    }

    func aiOrganizeDetailed(
        _ operations: [AIPlanOperation],
        scopeRoot: URL,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.aiOrganize(operations: operations, scopeRoot: scopeRoot), completion: completion)
    }

    func cancelCurrent() {
        activeTask?.cancel()
        if conflictContinuation != nil {
            resolveConflict(.cancel, applyToAll: false)
        }
    }

    func resolveConflict(_ resolution: FileConflictResolution, applyToAll: Bool) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil
        pendingConflict = nil
        if applyToAll {
            applyToAllResolution = resolution
        }
        continuation.resume(returning: resolution)
    }

    func retry(_ recordID: UUID) {
        guard let record = history.first(where: { $0.id == recordID && $0.status == .failed }),
              let retryRequest = record.retryRequest else { return }
        enqueue(retryRequest, origin: .retry)
    }

    func undo() {
        guard activeTask == nil, queue.isEmpty, let record = undoStack.popLast() else { return }

        activeOperation = FileOperationProgress(
            id: UUID(),
            kind: record.kind,
            totalUnitCount: max(record.changes.count, 1),
            completedUnitCount: 0
        )
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.reverse(record.changes)
                if let index = history.firstIndex(where: { $0.id == record.id }) {
                    history[index].status = .undone
                }
                redoStack.append(record)
            } catch {
                undoStack.append(record)
                history.insert(
                    Self.failureRecord(
                        for: record.request,
                        message: L10n.format("Undo failed: %@", error.localizedDescription)
                    ),
                    at: 0
                )
            }
            activeOperation = nil
            activeTask = nil
        }
    }

    func redo() {
        guard activeTask == nil, queue.isEmpty, let record = redoStack.popLast() else { return }
        enqueue(record.request, origin: .redo(record))
    }

    nonisolated static func validationError(forFileName name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("A file name cannot be empty.")
        }
        if name == "." || name == ".." {
            return L10n.format("“%@” is reserved and cannot be used as a file name.", name)
        }
        if name.contains("/") || name.unicodeScalars.contains("\0") {
            return L10n.string("File names cannot contain “/” or a null character.")
        }
        return nil
    }

    nonisolated static func isExtractableArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".tar", ".tgz", ".gz"].contains { suffix in
            name.hasSuffix(suffix) && name.count > suffix.count
        }
    }

    nonisolated static func extractionBaseName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lowercased = name.lowercased()
        for suffix in [".tar.gz", ".tgz", ".tar", ".zip", ".gz"]
        where lowercased.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    nonisolated static func uniqueDestination(for source: URL, in directory: URL, fileManager: FileManager = .default) -> URL {
        let original = directory.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let fileExtension = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var counter = 1

        while true {
            let copiedBaseName = counter == 1
                ? L10n.format("%@ copy", baseName)
                : L10n.format("%@ copy %lld", baseName, Int64(counter))
            let candidateName = fileExtension.isEmpty
                ? copiedBaseName
                : "\(copiedBaseName).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func enqueue(
        _ request: FileOperationRequest,
        origin: QueuedOperation.Origin = .normal,
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        guard request.itemCount > 0 else { return }
        if case .normal = origin {
            redoStack.removeAll()
        }
        queue.append(QueuedOperation(id: UUID(), request: request, origin: origin, completion: completion))
        queuedOperationCount = queue.count
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard activeTask == nil, !queue.isEmpty else { return }

        let queued = queue.removeFirst()
        queuedOperationCount = queue.count
        applyToAllResolution = nil
        activeOperation = FileOperationProgress(
            id: queued.id,
            kind: queued.request.kind,
            totalUnitCount: queued.request.itemCount,
            completedUnitCount: 0
        )

        activeTask = Task { [weak self] in
            guard let self else { return }
            let result = await execute(queued.request)
            let record = FileOperationRecord(
                id: queued.id,
                kind: queued.request.kind,
                date: Date(),
                status: result.status,
                itemCount: queued.request.itemCount,
                errorMessage: result.errorMessage,
                outcomes: result.outcomes,
                request: queued.request,
                retryRequest: queued.request.retryingFailedItems(from: result.outcomes),
                changes: result.changes
            )
            history.insert(record, at: 0)

            if !result.changes.isEmpty {
                undoStack.append(record)
            }

            if case .redo(let originalRecord) = queued.origin,
               result.status != .completed,
               result.changes.isEmpty {
                redoStack.append(originalRecord)
            }
            queued.completion?(result.publicResult)

            pendingConflict = nil
            conflictContinuation = nil
            activeOperation = nil
            activeTask = nil
            startNextIfNeeded()
        }
    }

    private func legacyCompletion(
        _ completion: ((Result<Void, FileOperationError>) -> Void)?
    ) -> ((FileOperationResult) -> Void)? {
        guard let completion else { return nil }
        return { result in
            if result.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(FileOperationError(
                    message: result.errorMessage ?? L10n.string("The operation did not complete.")
                )))
            }
        }
    }

    private func execute(_ request: FileOperationRequest) async -> ExecutionResult {
        do {
            try Self.preflightContainment(for: request)
        } catch {
            return Self.preflightFailureResult(for: request, error: error)
        }

        switch request {
        case .copy(let sources, let destination, let policy):
            return await executeTransfers(sources, to: destination, kind: .copy, policy: policy)
        case .move(let sources, let destination, let policy):
            return await executeTransfers(sources, to: destination, kind: .move, policy: policy)
        case .trash(let urls):
            return await executeTrash(urls)
        case .rename(let source, let destination, let policy):
            return await executeRename(source, to: destination, policy: policy)
        case .createFolder(let parent, let baseName):
            return await executeCreateFolder(in: parent, baseName: baseName)
        case .createFile(let parent, let baseName, let fileExtension, let contents):
            return await executeCreateFile(
                in: parent,
                baseName: baseName,
                fileExtension: fileExtension,
                contents: contents
            )
        case .batchRename(let pairs):
            return await executeBatchRename(pairs)
        case .compress(let sources):
            return await executeCompress(sources)
        case .extract(let archives):
            return await executeExtract(archives)
        case .aiOrganize(let operations, let scopeRoot):
            return await executeAIOrganize(operations, scopeRoot: scopeRoot)
        }
    }

    private nonisolated static func preflightContainment(for request: FileOperationRequest) throws {
        switch request {
        case .copy(let sources, let destination, _):
            for source in sources {
                try preflightContainment(
                    source: source,
                    destination: destination,
                    kind: .copy
                )
            }
        case .move(let sources, let destination, _):
            for source in sources {
                try preflightContainment(
                    source: source,
                    destination: destination,
                    kind: .move
                )
            }
        case .aiOrganize(let operations, let scopeRoot):
            let resolve: (String) -> URL = {
                scopeRoot.appendingPathComponent($0).standardizedFileURL
            }
            for operation in operations {
                switch operation {
                case .move(let source, let destination):
                    try preflightContainment(
                        source: resolve(source),
                        destination: resolve(destination),
                        kind: .move
                    )
                case .copy(let source, let destination):
                    try preflightContainment(
                        source: resolve(source),
                        destination: resolve(destination),
                        kind: .copy
                    )
                case .createFolder, .rename, .trash:
                    continue
                }
            }
        case .trash, .rename, .createFolder, .createFile, .batchRename, .compress, .extract:
            return
        }
    }

    private nonisolated static func preflightContainment(
        source: URL,
        destination: URL,
        kind: FileOperationKind
    ) throws {
        guard kind == .copy || kind == .move else { return }
        guard isRealDirectory(at: source) else { return }

        guard let sourcePath = resolvedContainmentPath(for: source),
              let destinationPath = resolvedContainmentPath(for: destination) else {
            throw FileOperationError(
                message: L10n.format(
                    "Could not verify that %@ is safe to copy or move.",
                    source.lastPathComponent
                )
            )
        }

        guard !isSameOrDescendant(destinationPath, of: sourcePath) else {
            throw FileOperationError(
                message: L10n.format(
                    "Cannot %@ “%@” into itself or one of its descendants.",
                    kind.localizedName,
                    source.lastPathComponent
                )
            )
        }
    }

    private nonisolated static func preflightFailureResult(
        for request: FileOperationRequest,
        error: Error
    ) -> ExecutionResult {
        let sources: [URL]
        switch request {
        case .copy(let requestSources, _, _), .move(let requestSources, _, _):
            sources = requestSources
        case .aiOrganize(let operations, let scopeRoot):
            sources = operations.map { aiOperationSource($0, scopeRoot: scopeRoot) }
        default:
            sources = []
        }

        let message = error.localizedDescription
        return ExecutionResult(
            status: .failed,
            changes: [],
            outcomes: sources.map { source in
                FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: message
                )
            },
            errorMessage: message
        )
    }

    private func executeTransfers(
        _ sources: [URL],
        to destination: URL,
        kind: FileOperationKind,
        policy: FileConflictPolicy
    ) async -> ExecutionResult {
        var changes: [FileOperationChange] = []
        var outcomes: [FileItemOperationOutcome] = []
        var wasCancelled = false

        for (index, source) in sources.enumerated() {
            do {
                try Task.checkCancellation()
                let result = try await transfer(source, to: destination, kind: kind, policy: policy)
                changes.append(contentsOf: result.changes)
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: result.destination,
                    status: result.skipped ? .skipped : .completed,
                    errorMessage: nil
                ))
                updateProgress(index + 1)
            } catch is CancellationError {
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                ))
                outcomes.append(contentsOf: sources.dropFirst(index + 1).map { remainingSource in
                    FileItemOperationOutcome(
                        source: remainingSource,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: L10n.string("The operation was cancelled before this item started.")
                    )
                })
                wasCancelled = true
                break
            } catch let error as WorkerFailure {
                changes.append(contentsOf: error.changes)
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            } catch {
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            }
        }

        return Self.executionResult(changes: changes, outcomes: outcomes, wasCancelled: wasCancelled)
    }

    private func executeTrash(_ urls: [URL]) async -> ExecutionResult {
        var changes: [FileOperationChange] = []
        var outcomes: [FileItemOperationOutcome] = []
        var wasCancelled = false

        for (index, url) in urls.enumerated() {
            do {
                try Task.checkCancellation()
                let change = try await Self.trash(url)
                changes.append(change)
                outcomes.append(FileItemOperationOutcome(
                    source: url,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                ))
                updateProgress(index + 1)
            } catch is CancellationError {
                outcomes.append(FileItemOperationOutcome(
                    source: url,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                ))
                outcomes.append(contentsOf: urls.dropFirst(index + 1).map { remainingURL in
                    FileItemOperationOutcome(
                        source: remainingURL,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: L10n.string("The operation was cancelled before this item started.")
                    )
                })
                wasCancelled = true
                break
            } catch {
                outcomes.append(FileItemOperationOutcome(
                    source: url,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            }
        }

        return Self.executionResult(changes: changes, outcomes: outcomes, wasCancelled: wasCancelled)
    }

    private func executeRename(
        _ source: URL,
        to destination: URL,
        policy: FileConflictPolicy
    ) async -> ExecutionResult {
        do {
            try Task.checkCancellation()
            let result = try await transfer(
                source,
                to: destination.deletingLastPathComponent(),
                kind: .rename,
                policy: policy,
                proposedDestination: destination
            )
            updateProgress(1)
            return Self.executionResult(
                changes: result.changes,
                outcomes: [FileItemOperationOutcome(
                    source: source,
                    destination: result.destination,
                    status: result.skipped ? .skipped : .completed,
                    errorMessage: nil
                )]
            )
        } catch is CancellationError {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                )],
                wasCancelled: true
            )
        } catch let error as WorkerFailure {
            return Self.executionResult(
                changes: error.changes,
                outcomes: [FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )]
            )
        } catch {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )]
            )
        }
    }

    private func executeCreateFolder(in parent: URL, baseName: String) async -> ExecutionResult {
        do {
            try Task.checkCancellation()
            let change = try await Self.createUniqueFolder(in: parent, baseName: baseName)
            updateProgress(1)
            return Self.executionResult(
                changes: [change],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                )]
            )
        } catch is CancellationError {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                )],
                wasCancelled: true
            )
        } catch {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )]
            )
        }
    }

    private func executeCreateFile(
        in parent: URL,
        baseName: String,
        fileExtension: String,
        contents: String
    ) async -> ExecutionResult {
        do {
            try Task.checkCancellation()
            let change = try await Self.createUniqueFile(
                in: parent,
                baseName: baseName,
                fileExtension: fileExtension,
                contents: contents
            )
            updateProgress(1)
            return Self.executionResult(
                changes: [change],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                )]
            )
        } catch is CancellationError {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                )],
                wasCancelled: true
            )
        } catch {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: parent,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )]
            )
        }
    }

    private func executeBatchRename(_ pairs: [BatchRenamePair]) async -> ExecutionResult {
        var changes: [FileOperationChange] = []
        var outcomes: [FileItemOperationOutcome] = []
        var wasCancelled = false

        for (index, pair) in pairs.enumerated() {
            do {
                try Task.checkCancellation()
                let change = try await Self.renameItem(pair.source, to: pair.destination)
                changes.append(change)
                outcomes.append(FileItemOperationOutcome(
                    source: pair.source,
                    destination: pair.destination,
                    status: .completed,
                    errorMessage: nil
                ))
                updateProgress(index + 1)
            } catch is CancellationError {
                outcomes.append(FileItemOperationOutcome(
                    source: pair.source,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                ))
                outcomes.append(contentsOf: pairs.dropFirst(index + 1).map { remainingPair in
                    FileItemOperationOutcome(
                        source: remainingPair.source,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: L10n.string("The operation was cancelled before this item started.")
                    )
                })
                wasCancelled = true
                break
            } catch {
                outcomes.append(FileItemOperationOutcome(
                    source: pair.source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            }
        }

        return Self.executionResult(changes: changes, outcomes: outcomes, wasCancelled: wasCancelled)
    }

    private func executeCompress(_ sources: [URL]) async -> ExecutionResult {
        guard let firstSource = sources.first else {
            return Self.executionResult(changes: [], outcomes: [])
        }
        do {
            try Task.checkCancellation()
            let change = try await Self.compress(sources)
            updateProgress(1)
            return Self.executionResult(
                changes: [change],
                outcomes: [FileItemOperationOutcome(
                    source: firstSource,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                )]
            )
        } catch is CancellationError {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: firstSource,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                )],
                wasCancelled: true
            )
        } catch {
            return Self.executionResult(
                changes: [],
                outcomes: [FileItemOperationOutcome(
                    source: firstSource,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )]
            )
        }
    }

    private func executeExtract(_ archives: [URL]) async -> ExecutionResult {
        var changes: [FileOperationChange] = []
        var outcomes: [FileItemOperationOutcome] = []
        var wasCancelled = false

        for (index, archive) in archives.enumerated() {
            do {
                try Task.checkCancellation()
                let change = try await Self.extract(archive)
                changes.append(change)
                outcomes.append(FileItemOperationOutcome(
                    source: archive,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                ))
                updateProgress(index + 1)
            } catch is CancellationError {
                outcomes.append(FileItemOperationOutcome(
                    source: archive,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                ))
                outcomes.append(contentsOf: archives.dropFirst(index + 1).map { remainingArchive in
                    FileItemOperationOutcome(
                        source: remainingArchive,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: L10n.string("The operation was cancelled before this item started.")
                    )
                })
                wasCancelled = true
                break
            } catch {
                outcomes.append(FileItemOperationOutcome(
                    source: archive,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            }
        }

        return Self.executionResult(changes: changes, outcomes: outcomes, wasCancelled: wasCancelled)
    }

    private func executeAIOrganize(_ operations: [AIPlanOperation], scopeRoot: URL) async -> ExecutionResult {
        var changes: [FileOperationChange] = []
        var outcomes: [FileItemOperationOutcome] = []
        var wasCancelled = false

        for (index, operation) in operations.enumerated() {
            let source = Self.aiOperationSource(operation, scopeRoot: scopeRoot)
            do {
                try Task.checkCancellation()
                let change = try await Self.performAIOperation(operation, scopeRoot: scopeRoot)
                changes.append(change)
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: change.currentURL,
                    status: .completed,
                    errorMessage: nil
                ))
                updateProgress(index + 1)
            } catch is CancellationError {
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .cancelled,
                    errorMessage: L10n.string("The operation was cancelled.")
                ))
                outcomes.append(contentsOf: operations.dropFirst(index + 1).map { remainingOperation in
                    FileItemOperationOutcome(
                        source: Self.aiOperationSource(remainingOperation, scopeRoot: scopeRoot),
                        destination: nil,
                        status: .cancelled,
                        errorMessage: L10n.string("The operation was cancelled before this item started.")
                    )
                })
                wasCancelled = true
                break
            } catch {
                outcomes.append(FileItemOperationOutcome(
                    source: source,
                    destination: nil,
                    status: .failed,
                    errorMessage: error.localizedDescription
                ))
                updateProgress(index + 1)
            }
        }

        return Self.executionResult(changes: changes, outcomes: outcomes, wasCancelled: wasCancelled)
    }

    fileprivate nonisolated static func aiOperationSource(
        _ operation: AIPlanOperation,
        scopeRoot: URL
    ) -> URL {
        switch operation {
        case .createFolder(let path):
            return scopeRoot.appendingPathComponent(path).standardizedFileURL
        case .move(let source, _), .copy(let source, _), .rename(let source, _), .trash(let source):
            return scopeRoot.appendingPathComponent(source).standardizedFileURL
        }
    }

    private nonisolated static func performAIOperation(
        _ operation: AIPlanOperation,
        scopeRoot: URL
    ) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            let resolve: (String) -> URL = { scopeRoot.appendingPathComponent($0).standardizedFileURL }
            try Task.checkCancellation()

            switch operation {
            case .createFolder(let path):
                let destination = resolve(path)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                return .created(destination, identity: try fileIdentity(at: destination))
            case .move(let source, let destination):
                let sourceURL = resolve(source)
                let destinationURL = resolve(destination)
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw FileOperationError(
                        message: L10n.format(
                            "An item named “%@” already exists.",
                            destinationURL.lastPathComponent
                        )
                    )
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return .moved(from: sourceURL, to: destinationURL, identity: try fileIdentity(at: destinationURL))
            case .copy(let source, let destination):
                let sourceURL = resolve(source)
                let destinationURL = resolve(destination)
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw FileOperationError(
                        message: L10n.format(
                            "An item named “%@” already exists.",
                            destinationURL.lastPathComponent
                        )
                    )
                }
                try copyItemCancellable(from: sourceURL, to: destinationURL, fileManager: fileManager)
                return .created(destinationURL, identity: try fileIdentity(at: destinationURL))
            case .rename(let source, let newName):
                let sourceURL = resolve(source)
                let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
                if sourceURL.path.caseInsensitiveCompare(destinationURL.path) != .orderedSame,
                   fileManager.fileExists(atPath: destinationURL.path) {
                    throw FileOperationError(
                        message: L10n.format("An item named “%@” already exists.", newName)
                    )
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return .moved(from: sourceURL, to: destinationURL, identity: try fileIdentity(at: destinationURL))
            case .trash(let source):
                return try trashSynchronously(resolve(source), fileManager: fileManager)
            }
        }
    }

    private nonisolated static func executionResult(
        changes: [FileOperationChange],
        outcomes: [FileItemOperationOutcome],
        wasCancelled: Bool = false
    ) -> ExecutionResult {
        let failed = outcomes.filter { $0.status == .failed }
        let skipped = outcomes.filter { $0.status == .skipped }
        let status: FileOperationStatus
        let errorMessage: String?

        if wasCancelled || outcomes.contains(where: { $0.status == .cancelled }) {
            status = .cancelled
            errorMessage = L10n.string("The operation was cancelled.")
        } else if !failed.isEmpty {
            status = .failed
            errorMessage = failed.count == 1
                ? failed[0].errorMessage
                : L10n.format("%lld items could not be processed.", Int64(failed.count))
        } else if !skipped.isEmpty {
            status = .partial
            errorMessage = skipped.count == 1
                ? L10n.string("One item was skipped.")
                : L10n.format("%lld items were skipped.", Int64(skipped.count))
        } else {
            status = .completed
            errorMessage = nil
        }

        return ExecutionResult(
            status: status,
            changes: changes,
            outcomes: outcomes,
            errorMessage: errorMessage
        )
    }

    private func transfer(
        _ source: URL,
        to directory: URL,
        kind: FileOperationKind,
        policy: FileConflictPolicy,
        proposedDestination: URL? = nil
    ) async throws -> TransferResult {
        var destination = proposedDestination ?? directory.appendingPathComponent(source.lastPathComponent)

        if source.standardizedFileURL == destination.standardizedFileURL {
            if kind == .copy {
                destination = Self.uniqueDestination(for: destination, in: directory)
            } else {
                return TransferResult(destination: destination, changes: [], skipped: true)
            }
        }

        var replacing = false
        let isCaseOnlyRename = kind == .rename &&
            (try? Self.isCaseOnlyRename(source: source, destination: destination)) == true
        if FileManager.default.fileExists(atPath: destination.path) && !isCaseOnlyRename {
            let resolution = await conflictResolution(
                for: FileConflict(source: source, destination: destination, kind: kind),
                policy: policy
            )

            switch resolution {
            case .skip:
                return TransferResult(destination: destination, changes: [], skipped: true)
            case .cancel:
                throw CancellationError()
            case .keepBoth:
                destination = Self.uniqueDestination(for: destination, in: directory)
            case .replace:
                replacing = true
            }
        }

        try Task.checkCancellation()
        let changes = try await Self.performTransfer(
            source: source,
            destination: destination,
            kind: kind,
            replacing: replacing,
            replacementInstallHook: replacementInstallHook,
            volumeIdentifierProvider: volumeIdentifierProvider
        )
        return TransferResult(destination: destination, changes: changes, skipped: false)
    }

    private func conflictResolution(for conflict: FileConflict, policy: FileConflictPolicy) async -> FileConflictResolution {
        if let applyToAllResolution {
            return applyToAllResolution
        }

        switch policy {
        case .replace: return .replace
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        case .ask:
            pendingConflict = conflict
            return await withCheckedContinuation { continuation in
                conflictContinuation = continuation
            }
        }
    }

    private func updateProgress(_ completed: Int) {
        activeOperation?.completedUnitCount = completed
    }

    private nonisolated static func performTransfer(
        source: URL,
        destination: URL,
        kind: FileOperationKind,
        replacing: Bool,
        replacementInstallHook: (@Sendable () throws -> Void)?,
        volumeIdentifierProvider: (@Sendable (URL) throws -> UInt64)?
    ) async throws -> [FileOperationChange] {
        try await runWorker {
            let fileManager = FileManager.default
            switch kind {
            case .copy:
                return try performCopy(
                    source: source,
                    destination: destination,
                    replacing: replacing,
                    replacementInstallHook: replacementInstallHook,
                    fileManager: fileManager
                )
            case .move, .rename:
                if kind == .rename, !replacing,
                   (try? isCaseOnlyRename(source: source, destination: destination)) == true {
                    try moveItemReliably(from: source, to: destination, fileManager: fileManager)
                    return [.moved(
                        from: source,
                        to: destination,
                        identity: try fileIdentity(at: destination)
                    )]
                }
                return try performMove(
                    source: source,
                    destination: destination,
                    replacing: replacing,
                    replacementInstallHook: replacementInstallHook,
                    volumeIdentifierProvider: volumeIdentifierProvider,
                    fileManager: fileManager
                )
            case .trash, .createFolder, .createFile, .batchRename, .compress, .extract, .aiOrganize:
                preconditionFailure("Unsupported transfer kind")
            }
        }
    }

    private nonisolated static func trash(_ url: URL) async throws -> FileOperationChange {
        try await runWorker {
            try Task.checkCancellation()
            return try trashSynchronously(url, fileManager: .default)
        }
    }

    private nonisolated static func trashSynchronously(_ url: URL, fileManager: FileManager) throws -> FileOperationChange {
        let identity = try fileIdentity(at: url)
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let trashedURL = resultingURL as URL? else {
            throw FileOperationError(
                message: L10n.format(
                    "The Trash did not return a location for %@.",
                    url.lastPathComponent
                )
            )
        }
        return .trashed(original: url, trashed: trashedURL, identity: identity)
    }

    private nonisolated static func createUniqueFolder(in parent: URL, baseName: String) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            var destination = parent.appendingPathComponent(baseName)
            var counter = 2
            while fileManager.fileExists(atPath: destination.path) {
                try Task.checkCancellation()
                destination = parent.appendingPathComponent("\(baseName) \(counter)")
                counter += 1
            }
            try Task.checkCancellation()
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return .created(destination, identity: try fileIdentity(at: destination))
        }
    }

    private nonisolated static func createUniqueFile(
        in parent: URL,
        baseName: String,
        fileExtension: String,
        contents: String
    ) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            var counter: Int?
            var destination = uniqueFileURL(
                in: parent,
                baseName: baseName,
                fileExtension: fileExtension,
                counter: counter
            )
            while fileManager.fileExists(atPath: destination.path) {
                try Task.checkCancellation()
                counter = (counter ?? 1) + 1
                destination = uniqueFileURL(
                    in: parent,
                    baseName: baseName,
                    fileExtension: fileExtension,
                    counter: counter
                )
            }
            try Task.checkCancellation()
            try Data(contents.utf8).write(to: destination, options: .withoutOverwriting)
            return .created(destination, identity: try fileIdentity(at: destination))
        }
    }

    nonisolated static func uniqueFileURL(
        in parent: URL,
        baseName: String,
        fileExtension: String,
        counter: Int?
    ) -> URL {
        let stem = counter.map { "\(baseName) \($0)" } ?? baseName
        return parent.appendingPathComponent(stem).appendingPathExtension(fileExtension)
    }

    private nonisolated static func renameItem(_ source: URL, to destination: URL) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            try Task.checkCancellation()
            let isCaseOnlyRename = (try? isCaseOnlyRename(source: source, destination: destination)) == true
            if !isCaseOnlyRename,
               fileManager.fileExists(atPath: destination.path) {
                throw FileOperationError(
                    message: L10n.format(
                        "An item named “%@” already exists.",
                        destination.lastPathComponent
                    )
                )
            }
            try moveItemReliably(from: source, to: destination, fileManager: fileManager)
            return .moved(from: source, to: destination, identity: try fileIdentity(at: destination))
        }
    }

    private nonisolated static func compress(_ sources: [URL]) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            guard let firstSource = sources.first else {
                throw FileOperationError(message: L10n.string("There is nothing to compress."))
            }
            let directory = firstSource.deletingLastPathComponent()
            let staging = directory.appendingPathComponent(".multifinder-compress-\(UUID().uuidString).zip")
            defer {
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
            }

            if sources.count == 1 {
                try runProcess(
                    "/usr/bin/ditto",
                    arguments: ["-ck", "--keepParent", "--sequesterRsrc", firstSource.path, staging.path]
                )
            } else {
                guard sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }) else {
                    throw FileOperationError(
                        message: L10n.string("Items can only be compressed together from the same folder.")
                    )
                }
                try runProcess(
                    "/usr/bin/zip",
                    arguments: ["-r", "-y", "-q", staging.path] + sources.map { $0.lastPathComponent },
                    currentDirectory: directory
                )
            }

            try Task.checkCancellation()
            let baseName = sources.count == 1
                ? firstSource.lastPathComponent
                : L10n.string("Archive")
            let destination = uniqueNumberedDestination(
                in: directory,
                baseName: baseName,
                fileExtension: "zip",
                fileManager: fileManager
            )
            try fileManager.moveItem(at: staging, to: destination)
            return .created(destination, identity: try fileIdentity(at: destination))
        }
    }

    private nonisolated static func extract(_ archive: URL) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            let directory = archive.deletingLastPathComponent()
            let name = archive.lastPathComponent
            let lowercased = name.lowercased()
            let staging = directory.appendingPathComponent(".multifinder-extract-\(UUID().uuidString)")
            defer {
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

            if lowercased.hasSuffix(".zip") {
                let entries = try inspectZipArchive(
                    archive,
                    staging: staging,
                    fileManager: fileManager
                )
                try validateArchiveEntries(entries)
                try runProcess("/usr/bin/ditto", arguments: ["-xk", archive.path, staging.path])
            } else if lowercased.hasSuffix(".tar") || lowercased.hasSuffix(".tar.gz") || lowercased.hasSuffix(".tgz") {
                let entries = try inspectTarArchive(
                    archive,
                    staging: staging,
                    fileManager: fileManager
                )
                try validateArchiveEntries(entries)
                try runProcess("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", staging.path])
            } else if lowercased.hasSuffix(".gz") {
                let outputName = String(name.dropLast(3))
                let outputURL = staging.appendingPathComponent(
                    outputName.isEmpty ? L10n.string("extracted") : outputName
                )
                guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
                    throw FileOperationError(
                        message: L10n.format("Could not create %@.", outputURL.lastPathComponent)
                    )
                }
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                try runProcess("/usr/bin/gunzip", arguments: ["-c", archive.path], standardOutput: output)
            } else {
                throw FileOperationError(
                    message: L10n.format("“%@” is not a supported archive.", name)
                )
            }

            try Task.checkCancellation()
            try validateExtractedTree(at: staging, fileManager: fileManager)
            let destination = uniqueNumberedDestination(
                in: directory,
                baseName: extractionBaseName(for: archive),
                fileExtension: nil,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: staging, to: destination)
            return .created(destination, identity: try fileIdentity(at: destination))
        }
    }

    private nonisolated static func inspectZipArchive(
        _ archive: URL,
        staging: URL,
        fileManager: FileManager
    ) throws -> [ArchiveEntry] {
        let names = try processOutputData(
            "/usr/bin/zipinfo",
            arguments: ["-1", archive.path],
            staging: staging,
            fileManager: fileManager
        )
        let verbose = try processOutputData(
            "/usr/bin/zipinfo",
            arguments: ["-v", archive.path],
            staging: staging,
            fileManager: fileManager
        )
        let rawNames = try outputLines(from: names)
        let kinds = try zipEntryKinds(from: verbose)
        guard rawNames.count == kinds.count else {
            throw archiveInspectionError()
        }

        var entries: [ArchiveEntry] = []
        for index in rawNames.indices {
            let rawPath = rawNames[index]
            let kind = kinds[index] ?? (rawPath.hasSuffix("/") ? .directory : .regular)
            if rawPath.hasSuffix("/") && kind != .directory {
                throw archiveInspectionError()
            }

            guard let path = try normalizedArchivePath(rawPath) else {
                guard kind == .directory else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                continue
            }

            var linkTarget: String?
            if kind == .symbolicLink || kind == .hardLink {
                let targetData = try processOutputData(
                    "/usr/bin/unzip",
                    arguments: ["-p", archive.path, rawPath],
                    staging: staging,
                    fileManager: fileManager
                )
                guard !targetData.isEmpty, targetData.count <= 4 * 1024,
                      let target = String(data: targetData, encoding: .utf8) else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                linkTarget = target
            }

            entries.append(ArchiveEntry(path: path, kind: kind, linkTarget: linkTarget))
        }
        return entries
    }

    private nonisolated static func inspectTarArchive(
        _ archive: URL,
        staging: URL,
        fileManager: FileManager
    ) throws -> [ArchiveEntry] {
        let namesData = try processOutputData(
            "/usr/bin/tar",
            arguments: ["-tf", archive.path],
            staging: staging,
            fileManager: fileManager
        )
        let verboseData = try processOutputData(
            "/usr/bin/tar",
            arguments: ["-tvf", archive.path],
            staging: staging,
            fileManager: fileManager
        )
        let rawNames = try outputLines(from: namesData)
        let verboseLines = try outputLines(from: verboseData)
        guard rawNames.count == verboseLines.count else {
            throw archiveInspectionError()
        }

        var entries: [ArchiveEntry] = []
        for index in rawNames.indices {
            let rawPath = rawNames[index]
            let detail = verboseLines[index]
            guard let type = detail.first else {
                throw archiveInspectionError()
            }

            let kind: ArchiveEntryKind
            let linkTarget: String?
            switch type {
            case "d":
                kind = .directory
                linkTarget = nil
            case "-":
                kind = .regular
                linkTarget = nil
            case "l":
                kind = .symbolicLink
                guard let marker = detail.range(of: " -> ") else {
                    throw archiveInspectionError()
                }
                let target = String(detail[marker.upperBound...])
                guard !target.isEmpty else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                linkTarget = target
            case "h":
                kind = .hardLink
                guard let marker = detail.range(of: " link to ") else {
                    throw archiveInspectionError()
                }
                let target = String(detail[marker.upperBound...])
                guard !target.isEmpty else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                linkTarget = target
            default:
                throw unsafeArchiveEntryError(rawPath)
            }

            guard let path = try normalizedArchivePath(rawPath) else {
                guard kind == .directory else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                continue
            }
            entries.append(ArchiveEntry(path: path, kind: kind, linkTarget: linkTarget))
        }
        return entries
    }

    private nonisolated static func zipEntryKinds(from data: Data) throws -> [ArchiveEntryKind?] {
        let lines = try outputLines(from: data)
        var blocks: [[String]] = []
        for line in lines {
            if line.hasPrefix("Central directory entry #") {
                blocks.append([])
            } else if !blocks.isEmpty {
                blocks[blocks.index(before: blocks.endIndex)].append(line)
            }
        }

        return try blocks.map { block in
            guard let attributesLine = block.first(where: {
                $0.hasPrefix("  Unix file attributes (")
            }) else {
                return nil
            }
            guard let marker = attributesLine.range(of: "): ") else {
                throw archiveInspectionError()
            }
            let mode = attributesLine[marker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard let type = mode.first else {
                throw archiveInspectionError()
            }
            switch type {
            case "d": return .directory
            case "-": return .regular
            case "l": return .symbolicLink
            case "h": return .hardLink
            default: throw archiveInspectionError()
            }
        }
    }

    private nonisolated static func validateArchiveEntries(_ entries: [ArchiveEntry]) throws {
        var entriesByKey: [String: ArchiveEntry] = [:]
        for entry in entries {
            let key = archivePathKey(entry.path)
            guard entriesByKey[key] == nil else {
                throw unsafeArchiveEntryError(entry.path)
            }
            entriesByKey[key] = entry
        }

        for entry in entries {
            switch entry.kind {
            case .directory, .regular:
                continue
            case .symbolicLink:
                guard let target = entry.linkTarget else {
                    throw unsafeArchiveEntryError(entry.path)
                }
                let targetPath = try resolveArchiveRelativePath(
                    from: archiveParentPath(entry.path),
                    target: target,
                    displayPath: entry.path
                )
                _ = try resolveArchivePath(
                    targetPath,
                    entriesByKey: entriesByKey,
                    visited: []
                )
            case .hardLink:
                guard let target = entry.linkTarget,
                      let targetPath = try normalizedArchivePath(target) else {
                    throw unsafeArchiveEntryError(entry.path)
                }
                guard let targetEntry = entriesByKey[archivePathKey(targetPath)],
                      targetEntry.kind == .regular || targetEntry.kind == .hardLink else {
                    throw unsafeArchiveEntryError(entry.path)
                }
                _ = try resolveArchivePath(
                    targetPath,
                    entriesByKey: entriesByKey,
                    visited: []
                )
            }
        }
    }

    private nonisolated static func resolveArchivePath(
        _ path: String,
        entriesByKey: [String: ArchiveEntry],
        visited: Set<String>
    ) throws -> String {
        let components = path.isEmpty ? [] : path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var index = 0

        while index < components.count {
            let component = components[index]
            let candidate = (resolved + [component]).joined(separator: "/")
            if let entry = entriesByKey[archivePathKey(candidate)],
               entry.kind == .symbolicLink {
                let key = archivePathKey(entry.path)
                guard !visited.contains(key), let target = entry.linkTarget else {
                    throw unsafeArchiveEntryError(entry.path)
                }
                var nextVisited = visited
                nextVisited.insert(key)
                let targetPath = try resolveArchiveRelativePath(
                    from: archiveParentPath(entry.path),
                    target: target,
                    displayPath: entry.path
                )
                let remainder = components.dropFirst(index + 1).joined(separator: "/")
                let combined = targetPath.isEmpty
                    ? remainder
                    : remainder.isEmpty ? targetPath : "\(targetPath)/\(remainder)"
                return try resolveArchivePath(
                    combined,
                    entriesByKey: entriesByKey,
                    visited: nextVisited
                )
            }
            resolved.append(component)
            index += 1
        }
        return resolved.joined(separator: "/")
    }

    private nonisolated static func resolveArchiveRelativePath(
        from parent: String,
        target: String,
        displayPath: String
    ) throws -> String {
        guard !target.isEmpty, !containsNUL(target), !isAbsoluteArchivePath(target) else {
            throw unsafeArchiveEntryError(displayPath)
        }

        var components = parent.isEmpty ? [] : parent.split(separator: "/").map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw unsafeArchiveEntryError(displayPath)
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    private nonisolated static func normalizedArchivePath(_ rawPath: String) throws -> String? {
        guard !rawPath.isEmpty, !containsNUL(rawPath), !isAbsoluteArchivePath(rawPath) else {
            throw unsafeArchiveEntryError(rawPath)
        }

        var components: [String] = []
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw unsafeArchiveEntryError(rawPath)
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private nonisolated static func validateExtractedTree(
        at root: URL,
        fileManager: FileManager
    ) throws {
        guard let rootPath = realPath(of: root) else {
            throw archiveInspectionError()
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard path.hasPrefix(prefix) else {
                throw unsafeArchiveEntryError(path)
            }
            let relativePath = String(path.dropFirst(prefix.count))
            var metadata = stat()
            let result = url.withUnsafeFileSystemRepresentation { filePath in
                guard let filePath else { return Int32(-1) }
                return lstat(filePath, &metadata)
            }
            guard result == 0 else {
                throw archiveInspectionError()
            }

            let fileType = metadata.st_mode & S_IFMT
            guard fileType == S_IFLNK else {
                guard fileType == S_IFDIR || fileType == S_IFREG else {
                    throw unsafeArchiveEntryError(relativePath)
                }
                continue
            }
            let target = try fileManager.destinationOfSymbolicLink(atPath: path)
            let targetPath = try resolveArchiveRelativePath(
                from: archiveParentPath(relativePath),
                target: target,
                displayPath: relativePath
            )
            let targetURL = targetPath.isEmpty
                ? root
                : root.appendingPathComponent(targetPath)
            if let resolvedTargetPath = realPath(of: targetURL),
               !isSameOrDescendant(resolvedTargetPath, of: rootPath) {
                throw unsafeArchiveEntryError(relativePath)
            }
        }
    }

    private nonisolated static func processOutputData(
        _ launchPath: String,
        arguments: [String],
        staging: URL,
        fileManager: FileManager
    ) throws -> Data {
        let outputURL = staging.appendingPathComponent(
            ".multifinder-archive-output-\(UUID().uuidString)"
        )
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw FileOperationError(
                message: L10n.format("Could not create %@.", outputURL.lastPathComponent)
            )
        }
        defer { try? fileManager.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        do {
            try runProcess(
                launchPath,
                arguments: arguments,
                standardOutput: output
            )
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        return try Data(contentsOf: outputURL)
    }

    private nonisolated static func outputLines(from data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8), !containsNUL(text) else {
            throw archiveInspectionError()
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    private nonisolated static func archiveInspectionError() -> FileOperationError {
        FileOperationError(message: L10n.string("The archive could not be inspected safely."))
    }

    private nonisolated static func unsafeArchiveEntryError(_ path: String) -> FileOperationError {
        FileOperationError(
            message: L10n.format("The archive contains an unsafe item: %@", path)
        )
    }

    private nonisolated static func archiveParentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    private nonisolated static func archivePathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private nonisolated static func containsNUL(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }

    private nonisolated static func isAbsoluteArchivePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard let first = bytes.first else { return false }
        if first == 47 || first == 92 {
            return true
        }
        guard bytes.count >= 3,
              ((bytes[0] >= 65 && bytes[0] <= 90) ||
               (bytes[0] >= 97 && bytes[0] <= 122)),
              bytes[1] == 58,
              bytes[2] == 47 || bytes[2] == 92 else {
            return false
        }
        return true
    }

    private nonisolated static func uniqueNumberedDestination(
        in directory: URL,
        baseName: String,
        fileExtension: String?,
        fileManager: FileManager
    ) -> URL {
        var counter = 1
        while true {
            let name = counter == 1 ? baseName : "\(baseName) \(counter)"
            let fullName = fileExtension.map { "\(name).\($0)" } ?? name
            let candidate = directory.appendingPathComponent(fullName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    nonisolated static func runProcess(
        _ launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardOutput: FileHandle? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        if let standardOutput {
            process.standardOutput = standardOutput
        }
        try process.run()

        let errorFileHandle = errorPipe.fileHandleForReading
        let errorFileDescriptor = errorFileHandle.fileDescriptor
        var errorData = Data()
        var errorPipeClosed = false
        var terminationRequested = false
        var cancellationRequested = false
        var pollError: Error?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while process.isRunning || !errorPipeClosed {
            if Task.isCancelled && process.isRunning && !terminationRequested {
                process.terminate()
                terminationRequested = true
                cancellationRequested = true
            }

            if errorPipeClosed {
                // The child closed stderr before it exited. Keep observing its
                // lifetime without polling a closed descriptor.
                usleep(50_000)
                continue
            }

            var descriptor = pollfd(
                fd: errorFileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 50)
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                pollError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                if !terminationRequested {
                    process.terminate()
                    terminationRequested = true
                }
                try? errorFileHandle.close()
                errorPipeClosed = true
                break
            }
            guard pollResult > 0 else { continue }

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    errorFileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if bytesRead > 0 {
                errorData.append(contentsOf: buffer.prefix(bytesRead))
            } else if bytesRead == 0 {
                errorPipeClosed = true
            } else if errno != EINTR {
                pollError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                if !terminationRequested {
                    process.terminate()
                    terminationRequested = true
                }
                try? errorFileHandle.close()
                errorPipeClosed = true
                break
            }
        }

        // On the normal path the pipe is drained before waiting, so a verbose
        // child cannot remain blocked on stderr while Process waits for it.
        process.waitUntilExit()
        try? errorFileHandle.close()

        if cancellationRequested {
            throw CancellationError()
        }
        if let pollError {
            throw pollError
        }

        guard process.terminationStatus == 0 else {
            let toolMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let toolName = (launchPath as NSString).lastPathComponent
            let detail = toolMessage.isEmpty
                ? L10n.format("exit code %lld", Int64(process.terminationStatus))
                : toolMessage
            throw FileOperationError(message: L10n.format("%@ failed: %@", toolName, detail))
        }
    }

    private nonisolated static func reverse(_ changes: [FileOperationChange]) async throws {
        try await runWorker {
            let fileManager = FileManager.default
            try Task.checkCancellation()
            try preflightReverse(changes)
            for change in changes.reversed() {
                switch change {
                case .created(let url, let expectedIdentity):
                    if let currentIdentity = try fileIdentityIfPresent(at: url) {
                        guard currentIdentity == expectedIdentity else {
                            throw identityMismatchError(at: url)
                        }
                        _ = try trashSynchronously(url, fileManager: fileManager)
                    }
                case .moved(let from, let to, let expectedIdentity):
                    guard let currentIdentity = try fileIdentityIfPresent(at: to) else {
                        if try fileIdentityIfPresent(at: from) == expectedIdentity { continue }
                        throw missingUndoItemError(at: to)
                    }
                    guard currentIdentity == expectedIdentity else {
                        throw identityMismatchError(at: to)
                    }
                    if let existingAtFrom = try fileIdentityIfPresent(at: from),
                       existingAtFrom != expectedIdentity ||
                        (try? isCaseOnlyRename(source: to, destination: from)) != true {
                        throw FileOperationError(
                            message: L10n.format(
                                "Cannot restore %@ because an item already exists there.",
                                from.lastPathComponent
                            )
                        )
                    }
                    try moveItemReliably(from: to, to: from, fileManager: fileManager)
                case .trashed(let original, let trashed, let expectedIdentity):
                    guard let currentIdentity = try fileIdentityIfPresent(at: trashed) else {
                        if try fileIdentityIfPresent(at: original) == expectedIdentity { continue }
                        throw missingUndoItemError(at: trashed)
                    }
                    guard currentIdentity == expectedIdentity else {
                        throw identityMismatchError(at: trashed)
                    }
                    if try fileIdentityIfPresent(at: original) != nil {
                        throw FileOperationError(
                            message: L10n.format(
                                "Cannot restore %@ because an item already exists there.",
                                original.lastPathComponent
                            )
                        )
                    }
                    try fileManager.moveItem(at: trashed, to: original)
                }
            }
        }
    }

    private nonisolated static func preflightReverse(_ changes: [FileOperationChange]) throws {
        for change in changes.reversed() {
            switch change {
            case .created(let url, let expectedIdentity):
                if let currentIdentity = try fileIdentityIfPresent(at: url),
                   currentIdentity != expectedIdentity {
                    throw identityMismatchError(at: url)
                }
            case .moved(let from, let to, let expectedIdentity):
                if let currentIdentity = try fileIdentityIfPresent(at: to) {
                    guard currentIdentity == expectedIdentity else {
                        throw identityMismatchError(at: to)
                    }
                } else if try fileIdentityIfPresent(at: from) != expectedIdentity {
                    throw missingUndoItemError(at: to)
                }
            case .trashed(let original, let trashed, let expectedIdentity):
                if let currentIdentity = try fileIdentityIfPresent(at: trashed) {
                    guard currentIdentity == expectedIdentity else {
                        throw identityMismatchError(at: trashed)
                    }
                } else if try fileIdentityIfPresent(at: original) != expectedIdentity {
                    throw missingUndoItemError(at: trashed)
                }
            }
        }
    }

    private nonisolated static func performCopy(
        source: URL,
        destination: URL,
        replacing: Bool,
        replacementInstallHook: (@Sendable () throws -> Void)?,
        fileManager: FileManager
    ) throws -> [FileOperationChange] {
        let stagingURL = temporarySibling(of: destination, role: "copy")
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try copyItemCancellable(from: source, to: stagingURL, fileManager: fileManager)
        try Task.checkCancellation()

        if replacing, fileManager.fileExists(atPath: destination.path) {
            return try commitReplacement(
                source: source,
                stagedItem: stagingURL,
                destination: destination,
                kind: .copy,
                replacementInstallHook: replacementInstallHook,
                fileManager: fileManager
            )
        }

        try fileManager.moveItem(at: stagingURL, to: destination)
        let installedIdentity = try fileIdentity(at: destination)
        return [.created(destination, identity: installedIdentity)]
    }

    private nonisolated static func performMove(
        source: URL,
        destination: URL,
        replacing: Bool,
        replacementInstallHook: (@Sendable () throws -> Void)?,
        volumeIdentifierProvider: (@Sendable (URL) throws -> UInt64)?,
        fileManager: FileManager
    ) throws -> [FileOperationChange] {
        try Task.checkCancellation()
        if replacing, fileManager.fileExists(atPath: destination.path) {
            let sourceVolume = try volumeIdentifier(
                at: source,
                provider: volumeIdentifierProvider
            )
            let destinationVolume = try volumeIdentifier(
                at: destination,
                provider: volumeIdentifierProvider
            )
            if sourceVolume != destinationVolume {
                let stagingURL = temporarySibling(of: destination, role: "move")
                defer {
                    if fileManager.fileExists(atPath: stagingURL.path) {
                        try? fileManager.removeItem(at: stagingURL)
                    }
                }
                try copyItemCancellable(from: source, to: stagingURL, fileManager: fileManager)
                try Task.checkCancellation()
                return try commitReplacement(
                    source: source,
                    stagedItem: stagingURL,
                    destination: destination,
                    kind: .move,
                    replacementInstallHook: replacementInstallHook,
                    fileManager: fileManager
                )
            }
            return try commitReplacement(
                source: source,
                stagedItem: nil,
                destination: destination,
                kind: .move,
                replacementInstallHook: replacementInstallHook,
                fileManager: fileManager
            )
        }

        try fileManager.moveItem(at: source, to: destination)
        let movedIdentity = try fileIdentity(at: destination)
        return [.moved(
            from: source,
            to: destination,
            identity: movedIdentity
        )]
    }

    private nonisolated static func commitReplacement(
        source: URL,
        stagedItem: URL?,
        destination: URL,
        kind: FileOperationKind,
        replacementInstallHook: (@Sendable () throws -> Void)?,
        fileManager: FileManager
    ) throws -> [FileOperationChange] {
        let backupURL = temporarySibling(of: destination, role: "backup")
        let displacedIdentity = try fileIdentity(at: destination)
        let newItemURL = stagedItem ?? source
        let preInstallIdentity = try fileIdentity(at: newItemURL)
        var installedIdentity: FileIdentity?

        try Task.checkCancellation()
        try fileManager.moveItem(at: destination, to: backupURL)

        do {
            try replacementInstallHook?()
            try Task.checkCancellation()
            try fileManager.moveItem(at: newItemURL, to: destination)
            installedIdentity = try fileIdentity(at: destination)
            if kind == .move, stagedItem != nil {
                try fileManager.removeItem(at: source)
            }
        } catch {
            let recoveryChanges = rollbackReplacement(
                source: source,
                destination: destination,
                backup: backupURL,
                kind: kind,
                displacedIdentity: displacedIdentity,
                installedIdentity: installedIdentity ?? preInstallIdentity,
                fileManager: fileManager
            )
            if error is CancellationError, recoveryChanges.isEmpty {
                throw CancellationError()
            }
            let recoveryMessage = recoveryChanges.isEmpty
                ? ""
                : L10n.format(
                    " The original item remains recoverable at %@.",
                    backupURL.path
                )
            throw WorkerFailure(
                message: L10n.format(
                    "Replacement failed: %@.%@",
                    error.localizedDescription,
                    recoveryMessage
                ),
                changes: recoveryChanges
            )
        }
        guard let installedIdentity else {
            throw FileOperationError(
                message: L10n.string("The installed item could not be identified.")
            )
        }

        let displacedChange = storeDisplacedItem(
            backupURL,
            original: destination,
            identity: displacedIdentity,
            fileManager: fileManager
        )
        if kind == .copy {
            return [displacedChange, .created(destination, identity: installedIdentity)]
        }
        return [
            displacedChange,
            .moved(from: source, to: destination, identity: installedIdentity)
        ]
    }

    private nonisolated static func rollbackReplacement(
        source: URL,
        destination: URL,
        backup: URL,
        kind: FileOperationKind,
        displacedIdentity: FileIdentity,
        installedIdentity: FileIdentity,
        fileManager: FileManager
    ) -> [FileOperationChange] {
        var installedChange: FileOperationChange?

        if let destinationIdentity = try? fileIdentity(at: destination),
           destinationIdentity == installedIdentity {
            if kind == .move, !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: destination, to: source)
            } else {
                try? fileManager.removeItem(at: destination)
            }
        }

        if fileManager.fileExists(atPath: backup.path),
           !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: backup, to: destination)
        }

        if let currentIdentity = try? fileIdentity(at: destination),
           currentIdentity == installedIdentity {
            if kind == .move {
                installedChange = .moved(from: source, to: destination, identity: currentIdentity)
            } else {
                installedChange = .created(destination, identity: currentIdentity)
            }
        }
        var recoveryChanges: [FileOperationChange] = []
        if fileManager.fileExists(atPath: backup.path) {
            recoveryChanges.append(.trashed(
                original: destination,
                trashed: backup,
                identity: displacedIdentity
            ))
        }
        if let installedChange {
            recoveryChanges.append(installedChange)
        }
        return recoveryChanges
    }

    private nonisolated static func volumeIdentifier(
        at url: URL,
        provider: (@Sendable (URL) throws -> UInt64)?
    ) throws -> UInt64 {
        if let provider {
            return try provider(url)
        }
        return try fileIdentity(at: url).device
    }

    private nonisolated static func storeDisplacedItem(
        _ backup: URL,
        original: URL,
        identity: FileIdentity,
        fileManager: FileManager
    ) -> FileOperationChange {
        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: backup, resultingItemURL: &resultingURL)
            if let storedURL = resultingURL as URL? {
                return .trashed(original: original, trashed: storedURL, identity: identity)
            }
        } catch {
            // Keeping the hidden backup is safer than losing the displaced item.
        }
        return .trashed(original: original, trashed: backup, identity: identity)
    }

    private nonisolated static func copyItemCancellable(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        try Task.checkCancellation()
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let fileType = attributes[.type] as? FileAttributeType

        switch fileType {
        case .typeDirectory:
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                try Task.checkCancellation()
                try copyItemCancellable(
                    from: child,
                    to: destination.appendingPathComponent(child.lastPathComponent),
                    fileManager: fileManager
                )
            }
            try copyMetadata(from: source, to: destination)

        case .typeRegular:
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw FileOperationError(
                    message: L10n.format("Could not create %@.", destination.lastPathComponent)
                )
            }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
                try output.write(contentsOf: data)
            }
            try copyMetadata(from: source, to: destination)

        case .typeSymbolicLink:
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            try copyMetadata(from: source, to: destination)

        default:
            try Task.checkCancellation()
            try fileManager.copyItem(at: source, to: destination)
        }
        try Task.checkCancellation()
    }

    private nonisolated static func copyMetadata(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return copyfile(
                    sourcePath,
                    destinationPath,
                    nil,
                    copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private nonisolated static func moveItemReliably(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if try isCaseOnlyRename(source: source, destination: destination) {
            try performCaseOnlyRename(
                from: source,
                to: destination,
                fileManager: fileManager
            )
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private nonisolated static func isCaseOnlyRename(
        source: URL,
        destination: URL
    ) throws -> Bool {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard sourcePath != destinationPath,
              sourcePath.caseInsensitiveCompare(destinationPath) == .orderedSame else {
            return false
        }

        guard (try? source.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) == false else {
            return false
        }

        return try fileIdentity(at: source) == fileIdentity(at: destination)
    }

    private nonisolated static func performCaseOnlyRename(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceIdentity = try fileIdentity(at: source)
        let temporary = temporarySibling(of: source, role: "rename")
        var sourceWasMoved = false

        defer {
            if fileManager.fileExists(atPath: temporary.path),
               !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: temporary, to: source)
            }
        }

        try Task.checkCancellation()
        try fileManager.moveItem(at: source, to: temporary)
        sourceWasMoved = true

        do {
            try Task.checkCancellation()
            try fileManager.moveItem(at: temporary, to: destination)
            guard try fileIdentity(at: destination) == sourceIdentity else {
                throw FileOperationError(
                    message: L10n.string("The renamed item could not be identified.")
                )
            }
        } catch {
            if sourceWasMoved,
               fileManager.fileExists(atPath: temporary.path),
               !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: temporary, to: source)
            }
            throw error
        }
    }

    private nonisolated static func temporarySibling(of destination: URL, role: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".multifinder-\(role)-\(UUID().uuidString)"
        )
    }

    private nonisolated static func isRealDirectory(at url: URL) -> Bool {
        var metadata = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            guard lstat(path, &metadata) == 0 else { return false }
            return (metadata.st_mode & S_IFMT) == S_IFDIR
        }
    }

    private nonisolated static func resolvedContainmentPath(for url: URL) -> String? {
        if let resolvedPath = realPath(of: url) {
            return resolvedPath
        }

        var unresolvedComponents: [String] = []
        var existingURL = url
        while realPath(of: existingURL) == nil {
            let parentURL = existingURL.deletingLastPathComponent()
            guard parentURL.path != existingURL.path,
                  !existingURL.lastPathComponent.isEmpty else {
                return nil
            }
            unresolvedComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL = parentURL
        }

        guard var resolvedPath = realPath(of: existingURL) else { return nil }
        for component in unresolvedComponents {
            resolvedPath = (resolvedPath as NSString).appendingPathComponent(component)
        }
        return resolvedPath
    }

    private nonisolated static func realPath(of url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return String(cString: resolvedPath)
        }
    }

    private nonisolated static func isSameOrDescendant(_ candidate: String, of source: String) -> Bool {
        guard candidate != source else { return true }
        if source == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    private nonisolated static func runWorker<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func fileIdentity(at url: URL) throws -> FileIdentity {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private nonisolated static func fileIdentityIfPresent(at url: URL) throws -> FileIdentity? {
        do {
            return try fileIdentity(at: url)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    private nonisolated static func identityMismatchError(at url: URL) -> FileOperationError {
        FileOperationError(
            message: L10n.format(
                "Cannot undo %@ because it is no longer the item created by this operation.",
                url.lastPathComponent
            )
        )
    }

    private nonisolated static func missingUndoItemError(at url: URL) -> FileOperationError {
        FileOperationError(
            message: L10n.format(
                "Cannot undo because %@ is no longer available.",
                url.lastPathComponent
            )
        )
    }

    private static func failureRecord(for request: FileOperationRequest, message: String) -> FileOperationRecord {
        FileOperationRecord(
            id: UUID(),
            kind: request.kind,
            date: Date(),
            status: .failed,
            itemCount: request.itemCount,
            errorMessage: message,
            outcomes: [],
            request: request,
            retryRequest: nil,
            changes: []
        )
    }
}
