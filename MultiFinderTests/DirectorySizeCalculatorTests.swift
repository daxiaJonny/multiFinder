import Darwin
import Foundation
import XCTest
@testable import MultiFinder

final class DirectorySizeCalculatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderDirectorySizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testCalculatesNestedFilesIncludesPackageContentsAndDoesNotFollowSymlinkDirectories() async throws {
        let topLevelContents = "hello"
        _ = try write(topLevelContents, at: "top.txt")
        let nestedDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedContents = "nested"
        _ = try write(nestedContents, at: "nested/deep.txt")

        let package = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let includedContents = String(repeating: "included", count: 20)
        _ = try write(includedContents, at: "Demo.app/Contents/ignored.txt")

        let emptyDirectory = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("nested-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nestedDirectory)

        let progress = ProgressCollector()
        let calculator = DirectorySizeCalculator()
        let result = try await calculator.calculate(url: root) { update in
            progress.append(update)
        }

        let linkSize = try symbolicLinkSize(at: link)
        XCTAssertEqual(
            result.byteCount,
            Int64(topLevelContents.utf8.count + nestedContents.utf8.count + includedContents.utf8.count) + linkSize
        )
        XCTAssertEqual(result.fileCount, 4)
        XCTAssertEqual(result.directoryCount, 4)
        XCTAssertEqual(result.itemCount, 8)
        XCTAssertEqual(result.skippedPackageCount, 0)
        XCTAssertEqual(result.skippedSymbolicLinkDirectoryCount, 1)
        let packageResult = try await calculator.calculate(url: package)
        XCTAssertEqual(packageResult.byteCount, Int64(includedContents.utf8.count))
        XCTAssertEqual(packageResult.fileCount, 1)
        XCTAssertEqual(packageResult.directoryCount, 1)
        XCTAssertEqual(packageResult.skippedPackageCount, 0)
        XCTAssertTrue(progress.values.contains { $0.processedItemCount > 0 })
        XCTAssertTrue(progress.values.allSatisfy { $0.skippedPackageCount == 0 })
        XCTAssertFalse(progress.values.contains { $0.byteCount > result.byteCount })
    }

    func testNestedSelectedRootsAreCountedOnlyOnce() async throws {
        _ = try write("one", at: "folder/one.txt")
        _ = try write("two", at: "folder/inside/two.txt")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let inside = folder.appendingPathComponent("inside", isDirectory: true)

        let calculator = DirectorySizeCalculator()
        let folderResult = try await calculator.calculate(url: folder)
        let aggregateResult = try await calculator.calculate(urls: [folder, inside])

        XCTAssertEqual(aggregateResult, folderResult)
    }

    func testCancellationIsObservedDuringTraversal() async throws {
        for index in 0..<2_000 {
            _ = try write("payload-\(index)", at: "many/item-\(index).txt")
        }

        let cancellation = TaskCancellationController()
        let calculationRoot = root!
        let task = Task {
            try await DirectorySizeCalculator().calculate(url: calculationRoot) { update in
                if update.processedItemCount == 1 {
                    cancellation.request()
                }
            }
        }
        cancellation.set(task)

        do {
            _ = try await task.value
            XCTFail("The directory size calculation should have been cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    private func write(_ contents: String, at relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func symbolicLinkSize(at url: URL) throws -> Int64 {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let result = lstat(path, &metadata)
            return (result, result == 0 ? 0 : errno)
        }
        guard result.0 == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.1))
        }
        return Int64(metadata.st_size)
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [DirectorySizeProgress] = []

    func append(_ value: DirectorySizeProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class TaskCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DirectorySizeResult, Error>?
    private var cancellationRequested = false

    func set(_ task: Task<DirectorySizeResult, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func request() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
