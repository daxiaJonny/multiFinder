import AppKit
import Foundation
@preconcurrency import QuickLookThumbnailing

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    struct RequestKey: Hashable, Sendable {
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Int
        let modificationStamp: Int64
        let usesSystemIcon: Bool

        init(
            url: URL,
            size: CGSize,
            scale: CGFloat,
            modificationDate: Date?,
            isDirectory: Bool,
            isPackage: Bool
        ) {
            let resolvedScale = scale.isFinite ? max(scale, 1) : 1
            let resolvedWidth = max(size.width, 1)
            let resolvedHeight = max(size.height, 1)

            self.url = url.standardizedFileURL
            self.pixelWidth = max(Int((resolvedWidth * resolvedScale).rounded(.up)), 1)
            self.pixelHeight = max(Int((resolvedHeight * resolvedScale).rounded(.up)), 1)
            self.scale = max(Int((resolvedScale * 100).rounded()), 1)
            self.modificationStamp = Self.modificationStamp(for: modificationDate)
            self.usesSystemIcon = isDirectory || isPackage
        }

        private static func modificationStamp(for date: Date?) -> Int64 {
            guard let date, date != .distantPast else { return 0 }
            return Int64((date.timeIntervalSinceReferenceDate * 1_000).rounded())
        }
    }

    private final class GeneratedThumbnail: @unchecked Sendable {
        let image: NSImage?

        init(image: NSImage?) {
            self.image = image
        }
    }

    private final class RequestCancellation: @unchecked Sendable {
        let generator: QLThumbnailGenerator
        let request: QLThumbnailGenerator.Request

        init(generator: QLThumbnailGenerator, request: QLThumbnailGenerator.Request) {
            self.generator = generator
            self.request = request
        }

        func cancel() {
            generator.cancel(request)
        }

        func generate() async -> GeneratedThumbnail {
            await withCheckedContinuation { continuation in
                generator.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(
                        returning: GeneratedThumbnail(image: representation?.nsImage)
                    )
                }
            }
        }
    }

    private let generator: QLThumbnailGenerator
    private let workspace: NSWorkspace
    private let cache = NSCache<NSString, NSImage>()
    private let generationGate = ThumbnailGenerationGate()

    init(
        generator: QLThumbnailGenerator = .shared,
        workspace: NSWorkspace = .shared
    ) {
        self.generator = generator
        self.workspace = workspace
        cache.countLimit = 1_200
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    nonisolated static func requestKey(
        for url: URL,
        size: CGSize,
        scale: CGFloat,
        modificationDate: Date? = nil,
        isDirectory: Bool = false,
        isPackage: Bool = false
    ) -> RequestKey {
        RequestKey(
            url: url,
            size: size,
            scale: scale,
            modificationDate: modificationDate,
            isDirectory: isDirectory,
            isPackage: isPackage
        )
    }

    func image(
        for url: URL,
        size: CGSize,
        scale: CGFloat = 2,
        modificationDate: Date? = nil,
        isDirectory: Bool = false,
        isPackage: Bool = false
    ) async -> NSImage {
        let key = Self.requestKey(
            for: url,
            size: size,
            scale: scale,
            modificationDate: modificationDate,
            isDirectory: isDirectory,
            isPackage: isPackage
        )
        let cacheKey = makeCacheKey(from: key)

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let fallback = isDirectory && !isPackage
            ? folderIcon(size: size)
            : systemIcon(for: key.url, size: size)
        guard !key.usesSystemIcon, !Task.isCancelled else {
            store(fallback, forKey: cacheKey, size: size)
            return fallback
        }

        let permit: ThumbnailGenerationGate.Permit
        do {
            permit = try await generationGate.acquire()
        } catch {
            return fallback
        }
        defer { generationGate.release(permit) }
        guard !Task.isCancelled else { return fallback }

        let request = QLThumbnailGenerator.Request(
            fileAt: key.url,
            size: CGSize(
                width: size.width.isFinite ? max(size.width, 1) : 1,
                height: size.height.isFinite ? max(size.height, 1) : 1
            ),
            scale: CGFloat(key.scale) / 100,
            representationTypes: .thumbnail
        )
        request.iconMode = false
        let cancellation = RequestCancellation(generator: generator, request: request)
        let generatedThumbnail = await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else {
                return GeneratedThumbnail(image: nil)
            }
            return await cancellation.generate()
        }, onCancel: {
            cancellation.cancel()
        })

        guard !Task.isCancelled else { return fallback }

        if let image = generatedThumbnail.image {
            store(image, forKey: cacheKey, size: size)
            return image
        }

        store(fallback, forKey: cacheKey, size: size)
        return fallback
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func fallbackIcon(for url: URL, size: CGSize) -> NSImage {
        systemIcon(for: url.standardizedFileURL, size: size)
    }

    private func folderIcon(size: CGSize) -> NSImage {
        let icon = (workspace.icon(for: .folder).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: max(size.width, 1), height: max(size.height, 1))
        return icon
    }

    private func systemIcon(for url: URL, size: CGSize) -> NSImage {
        let icon = workspace.icon(forFile: url.path)
        let result = (icon.copy() as? NSImage) ?? icon
        result.size = NSSize(width: max(size.width, 1), height: max(size.height, 1))
        return result
    }

    private func makeCacheKey(from key: RequestKey) -> NSString {
        NSString(
            string: [
                key.url.absoluteString,
                String(key.pixelWidth),
                String(key.pixelHeight),
                String(key.scale),
                String(key.modificationStamp),
                key.usesSystemIcon ? "icon" : "thumbnail"
            ].joined(separator: "|")
        )
    }

    private func store(_ image: NSImage, forKey key: NSString, size: CGSize) {
        let pixelArea = max(Int((size.width * size.height).rounded()), 1)
        cache.setObject(image, forKey: key, cost: pixelArea * 4)
    }
}

