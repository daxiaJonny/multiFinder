import Foundation
import XCTest
@testable import MultiFinder

final class FileBrowserViewModelTests: XCTestCase {
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
