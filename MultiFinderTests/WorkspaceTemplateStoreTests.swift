import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class WorkspaceTemplateStoreTests: XCTestCase {
    private static let storageKey = "workspaceTemplates"

    func testSavePersistsTemplateAndPaneCount() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let layout = makeLayout(paneCount: 3)

        let template = try XCTUnwrap(store.save(name: "Development", layoutState: layout))
        let restoredStore = makeStore(userDefaults: userDefaults)

        XCTAssertEqual(template.paneCount, 3)
        XCTAssertEqual(restoredStore.templates, [template])
    }

    func testSavingSameNameUpdatesTemplateInPlace() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let first = try XCTUnwrap(store.save(name: "Work", layoutState: makeLayout(paneCount: 1)))

        let updated = try XCTUnwrap(store.save(name: " work ", layoutState: makeLayout(paneCount: 4)))

        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.name, "work")
        XCTAssertEqual(updated.paneCount, 4)
        XCTAssertEqual(makeStore(userDefaults: userDefaults).templates.first?.paneCount, 4)
    }

    func testRemovePersistsAndCorruptStorageCanRecover() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let template = try XCTUnwrap(store.save(name: "Temporary", layoutState: makeLayout(paneCount: 2)))

        XCTAssertTrue(store.remove(id: template.id))
        XCTAssertTrue(makeStore(userDefaults: userDefaults).templates.isEmpty)

        userDefaults.set(Data("invalid".utf8), forKey: Self.storageKey)
        let recoveredStore = makeStore(userDefaults: userDefaults)
        XCTAssertTrue(recoveredStore.templates.isEmpty)
        XCTAssertNotNil(recoveredStore.save(name: "Recovered", layoutState: makeLayout(paneCount: 1)))
    }

    func testLegacyVersionThreeTemplateStillLoads() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let legacyJSON = """
        [{
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "savedAt": 700000000,
          "layoutState": {
            "version": 3,
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
        }]
        """
        userDefaults.set(Data(legacyJSON.utf8), forKey: Self.storageKey)

        let store = makeStore(userDefaults: userDefaults)

        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(store.templates.first?.paneCount, 1)
        XCTAssertEqual(store.templates.first?.layoutState.rows.first?.panes.first?.tabs.count, 1)
        XCTAssertEqual(store.templates.first?.layoutState.rows.first?.panes.first?.tabs.first?.location, .recents)
    }

    private func makeLayout(paneCount: Int) -> LayoutState {
        let panes = (0..<paneCount).map { index in
            PaneState(tabs: [
                TabState(
                    location: .directory(URL(fileURLWithPath: index.isMultiple(of: 2) ? "/" : "/Applications")),
                    sortField: .name,
                    sortAscending: true,
                    showHiddenFiles: false,
                    backHistory: [],
                    forwardHistory: []
                )
            ])
        }
        return LayoutState(
            version: LayoutState.currentVersion,
            rows: [RowState(panes: panes)],
            focusedIndex: 0
        )
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WorkspaceTemplateStoreTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeStore(userDefaults: UserDefaults) -> WorkspaceTemplateStore {
        WorkspaceTemplateStore(userDefaults: userDefaults, storageKey: Self.storageKey)
    }
}
