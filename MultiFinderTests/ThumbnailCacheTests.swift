import Foundation
import XCTest
@testable import MultiFinder

final class ThumbnailCacheTests: XCTestCase {
    @MainActor
    func testRegularFileThumbnailRequestCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderThumbnailTests-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Preview.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("thumbnail content".utf8).write(to: file)

        let image = await ThumbnailCache().image(
            for: file,
            size: CGSize(width: 72, height: 72),
            scale: 2
        )

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testRequestKeyNormalizesURLAndTracksRenderingInputs() {
        let url = URL(fileURLWithPath: "/tmp/../tmp/thumbnail-cache.txt")
        let date = Date(timeIntervalSinceReferenceDate: 123.456)

        let key = ThumbnailCache.requestKey(
            for: url,
            size: CGSize(width: 72, height: 64),
            scale: 2,
            modificationDate: date
        )
        let equivalentKey = ThumbnailCache.requestKey(
            for: url.standardizedFileURL,
            size: CGSize(width: 72, height: 64),
            scale: 2,
            modificationDate: date
        )

        XCTAssertEqual(key, equivalentKey)
        XCTAssertEqual(key.url, url.standardizedFileURL)
        XCTAssertEqual(key.pixelWidth, 144)
        XCTAssertEqual(key.pixelHeight, 128)
        XCTAssertFalse(key.usesSystemIcon)

        XCTAssertNotEqual(
            key,
            ThumbnailCache.requestKey(
                for: url,
                size: CGSize(width: 88, height: 64),
                scale: 2,
                modificationDate: date
            )
        )
        XCTAssertNotEqual(
            key,
            ThumbnailCache.requestKey(
                for: url,
                size: CGSize(width: 72, height: 64),
                scale: 2,
                modificationDate: date.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            ThumbnailCache.requestKey(
                for: url,
                size: CGSize(width: 72, height: 64),
                scale: 2,
                modificationDate: date,
                isDirectory: true
            ).usesSystemIcon
        )
    }
}
