import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import MultiFinder

@MainActor
final class FileTableRangeSelectionTests: XCTestCase, NSTableViewDataSource {
    private struct Row: Identifiable {
        let id: URL
    }

    private final class SelectionFixture: ObservableObject {
        let rows = (0..<8).map { Row(id: URL(fileURLWithPath: "/selection-test/\($0)")) }
        @Published var selection: Set<URL> = []
    }

    private struct HostedRows: View {
        @ObservedObject var fixture: SelectionFixture
        let isColumn: Bool

        var body: some View {
            Group {
                if isColumn {
                    List(selection: $fixture.selection) {
                        ForEach(fixture.rows) { row in
                            Text(row.id.lastPathComponent)
                                .tag(row.id)
                                .onDrag { NSItemProvider(object: row.id as NSURL) }
                        }
                    }
                } else {
                    Table(of: Row.self, selection: $fixture.selection) {
                        TableColumn("Name") { row in Text(row.id.lastPathComponent) }
                    } rows: {
                        ForEach(fixture.rows) { row in
                            TableRow(row).itemProvider { NSItemProvider(object: row.id as NSURL) }
                        }
                    }
                }
            }
            .overlay {
                FileTableRangeSelectionMonitor(itemIDs: fixture.rows.map(\.id), selection: $fixture.selection)
                    .allowsHitTesting(false)
            }
        }
    }

    func testHostedSwiftUITableRoutesShiftClicksThroughMonitor() async throws {
        try await verifyHostedRange(isColumn: false)
    }

    func testHostedSwiftUIListRoutesShiftClicksThroughMonitor() async throws {
        try await verifyHostedRange(isColumn: true)
    }

