import Darwin
import Foundation
import XCTest
@testable import MultiFinder

final class FileMetadataServiceTests: XCTestCase {
    private var root: URL!
    private let service = FileMetadataService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiFinderMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testReadsFinderStyleMetadata() throws {
        let file = try makeFile(named: "report.txt", contents: "metadata")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

        let metadata = try service.metadata(for: file)

        XCTAssertEqual(metadata.url, file.standardizedFileURL)
        XCTAssertEqual(metadata.name, "report.txt")
        XCTAssertFalse(metadata.isDirectory)
        XCTAssertFalse(metadata.isSymbolicLink)
        XCTAssertFalse(metadata.isPackage)
        XCTAssertEqual(metadata.byteSize, 8)
        XCTAssertFalse(metadata.kind.isEmpty)
        XCTAssertNotNil(metadata.contentTypeIdentifier)
        XCTAssertNotNil(metadata.creationDate)
        XCTAssertNotNil(metadata.modificationDate)
        XCTAssertEqual(metadata.path, file.standardizedFileURL.path)
        XCTAssertFalse(metadata.ownerName.isEmpty)
        XCTAssertFalse(metadata.groupName.isEmpty)
        XCTAssertEqual(metadata.permissions.mode & 0o777, 0o640)
        XCTAssertEqual(metadata.permissions.symbolicString, "rw-r-----")
    }

    func testTagsRoundTripAndSanitizeBeforeWriting() throws {
        let file = try makeFile(named: "tagged.txt", contents: "tags")

        let updated = try service.setTags([" Blue ", "Review", "Blue", "  "], for: file)
        XCTAssertEqual(updated.tags, ["Blue", "Review"])
        XCTAssertEqual(try service.tags(for: file), ["Blue", "Review"])

        let cleared = try service.setTags([], for: file)
        XCTAssertTrue(cleared.tags.isEmpty)
        XCTAssertTrue(try service.tags(for: file).isEmpty)
    }

    func testPermissionParsingValidationAndWriteRoundTrip() throws {
        let file = try makeFile(named: "permissions.txt", contents: "permissions")

        XCTAssertEqual(try POSIXPermissions(octalString: "755").octalString, "0755")
        XCTAssertEqual(try POSIXPermissions(octalString: "755").symbolicString, "rwxr-xr-x")
        XCTAssertEqual(try POSIXPermissions(octalString: "4755").symbolicString, "rwsr-xr-x")
        XCTAssertThrowsError(try POSIXPermissions(octalString: "0899")) { error in
            XCTAssertTrue(error is FileMetadataError)
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }

        _ = try service.setPOSIXPermissions("0640", for: file)
        XCTAssertEqual(try service.permissions(for: file).mode & 0o777, 0o640)

        XCTAssertThrowsError(try service.setPOSIXPermissions("0899", for: file))
        XCTAssertEqual(try service.permissions(for: file).mode & 0o777, 0o640)

        _ = try service.setPOSIXPermissions("0751", for: file)
        XCTAssertEqual(try service.permissions(for: file).mode & 0o777, 0o751)
    }

    func testBatchWritesApplyToEverySelectedItem() throws {
        let first = try makeFile(named: "first.txt", contents: "first")
        let second = try makeFile(named: "second.txt", contents: "second")

        let tagged = try service.setTags(["Shared"], for: [first, second])
        XCTAssertEqual(tagged.map(\.tags), [["Shared"], ["Shared"]])

        let permissions = try POSIXPermissions(octalString: "0600")
        _ = try service.setPOSIXPermissions(permissions, for: [first, second])
        XCTAssertEqual(try service.permissions(for: first), permissions)
        XCTAssertEqual(try service.permissions(for: second), permissions)
    }

    func testSymlinkMetadataIsReadWithoutAllowingWritesToItsTarget() throws {
        let target = try makeFile(named: "target.txt", contents: "target")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let metadata = try service.metadata(for: link)
        XCTAssertTrue(metadata.isSymbolicLink)
        XCTAssertFalse(metadata.isDirectory)
        XCTAssertEqual(metadata.symbolicLinkDestination, target.path)
        XCTAssertThrowsError(try service.setTags(["link"], for: link)) { error in
            XCTAssertTrue(error is FileMetadataError)
        }
        XCTAssertThrowsError(try service.setPOSIXPermissions("0600", for: link)) { error in
            XCTAssertTrue(error is FileMetadataError)
        }
        XCTAssertTrue(try service.tags(for: target).isEmpty)
    }

    func testMissingItemReturnsLocalizedError() throws {
        let missing = root.appendingPathComponent("missing.txt")

        XCTAssertThrowsError(try service.metadata(for: missing)) { error in
            guard let metadataError = error as? FileMetadataError else {
                return XCTFail("Expected FileMetadataError, got \(error)")
            }
            XCTAssertFalse(metadataError.localizedDescription.isEmpty)
            XCTAssertFalse(metadataError.errorDescription?.isEmpty ?? true)
        }
    }

    private func makeFile(named name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
