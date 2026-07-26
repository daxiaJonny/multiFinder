import Foundation
import XCTest
@testable import MultiFinder

final class ExternalIntegrationTests: XCTestCase {
    func testExternalOpenRequestRoundTripsEncodedPath() throws {
        let target = URL(fileURLWithPath: "/tmp/MultiFinder/A & B")
        let requestURL = try XCTUnwrap(ExternalOpenRequest.url(for: target))

        let request = try XCTUnwrap(ExternalOpenRequest(url: requestURL))

        XCTAssertEqual(request.targetURL, target.standardizedFileURL)
    }

    func testExternalOpenRequestRejectsOtherURLs() {
        XCTAssertNil(ExternalOpenRequest(url: URL(string: "https://example.com")!))
        XCTAssertNil(ExternalOpenRequest(url: URL(string: "multifinder://open")!))
    }

    func testITermScriptEscapesPathAndCreatesATab() {
        let script = ITermService.script(forPath: #"/tmp/A "Quoted"\Folder"#)

        XCTAssertTrue(script.contains(#"\"Quoted\""#))
        XCTAssertTrue(script.contains(#"\\Folder"#))
        XCTAssertTrue(script.contains("create tab with default profile"))
        XCTAssertTrue(script.contains("quoted form of targetPath"))
        XCTAssertTrue(script.contains(ITermService.bundleIdentifier))
    }
}
