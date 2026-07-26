import Foundation
import Darwin
import XCTest
@testable import MultiFinder

@MainActor
final class FileOperationServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var sourceDirectory: URL!
    private var destinationDirectory: URL!
    private var service: FileOperationService!

    override func setUp() async throws {
        try await MainActor.run {
            temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MultiFinderOperationTests-\(UUID().uuidString)")
            sourceDirectory = temporaryDirectory.appendingPathComponent("source")
            destinationDirectory = temporaryDirectory.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
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

    func testKeepBothGeneratesCopyTwoAndCopyThree() async throws {
        let source = sourceDirectory.appendingPathComponent("report.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destinationDirectory.appendingPathComponent("report.txt"))
        try Data("copy".utf8).write(to: destinationDirectory.appendingPathComponent("report copy.txt"))
        try Data("copy 2".utf8).write(to: destinationDirectory.appendingPathComponent("report copy 2.txt"))

        try await perform { completion in
            service.copy([source], to: destinationDirectory, conflictPolicy: .keepBoth, completion: completion)
        }

        let generated = destinationDirectory.appendingPathComponent("report copy 3.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path))
        XCTAssertEqual(try String(contentsOf: generated), "source")
    }

    func testQueueSerializesCopyThenMoveAndRecordsHistory() async throws {
        let first = sourceDirectory.appendingPathComponent("first.txt")
        let second = sourceDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let copyFinished = expectation(description: "copy finished")
        let moveFinished = expectation(description: "move finished")
        service.copy([first], to: destinationDirectory, conflictPolicy: .keepBoth) { result in
            if case .failure(let error) = result {
                XCTFail("Copy failed: \(error.localizedDescription)")
            }
            copyFinished.fulfill()
        }
        service.move([second], to: destinationDirectory, conflictPolicy: .keepBoth) { result in
            if case .failure(let error) = result {
                XCTFail("Move failed: \(error.localizedDescription)")
            }
            moveFinished.fulfill()
        }
        await fulfillment(of: [copyFinished, moveFinished], timeout: 3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("first.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("second.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(service.history.filter { $0.status == .completed }.count, 2)
    }

    func testRenameValidationRejectsReservedAndIllegalNames() {
        XCTAssertNotNil(FileOperationService.validationError(forFileName: ""))
        XCTAssertNotNil(FileOperationService.validationError(forFileName: "."))
        XCTAssertNotNil(FileOperationService.validationError(forFileName: ".."))
        XCTAssertNotNil(FileOperationService.validationError(forFileName: "a/b"))
        XCTAssertNil(FileOperationService.validationError(forFileName: "valid name.txt"))
    }

    func testSkipProducesPartialResultAndPreservesBothItems() async throws {
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        let result = await performDetailed { completion in
            service.copyDetailed(
                [source],
                to: destinationDirectory,
                conflictPolicy: .skip,
                completion: completion
            )
        }

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.outcomes[0].status, .skipped)
        XCTAssertEqual(result.outcomes[0].destination, destination)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: destination), "destination")
        XCTAssertFalse(service.canUndo)
    }

    func testRenameKeepBothUsesProposedNameAndReportsActualDestination() async throws {
        let source = sourceDirectory.appendingPathComponent("draft.txt")
        let proposedDestination = sourceDirectory.appendingPathComponent("final.txt")
        let actualDestination = sourceDirectory.appendingPathComponent("final copy.txt")
        try Data("draft".utf8).write(to: source)
        try Data("existing".utf8).write(to: proposedDestination)

        let result = await performDetailed { completion in
            service.renameDetailed(
                source,
                to: proposedDestination,
                conflictPolicy: .keepBoth,
                completion: completion
            )
        }

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outcomes.first?.destination, actualDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: actualDestination), "draft")
        XCTAssertEqual(try String(contentsOf: proposedDestination), "existing")
    }

    func testUndoReplacementRestoresOriginalDestination() async throws {
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: destination)

        let result = await performDetailed { completion in
            service.copyDetailed(
                [source],
                to: destinationDirectory,
                conflictPolicy: .replace,
                completion: completion
            )
        }
        let recordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertEqual(try String(contentsOf: source), "replacement")
        XCTAssertTrue(service.canRedo)

        let historyCount = service.history.count
        service.redo()
        try await waitUntil {
            self.service.activeOperation == nil && self.service.history.count == historyCount + 1
        }
        XCTAssertEqual(service.history.first?.status, .completed)
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertTrue(service.canUndo)
    }

    func testUndoCrossVolumeMoveReplacementUsesInstalledIdentity() async throws {
        let sourcePath = sourceDirectory.standardizedFileURL.path
        service = FileOperationService(volumeIdentifierProvider: { url in
            url.standardizedFileURL.path.hasPrefix(sourcePath) ? 1 : 2
        })
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: destination)
        let sourceInode = try fileInode(at: source)

        let result = await performDetailed { completion in
            service.moveDetailed(
                [source],
                to: destinationDirectory,
                conflictPolicy: .replace,
                completion: completion
            )
        }
        let recordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertNotEqual(try fileInode(at: destination), sourceInode)

        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertEqual(try String(contentsOf: source), "replacement")
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertTrue(service.canRedo)
    }

    func testReplacementFailureAfterBackupRestoresOriginalWithoutUndoRecord() async throws {
        service = FileOperationService(replacementInstallHook: {
            throw FileOperationError(message: "Injected replacement failure")
        })
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: destination)

        let result = await performDetailed { completion in
            service.copyDetailed(
                [source],
                to: destinationDirectory,
                conflictPolicy: .replace,
                completion: completion
            )
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertEqual(try String(contentsOf: source), "replacement")
        XCTAssertFalse(service.canUndo)
        let names = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".multifinder-") }))
    }

    func testRetryOnlyProcessesFailedMoveItems() async throws {
        let first = sourceDirectory.appendingPathComponent("first.txt")
        let missing = sourceDirectory.appendingPathComponent("missing.txt")
        try Data("first".utf8).write(to: first)

        let result = await performDetailed { completion in
            service.moveDetailed(
                [first, missing],
                to: destinationDirectory,
                conflictPolicy: .keepBoth,
                completion: completion
            )
        }
        let failedRecordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.completedOutcomes.map(\.source), [first])
        XCTAssertEqual(result.failedOutcomes.map(\.source), [missing])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("first.txt").path
        ))

        try Data("now available".utf8).write(to: missing)
        service.retry(failedRecordID)
        try await waitUntil {
            self.service.activeOperation == nil && self.service.history.count == 2
        }

        XCTAssertEqual(service.history[0].status, .completed)
        XCTAssertEqual(service.history[0].itemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("missing.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("first copy.txt").path
        ))
    }

    func testCopyIntoSameDirectoryCreatesAUniqueCopy() async throws {
        let source = sourceDirectory.appendingPathComponent("notes.txt")
        let expectedCopy = sourceDirectory.appendingPathComponent("notes copy.txt")
        try Data("notes".utf8).write(to: source)

        let result = await performDetailed { completion in
            service.copyDetailed([source], to: sourceDirectory, completion: completion)
        }

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outcomes.first?.destination, expectedCopy)
        XCTAssertEqual(try String(contentsOf: expectedCopy), "notes")
    }

    func testCancelWhileWaitingForConflictProducesCancelledOutcome() async throws {
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        let resultTask = Task { @MainActor in
            await performDetailed { completion in
                service.copyDetailed(
                    [source],
                    to: destinationDirectory,
                    conflictPolicy: .ask,
                    completion: completion
                )
            }
        }
        try await waitUntil { self.service.pendingConflict != nil }
        service.cancelCurrent()
        let result = await resultTask.value

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.outcomes.first?.status, .cancelled)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: destination), "destination")
        XCTAssertFalse(service.canUndo)
    }

    func testCancelDuringLargeCopyRemovesTheStagingItem() async throws {
        let source = sourceDirectory.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        let megabyte = Data(repeating: 0xA5, count: 1_048_576)
        for _ in 0..<256 {
            try writer.write(contentsOf: megabyte)
        }
        try writer.close()

        let resultTask = Task { @MainActor in
            await performDetailed { completion in
                service.copyDetailed([source], to: destinationDirectory, completion: completion)
            }
        }
        try await waitUntil(timeout: 5) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.destinationDirectory.path)) ?? []
            return names.contains(where: { $0.hasPrefix(".multifinder-copy-") })
        }
        service.cancelCurrent()
        let result = await resultTask.value

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("large.bin").path
        ))
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
        XCTAssertFalse(remainingNames.contains(where: { $0.hasPrefix(".multifinder-copy-") }))
    }

    func testUndoRefusesToDeleteAReplacementAtTheCreatedPath() async throws {
        let source = sourceDirectory.appendingPathComponent("report.txt")
        let destination = destinationDirectory.appendingPathComponent("report.txt")
        let movedCopy = temporaryDirectory.appendingPathComponent("moved-copy.txt")
        try Data("copied".utf8).write(to: source)

        let result = await performDetailed { completion in
            service.copyDetailed([source], to: destinationDirectory, completion: completion)
        }
        XCTAssertEqual(result.status, .completed)

        try FileManager.default.moveItem(at: destination, to: movedCopy)
        try Data("replacement".utf8).write(to: destination)
        let historyCount = service.history.count
        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil && self.service.history.count == historyCount + 1
        }

        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedCopy.path))
        XCTAssertEqual(service.history.first?.status, .failed)
        XCTAssertTrue(service.canUndo)
    }

    private func perform(
        _ operation: @MainActor (@escaping (Result<Void, FileOperationError>) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            operation { result in
                continuation.resume(with: result)
            }
        }
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

    private func fileInode(at url: URL) throws -> UInt64 {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return UInt64(metadata.st_ino)
    }
}
