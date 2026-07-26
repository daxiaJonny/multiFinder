import Foundation
import Combine
import Darwin

enum FileConflictResolution: String, Sendable {
    case replace
    case skip
    case keepBoth
    case cancel
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
    case batchRename = "Batch Rename"
    case compress = "Compress"
    case extract = "Extract"
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
    case batchRename(pairs: [BatchRenamePair])
    case compress(sources: [URL])
    case extract(archives: [URL])

    var kind: FileOperationKind {
        switch self {
        case .copy: return .copy
        case .move: return .move
        case .trash: return .trash
        case .rename: return .rename
        case .createFolder: return .createFolder
        case .batchRename: return .batchRename
        case .compress: return .compress
        case .extract: return .extract
        }
    }

    var itemCount: Int {
        switch self {
        case .copy(let sources, _, _), .move(let sources, _, _): return sources.count
        case .trash(let urls): return urls.count
        case .rename, .createFolder: return 1
        case .batchRename(let pairs): return pairs.count
        case .compress(let sources): return sources.isEmpty ? 0 : 1
        case .extract(let archives): return archives.count
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
        case .rename, .createFolder, .compress:
            return self
        case .batchRename(let pairs):
            let failed = pairs.filter { failedSources.contains($0.source.standardizedFileURL) }
            return failed.isEmpty ? nil : .batchRename(pairs: failed)
        case .extract(let archives):
            let failed = archives.filter { failedSources.contains($0.standardizedFileURL) }
            return failed.isEmpty ? nil : .extract(archives: failed)
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
        baseName: String = "untitled folder",
        completion: ((Result<Void, FileOperationError>) -> Void)? = nil
    ) {
        enqueue(
            .createFolder(parent: parent, baseName: baseName),
            completion: legacyCompletion(completion)
        )
    }

    func createFolderDetailed(
        in parent: URL,
        baseName: String = "untitled folder",
        completion: ((FileOperationResult) -> Void)? = nil
    ) {
        enqueue(.createFolder(parent: parent, baseName: baseName), completion: completion)
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
                history.insert(Self.failureRecord(for: record.request, message: "Undo failed: \(error.localizedDescription)"), at: 0)
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
            return "A file name cannot be empty."
        }
        if name == "." || name == ".." {
            return "“\(name)” is reserved and cannot be used as a file name."
        }
        if name.contains("/") || name.unicodeScalars.contains("\0") {
            return "File names cannot contain “/” or a null character."
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
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let candidateName = fileExtension.isEmpty
                ? "\(baseName)\(suffix)"
                : "\(baseName)\(suffix).\(fileExtension)"
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
                    message: result.errorMessage ?? "The operation did not complete."
                )))
            }
        }
    }

    private func execute(_ request: FileOperationRequest) async -> ExecutionResult {
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
        case .batchRename(let pairs):
            return await executeBatchRename(pairs)
        case .compress(let sources):
            return await executeCompress(sources)
        case .extract(let archives):
            return await executeExtract(archives)
        }
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
                    errorMessage: "The operation was cancelled."
                ))
                outcomes.append(contentsOf: sources.dropFirst(index + 1).map { remainingSource in
                    FileItemOperationOutcome(
                        source: remainingSource,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: "The operation was cancelled before this item started."
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
                    errorMessage: "The operation was cancelled."
                ))
                outcomes.append(contentsOf: urls.dropFirst(index + 1).map { remainingURL in
                    FileItemOperationOutcome(
                        source: remainingURL,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: "The operation was cancelled before this item started."
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
                    errorMessage: "The operation was cancelled."
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
                    errorMessage: "The operation was cancelled."
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
                    errorMessage: "The operation was cancelled."
                ))
                outcomes.append(contentsOf: pairs.dropFirst(index + 1).map { remainingPair in
                    FileItemOperationOutcome(
                        source: remainingPair.source,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: "The operation was cancelled before this item started."
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
                    errorMessage: "The operation was cancelled."
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
                    errorMessage: "The operation was cancelled."
                ))
                outcomes.append(contentsOf: archives.dropFirst(index + 1).map { remainingArchive in
                    FileItemOperationOutcome(
                        source: remainingArchive,
                        destination: nil,
                        status: .cancelled,
                        errorMessage: "The operation was cancelled before this item started."
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
            errorMessage = "The operation was cancelled."
        } else if !failed.isEmpty {
            status = .failed
            errorMessage = failed.count == 1
                ? failed[0].errorMessage
                : "\(failed.count) items could not be processed."
        } else if !skipped.isEmpty {
            status = .partial
            errorMessage = skipped.count == 1
                ? "One item was skipped."
                : "\(skipped.count) items were skipped."
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
        if FileManager.default.fileExists(atPath: destination.path) {
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
                return try performMove(
                    source: source,
                    destination: destination,
                    replacing: replacing,
                    replacementInstallHook: replacementInstallHook,
                    volumeIdentifierProvider: volumeIdentifierProvider,
                    fileManager: fileManager
                )
            case .trash, .createFolder, .batchRename, .compress, .extract:
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
            throw FileOperationError(message: "The Trash did not return a location for \(url.lastPathComponent).")
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

    private nonisolated static func renameItem(_ source: URL, to destination: URL) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            try Task.checkCancellation()
            if source.path.caseInsensitiveCompare(destination.path) != .orderedSame,
               fileManager.fileExists(atPath: destination.path) {
                throw FileOperationError(
                    message: "An item named “\(destination.lastPathComponent)” already exists."
                )
            }
            try fileManager.moveItem(at: source, to: destination)
            return .moved(from: source, to: destination, identity: try fileIdentity(at: destination))
        }
    }

    private nonisolated static func compress(_ sources: [URL]) async throws -> FileOperationChange {
        try await runWorker {
            let fileManager = FileManager.default
            guard let firstSource = sources.first else {
                throw FileOperationError(message: "There is nothing to compress.")
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
                    throw FileOperationError(message: "Items can only be compressed together from the same folder.")
                }
                try runProcess(
                    "/usr/bin/zip",
                    arguments: ["-r", "-y", "-q", staging.path] + sources.map { $0.lastPathComponent },
                    currentDirectory: directory
                )
            }

            try Task.checkCancellation()
            let baseName = sources.count == 1 ? firstSource.lastPathComponent : "Archive"
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
                try runProcess("/usr/bin/ditto", arguments: ["-xk", archive.path, staging.path])
            } else if lowercased.hasSuffix(".tar") || lowercased.hasSuffix(".tar.gz") || lowercased.hasSuffix(".tgz") {
                try runProcess("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", staging.path])
            } else if lowercased.hasSuffix(".gz") {
                let outputName = String(name.dropLast(3))
                let outputURL = staging.appendingPathComponent(outputName.isEmpty ? "extracted" : outputName)
                guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
                    throw FileOperationError(message: "Could not create \(outputURL.lastPathComponent).")
                }
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                try runProcess("/usr/bin/gunzip", arguments: ["-c", archive.path], standardOutput: output)
            } else {
                throw FileOperationError(message: "“\(name)” is not a supported archive.")
            }

            try Task.checkCancellation()
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

    private nonisolated static func runProcess(
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

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            usleep(50_000)
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let toolMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let toolName = (launchPath as NSString).lastPathComponent
            let detail = toolMessage.isEmpty ? "exit code \(process.terminationStatus)" : toolMessage
            throw FileOperationError(message: "\(toolName) failed: \(detail)")
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
                    if try fileIdentityIfPresent(at: from) != nil {
                        throw FileOperationError(message: "Cannot restore \(from.lastPathComponent) because an item already exists there.")
                    }
                    try fileManager.moveItem(at: to, to: from)
                case .trashed(let original, let trashed, let expectedIdentity):
                    guard let currentIdentity = try fileIdentityIfPresent(at: trashed) else {
                        if try fileIdentityIfPresent(at: original) == expectedIdentity { continue }
                        throw missingUndoItemError(at: trashed)
                    }
                    guard currentIdentity == expectedIdentity else {
                        throw identityMismatchError(at: trashed)
                    }
                    if try fileIdentityIfPresent(at: original) != nil {
                        throw FileOperationError(message: "Cannot restore \(original.lastPathComponent) because an item already exists there.")
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
                : " The original item remains recoverable at \(backupURL.path)."
            throw WorkerFailure(
                message: "Replacement failed: \(error.localizedDescription).\(recoveryMessage)",
                changes: recoveryChanges
            )
        }
        guard let installedIdentity else {
            throw FileOperationError(message: "The installed item could not be identified.")
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
                throw FileOperationError(message: "Could not create \(destination.lastPathComponent).")
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

    private nonisolated static func temporarySibling(of destination: URL, role: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".multifinder-\(role)-\(UUID().uuidString)"
        )
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
            message: "Cannot undo \(url.lastPathComponent) because it is no longer the item created by this operation."
        )
    }

    private nonisolated static func missingUndoItemError(at url: URL) -> FileOperationError {
        FileOperationError(
            message: "Cannot undo because \(url.lastPathComponent) is no longer available."
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
