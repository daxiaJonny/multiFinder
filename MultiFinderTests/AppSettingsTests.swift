import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class AppSettingsTests: XCTestCase {
    func testUsesProductDefaultsWhenNothingWasPersisted() {
        let (defaults, suiteName) = makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)

        XCTAssertEqual(settings.preferredEditorApplication, .automatic)
        XCTAssertEqual(settings.customEditorApplicationPath, "")
        XCTAssertEqual(settings.preferredTerminalApplication, .terminal)
        XCTAssertFalse(settings.showHiddenFilesByDefault)
        XCTAssertEqual(settings.cursorCLIExecutablePath, AppSettings.defaultCursorCLIExecutablePath)
    }

    func testPersistsEverySetting() {
        let (defaults, suiteName) = makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        settings.preferredEditorApplication = .custom
        settings.customEditorApplicationPath = "/Applications/Example Editor.app"
        settings.preferredTerminalApplication = .warp
        settings.showHiddenFilesByDefault = true
        settings.cursorCLIExecutablePath = "/opt/local/bin/agent"

        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual(restored.preferredEditorApplication, .custom)
        XCTAssertEqual(restored.customEditorApplicationPath, "/Applications/Example Editor.app")
        XCTAssertEqual(restored.preferredTerminalApplication, .warp)
        XCTAssertTrue(restored.showHiddenFilesByDefault)
        XCTAssertEqual(restored.cursorCLIExecutablePath, "/opt/local/bin/agent")
    }

    func testUnknownApplicationValuesFallBackToDefaults() {
        let (defaults, suiteName) = makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("missing-editor", forKey: AppSettings.preferredEditorDefaultsKey)
        defaults.set("missing-terminal", forKey: AppSettings.preferredTerminalDefaultsKey)

        let settings = AppSettings(userDefaults: defaults)

        XCTAssertEqual(settings.preferredEditorApplication, .automatic)
        XCTAssertEqual(settings.preferredTerminalApplication, .terminal)
    }

    func testRestoreDefaultsUpdatesPersistedValues() {
        let (defaults, suiteName) = makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        settings.preferredEditorApplication = .visualStudioCode
        settings.preferredTerminalApplication = .iTerm2
        settings.showHiddenFilesByDefault = true
        settings.cursorCLIExecutablePath = "/tmp/custom-agent"

        settings.restoreDefaults()

        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual(restored.preferredEditorApplication, .automatic)
        XCTAssertEqual(restored.preferredTerminalApplication, .terminal)
        XCTAssertFalse(restored.showHiddenFilesByDefault)
        XCTAssertEqual(restored.cursorCLIExecutablePath, AppSettings.defaultCursorCLIExecutablePath)
    }

    func testCursorCLIPathResolutionTrimsWhitespaceAndUsesDefaultForBlankInput() {
        XCTAssertEqual(
            AppSettings.resolvedCursorCLIExecutableURL(from: "  /tmp/example-agent\n").path,
            "/tmp/example-agent"
        )
        XCTAssertEqual(
            AppSettings.resolvedCursorCLIExecutableURL(from: " \t\n").path,
            AppSettings.defaultCursorCLIExecutablePath
        )
    }

    private func makeUserDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
