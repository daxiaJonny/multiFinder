import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class StashShelfStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: StashShelfStore!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StashShelfStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = StashShelfStore(operationService: .shared)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
    }

    func testAddAndDeduplicateItems() throws {
        let file1 = tempDirectory.appendingPathComponent("test1.txt")
        let file2 = tempDirectory.appendingPathComponent("test2.txt")
        try "Hello 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Hello 2".write(to: file2, atomically: true, encoding: .utf8)

        store.add(urls: [file1, file2])
        XCTAssertEqual(store.count, 2)
        XCTAssertTrue(store.isPresented)

        // Adding duplicate file should not increase count
        store.add(urls: [file1])
        XCTAssertEqual(store.count, 2)
    }

    func testRemoveItem() throws {
        let file = tempDirectory.appendingPathComponent("remove_me.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        store.add(urls: [file])
        XCTAssertEqual(store.count, 1)

        let itemID = store.items[0].id
        store.remove(id: itemID)
        XCTAssertEqual(store.count, 0)
    }

    func testClearItems() throws {
        let file1 = tempDirectory.appendingPathComponent("f1.txt")
        let file2 = tempDirectory.appendingPathComponent("f2.txt")
        try "1".write(to: file1, atomically: true, encoding: .utf8)
        try "2".write(to: file2, atomically: true, encoding: .utf8)

        store.add(urls: [file1, file2])
        XCTAssertEqual(store.count, 2)

        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.totalSize, 0)
    }

    func testTotalSizeCalculation() throws {
        let file = tempDirectory.appendingPathComponent("sized.txt")
        let data = Data(repeating: 65, count: 1024)
        try data.write(to: file)

        store.add(urls: [file])
        XCTAssertEqual(store.totalSize, 1024)
        XCTAssertFalse(store.formattedTotalSize.isEmpty)
    }
}
