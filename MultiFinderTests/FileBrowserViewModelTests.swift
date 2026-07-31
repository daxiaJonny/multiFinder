import Foundation
import XCTest
@testable import MultiFinder

final class FileBrowserViewModelTests: XCTestCase {
    private struct StubQuestionAnswerer: AIQuestionAnswering {
        let response: String

        func answer(_ request: AIAssistantRequest) async throws -> String {
            response
        }
    }

    private struct CancellationIgnoringQuestionAnswerer: AIQuestionAnswering {
        func answer(_ request: AIAssistantRequest) async throws -> String {
            let delay: Duration = request.question == "first" ? .milliseconds(10) : .milliseconds(200)
            try? await Task.sleep(for: delay)
            return "answer to \(request.question)"
        }
    }

    private struct CancellationIgnoringPlanner: AIPlanner {
        func plan(_ request: AIPlanRequest) async throws -> AIPlan {
            let delay: Duration = request.instruction == "first" ? .milliseconds(10) : .milliseconds(200)
            try? await Task.sleep(for: delay)
            return AIPlan(
                kind: .organize,
                summary: request.instruction,
                search: nil,
                operations: []
            )
        }
    }

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderBrowserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    @MainActor
    func testRapidNavigationCannotApplyAnOlderDirectoryResult() async throws {
        let first = temporaryDirectory.appendingPathComponent("first")
        let second = temporaryDirectory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<500 {
            _ = FileManager.default.createFile(
                atPath: first.appendingPathComponent("old-\(index)").path,
                contents: Data()
            )
        }
        try Data("new".utf8).write(to: second.appendingPathComponent("current.txt"))

        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        viewModel.navigate(to: first)
        viewModel.navigate(to: second)

        try await waitUntil { !viewModel.isLoading }
        XCTAssertEqual(viewModel.location, .directory(second.standardizedFileURL))
        XCTAssertEqual(viewModel.items.map(\.name), ["current.txt"])
    }

    @MainActor
    func testNavigationHistorySupportsBackAndForward() async throws {
        let first = temporaryDirectory.appendingPathComponent("first")
        let second = temporaryDirectory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        viewModel.navigate(to: first)
        viewModel.navigate(to: second)
        viewModel.goBack()
        XCTAssertEqual(viewModel.location, .directory(first.standardizedFileURL))
        viewModel.goForward()
        XCTAssertEqual(viewModel.location, .directory(second.standardizedFileURL))
    }

    @MainActor
    func testDirectoryMonitorRefreshesAfterExternalChange() async throws {
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }

        try Data("created elsewhere".utf8).write(to: temporaryDirectory.appendingPathComponent("external.txt"))

