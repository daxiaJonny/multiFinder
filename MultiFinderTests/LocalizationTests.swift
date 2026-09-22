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

    func testCatalogCoversFinderStyleSurfaces() {
        XCTAssertEqual(localized("Overview", locale: "zh-Hans"), "概览")
        XCTAssertEqual(localized("Permissions", locale: "zh-Hans"), "权限")
        XCTAssertEqual(localized("Icons", locale: "zh-Hans"), "图标")
        XCTAssertEqual(localized("Columns", locale: "zh-Hans"), "分栏")
        XCTAssertEqual(localized("Gallery", locale: "zh-Hans"), "画廊")
        XCTAssertEqual(localized("Duplicate", locale: "zh-Hans"), "制作副本")
        XCTAssertEqual(localized("Close Pane", locale: "zh-Hans"), "关闭窗格")
        XCTAssertEqual(localized("Quick Look", locale: "zh-Hans"), "快速查看")
        XCTAssertEqual(localized("Sort By", locale: "zh-Hans"), "排序方式")
        XCTAssertEqual(localized("Sort Direction", locale: "zh-Hans"), "排序方向")
        XCTAssertEqual(localized("iCloud Drive", locale: "zh-Hans"), "iCloud 云盘")
        XCTAssertEqual(localized("Done", locale: "zh-Hans"), "完成")
        XCTAssertEqual(localized("Eject %@", locale: "zh-Hans"), "推出 %@")
        XCTAssertEqual(localized("Ejecting %@...", locale: "zh-Hans"), "正在推出 %@…")
        XCTAssertEqual(localized("Hide Sidebar", locale: "zh-Hans"), "隐藏边栏")
        XCTAssertEqual(localized("Go to Folder…", locale: "zh-Hans"), "前往文件夹…")
    }

    func testCatalogFormatsFinderStyleProgress() {
        let locale = Locale(identifier: "zh-Hans")
        let format = localized("%lld items inspected", locale: "zh-Hans")

        XCTAssertEqual(
            String(format: format, locale: locale, arguments: [Int64(12)]),
            "已检查 12 个项目"
        )
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
