import Combine
import Foundation
import XCTest
@testable import MultiFinder

final class FileBrowserPerformanceTests: XCTestCase {
    func testNaturalSortTenThousandItems() {
        let directory = URL(fileURLWithPath: "/performance-fixture")
        let items = (0..<10_000).map { FileItem(named: "file-\(($0 * 7919) % 10_000).txt", in: directory) }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let sorted = FileBrowserViewModel.sort(items: items, by: .name, ascending: true)
            XCTAssertEqual(sorted.first?.name, "file-0.txt")
            XCTAssertEqual(sorted.last?.name, "file-9999.txt")
        }
    }

    @MainActor
    func testLoadTenThousandFilesPublishesNamesBeforeMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<10_000 {
            try Data([0]).write(to: directory.appendingPathComponent("file-\(index).txt"))
        }
        let start = Date()
        let viewModel = FileBrowserViewModel(location: .directory(directory))
        var firstPaint: TimeInterval?
        let subscription = viewModel.$items.sink { items in
            if firstPaint == nil, items.count == 10_000, items.contains(where: { !$0.isMetadataLoaded }) {
                firstPaint = Date().timeIntervalSince(start)
            }
        }
        while viewModel.isLoading, Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(10))
        }
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(firstPaint)
        XCTAssertEqual(viewModel.items.count, 10_000)
        XCTAssertTrue(viewModel.items.allSatisfy { $0.isMetadataLoaded && $0.size == 1 })
        print("10k directory: names=\(firstPaint ?? -1)s, complete=\(Date().timeIntervalSince(start))s")
    }
}