        try await waitUntil(timeout: 4) {
            viewModel.items.contains(where: { $0.name == "external.txt" })
        }
    }

    @MainActor
    func testRecentsIsNotRepresentedByDirectoryURL() {
        let viewModel = FileBrowserViewModel(location: .recents)

        XCTAssertNil(viewModel.currentURL)
        XCTAssertFalse(viewModel.canCreateItems)
        viewModel.newFolder()
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testChangingSortDuringLoadUsesLatestComparator() async throws {
        let directory = temporaryDirectory.appendingPathComponent("sorted")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 1...300 {
            try Data(repeating: 0, count: index).write(to: directory.appendingPathComponent("item-\(index)"))
        }

        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        viewModel.navigate(to: directory)
        viewModel.sortOrder = [FileItemComparator(field: .size, order: .reverse)]

        try await waitUntil { !viewModel.isLoading }
        XCTAssertEqual(viewModel.items.first?.size, 300)
        XCTAssertEqual(viewModel.items.last?.size, 1)
    }

    @MainActor
    func testFilterMatchesCaseAndDiacriticsAndLimitsSelectAll() async throws {
        try Data().write(to: temporaryDirectory.appendingPathComponent("Résumé.txt"))
        try Data().write(to: temporaryDirectory.appendingPathComponent("REPORT.log"))
        try Data().write(to: temporaryDirectory.appendingPathComponent("photo.png"))
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }

        viewModel.filterText = "resume"
        XCTAssertEqual(viewModel.visibleItems.map(\.name), ["Résumé.txt"])

        viewModel.selectAll()
        XCTAssertEqual(viewModel.selectedItemURLs, [
            temporaryDirectory.appendingPathComponent("Résumé.txt").standardizedFileURL
        ])

        viewModel.filterText = "report"
        XCTAssertEqual(viewModel.visibleItems.map(\.name), ["REPORT.log"])
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
    }

    @MainActor
    func testNavigationClearsFilter() async throws {
        let child = temporaryDirectory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }
        viewModel.filterText = "child"

        viewModel.navigate(to: child)

        XCTAssertEqual(viewModel.filterText, "")
    }

    @MainActor
    func testNewBrowserUsesHiddenFileSettingByDefault() async throws {
        let suiteName = "FileBrowserSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        settings.showHiddenFilesByDefault = true
        try Data().write(to: temporaryDirectory.appendingPathComponent(".visible-by-setting"))

        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            appSettings: settings
        )
        try await waitUntil { !viewModel.isLoading }

        XCTAssertTrue(viewModel.showHiddenFiles)
        XCTAssertTrue(viewModel.items.contains { $0.name == ".visible-by-setting" })
    }

    @MainActor
    func testChangingCursorCLIPathUpdatesExistingBrowserAvailability() throws {
        let suiteName = "FileBrowserCursorSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        settings.cursorCLIExecutablePath = temporaryDirectory.appendingPathComponent("missing-agent").path
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            appSettings: settings
        )
        XCTAssertFalse(viewModel.isAIAssistantAvailable)

        let executable = temporaryDirectory.appendingPathComponent("agent")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        settings.cursorCLIExecutablePath = " \(executable.path)\t"

        XCTAssertTrue(viewModel.isAIAssistantAvailable)
    }

    @MainActor
    func testCopySelectsAllCompletedDestinations() async throws {
        let sourceDirectory = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectory = temporaryDirectory.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let first = sourceDirectory.appendingPathComponent("first.txt")
        let second = sourceDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let viewModel = FileBrowserViewModel(
            location: .directory(destinationDirectory),
            operationService: FileOperationService()
        )
        try await waitUntil { !viewModel.isLoading }
        viewModel.filterText = "does-not-match"

        viewModel.copyItems(from: [first, second])

        let expected = Set([
            destinationDirectory.appendingPathComponent("first.txt").standardizedFileURL,
            destinationDirectory.appendingPathComponent("second.txt").standardizedFileURL
        ])
        try await waitUntil {
            !viewModel.isLoading && viewModel.selectedItems == expected
        }
        XCTAssertEqual(viewModel.filterText, "")
    }

    @MainActor
    func testFolderQuestionStoresNaturalLanguageExchange() async throws {
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            aiQuestionAnswerer: StubQuestionAnswerer(response: "There are two projects: api and web."),
            aiPlannerAvailable: true
        )

        viewModel.submitAIQuestion("How many projects are here?")

        try await waitUntil { !viewModel.isAIAnswering }
        XCTAssertEqual(viewModel.aiConversation.count, 1)
        XCTAssertEqual(viewModel.aiConversation.first?.question, "How many projects are here?")
        XCTAssertEqual(viewModel.aiConversation.first?.answer, "There are two projects: api and web.")
        XCTAssertNil(viewModel.aiAssistantErrorMessage)
    }

    @MainActor
    func testNavigatingAwayClearsFolderConversation() async throws {
        let child = temporaryDirectory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            aiQuestionAnswerer: StubQuestionAnswerer(response: "Answer"),
            aiPlannerAvailable: true
        )
        viewModel.submitAIQuestion("Question")
        try await waitUntil { !viewModel.isAIAnswering }

        viewModel.navigate(to: child)

        XCTAssertTrue(viewModel.aiConversation.isEmpty)
    }

    @MainActor
    func testCancelledQuestionCannotClearRestartedQuestionState() async throws {
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            aiQuestionAnswerer: CancellationIgnoringQuestionAnswerer(),
            aiPlannerAvailable: true
        )

        viewModel.submitAIQuestion("first")
        viewModel.cancelAIAnswering()
        viewModel.submitAIQuestion("second")

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(viewModel.isAIAnswering)
        XCTAssertEqual(viewModel.aiPendingQuestion, "second")

        try await waitUntil { !viewModel.isAIAnswering }
        XCTAssertEqual(viewModel.aiConversation.map(\.question), ["second"])
    }

    @MainActor
    func testCancelledPlanCannotClearRestartedPlanState() async throws {
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            aiPlanner: CancellationIgnoringPlanner(),
            aiPlannerAvailable: true
        )

        viewModel.submitAIOrganizeInstruction("first")
        viewModel.cancelAIPlanning()
        viewModel.submitAIOrganizeInstruction("second")

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(viewModel.isAIPlanning)
        XCTAssertNil(viewModel.aiPlanPreview)

        try await waitUntil { !viewModel.isAIPlanning }
        XCTAssertEqual(viewModel.aiPlanPreview?.plan.summary, "second")
    }

    @MainActor
    func testFolderDropMovesFolderIntoSiblingFolder() async throws {
        let source = temporaryDirectory.appendingPathComponent("Projects")
        let nestedFile = source.appendingPathComponent("notes.txt")
        let target = temporaryDirectory.appendingPathComponent("Archive")
        let destination = target.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: nestedFile)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = FileOperationService()
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            operationService: service
        )

        XCTAssertTrue(viewModel.transferDroppedItems([source], into: target, operation: .move))
        try await waitUntil { FileManager.default.fileExists(atPath: destination.path) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("notes.txt")), "notes")
        XCTAssertTrue(service.canUndo)
    }

    @MainActor
    func testOptionFolderDropCopiesItemAndKeepsSource() async throws {
        let source = temporaryDirectory.appendingPathComponent("report.txt")
        let target = temporaryDirectory.appendingPathComponent("Archive")
        let destination = target.appendingPathComponent(source.lastPathComponent)
        try Data("report".utf8).write(to: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            operationService: FileOperationService()
        )

        XCTAssertTrue(viewModel.transferDroppedItems([source], into: target, operation: .copy))
        try await waitUntil { FileManager.default.fileExists(atPath: destination.path) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination), "report")
    }

    @MainActor
    func testFolderDropRejectsItselfAndItsDescendant() throws {
        let source = temporaryDirectory.appendingPathComponent("Source")
        let child = source.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))

        XCTAssertFalse(viewModel.transferDroppedItems([source], into: source, operation: .move))
        XCTAssertFalse(viewModel.transferDroppedItems([source], into: child, operation: .move))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }

    @MainActor
    func testFolderDropRejectsProtectedDirectoryFromExecutionLayer() throws {
        let target = temporaryDirectory.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))

        XCTAssertFalse(
            viewModel.transferDroppedItems(
                [URL(fileURLWithPath: "/Applications", isDirectory: true)],
                into: target,
                operation: .move
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Applications").path))
    }

    @MainActor
    func testFolderDropRejectsEntireBatchWhenAnySourceIsProtected() throws {
        let source = temporaryDirectory.appendingPathComponent("notes.txt")
        let target = temporaryDirectory.appendingPathComponent("Archive")
        try Data("notes".utf8).write(to: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))

        XCTAssertFalse(
            viewModel.transferDroppedItems(
                [source, URL(fileURLWithPath: "/Applications", isDirectory: true)],
                into: target,
                operation: .move
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
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
