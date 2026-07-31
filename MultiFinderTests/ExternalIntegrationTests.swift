import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class ExternalIntegrationTests: XCTestCase {
    func testExternalOpenRequestRoundTripsEncodedPath() throws {
        let target = URL(fileURLWithPath: "/tmp/MultiFinder/A & B")
        let requestURL = try XCTUnwrap(ExternalOpenRequest.url(for: target))

        let request = try XCTUnwrap(ExternalOpenRequest(url: requestURL))

        XCTAssertEqual(request.targetURL, target.standardizedFileURL)
    }

    func testExternalOpenRequestRejectsOtherURLs() {
        XCTAssertNil(ExternalOpenRequest(url: URL(string: "https://example.com")!))
        XCTAssertNil(ExternalOpenRequest(url: URL(string: "multifinder://open")!))
    }

    func testTerminalChoicesHaveExpectedBundleIdentifiers() {
        XCTAssertEqual(PreferredTerminalApplication.terminal.bundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(PreferredTerminalApplication.iTerm2.bundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(PreferredTerminalApplication.warp.bundleIdentifier, "dev.warp.Warp-Stable")
    }

    func testTerminalLaunchArgumentsPreserveApplicationAndDirectoryPaths() {
        let applicationURL = URL(fileURLWithPath: "/Applications/Terminal With Spaces.app")
        let directoryURL = URL(fileURLWithPath: #"/tmp/A "Quoted"\Folder"#)

        let arguments = TerminalService.launchArguments(
            applicationURL: applicationURL,
            directoryURL: directoryURL
        )

        XCTAssertEqual(arguments, ["-a", applicationURL.path, directoryURL.path])
    }

    func testTerminalServiceReadsUpdatedSelectionWithoutRecreation() throws {
        let suiteName = "ExternalIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        let service = TerminalService(settings: settings)

        settings.preferredTerminalApplication = .terminal
        XCTAssertEqual(service.selectedApplication, .terminal)
        XCTAssertEqual(service.applicationName, L10n.string("Terminal"))

        settings.preferredTerminalApplication = .warp
        XCTAssertEqual(service.selectedApplication, .warp)
        XCTAssertEqual(service.applicationName, "Warp")
    }
}
