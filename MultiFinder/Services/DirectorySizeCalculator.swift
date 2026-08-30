import Darwin
import Foundation

public struct DirectorySizeProgress: Equatable, Sendable {
    public let rootURL: URL
    public let processedItemCount: Int
    public let fileCount: Int
    public let directoryCount: Int
    public let byteCount: Int64
    public let skippedItemCount: Int
    public let skippedPackageCount: Int
    public let skippedSymbolicLinkDirectoryCount: Int

    public init(
        rootURL: URL,
        processedItemCount: Int,
        fileCount: Int,
        directoryCount: Int,
        byteCount: Int64,
        skippedItemCount: Int,
        skippedPackageCount: Int = 0,
        skippedSymbolicLinkDirectoryCount: Int = 0
    ) {
        self.rootURL = rootURL
        self.processedItemCount = processedItemCount
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.byteCount = byteCount
        self.skippedItemCount = skippedItemCount
        self.skippedPackageCount = skippedPackageCount
        self.skippedSymbolicLinkDirectoryCount = skippedSymbolicLinkDirectoryCount
    }
}

public struct DirectorySizeResult: Equatable, Sendable {
    public let byteCount: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let skippedItemCount: Int
    public let skippedPackageCount: Int
    public let skippedSymbolicLinkDirectoryCount: Int

    public init(
        byteCount: Int64,
        fileCount: Int,
        directoryCount: Int,
        skippedItemCount: Int = 0,
        skippedPackageCount: Int = 0,
        skippedSymbolicLinkDirectoryCount: Int = 0
    ) {
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.skippedItemCount = skippedItemCount
        self.skippedPackageCount = skippedPackageCount
        self.skippedSymbolicLinkDirectoryCount = skippedSymbolicLinkDirectoryCount
    }

    public var itemCount: Int {
        fileCount + directoryCount
    }
}

public enum DirectorySizeCalculatorError: LocalizedError, Sendable {
    case invalidURL(URL)
    case unableToRead(URL, reason: String)
    case sizeOverflow(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The item URL is not a local file URL.")
        case .unableToRead(let url, let reason):
            return String(
                format: String(localized: "Unable to calculate the size of %@: %@"),
                locale: Locale.current,
                url.path,
                reason
            )
        case .sizeOverflow(let url):
            return String(
                format: String(localized: "The size of %@ is too large to calculate."),
                locale: Locale.current,
                url.path
            )
        }
    }
}

public struct DirectorySizeCalculator: Sendable {
    public init() {}

    public func calculate(
        url: URL,
        progress: @escaping @Sendable (DirectorySizeProgress) -> Void = { _ in }
    ) async throws -> DirectorySizeResult {
        try await calculate(urls: [url], progress: progress)
    }

    public func calculate(
        urls: [URL],
        progress: @escaping @Sendable (DirectorySizeProgress) -> Void = { _ in }
    ) async throws -> DirectorySizeResult {
        let roots = try Self.normalizedRoots(urls)
        guard !roots.isEmpty else {
            return DirectorySizeResult(byteCount: 0, fileCount: 0, directoryCount: 0)
        }

        let cancellation = DirectorySizeCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try DirectorySizeWorker(
                    cancellation: cancellation,
                    progress: progress
                ).calculate(roots: roots)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func normalizedRoots(_ urls: [URL]) throws -> [URL] {
        let normalized = try urls.map { url -> URL in
            guard url.isFileURL else {
                throw DirectorySizeCalculatorError.invalidURL(url)
            }
            return url.standardizedFileURL
        }

        var roots: [URL] = []
        for url in normalized.sorted(by: { $0.path.count < $1.path.count }) {
            guard !roots.contains(where: { Self.isSameOrDescendant(url, of: $0) }) else {
                continue
            }
            roots.append(url)
        }
        return roots
    }

    private static func isSameOrDescendant(_ url: URL, of parent: URL) -> Bool {
        let urlPath = url.path
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return urlPath == parent.path || urlPath.hasPrefix(parentPath)
    }
}

private final class DirectorySizeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()

        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}

private struct DirectorySizeWorker: Sendable {
    let cancellation: DirectorySizeCancellation
    let progress: @Sendable (DirectorySizeProgress) -> Void

