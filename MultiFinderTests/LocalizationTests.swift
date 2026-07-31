import Foundation
import XCTest
@testable import MultiFinder

final class LocalizationTests: XCTestCase {
    func testCatalogProvidesSimplifiedChineseTranslation() {
        XCTAssertEqual(localized("Recents", locale: "zh-Hans"), "最近使用")
    }

    func testCatalogFormatsSimplifiedChineseArguments() {
        let locale = Locale(identifier: "zh-Hans")
        let format = localized("Search: %@", locale: "zh-Hans")

        XCTAssertEqual(
            String(format: format, locale: locale, arguments: ["报告"]),
            "搜索：报告"
        )
    }

    func testCatalogCoversFilteringAndCrossPaneCommands() {
        XCTAssertEqual(localized("Filter by file name", locale: "zh-Hans"), "按文件名筛选")
        XCTAssertEqual(localized("Copy to Adjacent Pane", locale: "zh-Hans"), "复制到相邻窗格")
        XCTAssertEqual(localized("Move to Adjacent Pane", locale: "zh-Hans"), "移动到相邻窗格")
    }

    private func localized(_ key: String, locale identifier: String) -> String {
        guard let localizationURL = Bundle.main.url(
            forResource: identifier,
            withExtension: "lproj"
        ), let localizationBundle = Bundle(url: localizationURL) else {
            XCTFail("Missing bundled localization for \(identifier)")
            return key
        }

        return localizationBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}
