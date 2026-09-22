import AppKit
import SwiftUI
import XCTest
@testable import MultiFinder

@MainActor
final class VirtualFileViewTests: XCTestCase {
    private let files = ["alpha.txt", "beta.txt"].map {
        FileItem(named: $0, in: URL(fileURLWithPath: "/tmp"))
    }

    func testTableUpdatesFilteredRowsWithoutMetadataRevisionChange() {
        let table = VirtualFileTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let initial = tableInput(files, revision: 0)
        let coordinator = initial.makeCoordinator()
        coordinator.tableView = table
        table.dataSource = coordinator
        coordinator.apply(initial)
        XCTAssertEqual(table.numberOfRows, 2)

        coordinator.apply(tableInput([files[1]], revision: 1))
        XCTAssertEqual(table.numberOfRows, 1)
        coordinator.apply(tableInput([], revision: 2))
        XCTAssertEqual(table.numberOfRows, 0)
        coordinator.apply(tableInput(files, revision: 3))
        XCTAssertEqual(table.numberOfRows, 2)
        coordinator.apply(tableInput(Array(files.reversed()), revision: 4, selection: [files[0].id]))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
    }

    func testGridUpdatesFilteredRowsWithoutMetadataRevisionChange() async throws {
        let initial = gridInput(files, revision: 0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: initial)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        func findCollection(_ view: NSView) -> VirtualFileCollectionView? {
            if let collection = view as? VirtualFileCollectionView { return collection }
            return view.subviews.lazy.compactMap(findCollection).first
        }
        let collection = try XCTUnwrap(window.contentView.flatMap(findCollection))
        let coordinator = try XCTUnwrap(collection.coordinator)
        XCTAssertEqual(coordinator.collectionView(collection, numberOfItemsInSection: 0), 2)

        coordinator.apply(gridInput([files[1]], revision: 1))
        XCTAssertEqual(coordinator.collectionView(collection, numberOfItemsInSection: 0), 1)
        coordinator.apply(gridInput([], revision: 2))
        XCTAssertEqual(coordinator.collectionView(collection, numberOfItemsInSection: 0), 0)
        coordinator.apply(gridInput(files, revision: 3))
        XCTAssertEqual(coordinator.collectionView(collection, numberOfItemsInSection: 0), 2)
        collection.isSelectable = true
        coordinator.apply(gridInput(Array(files.reversed()), revision: 4, selection: [files[0].id]))
        XCTAssertEqual(collection.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
    }

    private func tableInput(_ items: [FileItem], revision: UInt64, selection: Set<URL> = []) -> VirtualFileTable {
        VirtualFileTable(
            items: items, itemsRevision: 1, tableRevision: revision,
            selection: selection, sortOrder: [.init(field: .name)], gitIndex: nil, gitGeneration: 0,
            onSelection: { _ in }, onSort: { _ in }, onOpen: { _ in }, onBeginRename: {},
            onFocus: {}, onQuickLook: {}, onBeginFiltering: {}, onDelete: {}, onDrop: { _, _ in }
        )
    }

    private func gridInput(_ items: [FileItem], revision: UInt64, selection: Set<URL> = []) -> VirtualFileGrid {
        VirtualFileGrid(
            items: items, itemsRevision: 1, tableRevision: revision,
            selection: selection, gitIndex: nil, gitGeneration: 0,
            onSelection: { _ in }, onOpen: { _ in }, onFocus: {},
            onQuickLook: {}, onBeginFiltering: {}, onDelete: {}, onDrop: { _, _ in }
        )
    }
}
