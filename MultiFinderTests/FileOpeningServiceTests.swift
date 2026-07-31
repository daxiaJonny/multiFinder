import Foundation
import XCTest
@testable import MultiFinder

@MainActor
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

    func testConfiguredCustomEditorIsReadWithoutRecreatingService() throws {
        let suiteName = "FileOpeningServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        let service = FileOpeningService(settings: settings)
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Example Editor-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        settings.preferredEditorApplication = .custom
        settings.customEditorApplicationPath = applicationURL.path
        XCTAssertEqual(
            service.preferredTextEditorURL(for: URL(fileURLWithPath: "/tmp/notes.txt")),
            applicationURL.standardizedFileURL
        )

        settings.preferredEditorApplication = .systemDefault
        XCTAssertNil(service.preferredTextEditorURL(for: URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testConfiguredEditorOnlyOverridesTextFiles() throws {
        let suiteName = "FileOpeningServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Example Editor-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        settings.preferredEditorApplication = .custom
        settings.customEditorApplicationPath = applicationURL.path

        let service = FileOpeningService(settings: settings)

        XCTAssertNil(service.preferredTextEditorURL(for: URL(fileURLWithPath: "/tmp/photo.png")))
    }
}
