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
