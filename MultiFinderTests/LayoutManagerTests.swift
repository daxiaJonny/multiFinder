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
                        location: .search(SearchQuery(text: "swift", scope: URL(fileURLWithPath: "/tmp"))),
                        sortField: .kind,
                        sortAscending: false,
                        showHiddenFiles: true,
                        backHistory: [.recents],
                        forwardHistory: [.directory(URL(fileURLWithPath: "/"))]
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
        XCTAssertEqual(manager.rows[0].panes.compactMap(\.currentURL), [root, home])
        XCTAssertEqual(manager.focusedPane?.currentURL, applications)
    }

    func testTemplateSnapshotDropsNavigationHistory() throws {
        let manager = LayoutManager()
        let pane = try XCTUnwrap(manager.focusedPane)
        pane.navigate(to: URL(fileURLWithPath: "/"))

        let template = manager.makeTemplateState()

        XCTAssertTrue(template.rows.flatMap(\.panes).allSatisfy {
            $0.backHistory.isEmpty && $0.forwardHistory.isEmpty
        })
    }

    func testExternalPathReusesAndHighlightsPaneAlreadyShowingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LayoutManager()
        let matchingPane = manager.rows[0].panes[0]
        matchingPane.navigate(to: directory)
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
        parentPane.navigate(to: parent)

        XCTAssertTrue(manager.openExternalPath(child))

        XCTAssertEqual(manager.totalPaneCount, 2)
        XCTAssertEqual(manager.focusedPaneID, parentPane.id)
        XCTAssertEqual(parentPane.currentURL, child.standardizedFileURL)
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

    private func paneState(url: URL) -> PaneState {
        PaneState(
            location: .directory(url),
            sortField: .name,
            sortAscending: true,
            showHiddenFiles: false,
            backHistory: [],
            forwardHistory: []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.standardizedFileURL
    }
}