    func calculate(roots: [URL]) throws -> DirectorySizeResult {
        var accumulator = DirectorySizeAccumulator()

        for root in roots {
            try cancellation.throwIfCancelled()
            let metadata = try lstatMetadata(at: root)

            if isSymbolicLink(metadata.st_mode) {
                if isDirectoryTarget(root) {
                    accumulator.skippedSymbolicLinkDirectoryCount += 1
                }
                try accumulator.addFile(at: root, byteCount: Int64(max(metadata.st_size, 0)))
                accumulator.processedItemCount += 1
                emitProgress(for: root, accumulator: accumulator)
            } else if isDirectory(metadata.st_mode) {
                try enumerateDirectory(at: root, accumulator: &accumulator)
            } else {
                try accumulator.addFile(at: root, byteCount: Int64(max(metadata.st_size, 0)))
                accumulator.processedItemCount += 1
                emitProgress(for: root, accumulator: accumulator)
            }
        }

        try cancellation.throwIfCancelled()
        return accumulator.result
    }

    private func enumerateDirectory(
        at root: URL,
        accumulator: inout DirectorySizeAccumulator
    ) throws {
        let fileManager = FileManager()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw DirectorySizeCalculatorError.unableToRead(
                root,
                reason: String(localized: "The directory could not be opened.")
            )
        }

        while let item = enumerator.nextObject() as? URL {
            try cancellation.throwIfCancelled()

            guard let metadata = try? lstatMetadata(at: item) else {
                accumulator.skippedItemCount += 1
                accumulator.processedItemCount += 1
                enumerator.skipDescendants()
                emitProgress(for: root, accumulator: accumulator)
                continue
            }

            if isSymbolicLink(metadata.st_mode) {
                if isDirectoryTarget(item) {
                    accumulator.skippedSymbolicLinkDirectoryCount += 1
                }
                try accumulator.addFile(at: item, byteCount: Int64(max(metadata.st_size, 0)))
                enumerator.skipDescendants()
            } else if isDirectory(metadata.st_mode) {
                accumulator.directoryCount += 1
            } else {
                try accumulator.addFile(at: item, byteCount: Int64(max(metadata.st_size, 0)))
            }

            accumulator.processedItemCount += 1
            emitProgress(for: root, accumulator: accumulator)
        }
    }

    private func emitProgress(for root: URL, accumulator: DirectorySizeAccumulator) {
        progress(
            DirectorySizeProgress(
                rootURL: root,
                processedItemCount: accumulator.processedItemCount,
                fileCount: accumulator.fileCount,
                directoryCount: accumulator.directoryCount,
                byteCount: accumulator.byteCount,
                skippedItemCount: accumulator.skippedItemCount,
                skippedPackageCount: accumulator.skippedPackageCount,
                skippedSymbolicLinkDirectoryCount: accumulator.skippedSymbolicLinkDirectoryCount
            )
        )
    }

    private func isDirectoryTarget(_ url: URL) -> Bool {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &metadata)
        }
        return result == 0 && isDirectory(metadata.st_mode)
    }

    private func lstatMetadata(at url: URL) throws -> stat {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, ENOENT) }
            let result = Darwin.lstat(path, &metadata)
            return (result, result == 0 ? 0 : errno)
        }

        guard result.0 == 0 else {
            let reason = String(cString: strerror(result.1))
            throw DirectorySizeCalculatorError.unableToRead(url, reason: reason)
        }
        return metadata
    }

    private func isDirectory(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFDIR
    }

    private func isSymbolicLink(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFLNK
    }
}

private struct DirectorySizeAccumulator {
    var byteCount: Int64 = 0
    var fileCount = 0
    var directoryCount = 0
    var processedItemCount = 0
    var skippedItemCount = 0
    var skippedPackageCount = 0
    var skippedSymbolicLinkDirectoryCount = 0

    mutating func addFile(at url: URL, byteCount: Int64) throws {
        let (updated, overflowed) = self.byteCount.addingReportingOverflow(byteCount)
        guard !overflowed else {
            throw DirectorySizeCalculatorError.sizeOverflow(url)
        }
        self.byteCount = updated
        fileCount += 1
    }

    var result: DirectorySizeResult {
        DirectorySizeResult(
            byteCount: byteCount,
            fileCount: fileCount,
            directoryCount: directoryCount,
            skippedItemCount: skippedItemCount,
            skippedPackageCount: skippedPackageCount,
            skippedSymbolicLinkDirectoryCount: skippedSymbolicLinkDirectoryCount
        )
    }
}
