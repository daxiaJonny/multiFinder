import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class LayoutManagerTests: XCTestCase {
    func testWorkspaceRoundTripPreservesSpecialLocationAndPaneSettings() throws {
        let manager = LayoutManager()
        guard let pane = manager.focusedPane else {
            return XCTFail("Expected a focused pane")
        }

        pane.loadRecents()
        pane.sortOrder = [FileItemComparator(field: .date, order: .reverse)]
        pane.showHiddenFiles = true
        manager.save()

        let encoded = manager.serializedState
        let restored = LayoutManager(serializedState: encoded)
        guard let restoredPane = restored.focusedPane else {
            return XCTFail("Expected a restored pane")
        }

        XCTAssertEqual(restoredPane.location, .recents)
        XCTAssertNil(restoredPane.currentURL)
        XCTAssertEqual(restoredPane.sortField, .date)
        XCTAssertFalse(restoredPane.sortAscending)
        XCTAssertTrue(restoredPane.showHiddenFiles)
        XCTAssertFalse(restoredPane.backHistory.isEmpty)
    }

    func testCodableLayoutStateRoundTrip() throws {
        let state = LayoutState(
            version: LayoutState.currentVersion,
            rows: [
                RowState(panes: [
                    PaneState(
                        tabs: [
                            TabState(
                                location: .search(SearchQuery(text: "swift", scope: URL(fileURLWithPath: "/tmp"))),
                                sortField: .kind,
                                sortAscending: false,
                                showHiddenFiles: true,
                                backHistory: [.recents],
                                forwardHistory: [.directory(URL(fileURLWithPath: "/"))]
                            ),
                            TabState(
                                location: .recents,
                                sortField: .date,
                                sortAscending: true,
                                showHiddenFiles: false,
                                backHistory: [],
                                forwardHistory: []
                            )
                        ],
                        selectedTabIndex: 1
                    )
                ])
            ],
            focusedIndex: 0
        )

        let encoded = try XCTUnwrap(LayoutManager.encode(state))
        XCTAssertEqual(LayoutManager.decode(encoded), state)
    }

    func testWeightedLayoutRoundTripPreservesSidebarPaneAndRowSizing() throws {
        let manager = LayoutManager()
        let firstPaneID = try XCTUnwrap(manager.focusedPaneID)

        manager.resizeSidebar(to: 278)
        manager.resizePane(rowIndex: 0, dividerIndex: 0, delta: 180, availableWidth: 900)
        manager.addRowBelow(of: firstPaneID)
        manager.resizeRow(dividerIndex: 0, delta: 120, availableHeight: 600)
        manager.save()

        let restored = LayoutManager(serializedState: manager.serializedState)

        XCTAssertEqual(restored.sidebarWidth, 278, accuracy: 0.001)
        XCTAssertEqual(restored.rows.count, 2)
        XCTAssertEqual(restored.rows[0].paneWeights[0], 0.7, accuracy: 0.001)
        XCTAssertEqual(restored.rows[0].paneWeights[1], 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.rows[0].heightWeight, 0.7, accuracy: 0.001)
        XCTAssertEqual(restored.rows[1].heightWeight, 0.3, accuracy: 0.001)
    }

    func testPaneWeightsRemainNormalizedAfterResizeAddAndRemove() throws {
        let manager = LayoutManager()
        let firstPaneID = try XCTUnwrap(manager.focusedPaneID)

        manager.resizePane(rowIndex: 0, dividerIndex: 0, delta: 180, availableWidth: 900)
        manager.addPaneRight(of: firstPaneID)

        XCTAssertEqual(manager.rows[0].paneWeights.reduce(0, +), 1, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].paneWeights[0], 0.35, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].paneWeights[1], 0.35, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].paneWeights[2], 0.3, accuracy: 0.001)

        let addedPaneID = try XCTUnwrap(manager.focusedPaneID)
        manager.removePane(addedPaneID)

        XCTAssertEqual(manager.rows[0].paneWeights.reduce(0, +), 1, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].paneWeights[0], 0.35, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].paneWeights[1], 0.65, accuracy: 0.001)
        XCTAssertTrue(manager.rows[0].paneWeights.allSatisfy { $0 > 0 })
    }

    func testRowWeightsRemainNormalizedAfterResizeAddAndRemove() throws {
        let manager = LayoutManager()
        let firstPaneID = try XCTUnwrap(manager.focusedPaneID)

        manager.addRowBelow(of: firstPaneID)
        manager.resizeRow(dividerIndex: 0, delta: 120, availableHeight: 600)
        XCTAssertEqual(manager.rows.map(\.heightWeight).reduce(0, +), 1, accuracy: 0.001)
        XCTAssertEqual(manager.rows[0].heightWeight, 0.7, accuracy: 0.001)
        XCTAssertEqual(manager.rows[1].heightWeight, 0.3, accuracy: 0.001)

        let secondRowPaneID = try XCTUnwrap(manager.focusedPaneID)
        manager.addRowBelow(of: secondRowPaneID)
        XCTAssertEqual(manager.rows.map(\.heightWeight).reduce(0, +), 1, accuracy: 0.001)

        manager.removePane(secondRowPaneID)
        XCTAssertEqual(manager.rows.map(\.heightWeight).reduce(0, +), 1, accuracy: 0.001)
        XCTAssertTrue(manager.rows.allSatisfy { $0.heightWeight > 0 })
    }

    func testVersionTwoLayoutDefaultsMissingSizingFields() throws {
        let legacyJSON = """
        {
          "version": 2,
          "rows": [{
            "panes": [{
              "location": {"recents": {}},
              "sortField": "Name",
              "sortAscending": true,
              "showHiddenFiles": false,
              "backHistory": [],
              "forwardHistory": []
            }]
          }],
          "focusedIndex": 0
        }
        """
        let encoded = Data(legacyJSON.utf8).base64EncodedString()

        let decoded = try XCTUnwrap(LayoutManager.decode(encoded))
        let restored = LayoutManager(serializedState: encoded)

        XCTAssertEqual(decoded.sidebarWidth, 160)
        XCTAssertEqual(decoded.rows[0].paneWeights, [])
        XCTAssertEqual(decoded.rows[0].heightWeight, 1)
        XCTAssertEqual(restored.sidebarWidth, 160)
        XCTAssertEqual(restored.rows[0].paneWeights, [1])
        XCTAssertEqual(restored.rows[0].heightWeight, 1)
    }

    func testApplyingTemplateReplacesPaneLayoutPathsAndSizing() throws {
        let manager = LayoutManager()
        let root = URL(fileURLWithPath: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applications = URL(fileURLWithPath: "/Applications")
        let template = LayoutState(
            version: LayoutState.currentVersion,
            rows: [
                RowState(
                    panes: [paneState(url: root), paneState(url: home)],
                    paneWeights: [0.3, 0.7],
                    heightWeight: 0.6
                ),
                RowState(
                    panes: [paneState(url: applications)],
                    paneWeights: [1],
                    heightWeight: 0.4
                )
            ],
            focusedIndex: 2,
            sidebarWidth: 245
        )

        XCTAssertTrue(manager.applyTemplate(template))

        XCTAssertEqual(manager.rows.count, 2)
        XCTAssertEqual(manager.totalPaneCount, 3)
        XCTAssertEqual(manager.rows[0].paneWeights, [0.3, 0.7])
        XCTAssertEqual(manager.rows.map(\.heightWeight), [0.6, 0.4])
        XCTAssertEqual(manager.sidebarWidth, 245)
        XCTAssertEqual(manager.rows[0].panes.compactMap { $0.selectedTab.currentURL }, [root, home])
        XCTAssertEqual(manager.focusedPane?.currentURL, applications)
    }

    func testTemplateSnapshotDropsNavigationHistory() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedPane)
        pane.navigate(to: URL(fileURLWithPath: "/"))

        let template = manager.makeTemplateState()

        XCTAssertTrue(template.rows.flatMap(\.panes).flatMap(\.tabs).allSatisfy {
            $0.backHistory.isEmpty && $0.forwardHistory.isEmpty
        })
    }

    func testExternalPathReusesAndHighlightsPaneAlreadyShowingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LayoutManager()
        let matchingPane = manager.rows[0].panes[0]
        matchingPane.selectedTab.navigate(to: directory)
        manager.focusedPaneID = manager.rows[0].panes[1].id

        XCTAssertTrue(manager.openExternalPath(directory))

        XCTAssertEqual(manager.totalPaneCount, 2)
        XCTAssertEqual(manager.focusedPaneID, matchingPane.id)
        XCTAssertEqual(manager.highlightedPaneID, matchingPane.id)
    }

    func testExternalDirectChildReusesParentPane() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let manager = LayoutManager()
        let parentPane = manager.rows[0].panes[0]
        parentPane.selectedTab.navigate(to: parent)

        XCTAssertTrue(manager.openExternalPath(child))

        XCTAssertEqual(manager.totalPaneCount, 2)
        XCTAssertEqual(manager.focusedPaneID, parentPane.id)
        XCTAssertEqual(parentPane.selectedTab.currentURL, child.standardizedFileURL)
        XCTAssertEqual(manager.highlightedPaneID, parentPane.id)
    }

    func testExternalUnrelatedPathCreatesNewPane() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LayoutManager()

        XCTAssertTrue(manager.openExternalPath(directory))

        XCTAssertEqual(manager.totalPaneCount, 3)
        XCTAssertEqual(manager.focusedPane?.currentURL, directory.standardizedFileURL)
        XCTAssertNil(manager.highlightedPaneID)
    }

    func testExternalMissingPathReportsErrorWithoutAddingPane() {
        let manager = LayoutManager()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertFalse(manager.openExternalPath(missingURL))

        XCTAssertEqual(manager.totalPaneCount, 2)
        XCTAssertNotNil(manager.focusedPane?.errorMessage)
    }

    func testNewTabDuplicatesCurrentLocationAndSelectsIt() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        pane.selectedTab.navigate(to: URL(fileURLWithPath: "/Applications"))

        manager.newTab(in: pane.id)

        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.selectedTabIndex, 1)
        XCTAssertEqual(pane.selectedTab.currentURL, URL(fileURLWithPath: "/Applications").standardizedFileURL)
        XCTAssertTrue(pane.selectedTab.backHistory.isEmpty)
        XCTAssertEqual(manager.focusedPane?.id, pane.selectedTab.id)
    }

    func testCloseTabAdjustsSelectionAndClosingLastTabRemovesPane() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        manager.newTab(in: pane.id)
        manager.newTab(in: pane.id)
        XCTAssertEqual(pane.tabs.count, 3)
        XCTAssertEqual(pane.selectedTabIndex, 2)

        manager.closeTab(in: pane.id)
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.selectedTabIndex, 1)

        manager.closeTab(at: 0, in: pane.id)
        XCTAssertEqual(pane.tabs.count, 1)
        XCTAssertEqual(pane.selectedTabIndex, 0)

        manager.closeTab(in: pane.id)
        XCTAssertEqual(manager.totalPaneCount, 1)
        XCTAssertNil(manager.findPane(id: pane.id))
        XCTAssertNotNil(manager.focusedPane)
    }

    func testClosingOnlyTabOfOnlyPaneKeepsPane() throws {
        let manager = LayoutManager()
        let firstPaneID = try XCTUnwrap(manager.focusedPaneID)
        manager.removePane(manager.rows[0].panes[1].id)
        XCTAssertEqual(manager.totalPaneCount, 1)

        manager.closeTab(in: firstPaneID)

        XCTAssertEqual(manager.totalPaneCount, 1)
        XCTAssertEqual(manager.findPane(id: firstPaneID)?.tabs.count, 1)
        XCTAssertFalse(manager.canCloseTab)
    }

    func testSelectNextAndPreviousTabWrapAround() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        manager.newTab(in: pane.id)
        manager.newTab(in: pane.id)
        XCTAssertEqual(pane.selectedTabIndex, 2)

        manager.selectNextTab(in: pane.id)
        XCTAssertEqual(pane.selectedTabIndex, 0)

        manager.selectPreviousTab(in: pane.id)
        XCTAssertEqual(pane.selectedTabIndex, 2)

        manager.selectTab(at: 1, in: pane.id)
        XCTAssertEqual(pane.selectedTabIndex, 1)
        XCTAssertEqual(manager.focusedPane?.id, pane.tabs[1].id)
    }

    func testSwitchingTabsClearsFilterFromTabBeingLeft() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        manager.newTab(in: pane.id)
        manager.selectTab(at: 0, in: pane.id)
        pane.selectedTab.filterText = "swift"

        manager.selectNextTab(in: pane.id)

        XCTAssertEqual(pane.tabs[0].filterText, "")
        XCTAssertEqual(pane.selectedTabIndex, 1)
    }

    func testAdjacentPaneUsesRowMajorOrderAndWraps() throws {
        let manager = LayoutManager()
        let first = manager.rows[0].panes[0]
        let second = manager.rows[0].panes[1]
        manager.addRowBelow(of: second.id)
        let third = try XCTUnwrap(manager.rows.last?.panes.first)

        XCTAssertEqual(manager.adjacentPane(of: first.id)?.id, second.id)
        XCTAssertEqual(manager.adjacentPane(of: second.id)?.id, third.id)
        XCTAssertEqual(manager.adjacentPane(of: third.id)?.id, first.id)
    }

    func testCopySelectionToAdjacentPaneCopiesAndSelectsDestination() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceFile = sourceDirectory.appendingPathComponent("copy-me.txt")
        try Data("copy".utf8).write(to: sourceFile)
        let manager = LayoutManager()
        let sourcePane = manager.rows[0].panes[0]
        let targetPane = manager.rows[0].panes[1]
        sourcePane.selectedTab.navigate(to: sourceDirectory)
        targetPane.selectedTab.navigate(to: destinationDirectory)
        manager.focusedPaneID = sourcePane.id
        try await waitUntil {
            !sourcePane.selectedTab.isLoading && !targetPane.selectedTab.isLoading
        }
        sourcePane.selectedTab.selectedItems = [sourceFile.standardizedFileURL]

        XCTAssertTrue(manager.copySelectionToAdjacentPane())

        let destination = destinationDirectory.appendingPathComponent("copy-me.txt").standardizedFileURL
        try await waitUntil {
            !targetPane.selectedTab.isLoading
                && targetPane.selectedTab.selectedItems == [destination]
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertEqual(try String(contentsOf: destination), "copy")
    }

    func testMoveSelectionToAdjacentPaneMovesAndRefreshesBothPanes() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceFile = sourceDirectory.appendingPathComponent("move-me.txt")
        try Data("move".utf8).write(to: sourceFile)
        let manager = LayoutManager()
        let sourcePane = manager.rows[0].panes[0]
        let targetPane = manager.rows[0].panes[1]
        sourcePane.selectedTab.navigate(to: sourceDirectory)
        targetPane.selectedTab.navigate(to: destinationDirectory)
        manager.focusedPaneID = sourcePane.id
        try await waitUntil {
            !sourcePane.selectedTab.isLoading && !targetPane.selectedTab.isLoading
        }
        sourcePane.selectedTab.selectedItems = [sourceFile.standardizedFileURL]

        XCTAssertTrue(manager.moveSelectionToAdjacentPane())

        let destination = destinationDirectory.appendingPathComponent("move-me.txt").standardizedFileURL
        try await waitUntil {
            !sourcePane.selectedTab.isLoading
                && !targetPane.selectedTab.isLoading
                && sourcePane.selectedTab.items.isEmpty
                && targetPane.selectedTab.selectedItems == [destination]
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertEqual(try String(contentsOf: destination), "move")
    }

    func testSameDirectoryDisablesMoveButStillAllowsCopyToAdjacentPane() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: sourceFile)
        let manager = LayoutManager()
        let sourcePane = manager.rows[0].panes[0]
        let targetPane = manager.rows[0].panes[1]
        sourcePane.selectedTab.navigate(to: directory)
        targetPane.selectedTab.navigate(to: directory)
        manager.focusedPaneID = sourcePane.id
        try await waitUntil {
            !sourcePane.selectedTab.isLoading && !targetPane.selectedTab.isLoading
        }
        sourcePane.selectedTab.selectedItems = [sourceFile.standardizedFileURL]

        XCTAssertTrue(
            manager.canTransferSelectionToAdjacentPane(from: sourcePane.id, operation: .copy)
        )
        XCTAssertFalse(
            manager.canTransferSelectionToAdjacentPane(from: sourcePane.id, operation: .move)
        )
        XCTAssertFalse(manager.moveSelectionToAdjacentPane())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testVirtualAdjacentLocationDisablesCrossPaneTransfers() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let sourceFile = sourceDirectory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: sourceFile)
        let manager = LayoutManager()
        let sourcePane = manager.rows[0].panes[0]
        let targetPane = manager.rows[0].panes[1]
        sourcePane.selectedTab.navigate(to: sourceDirectory)
        targetPane.selectedTab.loadRecents()
        manager.focusedPaneID = sourcePane.id
        try await waitUntil { !sourcePane.selectedTab.isLoading }
        sourcePane.selectedTab.selectedItems = [sourceFile.standardizedFileURL]

        XCTAssertFalse(
            manager.canTransferSelectionToAdjacentPane(from: sourcePane.id, operation: .copy)
        )
        XCTAssertFalse(
            manager.canTransferSelectionToAdjacentPane(from: sourcePane.id, operation: .move)
        )
        XCTAssertFalse(manager.copySelectionToAdjacentPane())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testMixedProtectedBatchIsRejectedWithoutMovingValidItems() async throws {
        let sourceDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceFile = sourceDirectory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: sourceFile)
        let manager = LayoutManager()
        let sourcePane = manager.rows[0].panes[0]
        let targetPane = manager.rows[0].panes[1]
        sourcePane.selectedTab.navigate(to: sourceDirectory)
        targetPane.selectedTab.navigate(to: destinationDirectory)
        try await waitUntil {
            !sourcePane.selectedTab.isLoading && !targetPane.selectedTab.isLoading
        }
        let sources = [
            sourceFile,
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]

        XCTAssertFalse(
            manager.canTransferItemsToAdjacentPane(
                sources,
                from: sourcePane.id,
                operation: .move
            )
        )
        XCTAssertFalse(
            manager.transferItemsToAdjacentPane(
                sources,
                from: sourcePane.id,
                operation: .move
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDirectory.appendingPathComponent("notes.txt").path
            )
        )
    }

    func testWorkspaceRoundTripPreservesTabsAndSelection() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedBrowserPane)
        pane.selectedTab.navigate(to: URL(fileURLWithPath: "/Applications"))
        manager.newTab(in: pane.id)
        pane.selectedTab.loadRecents()
        manager.selectTab(at: 0, in: pane.id)
        manager.save()

        let restored = LayoutManager(serializedState: manager.serializedState)
        let restoredPane = try XCTUnwrap(restored.focusedBrowserPane)

        XCTAssertEqual(restoredPane.tabs.count, 2)
        XCTAssertEqual(restoredPane.selectedTabIndex, 0)
        XCTAssertEqual(restoredPane.tabs[0].currentURL, URL(fileURLWithPath: "/Applications").standardizedFileURL)
        XCTAssertEqual(restoredPane.tabs[1].location, .recents)
    }

    func testVersionThreeLayoutMigratesPanesToSingleTab() throws {
        let legacyJSON = """
        {
          "version": 3,
          "rows": [{
            "panes": [{
              "location": {"directory": {"_0": "file:///"}},
              "sortField": "Name",
              "sortAscending": true,
              "showHiddenFiles": false,
              "backHistory": [],
              "forwardHistory": []
            }, {
              "location": {"directory": {"_0": "file:///Applications/"}},
              "sortField": "Date Modified",
              "sortAscending": false,
              "showHiddenFiles": true,
              "backHistory": [{"recents": {}}],
              "forwardHistory": []
            }],
            "paneWeights": [0.4, 0.6],
            "heightWeight": 1
          }],
          "focusedIndex": 1,
          "sidebarWidth": 200
        }
        """
        let encoded = Data(legacyJSON.utf8).base64EncodedString()

        let decoded = try XCTUnwrap(LayoutManager.decode(encoded))
        let restored = LayoutManager(serializedState: encoded)

        XCTAssertEqual(decoded.rows[0].panes.map(\.tabs.count), [1, 1])
        XCTAssertEqual(decoded.rows[0].panes.map(\.selectedTabIndex), [0, 0])
        XCTAssertEqual(decoded.rows[0].panes[1].tabs[0].backHistory, [.recents])
        XCTAssertEqual(restored.rows[0].panes.map(\.tabs.count), [1, 1])
        XCTAssertEqual(restored.focusedPane?.currentURL, URL(fileURLWithPath: "/Applications").standardizedFileURL)
        XCTAssertEqual(restored.focusedPane?.sortField, .date)
        XCTAssertFalse(restored.focusedPane?.sortAscending ?? true)
        XCTAssertTrue(restored.focusedPane?.showHiddenFiles ?? false)
    }

    private func paneState(url: URL) -> PaneState {
        PaneState(tabs: [
            TabState(
                location: .directory(url),
                sortField: .name,
                sortAscending: true,
                showHiddenFiles: false,
                backHistory: [],
                forwardHistory: []
            )
        ])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.standardizedFileURL
    }

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
