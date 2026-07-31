import Foundation
import XCTest
@testable import MultiFinder

final class FileOpeningServiceTests: XCTestCase {
    func testPlainTextAndLogFilesPreferSublimeText() {
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/server.LOG")))
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/README.md")))
    }

    func testSourceAndConfigurationFilesPreferSublimeText() {
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/main.swift")))
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/settings.yaml")))
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/.gitignore")))
        XCTAssertTrue(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/Makefile")))
    }

    func testBinaryAndArchiveFilesKeepTheirSystemDefaultApplication() {
        XCTAssertFalse(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/photo.png")))
        XCTAssertFalse(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/document.pdf")))
        XCTAssertFalse(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertFalse(FileOpeningService.prefersSublimeText(for: URL(fileURLWithPath: "/tmp/.DS_Store")))
    }
}
