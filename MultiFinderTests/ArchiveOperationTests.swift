import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class ArchiveOperationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var workingDirectory: URL!
    private var service: FileOperationService!

    override func setUp() async throws {
        try await MainActor.run {
            temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MultiFinderArchiveTests-\(UUID().uuidString)")
            workingDirectory = temporaryDirectory.appendingPathComponent("working")
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            service = FileOperationService()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
    }

    func testCompressSingleFolderAndExtractRoundTrip() async throws {
        let folder = workingDirectory.appendingPathComponent("docs")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))

        let compressResult = await performDetailed { completion in
            service.compressDetailed([folder], completion: completion)
        }
        let archive = workingDirectory.appendingPathComponent("docs.zip")

        XCTAssertEqual(compressResult.status, .completed)
        XCTAssertEqual(compressResult.outcomes.first?.destination, archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let extractResult = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("docs 2")

        XCTAssertEqual(extractResult.status, .completed)
        XCTAssertEqual(extractResult.outcomes.first?.destination?.path, extracted.path)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("docs/readme.txt")),
            "hello"
        )
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("docs/nested/deep.txt")),
            "deep"
        )
    }

    func testCompressMultipleItemsCreatesUniqueArchiveName() async throws {
        let first = workingDirectory.appendingPathComponent("first.txt")
        let second = workingDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("occupied".utf8).write(to: workingDirectory.appendingPathComponent("Archive.zip"))

        let compressResult = await performDetailed { completion in
            service.compressDetailed([first, second], completion: completion)
        }
        let archive = workingDirectory.appendingPathComponent("Archive 2.zip")

        XCTAssertEqual(compressResult.status, .completed)
        XCTAssertEqual(compressResult.outcomes.first?.destination, archive)

        let extractResult = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("Archive 2")

        XCTAssertEqual(extractResult.status, .completed)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("first.txt")), "first")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("second.txt")), "second")
    }

    func testExtractTarRoundTrip() async throws {
        let payload = workingDirectory.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("tarred".utf8).write(to: payload.appendingPathComponent("data.txt"))
        let archive = workingDirectory.appendingPathComponent("bundle.tar")
        try runTool("/usr/bin/tar", ["-cf", archive.path, "-C", workingDirectory.path, "payload"])

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("bundle")

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("payload/data.txt")),
            "tarred"
        )
    }

    func testExtractGzipProducesDecompressedFileInsideDirectory() async throws {
        let original = workingDirectory.appendingPathComponent("notes.txt")
        try Data("gzipped".utf8).write(to: original)
        try runTool("/usr/bin/gzip", [original.path])
        let archive = workingDirectory.appendingPathComponent("notes.txt.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("notes.txt")

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("notes.txt")),
            "gzipped"
        )
    }

    func testUndoCompressTrashesTheArchive() async throws {
        let source = workingDirectory.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: source)

        let result = await performDetailed { completion in
            service.compressDetailed([source], completion: completion)
        }
        let archive = workingDirectory.appendingPathComponent("report.txt.zip")
        let recordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(service.canUndo)

        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(service.canRedo)
    }

    func testUndoExtractTrashesTheExtractedDirectory() async throws {
        let source = workingDirectory.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: source)
        _ = await performDetailed { completion in
            service.compressDetailed([source], completion: completion)
        }
        let archive = workingDirectory.appendingPathComponent("report.txt.zip")

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = try XCTUnwrap(result.outcomes.first?.destination)
        let recordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .completed)
        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testExtractCorruptZipReportsToolFailure() async throws {
        let archive = workingDirectory.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: archive)

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.outcomes.first?.status, .failed)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertFalse(service.canUndo)
        let names = try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".multifinder-") }))
    }

    func testIsExtractableArchiveMatchesSupportedExtensionsOnly() {
        XCTAssertTrue(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.tar")))
        XCTAssertTrue(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        XCTAssertTrue(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.tgz")))
        XCTAssertTrue(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.gz")))
        XCTAssertFalse(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.rar")))
        XCTAssertFalse(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/a.7z")))
        XCTAssertFalse(FileOperationService.isExtractableArchive(URL(fileURLWithPath: "/tmp/.gz")))
        XCTAssertEqual(
            FileOperationService.extractionBaseName(for: URL(fileURLWithPath: "/tmp/bundle.tar.gz")),
            "bundle"
        )
    }

    private func performDetailed(
        _ operation: @MainActor (@escaping (FileOperationResult) -> Void) -> Void
    ) async -> FileOperationResult {
        await withCheckedContinuation { continuation in
            operation { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Condition was not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private nonisolated func runTool(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError(message: "\(launchPath) exited with \(process.terminationStatus)")
        }
    }
}
