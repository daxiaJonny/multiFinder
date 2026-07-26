import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class AIOrganizeServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var scopeRoot: URL!
    private var service: FileOperationService!

    override func setUp() async throws {
        try await MainActor.run {
            temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MultiFinderAIOrganizeTests-\(UUID().uuidString)")
            scopeRoot = temporaryDirectory.appendingPathComponent("scope")
            try FileManager.default.createDirectory(at: scopeRoot, withIntermediateDirectories: true)
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

    func testOrganizePlanExecutesAllOperationsAndRecordsHistory() async throws {
        try Data("one".utf8).write(to: scopeRoot.appendingPathComponent("IMG_001.png"))
        try Data("two".utf8).write(to: scopeRoot.appendingPathComponent("IMG_002.png"))
        try Data("notes".utf8).write(to: scopeRoot.appendingPathComponent("notes.txt"))
        try Data("draft".utf8).write(to: scopeRoot.appendingPathComponent("draft.txt"))

        let result = await performDetailed { completion in
            service.aiOrganizeDetailed(
                [
                    .createFolder(path: "Archive"),
                    .move(source: "IMG_001.png", destination: "Archive/IMG_001.png"),
                    .move(source: "IMG_002.png", destination: "Archive/IMG_002.png"),
                    .copy(source: "notes.txt", destination: "Archive/notes.txt"),
                    .rename(source: "draft.txt", newName: "final.txt")
                ],
                scopeRoot: scopeRoot,
                completion: completion
            )
        }

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.outcomes.count, 5)
        XCTAssertEqual(service.history.first?.kind, .aiOrganize)
        XCTAssertEqual(service.history.first?.itemCount, 5)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scopeRoot.appendingPathComponent("Archive").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("Archive/IMG_001.png")), "one")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("Archive/IMG_002.png")), "two")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("Archive/notes.txt")), "notes")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("notes.txt")), "notes")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("final.txt")), "draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("IMG_001.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("draft.txt").path))
        XCTAssertTrue(service.canUndo)
    }

    func testUndoRestoresMovedFilesAndRemovesCreatedItems() async throws {
        try Data("one".utf8).write(to: scopeRoot.appendingPathComponent("IMG_001.png"))
        try Data("notes".utf8).write(to: scopeRoot.appendingPathComponent("notes.txt"))
        try Data("draft".utf8).write(to: scopeRoot.appendingPathComponent("draft.txt"))

        let result = await performDetailed { completion in
            service.aiOrganizeDetailed(
                [
                    .createFolder(path: "Archive"),
                    .move(source: "IMG_001.png", destination: "Archive/IMG_001.png"),
                    .copy(source: "notes.txt", destination: "Archive/notes.txt"),
                    .rename(source: "draft.txt", newName: "final.txt")
                ],
                scopeRoot: scopeRoot,
                completion: completion
            )
        }
        let recordID = try XCTUnwrap(service.history.first?.id)
        XCTAssertEqual(result.status, .completed)

        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("IMG_001.png")), "one")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("notes.txt")), "notes")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("draft.txt")), "draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("Archive").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("final.txt").path))
        XCTAssertTrue(service.canRedo)
    }

    func testTrashOperationSendsItemToTrashAndUndoRestoresIt() async throws {
        let junk = scopeRoot.appendingPathComponent("junk.tmp")
        try Data("junk".utf8).write(to: junk)

        let result = await performDetailed { completion in
            service.aiOrganizeDetailed(
                [.trash(source: "junk.tmp")],
                scopeRoot: scopeRoot,
                completion: completion
            )
        }
        let recordID = try XCTUnwrap(service.history.first?.id)
        let trashedURL = try XCTUnwrap(result.outcomes.first?.destination)

        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
        XCTAssertNotEqual(trashedURL.standardizedFileURL.path, junk.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))
        XCTAssertTrue(service.canUndo)

        service.undo()
        try await waitUntil {
            self.service.activeOperation == nil &&
                self.service.history.first(where: { $0.id == recordID })?.status == .undone
        }

        XCTAssertEqual(try String(contentsOf: junk), "junk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedURL.path))
        XCTAssertTrue(service.canRedo)
    }

    func testFailedItemKeepsRemainingItemsRunningAndIsRetryable() async throws {
        try Data("a".utf8).write(to: scopeRoot.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: scopeRoot.appendingPathComponent("b.txt"))
        try Data("c".utf8).write(to: scopeRoot.appendingPathComponent("c.txt"))
        try Data("occupied".utf8).write(to: scopeRoot.appendingPathComponent("occupied.txt"))

        let result = await performDetailed { completion in
            service.aiOrganizeDetailed(
                [
                    .move(source: "a.txt", destination: "sorted-a.txt"),
                    .move(source: "b.txt", destination: "occupied.txt"),
                    .rename(source: "c.txt", newName: "c-final.txt")
                ],
                scopeRoot: scopeRoot,
                completion: completion
            )
        }
        let failedRecordID = try XCTUnwrap(service.history.first?.id)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(
            result.completedOutcomes.map(\.source.lastPathComponent),
            ["a.txt", "c.txt"]
        )
        XCTAssertEqual(result.failedOutcomes.map(\.source.lastPathComponent), ["b.txt"])
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("sorted-a.txt")), "a")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("b.txt")), "b")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("occupied.txt")), "occupied")
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("c-final.txt")), "c")
        XCTAssertTrue(service.canUndo)

        try FileManager.default.removeItem(at: scopeRoot.appendingPathComponent("occupied.txt"))
        service.retry(failedRecordID)
        try await waitUntil {
            self.service.activeOperation == nil && self.service.history.count == 2
        }

        XCTAssertEqual(service.history[0].status, .completed)
        XCTAssertEqual(service.history[0].itemCount, 1)
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("occupied.txt")), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("b.txt").path))
    }

    func testOperationsDependingOnEarlierCreatedFoldersSucceed() async throws {
        try Data("deep".utf8).write(to: scopeRoot.appendingPathComponent("deep.txt"))

        let result = await performDetailed { completion in
            service.aiOrganizeDetailed(
                [
                    .createFolder(path: "A"),
                    .createFolder(path: "A/B"),
                    .move(source: "deep.txt", destination: "A/B/deep.txt")
                ],
                scopeRoot: scopeRoot,
                completion: completion
            )
        }

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: scopeRoot.appendingPathComponent("A/B/deep.txt")), "deep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeRoot.appendingPathComponent("deep.txt").path))
    }

    func testEmptyOperationsArrayIsDroppedWithoutHistory() async throws {
        service.aiOrganizeDetailed([], scopeRoot: scopeRoot)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(service.activeOperation)
        XCTAssertEqual(service.queuedOperationCount, 0)
        XCTAssertTrue(service.history.isEmpty)
        XCTAssertFalse(service.canUndo)
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
}
