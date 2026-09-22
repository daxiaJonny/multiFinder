import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class ExternalIntegrationTests: XCTestCase {
    func testNewTabRequestRoundTripsAndDoesNotDeduplicateOrdinaryOpen() throws {
        let target = URL(fileURLWithPath: "/tmp/A & B/#notes.txt")
        let url = try XCTUnwrap(ExternalOpenRequest.url(for: target, opensInNewTab: true))
        XCTAssertEqual(ExternalOpenRequest(url: url)?.opensInNewTab, true)
        XCTAssertEqual(ExternalOpenRequest(url: url)?.targetURL, target)
        let router = ExternalOpenRouter()
        var modes: [Bool] = []
        router.register { modes.append($0.opensInNewTab) }
        XCTAssertEqual(router.receive(urls: [target, url]), 2)
        XCTAssertEqual(router.receive(urls: [url], source: .swiftUI), 0)
        XCTAssertEqual(modes, [false, true])
    }

    func testNewTabRequestRejectsMalformedOptions() throws {
        for query in ["newTab=maybe", "newTab", "newTab=true&newTab=false"] {
            let url = try XCTUnwrap(URL(string: "multifinder://open?path=/tmp&\(query)"))
            XCTAssertNil(ExternalOpenRequest(url: url))
        }
    }

    func testExternalNewTabKeepsExistingTabAndRevealsFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.txt")
        try Data().write(to: file)
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        let original = pane.selectedTab
        original.navigate(to: directory)
        original.viewMode = .gallery
        original.filterText = "original filter"
        let paneCount = manager.totalPaneCount
        let tabCount = pane.tabs.count

        XCTAssertTrue(manager.openExternalPaths([file], inNewTab: true))
        let opened = pane.selectedTab
        try await waitUntil { !opened.isLoading }
        XCTAssertEqual(pane.tabs.count, tabCount + 1)
        XCTAssertEqual(manager.totalPaneCount, paneCount)
        XCTAssertFalse(opened === original)
        XCTAssertEqual(original.filterText, "original filter")
        XCTAssertEqual(opened.viewMode, .gallery)
        XCTAssertEqual(opened.currentURL, directory.standardizedFileURL)
        XCTAssertEqual(opened.selectedItems, [file.standardizedFileURL])

        XCTAssertTrue(manager.openExternalPaths([directory], inNewTab: true))
        XCTAssertEqual(pane.tabs.count, tabCount + 2)
        XCTAssertFalse(manager.openExternalPaths([directory.appendingPathComponent("missing")], inNewTab: true))
        XCTAssertEqual(pane.tabs.count, tabCount + 2)
    }

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

    func testExternalOpenRequestNormalizesFileURLsAndMultifinderPaths() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/MultiFinder/../MultiFinder/report.txt")
        let fileRequest = try XCTUnwrap(ExternalOpenRequest(url: fileURL))
        XCTAssertEqual(fileRequest.targetURL.path, "/tmp/MultiFinder/report.txt")

        let customURL = try XCTUnwrap(ExternalOpenRequest.url(for: fileURL))
        let customRequest = try XCTUnwrap(ExternalOpenRequest(url: customURL))
        XCTAssertEqual(customRequest.targetURL, fileRequest.targetURL)
    }

    func testExternalOpenRequestRejectsRelativePathsAndRemoteFileHosts() throws {
        let relativePath = try XCTUnwrap(URL(string: "multifinder://open?path=relative/report.txt"))
        XCTAssertNil(ExternalOpenRequest(url: relativePath))

        let remoteFile = try XCTUnwrap(URL(string: "file://server/share/report.txt"))
        XCTAssertNil(ExternalOpenRequest(url: remoteFile))
        XCTAssertNil(ExternalOpenRequest.url(for: remoteFile))

        let localHostFile = try XCTUnwrap(URL(string: "file://localhost/tmp/report.txt"))
        XCTAssertEqual(
            ExternalOpenRequest(url: localHostFile)?.targetURL,
            URL(fileURLWithPath: "/tmp/report.txt")
        )
    }

    func testExternalOpenRouterQueuesAndDrainsMultipleURLsInOrder() {
        let router = ExternalOpenRouter()
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        var delivered: [URL] = []

        XCTAssertEqual(router.receive(urls: [first, second]), 2)
        XCTAssertEqual(router.pendingRequestCount, 2)

        router.register(workspaceID: UUID()) { request in
            delivered.append(request.targetURL)
        }

        XCTAssertEqual(delivered, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(router.pendingRequestCount, 0)
        XCTAssertEqual(router.drainPendingRequests(), 0)
        XCTAssertEqual(delivered.count, 2)
    }

    func testExternalOpenRouterPreservesBatchEventForBatchWorkspace() {
        let router = ExternalOpenRouter()
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        var deliveredEvents: [[URL]] = []

        router.registerBatch(workspaceID: UUID()) { requests in
            deliveredEvents.append(requests.map(\.targetURL))
        }

        XCTAssertEqual(router.receive(urls: [first, second]), 2)
        XCTAssertEqual(deliveredEvents, [[first.standardizedFileURL, second.standardizedFileURL]])
        XCTAssertEqual(router.pendingRequestCount, 0)
    }

    func testExternalOpenRouterKeepsPendingEventBatchUntilWorkspaceRegisters() {
        let router = ExternalOpenRouter()
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        var deliveredEvents: [[URL]] = []

        XCTAssertEqual(router.receive(urls: [first, second]), 2)
        XCTAssertEqual(router.pendingRequestCount, 2)

        router.registerBatch(workspaceID: UUID()) { requests in
            deliveredEvents.append(requests.map(\.targetURL))
        }

        XCTAssertEqual(deliveredEvents, [[first.standardizedFileURL, second.standardizedFileURL]])
        XCTAssertEqual(router.pendingRequestCount, 0)
    }

    func testExternalOpenBatchSelectsAllFilesInOneParent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderExternalOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)

        let manager = LayoutManager()
        let pane = manager.rows[0].panes[0]
        pane.selectedTab.navigate(to: directory)
        try await waitUntil { !pane.selectedTab.isLoading }
        pane.selectedTab.filterText = "does-not-match"

        XCTAssertTrue(manager.openExternalPaths([first, second]))
        try await waitUntil {
            !pane.selectedTab.isLoading
                && pane.selectedTab.filterText.isEmpty
                && pane.selectedTab.selectedItems == Set([first.standardizedFileURL, second.standardizedFileURL])
        }
    }

    func testExternalOpenRouterSuppressesDuplicateDeliveryAcrossEventSources() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let router = ExternalOpenRouter(
            duplicateDeliveryWindow: 10,
            now: { currentTime }
        )
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        var delivered: [URL] = []
        router.register(workspaceID: UUID()) { request in
            delivered.append(request.targetURL)
        }

        XCTAssertEqual(router.receive(urls: [first, second], source: .appKit), 2)
        XCTAssertEqual(router.receive(urls: [first, second], source: .swiftUI), 0)
        XCTAssertEqual(delivered, [first.standardizedFileURL, second.standardizedFileURL])

        currentTime = currentTime.addingTimeInterval(11)
        XCTAssertEqual(router.receive(urls: [first], source: .swiftUI), 1)
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered.last, first.standardizedFileURL)
    }

    func testExternalOpenRouterDeduplicatesWithinAndAcrossOverlappingEvents() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let router = ExternalOpenRouter(
            duplicateDeliveryWindow: 10,
            now: { currentTime }
        )
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        let third = URL(fileURLWithPath: "/tmp/MultiFinder/third.txt")
        var delivered: [URL] = []
        router.register(workspaceID: UUID()) { request in
            delivered.append(request.targetURL)
        }

        XCTAssertEqual(router.receive(urls: [first, first, second], source: .appKit), 2)
        XCTAssertEqual(router.receive(urls: [second, third], source: .swiftUI), 1)
        XCTAssertEqual(delivered, [first.standardizedFileURL, second.standardizedFileURL, third.standardizedFileURL])

        currentTime = currentTime.addingTimeInterval(11)
        XCTAssertEqual(router.receive(urls: [first], source: .appKit), 1)
        XCTAssertEqual(delivered.last, first.standardizedFileURL)
    }

    func testExternalOpenRouterRequestsOneWorkspaceWhenAllWindowsAreClosed() {
        let router = ExternalOpenRouter()
        let first = URL(fileURLWithPath: "/tmp/MultiFinder/first.txt")
        let second = URL(fileURLWithPath: "/tmp/MultiFinder/second.txt")
        var workspaceOpenRequests = 0
        var delivered: [URL] = []

        router.setWorkspaceOpenAction {
            workspaceOpenRequests += 1
        }

        XCTAssertEqual(router.receive(urls: [first]), 1)
        XCTAssertEqual(router.receive(urls: [second], source: .swiftUI), 1)
        XCTAssertEqual(workspaceOpenRequests, 1)
        XCTAssertEqual(router.pendingRequestCount, 2)

        router.register(workspaceID: UUID()) { request in
            delivered.append(request.targetURL)
        }

        XCTAssertEqual(delivered, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(router.pendingRequestCount, 0)
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

    func testTerminalServiceOpenInITermPreferredLaunchesExpectedApplication() throws {
        var launchedArgs: [String]?
        let service = TerminalService(processRunner: { args in
            launchedArgs = args
        })

        let tempDir = FileManager.default.temporaryDirectory
        try service.openInITermPreferred(tempDir)
        XCTAssertNotNil(launchedArgs)
        if service.isITermAvailable {
            XCTAssertTrue(launchedArgs?.contains(where: { $0.contains("iTerm") }) == true)
        } else {
            XCTAssertTrue(launchedArgs?.contains(where: { $0.contains("Terminal") }) == true)
        }
    }

    func testTerminalServiceOpenDirectoryWithExplicitApplication() throws {
        var launchedArgs: [String]?
        let service = TerminalService(processRunner: { args in
            launchedArgs = args
        })

        let tempDir = FileManager.default.temporaryDirectory
        if service.applicationURL(for: .terminal) != nil {
            try service.openDirectory(tempDir, application: .terminal)
            XCTAssertNotNil(launchedArgs)
            XCTAssertTrue(launchedArgs?.contains(where: { $0.contains("Terminal") }) == true)
        }
    }

    @MainActor
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
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
