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
}