    private func verifyHostedRange(isColumn: Bool) async throws {
        let fixture = SelectionFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: HostedRows(fixture: fixture, isColumn: isColumn))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let table = try XCTUnwrap(findTable(window.contentView!))
        XCTAssertEqual(table.numberOfRows, 8)
        for row in [6, 0] {
            let down = click(row, in: table, flags: .shift)
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp, location: down.locationInWindow,
                modifierFlags: .shift, timestamp: down.timestamp + 0.1,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0
            ))
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(fixture.selection, Set(fixture.rows[0...6].map(\.id)))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0...6))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 8 }

    private func withTable(
        _ body: (FileTableRangeSelectionMonitor.Coordinator, NSTableView, NSWindow) throws -> Void
    ) rethrows {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let table = NSTableView(frame: scroll.bounds)
        table.headerView = nil
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name")))
        table.dataSource = self
        scroll.documentView = table
        window.contentView!.addSubview(scroll)
        table.reloadData()
        window.contentView!.layoutSubtreeIfNeeded()
        let coordinator = FileTableRangeSelectionMonitor.Coordinator()
        coordinator.anchorView = scroll
        coordinator.itemIDs = (0..<8).map { URL(fileURLWithPath: "/selection-test/\($0)") }
        try body(coordinator, table, window)
    }

    private func click(_ row: Int, in table: NSTableView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let rect = table.rect(ofRow: row)
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: table.convert(NSPoint(x: 30, y: rect.midY), to: nil),
            modifierFlags: flags, timestamp: 1, windowNumber: table.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    func testBottomToTopShiftClickSelectsEveryRowAndConsumesEvent() {
        withTable { coordinator, table, _ in
            XCTAssertNotNil(coordinator.handle(click(6, in: table)))
            coordinator.selection = [coordinator.itemIDs[6]]
            var published: Set<URL> = []
            coordinator.onSelection = { published = $0 }
            XCTAssertNil(coordinator.handle(click(0, in: table, flags: .shift)))
            XCTAssertEqual(published, Set(coordinator.itemIDs[0...6]))
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0...6))
        }
    }

    func testShiftRangeKeepsOriginalAnchorWhenShrinking() {
        withTable { coordinator, table, _ in
            _ = coordinator.handle(click(1, in: table))
            coordinator.selection = [coordinator.itemIDs[1]]
            XCTAssertNil(coordinator.handle(click(7, in: table, flags: .shift)))
            XCTAssertNil(coordinator.handle(click(3, in: table, flags: .shift)))
            XCTAssertEqual(coordinator.selection, Set(coordinator.itemIDs[1...3]))
        }
    }

    func testTwoShiftClicksWithoutPriorSelectionSetThenExtendAnchor() {
        withTable { coordinator, table, _ in
            XCTAssertNil(coordinator.handle(click(7, in: table, flags: .shift)))
            XCTAssertEqual(coordinator.selection, [coordinator.itemIDs[7]])
            XCTAssertNil(coordinator.handle(click(0, in: table, flags: .shift)))
            XCTAssertEqual(coordinator.selection, Set(coordinator.itemIDs))
        }
    }

    func testCommandShiftPreservesOtherSelectedRows() {
        withTable { coordinator, table, _ in
            _ = coordinator.handle(click(4, in: table, flags: .command))
            coordinator.selection = [coordinator.itemIDs[0], coordinator.itemIDs[4]]
            XCTAssertNil(coordinator.handle(click(6, in: table, flags: [.command, .shift])))
            XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 4, 5, 6]))
        }
    }
}

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
    func testSetSortUsesRequestedFieldAndDirection() async throws {
        try Data(repeating: 0, count: 1).write(
            to: temporaryDirectory.appendingPathComponent("small.txt")
        )
        try Data(repeating: 0, count: 10).write(
            to: temporaryDirectory.appendingPathComponent("large.txt")
        )
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 2 }

        viewModel.setSort(by: .size, ascending: false)

        XCTAssertEqual(viewModel.sortField, .size)
        XCTAssertFalse(viewModel.sortAscending)
        XCTAssertEqual(viewModel.items.map(\.name), ["large.txt", "small.txt"])
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
    func testInfoPresentationRequiresSelectionAndClosesOnNavigation() async throws {
        let file = temporaryDirectory.appendingPathComponent("notes.txt")
        let child = temporaryDirectory.appendingPathComponent("child", isDirectory: true)
        try Data().write(to: file)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }

        viewModel.presentInfo()
        XCTAssertFalse(viewModel.isInfoPresented)

        viewModel.selectedItems = [file.standardizedFileURL]
        viewModel.presentInfo()
        XCTAssertTrue(viewModel.isInfoPresented)

        viewModel.navigate(to: child)
        XCTAssertFalse(viewModel.isInfoPresented)
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
    func testNavigateToMissingFileKeepsCurrentLocationAndHistory() async throws {
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }
        let missingFile = temporaryDirectory.appendingPathComponent("missing.txt")

        viewModel.navigateToFile(missingFile)

        XCTAssertEqual(viewModel.location, .directory(temporaryDirectory.standardizedFileURL))
        XCTAssertTrue(viewModel.backHistory.isEmpty)
        XCTAssertTrue(viewModel.forwardHistory.isEmpty)
        XCTAssertEqual(
            viewModel.errorMessage,
            L10n.format("“%@” does not exist.", "missing.txt")
        )
        XCTAssertTrue(viewModel.selectedItems.isEmpty)
    }

    @MainActor
    func testNavigateToFileAcceptsAnExistingDirectory() async throws {
        let child = temporaryDirectory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }

        viewModel.navigateToFile(child)

        try await waitUntil { !viewModel.isLoading }
        XCTAssertEqual(viewModel.location, .directory(child.standardizedFileURL))
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRevealFilesSelectsAllFilesAndClearsCurrentFilter() async throws {
        let first = temporaryDirectory.appendingPathComponent("first.txt")
        let second = temporaryDirectory.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }
        viewModel.filterText = "does-not-match"

        XCTAssertTrue(viewModel.revealFiles([first, second]))
        let expected = Set([first.standardizedFileURL, second.standardizedFileURL])
        try await waitUntil {
            !viewModel.isLoading
                && viewModel.filterText.isEmpty
                && viewModel.selectedItems == expected
        }
        XCTAssertEqual(viewModel.visibleItems.map(\.url), [first.standardizedFileURL, second.standardizedFileURL])
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
    func testDuplicateSelectedCreatesUniqueCopyAndSelectsIt() async throws {
        let source = temporaryDirectory.appendingPathComponent("notes.txt").standardizedFileURL
        try Data("notes".utf8).write(to: source)
        let existingCopy = FileOperationService.uniqueDestination(
            for: source,
            in: temporaryDirectory
        )
        try Data("existing".utf8).write(to: existingCopy)
        let expectedCopy = FileOperationService.uniqueDestination(
            for: source,
            in: temporaryDirectory
        ).standardizedFileURL
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            operationService: FileOperationService()
        )
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 2 }
        viewModel.selectedItems = [source]

        viewModel.duplicateSelected()

        try await waitUntil {
            !viewModel.isLoading && viewModel.selectedItems == [expectedCopy]
        }
        XCTAssertEqual(try String(contentsOf: source), "notes")
        XCTAssertEqual(try String(contentsOf: existingCopy), "existing")
        XCTAssertEqual(try String(contentsOf: expectedCopy), "notes")
    }

    @MainActor
    func testRenameKeepsPublishedSelectionValidAndRebuildsTable() async throws {
        let source = temporaryDirectory.appendingPathComponent("draft.txt").standardizedFileURL
        let destination = temporaryDirectory.appendingPathComponent("final.txt").standardizedFileURL
        try Data("draft".utf8).write(to: source)
        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            operationService: FileOperationService()
        )
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 1 }
        viewModel.selectedItems = [source]
        let initialRevision = viewModel.tableRevision
        var publishedInvalidSelection = false
        let cancellable = viewModel.$items.dropFirst().sink { updatedItems in
            let updatedIDs = Set(updatedItems.map(\.id))
            if !viewModel.selectedItems.isSubset(of: updatedIDs) {
                publishedInvalidSelection = true
            }
        }

        viewModel.rename(item: try XCTUnwrap(viewModel.selectedItem), to: destination.lastPathComponent)

        try await waitUntil {
            !viewModel.isLoading
                && viewModel.items.map(\.id) == [destination]
                && viewModel.selectedItems == [destination]
        }
        withExtendedLifetime(cancellable) {}
        XCTAssertFalse(publishedInvalidSelection)
        XCTAssertGreaterThan(viewModel.tableRevision, initialRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testExternalRowIdentityChangesRebuildTable() async throws {
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading }
        let initialRevision = viewModel.tableRevision
        let addedFile = temporaryDirectory.appendingPathComponent("added.txt")
        try Data().write(to: addedFile)

        viewModel.refresh()

        try await waitUntil {
            !viewModel.isLoading && viewModel.items.map(\.name) == ["added.txt"]
        }
        XCTAssertGreaterThan(viewModel.tableRevision, initialRevision)
        let revisionAfterAddition = viewModel.tableRevision
        try FileManager.default.removeItem(at: addedFile)

        viewModel.refresh()

        try await waitUntil { !viewModel.isLoading && viewModel.items.isEmpty }
        XCTAssertGreaterThan(viewModel.tableRevision, revisionAfterAddition)
    }

    @MainActor
    func testMetadataChangeRebuildsVisibleRows() async throws {
        let file = temporaryDirectory.appendingPathComponent("changing.txt")
        try Data("a".utf8).write(to: file)
        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading && viewModel.items.first?.size == 1 }
        let initialRevision = viewModel.tableRevision

        try Data("updated contents".utf8).write(to: file)
        viewModel.refresh()

        try await waitUntil {
            !viewModel.isLoading && viewModel.items.first?.size == 16
        }
        XCTAssertGreaterThan(viewModel.tableRevision, initialRevision)
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
    func testPasteDestinationUsesTheRightClickedFolderOrCurrentDirectory() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.txt")
        let folder = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 2 }

        XCTAssertEqual(viewModel.pasteDestination(for: [folder]), folder.standardizedFileURL)
        XCTAssertEqual(viewModel.pasteDestination(for: [source]), temporaryDirectory.standardizedFileURL)
        XCTAssertEqual(viewModel.pasteDestination(for: []), temporaryDirectory.standardizedFileURL)
    }

    @MainActor
    func testCopyItemsCanPasteIntoTheRequestedFolder() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.txt")
        let folder = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        let pasted = folder.appendingPathComponent(source.lastPathComponent)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let viewModel = FileBrowserViewModel(
            location: .directory(temporaryDirectory),
            operationService: FileOperationService()
        )
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 2 }

        viewModel.copyItems(from: [source], to: folder)

        try await waitUntil { FileManager.default.fileExists(atPath: pasted.path) }
        XCTAssertEqual(try String(contentsOf: pasted), "source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testPasteDestinationRejectsReadOnlyAndNonDirectoryTargets() async throws {
        let readOnlyFolder = temporaryDirectory.appendingPathComponent("ReadOnly", isDirectory: true)
        let file = temporaryDirectory.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: false)
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: readOnlyFolder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: readOnlyFolder.path
            )
        }

        let viewModel = FileBrowserViewModel(location: .directory(temporaryDirectory))
        try await waitUntil { !viewModel.isLoading && viewModel.items.count == 2 }

        XCTAssertFalse(FileBrowserViewModel.isWritableOrdinaryDirectory(readOnlyFolder))
        XCTAssertNil(viewModel.pasteDestination(for: [readOnlyFolder]))
        XCTAssertEqual(viewModel.pasteDestination(for: [file]), temporaryDirectory.standardizedFileURL)
    }

    func testDropOperationUsesMoveOnTheSameVolumeAndCopyForOption() throws {
        let source = temporaryDirectory.appendingPathComponent("source.txt")
        let destination = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try Data().write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertEqual(
            FileBrowserViewModel.dropOperation(
                for: [source],
                into: destination,
                optionPressed: false
            ),
            .move
        )
        XCTAssertEqual(
            FileBrowserViewModel.dropOperation(
                for: [source],
                into: destination,
                optionPressed: true
            ),
            .copy
        )
    }

    func testDropOperationFallsBackToCopyWhenAVolumeCannotBeResolved() {
        let source = temporaryDirectory.appendingPathComponent("missing-source")
        let destination = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)

        XCTAssertEqual(
            FileBrowserViewModel.dropOperation(
                for: [source],
                into: destination,
                optionPressed: false
            ),
            .copy
        )
    }

    func testVisibleItemsAppliesNameFilterAndGitRestrictionTogether() {
        let changed = FileItem(url: URL(fileURLWithPath: "/tmp/changed.txt"))
        let other = FileItem(url: URL(fileURLWithPath: "/tmp/other.txt"))
        let alsoChanged = FileItem(url: URL(fileURLWithPath: "/tmp/changed-notes.md"))

        XCTAssertEqual(
            FileBrowserViewModel.visibleItems(
                in: [other, changed, alsoChanged],
                filterText: "",
                restrictingTo: [changed.id, alsoChanged.id]
            ).map(\.name),
            ["changed.txt", "changed-notes.md"]
        )
        XCTAssertEqual(
            FileBrowserViewModel.visibleItems(
                in: [other, changed, alsoChanged],
                filterText: "notes",
                restrictingTo: [changed.id, alsoChanged.id]
            ).map(\.name),
            ["changed-notes.md"]
        )
    }

    func testMultiFileDragPayloadRoundTripsAllFileURLs() throws {
        let urls = [
            temporaryDirectory.appendingPathComponent("first.txt"),
            temporaryDirectory.appendingPathComponent("second folder", isDirectory: true)
        ]
        let data = try XCTUnwrap(DroppedFileURL.batchData(for: urls))

        XCTAssertEqual(
            DroppedFileURL.urls(fromBatchData: data),
            urls.map(\.standardizedFileURL)
        )
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
