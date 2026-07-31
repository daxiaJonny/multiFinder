import AppKit
import XCTest
@testable import MultiFinder

@MainActor
final class FileClipboardTests: XCTestCase {
    @MainActor
    func testTextEditingCommandRouterRecognizesTextRespondersOnly() {
        XCTAssertTrue(TextEditingCommandRouter.isTextEditingResponder(NSTextView()))
        XCTAssertFalse(TextEditingCommandRouter.isTextEditingResponder(NSTextField()))
        XCTAssertFalse(TextEditingCommandRouter.isTextEditingResponder(NSView()))
        XCTAssertFalse(TextEditingCommandRouter.isTextEditingResponder(nil))
    }

    func testTextEditingUndoAndRedoAreConsumedWithoutAvailableEdits() {
        let textView = NSTextView()

        XCTAssertTrue(TextEditingCommandRouter.performUndo(on: textView))
        XCTAssertTrue(TextEditingCommandRouter.performRedo(on: textView))
        XCTAssertFalse(TextEditingCommandRouter.performUndo(on: NSTextField()))
        XCTAssertFalse(TextEditingCommandRouter.performRedo(on: NSView()))
    }

    private var pasteboard: NSPasteboard!
    private var clipboard: FileClipboard!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: .init("MultiFinderTests.\(UUID().uuidString)"))
        clipboard = FileClipboard(pasteboard: pasteboard, startPolling: false)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderClipboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: temporaryDirectory)
        pasteboard = nil
        clipboard = nil
        temporaryDirectory = nil
    }

    func testCutPayloadContainsOnlyFileURLs() throws {
        let fileURL = try makeFile("example.txt")
        clipboard.cut(urls: [fileURL])

        let payload = try XCTUnwrap(clipboard.payload)
        XCTAssertEqual(payload.urls, [fileURL.standardizedFileURL])
        XCTAssertTrue(payload.isCut)
    }

    func testOldOperationCannotConsumeNewClipboardContents() throws {
        clipboard.cut(urls: [try makeFile("old.txt")])
        let oldPayload = try XCTUnwrap(clipboard.payload)

        pasteboard.clearContents()
        pasteboard.setString("new clipboard value", forType: .string)

        XCTAssertFalse(clipboard.consumeIfUnchanged(oldPayload))
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard value")
    }

    func testPartialConsumptionKeepsRemainingCutURLs() throws {
        let first = try makeFile("first.txt")
        let second = try makeFile("second.txt")
        clipboard.cut(urls: [first, second])
        let payload = try XCTUnwrap(clipboard.payload)

        XCTAssertTrue(clipboard.consumeIfUnchanged(payload, remainingURLs: [second]))
        let remaining = try XCTUnwrap(clipboard.payload)
        XCTAssertEqual(remaining.urls, [second.standardizedFileURL])
        XCTAssertTrue(remaining.isCut)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
}