/// Async cap on in-flight Quick Look generations. Waiting suspends and is cancellable;
/// this must not block the main actor the way a `DispatchSemaphore` would.
private final class ThumbnailGenerationGate: @unchecked Sendable {
    static let limit = 4

    struct Permit: Sendable {
        fileprivate let id: UUID
    }

    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Permit, any Error>?
        var state: State = .pending

        enum State {
            case pending
            case waiting
            case finished
        }
    }

    private let lock = NSLock()
    private var held: Set<UUID> = []
    private var order: [Waiter] = []

    func acquire() async throws -> Permit {
        try Task.checkCancellation()
        if let permit = tryTakePermit() {
            return permit
        }

        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Permit, any Error>) in
                let decision = self.lock.withLock { () -> Decision in
                    if waiter.state == .finished {
                        return .cancel
                    }
                    if self.held.count < Self.limit {
                        return .permit(self.insertPermit())
                    }
                    waiter.continuation = continuation
                    waiter.state = .waiting
                    self.order.append(waiter)
                    return .queued
                }
                switch decision {
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                case .permit(let permit):
                    continuation.resume(returning: permit)
                case .queued:
                    break
                }
            }
        } onCancel: {
            self.cancel(waiter)
        }
    }

    func release(_ permit: Permit) {
        let resumeNext: (() -> Void)? = lock.withLock {
            guard held.remove(permit.id) != nil else { return nil }
            while !order.isEmpty {
                let waiter = order.removeFirst()
                guard waiter.state == .waiting, let continuation = waiter.continuation else { continue }
                waiter.state = .finished
                waiter.continuation = nil
                let next = insertPermit()
                return { continuation.resume(returning: next) }
            }
            return nil
        }
        resumeNext?()
    }

    private enum Decision {
        case cancel
        case permit(Permit)
        case queued
    }

    private func tryTakePermit() -> Permit? {
        lock.withLock {
            guard held.count < Self.limit else { return nil }
            return insertPermit()
        }
    }

    /// Caller holds `lock`.
    private func insertPermit() -> Permit {
        let permit = Permit(id: UUID())
        held.insert(permit.id)
        return permit
    }

    private func cancel(_ waiter: Waiter) {
        let continuation: CheckedContinuation<Permit, any Error>? = lock.withLock {
            switch waiter.state {
            case .waiting:
                waiter.state = .finished
                let continuation = waiter.continuation
                waiter.continuation = nil
                order.removeAll { $0 === waiter }
                return continuation
            case .pending:
                waiter.state = .finished
                return nil
            case .finished:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }
}
