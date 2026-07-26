import Foundation
import XCTest
@testable import MultiFinder

final class BatchRenameEngineTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/BatchRenameEngineTests/\(name)")
    }

    func testFindReplaceRespectsCaseSensitivityToggle() {
        let sensitive = BatchRenameMode.findReplace(find: "IMG", replace: "photo", useRegex: false, caseSensitive: true)
        XCTAssertEqual(BatchRenameEngine.newName(for: "img_001.jpg", index: 0, mode: sensitive), "img_001.jpg")

        let insensitive = BatchRenameMode.findReplace(find: "IMG", replace: "photo", useRegex: false, caseSensitive: false)
        XCTAssertEqual(BatchRenameEngine.newName(for: "img_001.jpg", index: 0, mode: insensitive), "photo_001.jpg")
    }

    func testFindReplaceRegexUsesTemplateCaptures() {
        let mode = BatchRenameMode.findReplace(find: "IMG_(\\d+)", replace: "photo-$1", useRegex: true, caseSensitive: true)
        XCTAssertEqual(BatchRenameEngine.newName(for: "IMG_0042.jpg", index: 0, mode: mode), "photo-0042.jpg")
    }

    func testInvalidRegexKeepsNamesAndReportsConfigurationIssue() {
        let mode = BatchRenameMode.findReplace(find: "[unclosed", replace: "x", useRegex: true, caseSensitive: true)
        XCTAssertEqual(BatchRenameEngine.newName(for: "IMG_0042.jpg", index: 0, mode: mode), "IMG_0042.jpg")
        XCTAssertNotNil(BatchRenameEngine.configurationIssue(for: mode))
    }

    func testAddTextInsertsSuffixBeforeExtension() {
        let mode = BatchRenameMode.addText(prefix: "a-", suffix: "-b")
        XCTAssertEqual(BatchRenameEngine.newName(for: "notes.txt", index: 0, mode: mode), "a-notes-b.txt")
        XCTAssertEqual(BatchRenameEngine.newName(for: "README", index: 0, mode: mode), "a-README-b")
    }

    func testSequenceAppliesStartPaddingAndExtension() {
        let mode = BatchRenameMode.sequence(format: "trip-{n}", start: 5, padding: 3)
        XCTAssertEqual(BatchRenameEngine.newName(for: "a.jpg", index: 0, mode: mode), "trip-005.jpg")
        XCTAssertEqual(BatchRenameEngine.newName(for: "b.jpg", index: 1, mode: mode), "trip-006.jpg")

        let noToken = BatchRenameMode.sequence(format: "trip", start: 1, padding: 1)
        XCTAssertEqual(BatchRenameEngine.newName(for: "a.jpg", index: 0, mode: noToken), "trip1.jpg")
    }

    func testPreviewFlagsSameTargetForTwoItems() {
        let rows = BatchRenameEngine.preview(
            urls: [url("draft-a.txt"), url("draft-b.txt")],
            mode: .findReplace(find: "-[ab]", replace: "", useRegex: true, caseSensitive: true),
            existingNames: ["draft-a.txt", "draft-b.txt"]
        )
        XCTAssertEqual(rows.map(\.newName), ["draft.txt", "draft.txt"])
        XCTAssertNotNil(rows[0].issue)
        XCTAssertNotNil(rows[1].issue)
        XCTAssertFalse(BatchRenameEngine.canApply(rows, mode: .findReplace(find: "-[ab]", replace: "", useRegex: true, caseSensitive: true)))
    }

    func testPreviewFlagsTargetThatAlreadyExistsOnDisk() {
        let rows = BatchRenameEngine.preview(
            urls: [url("old.txt")],
            mode: .findReplace(find: "old", replace: "existing", useRegex: false, caseSensitive: true),
            existingNames: ["old.txt", "existing.txt"]
        )
        XCTAssertEqual(rows[0].newName, "existing.txt")
        XCTAssertNotNil(rows[0].issue)
    }

    func testPreviewAllowsCaseOnlyRename() {
        let rows = BatchRenameEngine.preview(
            urls: [url("file.txt")],
            mode: .findReplace(find: "file", replace: "File", useRegex: false, caseSensitive: true),
            existingNames: ["file.txt"]
        )
        XCTAssertEqual(rows[0].newName, "File.txt")
        XCTAssertNil(rows[0].issue)
        XCTAssertTrue(rows[0].isRenamed)
    }

    func testPreviewRejectsIllegalGeneratedNames() {
        let rows = BatchRenameEngine.preview(
            urls: [url("clip.mov")],
            mode: .findReplace(find: "clip", replace: "a/b", useRegex: false, caseSensitive: true),
            existingNames: ["clip.mov"]
        )
        XCTAssertNotNil(rows[0].issue)
    }

    func testNoOpRowsAreValidButNotApplicableAlone() {
        let mode = BatchRenameMode.findReplace(find: "missing", replace: "x", useRegex: false, caseSensitive: true)
        let rows = BatchRenameEngine.preview(
            urls: [url("a.txt"), url("b.txt")],
            mode: mode,
            existingNames: ["a.txt", "b.txt"]
        )
        XCTAssertTrue(rows.allSatisfy(\.isNoOp))
        XCTAssertTrue(rows.allSatisfy { $0.issue == nil })
        XCTAssertFalse(BatchRenameEngine.canApply(rows, mode: mode))
    }
}
