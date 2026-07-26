import Foundation
import XCTest
@testable import MultiFinder

final class FileItemTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testIdentityIsStableAcrossRefreshes() throws {
        let file = temporaryDirectory.appendingPathComponent("stable.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertEqual(FileItem(url: file).id, FileItem(url: file).id)
    }

    func testDescendingComparatorReturnsSameForSameItem() throws {
        let file = temporaryDirectory.appendingPathComponent("same.txt")
        try Data("hello".utf8).write(to: file)
        let item = FileItem(url: file)

        for field in SortField.allCases {
            let comparator = FileItemComparator(field: field, order: .reverse)
            XCTAssertEqual(comparator.compare(item, item), .orderedSame, "Failed for \(field)")
        }
    }

    func testFoldersRemainFirstAndTiesUseNameFallback() throws {
        let folder = temporaryDirectory.appendingPathComponent("z-folder")
        let alpha = temporaryDirectory.appendingPathComponent("alpha.txt")
        let beta = temporaryDirectory.appendingPathComponent("beta.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1]).write(to: alpha)
        try Data([2]).write(to: beta)

        let items = [FileItem(url: beta), FileItem(url: folder), FileItem(url: alpha)]
        let sorted = FileBrowserViewModel.sort(items: items, by: .size, ascending: true)

        XCTAssertEqual(sorted.map(\.name), ["z-folder", "alpha.txt", "beta.txt"])
    }

    func testApplicationPackageIsOpenedRatherThanNavigated() throws {
        let application = temporaryDirectory.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        let item = FileItem(url: application)

        XCTAssertTrue(item.isDirectory)
        XCTAssertTrue(item.isPackage)
        XCTAssertFalse(FileBrowserViewModel.shouldNavigateInto(item))
    }
}
