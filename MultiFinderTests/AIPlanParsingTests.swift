import Foundation
import XCTest
@testable import MultiFinder

final class AIPlanParsingTests: XCTestCase {
    private func dayDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    func testParsesCleanOrganizeJSON() throws {
        let text = """
        {
          "kind": "organize",
          "summary": "归档截图到月份文件夹",
          "operations": [
            {"op": "createFolder", "path": "Screenshots/2026-06"},
            {"op": "move", "source": "IMG_001.png", "destination": "Screenshots/2026-06/IMG_001.png"},
            {"op": "copy", "source": "notes.txt", "destination": "backup/notes.txt"},
            {"op": "rename", "source": "draft.md", "newName": "final.md"},
            {"op": "trash", "source": "junk.tmp"}
          ]
        }
        """
        let plan = try AIPlan.parse(from: text)
        XCTAssertEqual(plan.kind, .organize)
        XCTAssertEqual(plan.summary, "归档截图到月份文件夹")
        XCTAssertNil(plan.search)
        XCTAssertEqual(plan.operations, [
            .createFolder(path: "Screenshots/2026-06"),
            .move(source: "IMG_001.png", destination: "Screenshots/2026-06/IMG_001.png"),
            .copy(source: "notes.txt", destination: "backup/notes.txt"),
            .rename(source: "draft.md", newName: "final.md"),
            .trash(source: "junk.tmp")
        ])
    }

    func testParsesJSONWrappedInMarkdownFence() throws {
        let text = """
        ```json
        {"kind": "organize", "summary": "clean", "operations": [{"op": "trash", "source": "junk.tmp"}]}
        ```
        """
        let plan = try AIPlan.parse(from: text)
        XCTAssertEqual(plan.operations, [.trash(source: "junk.tmp")])
    }

    func testParsesJSONWithSurroundingProseAndPlainFence() throws {
        let text = """
        Sure, here is the plan you asked for.
        ```
        {"kind": "organize", "summary": "clean", "operations": [{"op": "trash", "source": "junk.tmp"}]}
        ```
        Let me know if you need anything else! :}
        """
        let plan = try AIPlan.parse(from: text)
        XCTAssertEqual(plan.summary, "clean")
        XCTAssertEqual(plan.operations?.count, 1)
    }

    func testRejectsUnknownOperation() {
        let text = """
        {"kind": "organize", "summary": "x", "operations": [{"op": "chmod", "source": "a.txt"}]}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text)) { error in
            let message = (error as? AIPlanParseError)?.message ?? ""
            XCTAssertTrue(message.contains("chmod"))
        }
    }

    func testIgnoresUnknownExtraFields() throws {
        let text = """
        {
          "kind": "organize",
          "summary": "x",
          "confidence": 0.9,
          "operations": [
            {"op": "trash", "source": "junk.tmp", "reason": "temporary file"}
          ]
        }
        """
        let plan = try AIPlan.parse(from: text)
        XCTAssertEqual(plan.operations, [.trash(source: "junk.tmp")])
    }

    func testMissingSummaryProducesReadableError() {
        let text = """
        {"kind": "organize", "operations": [{"op": "trash", "source": "junk.tmp"}]}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text)) { error in
            let message = (error as? AIPlanParseError)?.message ?? ""
            XCTAssertTrue(message.contains("summary"))
        }
    }

    func testMissingOperationFieldMentionsFieldName() {
        let text = """
        {"kind": "organize", "summary": "x", "operations": [{"op": "move", "source": "a.txt"}]}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text)) { error in
            let message = (error as? AIPlanParseError)?.message ?? ""
            XCTAssertTrue(message.contains("destination"))
        }
    }

    func testRejectsUnknownPlanKind() {
        let text = """
        {"kind": "delete-all", "summary": "x", "operations": []}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text)) { error in
            let message = (error as? AIPlanParseError)?.message ?? ""
            XCTAssertTrue(message.contains("delete-all"))
        }
    }

    func testSearchPlanParsesCriteriaAndDates() throws {
        let text = """
        {
          "kind": "search",
          "summary": "上周修改过的 PDF",
          "search": {
            "nameContains": ["报告", "report"],
            "extensions": ["pdf"],
            "modifiedAfter": "2026-06-01",
            "modifiedBefore": "2026-07-01",
            "minSize": 0,
            "maxSize": 10485760,
            "recursive": true
          }
        }
        """
        let plan = try AIPlan.parse(from: text)
        XCTAssertEqual(plan.kind, .search)
        XCTAssertNil(plan.operations)
        let criteria = try XCTUnwrap(plan.search)
        XCTAssertEqual(criteria.nameContains, ["报告", "report"])
        XCTAssertEqual(criteria.extensions, ["pdf"])
        XCTAssertEqual(criteria.modifiedAfter, dayDate("2026-06-01"))
        XCTAssertEqual(criteria.modifiedBefore, dayDate("2026-07-01"))
        XCTAssertEqual(criteria.minSize, 0)
        XCTAssertEqual(criteria.maxSize, 10_485_760)
        XCTAssertEqual(criteria.recursive, true)
    }

    func testSearchPlanRoundTrip() throws {
        let plan = AIPlan(
            kind: .search,
            summary: "find screenshots",
            search: AISearchCriteria(
                nameContains: ["Screenshot"],
                extensions: ["png"],
                modifiedAfter: dayDate("2026-06-01"),
                recursive: true
            ),
            operations: nil
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try AIPlan.parse(from: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(decoded, plan)
    }

    func testOrganizePlanRoundTrip() throws {
        let plan = AIPlan(
            kind: .organize,
            summary: "archive",
            search: nil,
            operations: [
                .createFolder(path: "Archive"),
                .move(source: "a.txt", destination: "Archive/a.txt"),
                .copy(source: "b.txt", destination: "Archive/b.txt"),
                .rename(source: "c.txt", newName: "d.txt"),
                .trash(source: "e.txt")
            ]
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try AIPlan.parse(from: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(decoded, plan)
    }

    func testSearchPlanRequiresCriteria() {
        XCTAssertThrowsError(try AIPlan.parse(from: "{\"kind\": \"search\", \"summary\": \"x\"}"))
    }

    func testOrganizePlanRequiresOperations() {
        XCTAssertThrowsError(try AIPlan.parse(from: "{\"kind\": \"organize\", \"summary\": \"x\"}"))
        XCTAssertThrowsError(try AIPlan.parse(from: "{\"kind\": \"organize\", \"summary\": \"x\", \"operations\": []}"))
    }

    func testRejectsResponseWithoutJSONObject() {
        XCTAssertThrowsError(try AIPlan.parse(from: "I could not produce a plan for that request."))
        XCTAssertThrowsError(try AIPlan.parse(from: "{\"kind\": \"organize\", \"summary\": \"unterminated"))
    }

    func testRejectsInvalidDateInSearchCriteria() {
        let text = """
        {"kind": "search", "summary": "x", "search": {"modifiedAfter": "next week"}}
        """
        XCTAssertThrowsError(try AIPlan.parse(from: text)) { error in
            let message = (error as? AIPlanParseError)?.message ?? ""
            XCTAssertTrue(message.contains("next week"))
        }
    }
}
