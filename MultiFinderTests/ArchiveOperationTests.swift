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

        XCTAssertEqual(compressResult.status, .completed, compressResult.errorMessage ?? "")
        XCTAssertEqual(compressResult.outcomes.first?.destination, archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let extractResult = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("docs 2")

        XCTAssertEqual(extractResult.status, .completed, extractResult.errorMessage ?? "")
        XCTAssertEqual(extractResult.outcomes.first?.destination?.path, extracted.path)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("docs/readme.txt")),
            "hello"
        )
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("docs/nested/deep.txt")),
            "deep"
        )
        XCTAssertTrue(try operationArtifacts(in: extracted).isEmpty)
    }

    func testCompressMultipleItemsCreatesUniqueArchiveName() async throws {
        let first = workingDirectory.appendingPathComponent("first.txt")
        let second = workingDirectory.appendingPathComponent("second.txt")
        let archiveBaseName = L10n.string("Archive")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("occupied".utf8).write(
            to: workingDirectory.appendingPathComponent("\(archiveBaseName).zip")
        )

        let compressResult = await performDetailed { completion in
            service.compressDetailed([first, second], completion: completion)
        }
        let archive = workingDirectory.appendingPathComponent("\(archiveBaseName) 2.zip")

        XCTAssertEqual(compressResult.status, .completed, compressResult.errorMessage ?? "")
        XCTAssertEqual(compressResult.outcomes.first?.destination, archive)

        let extractResult = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("\(archiveBaseName) 2")

        XCTAssertEqual(extractResult.status, .completed, extractResult.errorMessage ?? "")
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

        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "")
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("payload/data.txt")),
            "tarred"
        )
        XCTAssertTrue(try operationArtifacts(in: extracted).isEmpty)
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

        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "")
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

        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "")
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

    func testExtractZipRejectsTraversalPathWithoutLeavingStagingOrWritingOutside() async throws {
        let archiveRoot = workingDirectory.appendingPathComponent("zip-root")
        let outside = workingDirectory.appendingPathComponent("zip-outside.txt")
        let archive = workingDirectory.appendingPathComponent("unsafe.zip")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("must remain untouched".utf8).write(to: outside)
        try runTool(
            "/usr/bin/zip",
            ["-q", archive.path, "../zip-outside.txt"],
            currentDirectory: archiveRoot
        )

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try String(contentsOf: outside), "must remain untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workingDirectory.appendingPathComponent("unsafe").path
        ))
        XCTAssertTrue(try operationArtifacts(in: workingDirectory).isEmpty)
    }

    func testExtractTarRejectsEscapingSymlinkWithoutLeavingStagingOrWritingOutside() async throws {
        let archiveRoot = workingDirectory.appendingPathComponent("tar-root")
        let outside = workingDirectory.appendingPathComponent("tar-outside.txt")
        let archive = workingDirectory.appendingPathComponent("unsafe-tar.tar")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("must remain untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: archiveRoot.appendingPathComponent("escape").path,
            withDestinationPath: "../tar-outside.txt"
        )
        try runTool(
            "/usr/bin/tar",
            ["-cf", archive.path, "-C", archiveRoot.path, "."]
        )

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try String(contentsOf: outside), "must remain untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workingDirectory.appendingPathComponent("unsafe-tar").path
        ))
        XCTAssertTrue(try operationArtifacts(in: workingDirectory).isEmpty)
    }

    func testExtractTarRejectsAbsolutePathAndEscapingHardlink() async throws {
        let outside = workingDirectory.appendingPathComponent("hardlink-outside.txt")
        try Data("must remain untouched".utf8).write(to: outside)

        let absoluteArchive = workingDirectory.appendingPathComponent("absolute.tar")
        try writeTarArchive(
            at: absoluteArchive,
            entries: [TarEntry(name: "/absolute.txt", type: 48, linkName: "", data: Data("bad".utf8))]
        )
        let absoluteResult = await performDetailed { completion in
            service.extractDetailed([absoluteArchive], completion: completion)
        }
        XCTAssertEqual(absoluteResult.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workingDirectory.appendingPathComponent("absolute").path
        ))

        let hardlinkArchive = workingDirectory.appendingPathComponent("hardlink.tar")
        try writeTarArchive(
            at: hardlinkArchive,
            entries: [TarEntry(name: "linked", type: 49, linkName: "../hardlink-outside.txt", data: Data())]
        )
        let hardlinkResult = await performDetailed { completion in
            service.extractDetailed([hardlinkArchive], completion: completion)
        }

        XCTAssertEqual(hardlinkResult.status, .failed)
        XCTAssertEqual(try String(contentsOf: outside), "must remain untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workingDirectory.appendingPathComponent("hardlink").path
        ))
        XCTAssertTrue(try operationArtifacts(in: workingDirectory).isEmpty)
    }

    func testExtractTarPreservesSafeInternalSymlink() async throws {
        let archiveRoot = workingDirectory.appendingPathComponent("safe-tar-root")
        let archive = workingDirectory.appendingPathComponent("safe-links.tar")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: archiveRoot.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: archiveRoot.appendingPathComponent("link").path,
            withDestinationPath: "target.txt"
        )
        try runTool(
            "/usr/bin/tar",
            ["-cf", archive.path, "-C", archiveRoot.path, "."]
        )

        let result = await performDetailed { completion in
            service.extractDetailed([archive], completion: completion)
        }
        let extracted = workingDirectory.appendingPathComponent("safe-links")

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: extracted.appendingPathComponent("link").path
            ),
            "target.txt"
        )
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("link")),
            "inside"
        )
    }

    func testArchiveProcessDrainsLargeStderrAndPreservesFailureMessage() throws {
        let command = [
            "dd if=/dev/zero bs=1048576 count=1 1>&2 2>/dev/null",
            "printf 'archive stderr marker\\n' >&2",
            "exit 7"
        ].joined(separator: "; ")

        do {
            try FileOperationService.runProcess(
                "/bin/sh",
                arguments: ["-c", command]
            )
            XCTFail("The verbose process should have failed")
        } catch let error as FileOperationError {
            XCTAssertTrue(error.message.contains("archive stderr marker"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    private nonisolated func runTool(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError(message: "\(launchPath) exited with \(process.terminationStatus)")
        }
    }

    private struct TarEntry {
        let name: String
        let type: UInt8
        let linkName: String
        let data: Data
    }

    private func writeTarArchive(at url: URL, entries: [TarEntry]) throws {
        var archive = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            writeTarField(entry.name, to: &header, offset: 0, length: 100)
            writeTarField("0000644\0", to: &header, offset: 100, length: 8)
            writeTarField("0000000\0", to: &header, offset: 108, length: 8)
            writeTarField("0000000\0", to: &header, offset: 116, length: 8)
            writeTarField(
                String(format: "%011o", entry.data.count) + "\0",
                to: &header,
                offset: 124,
                length: 12
            )
            writeTarField("00000000000\0", to: &header, offset: 136, length: 12)
            for index in 148..<156 {
                header[index] = 32
            }
            header[156] = entry.type
            writeTarField(entry.linkName, to: &header, offset: 157, length: 100)
            writeTarField("ustar\0", to: &header, offset: 257, length: 6)
            writeTarField("00", to: &header, offset: 263, length: 2)

            let checksum = header.reduce(0) { $0 + UInt64($1) }
            writeTarField(
                String(format: "%06o", checksum) + " \0",
                to: &header,
                offset: 148,
                length: 8
            )
            archive.append(contentsOf: header)
            archive.append(entry.data)
            let padding = (512 - (entry.data.count % 512)) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: 1024))
        try archive.write(to: url)
    }

    private func writeTarField(
        _ value: String,
        to header: inout [UInt8],
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private func operationArtifacts(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".multifinder-") }
    }
}
