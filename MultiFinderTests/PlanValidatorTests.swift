import Foundation
import XCTest
@testable import MultiFinder

final class PlanValidatorTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanValidatorTests-\(UUID().uuidString)")
        outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanValidatorTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    private func createFile(_ relativePath: String, in directory: URL? = nil) throws {
        let url = (directory ?? root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    func testValidPlanIsExecutable() throws {
        try createFile("IMG_001.png")
        try createFile("IMG_002.png")
        try createFile("junk.tmp")

        let result = try PlanValidator.validate(
            [
                .createFolder(path: "Screenshots"),
                .createFolder(path: "Screenshots/2026-06"),
                .move(source: "IMG_001.png", destination: "Screenshots/2026-06/IMG_001.png"),
                .copy(source: "IMG_002.png", destination: "Screenshots/2026-06/IMG_002.png"),
                .rename(source: "IMG_002.png", newName: "cover.png"),
                .trash(source: "junk.tmp")
            ],
            scopeRoot: root
        )

        XCTAssertTrue(result.isExecutable)
        XCTAssertTrue(result.conflictedOperations.isEmpty)
        XCTAssertEqual(result.operations.count, 6)
    }

    func testRejectsParentDirectoryEscape() throws {
        try createFile("a.txt")
        XCTAssertThrowsError(try PlanValidator.validate(
            [.move(source: "../escape.txt", destination: "a.txt")],
            scopeRoot: root
        )) { error in
            XCTAssertTrue(error is PlanValidationError)
        }
        XCTAssertThrowsError(try PlanValidator.validate(
            [.move(source: "a.txt", destination: "sub/../../escape.txt")],
            scopeRoot: root
        ))
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try PlanValidator.validate(
            [.trash(source: "/etc/hosts")],
            scopeRoot: root
        )) { error in
            XCTAssertTrue(error is PlanValidationError)
        }
        XCTAssertThrowsError(try PlanValidator.validate(
            [.trash(source: "~/Documents/a.txt")],
            scopeRoot: root
        ))
    }

    func testRejectsSymlinkEscape() throws {
        try createFile("target.txt", in: outside)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)

        XCTAssertThrowsError(try PlanValidator.validate(
            [.trash(source: "link/target.txt")],
            scopeRoot: root
        )) { error in
            XCTAssertTrue(error is PlanValidationError)
        }
        XCTAssertThrowsError(try PlanValidator.validate(
            [.trash(source: "link")],
            scopeRoot: root
        ))
    }

    func testUnknownOperationIsRejectedAtParse() {
        let text = """
        {"kind": "organize", "summary": "x", "operations": [{"op": "deletePermanently", "source": "a.txt"}]}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text))
    }

    func testRenameWithIllegalNameIsRejected() throws {
        try createFile("a.txt")
        XCTAssertThrowsError(try PlanValidator.validate(
            [.rename(source: "a.txt", newName: "b/c.txt")],
            scopeRoot: root
        ))
        XCTAssertThrowsError(try PlanValidator.validate(
            [.rename(source: "a.txt", newName: "..")],
            scopeRoot: root
        ))
    }

    func testDestinationExistingOnDiskIsConflict() throws {
        try createFile("a.txt")
        try createFile("b.txt")

        let result = try PlanValidator.validate(
            [.move(source: "a.txt", destination: "b.txt")],
            scopeRoot: root
        )

        XCTAssertFalse(result.isExecutable)
        XCTAssertEqual(result.operations.count, 1)
        XCTAssertTrue(result.operations[0].isConflicted)
        XCTAssertFalse(result.operations[0].issues.isEmpty)
    }

    func testDuplicateDestinationsWithinBatchFlagBothRows() throws {
        try createFile("a.txt")
        try createFile("b.txt")

        let result = try PlanValidator.validate(
            [
                .move(source: "a.txt", destination: "merged.txt"),
                .move(source: "b.txt", destination: "merged.txt")
            ],
            scopeRoot: root
        )

        XCTAssertFalse(result.isExecutable)
        XCTAssertTrue(result.operations[0].isConflicted)
        XCTAssertTrue(result.operations[1].isConflicted)
    }

    func testCreateFolderParentCanBeCreatedEarlierInPlan() throws {
        try createFile("a.txt")
        let result = try PlanValidator.validate(
            [
                .createFolder(path: "Archive"),
                .createFolder(path: "Archive/2026"),
                .move(source: "a.txt", destination: "Archive/2026/a.txt")
            ],
            scopeRoot: root
        )
        XCTAssertTrue(result.isExecutable)
    }

    func testCreateFolderWithMissingParentIsConflict() throws {
        let result = try PlanValidator.validate(
            [.createFolder(path: "Missing/2026")],
            scopeRoot: root
        )
        XCTAssertFalse(result.isExecutable)
        XCTAssertTrue(result.operations[0].isConflicted)
    }

    func testMissingSourceIsConflictNotRejection() throws {
        let result = try PlanValidator.validate(
            [.trash(source: "ghost.txt")],
            scopeRoot: root
        )
        XCTAssertFalse(result.isExecutable)
        XCTAssertTrue(result.operations[0].isConflicted)
    }

    func testOperationCountLimit() throws {
        let overLimit = (0..<501).map { AIPlanOperation.trash(source: "file-\($0).txt") }
        XCTAssertThrowsError(try PlanValidator.validate(overLimit, scopeRoot: root)) { error in
            XCTAssertTrue(error is PlanValidationError)
        }
        XCTAssertNoThrow(try PlanValidator.validate(Array(overLimit.prefix(500)), scopeRoot: root))
    }

    func testSubsetRevalidationAfterExcludingConflictedRow() throws {
        try createFile("a.txt")
        try createFile("b.txt")
        try createFile("existing.txt")

        let operations: [AIPlanOperation] = [
            .move(source: "a.txt", destination: "moved-a.txt"),
            .move(source: "b.txt", destination: "existing.txt")
        ]
        let first = try PlanValidator.validate(operations, scopeRoot: root)
        XCTAssertFalse(first.isExecutable)
        XCTAssertEqual(first.conflictedOperations.map(\.id), [1])

        let remaining = first.operations.filter { !$0.isConflicted }.map(\.operation)
        let second = try PlanValidator.validate(remaining, scopeRoot: root)
        XCTAssertTrue(second.isExecutable)
        XCTAssertEqual(second.operations.map(\.operation), [.move(source: "a.txt", destination: "moved-a.txt")])
    }

    func testEmptyPlanIsNotExecutable() throws {
        let result = try PlanValidator.validate([], scopeRoot: root)
        XCTAssertFalse(result.isExecutable)
        XCTAssertTrue(result.operations.isEmpty)
    }

    func testValidatePlanConvenienceUsesOperations() throws {
        try createFile("a.txt")
        let plan = AIPlan(
            kind: .organize,
            summary: "x",
            search: nil,
            operations: [.trash(source: "a.txt")]
        )
        let result = try PlanValidator.validate(plan, scopeRoot: root)
        XCTAssertTrue(result.isExecutable)
    }
}
