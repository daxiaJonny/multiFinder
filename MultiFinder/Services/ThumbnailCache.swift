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

        let fallback = systemIcon(for: key.url, size: size)
        guard !key.usesSystemIcon, !Task.isCancelled else {
            store(fallback, forKey: cacheKey, size: size)
            return fallback
        }

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
            await cancellation.generate()
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
