import Foundation
import XCTest
@testable import MultiFinder

final class AISearchMatcherTests: XCTestCase {
    private func matcher(_ criteria: AISearchCriteria) -> AISearchMatcher {
        AISearchMatcher(criteria: criteria)
    }

    private func date(_ iso: String) -> Date {
        AISearchCriteria.isoDate(from: iso)!
    }

    // MARK: - Name

    func testEmptyCriteriaMatchesEverything() {
        let matcher = matcher(AISearchCriteria())
        XCTAssertTrue(matcher.matches(name: "anything.txt", size: 10, modificationDate: Date()))
        XCTAssertTrue(matcher.matches(name: "folder", size: nil, modificationDate: nil))
    }

    func testNameContainsIsOrMatchedCaseInsensitive() {
        let matcher = matcher(AISearchCriteria(nameContains: ["截图", "Screenshot"]))
        XCTAssertTrue(matcher.matches(name: "屏幕截图 2026.png", size: 1, modificationDate: nil))
        XCTAssertTrue(matcher.matches(name: "my-SCREENSHOT-01.png", size: 1, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "photo.png", size: 1, modificationDate: nil))
    }

    func testEmptyNameFragmentsDoNotMatchEverything() {
        let matcher = matcher(AISearchCriteria(nameContains: [""]))
        XCTAssertFalse(matcher.matches(name: "photo.png", size: 1, modificationDate: nil))
    }

    // MARK: - Extensions

    func testExtensionFilterIsCaseInsensitiveAndIgnoresLeadingDot() {
        let matcher = matcher(AISearchCriteria(extensions: ["PNG", ".jpg"]))
        XCTAssertTrue(matcher.matches(name: "a.png", size: 1, modificationDate: nil))
        XCTAssertTrue(matcher.matches(name: "b.JPG", size: 1, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "c.pdf", size: 1, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "no-extension", size: 1, modificationDate: nil))
    }

    // MARK: - Dates

    func testModifiedDateWindow() {
        let matcher = matcher(AISearchCriteria(
            modifiedAfter: date("2026-06-01"),
            modifiedBefore: date("2026-07-01")
        ))
        XCTAssertTrue(matcher.matches(name: "a", size: nil, modificationDate: date("2026-06-15")))
        XCTAssertTrue(matcher.matches(name: "a", size: nil, modificationDate: date("2026-06-01")))
        XCTAssertFalse(matcher.matches(name: "a", size: nil, modificationDate: date("2026-05-31")))
        XCTAssertFalse(matcher.matches(name: "a", size: nil, modificationDate: date("2026-07-02")))
        XCTAssertFalse(matcher.matches(name: "a", size: nil, modificationDate: nil))
    }

    // MARK: - Size

    func testSizeBounds() {
        let matcher = matcher(AISearchCriteria(minSize: 100, maxSize: 1000))
        XCTAssertTrue(matcher.matches(name: "a", size: 100, modificationDate: nil))
        XCTAssertTrue(matcher.matches(name: "a", size: 1000, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "a", size: 99, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "a", size: 1001, modificationDate: nil))
        XCTAssertFalse(matcher.matches(name: "a", size: nil, modificationDate: nil))
    }

    func testZeroSizeBoundsMeanUnlimited() {
        let matcher = matcher(AISearchCriteria(minSize: 0, maxSize: 0))
        XCTAssertTrue(matcher.matches(name: "a", size: 5, modificationDate: nil))
        XCTAssertTrue(matcher.matches(name: "folder", size: nil, modificationDate: nil))
    }

    // MARK: - Combinations

    func testAllCriteriaMustMatchTogether() {
        let matcher = matcher(AISearchCriteria(
            nameContains: ["report"],
            extensions: ["pdf"],
            modifiedAfter: date("2026-01-01"),
            minSize: 10
        ))
        XCTAssertTrue(matcher.matches(name: "Q2 Report.pdf", size: 50, modificationDate: date("2026-03-01")))
        XCTAssertFalse(matcher.matches(name: "Q2 Report.txt", size: 50, modificationDate: date("2026-03-01")))
        XCTAssertFalse(matcher.matches(name: "notes.pdf", size: 50, modificationDate: date("2026-03-01")))
        XCTAssertFalse(matcher.matches(name: "Q2 Report.pdf", size: 5, modificationDate: date("2026-03-01")))
        XCTAssertFalse(matcher.matches(name: "Q2 Report.pdf", size: 50, modificationDate: date("2025-03-01")))
    }

    func testRecursiveDefaultsToTrue() {
        XCTAssertTrue(matcher(AISearchCriteria()).isRecursive)
        XCTAssertFalse(matcher(AISearchCriteria(recursive: false)).isRecursive)
    }

    // MARK: - BrowserLocation.aiSearch Codable

    func testAISearchLocationRoundTrip() throws {
        let criteria = AISearchCriteria(
            nameContains: ["Screenshot"],
            extensions: ["png"],
            modifiedAfter: date("2026-06-01"),
            modifiedBefore: date("2026-07-01"),
            minSize: 1,
            maxSize: 5000,
            recursive: true
        )
        let location = BrowserLocation.aiSearch(
            root: URL(fileURLWithPath: "/Users/test/Downloads"),
            criteria: criteria,
            title: "screenshots from last month"
        )

        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(BrowserLocation.self, from: data)

        XCTAssertEqual(decoded, location)
        XCTAssertEqual(decoded.title, "screenshots from last month")
        XCTAssertEqual(decoded.pathDescription, "/Users/test/Downloads")
        XCTAssertFalse(decoded.supportsCreatingItems)
    }

    func testLegacyLocationJSONStillDecodes() throws {
        let legacyJSON = """
        [
          {"directory": {"_0": "file:///Applications/"}},
          {"recents": {}},
          {"search": {"_0": {"text": "swift", "scope": "file:///Users/"}}}
        ]
        """

        let decoded = try JSONDecoder().decode([BrowserLocation].self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded[0], .directory(URL(fileURLWithPath: "/Applications/")))
        XCTAssertEqual(decoded[1], .recents)
        XCTAssertEqual(decoded[2], .search(SearchQuery(text: "swift", scope: URL(fileURLWithPath: "/Users/"))))
    }
}
