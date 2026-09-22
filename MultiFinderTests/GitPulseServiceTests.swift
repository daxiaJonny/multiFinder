import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class GitPulseServiceTests: XCTestCase {
    private var tempRepoURL: URL!
    private var gitStore: GitPulseStore!

    override func setUp() async throws {
        gitStore = GitPulseStore()

        tempRepoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitPulseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRepoURL, withIntermediateDirectories: true)

        try runGit(["init", "-b", "main"], in: tempRepoURL)
        try runGit(["config", "user.name", "TestUser"], in: tempRepoURL)
        try runGit(["config", "user.email", "test@example.com"], in: tempRepoURL)

        let testFile = tempRepoURL.appendingPathComponent("readme.txt")
        try "Hello World".write(to: testFile, atomically: true, encoding: .utf8)

        try runGit(["add", "readme.txt"], in: tempRepoURL)
        try runGit(["commit", "-m", "Initial test commit"], in: tempRepoURL)
    }

    override func tearDown() async throws {
        if let tempRepoURL = tempRepoURL {
            try? FileManager.default.removeItem(at: tempRepoURL)
        }
        gitStore = nil
    }

    @discardableResult
    private func runGit(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testFindRepoRootForProject() throws {
        let root = gitStore.findRepoRoot(for: tempRepoURL)
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.path, tempRepoURL.standardizedFileURL.path)

        // Nested directory should also find the root
        let nestedDir = tempRepoURL.appendingPathComponent("nested/deep/path")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedRoot = gitStore.findRepoRoot(for: nestedDir)
        XCTAssertEqual(nestedRoot?.path, tempRepoURL.standardizedFileURL.path)
    }

    func testFindRepoRootForNonRepoReturnsNil() {
        let nonRepoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NonRepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: nonRepoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepoDir) }

        let root = gitStore.findRepoRoot(for: nonRepoDir)
        XCTAssertNil(root)
    }

    func testFetchRecentCommitsReturnsHistory() async {
        let commits = await gitStore.fetchRecentCommits(for: tempRepoURL, maxCount: 3)
        XCTAssertFalse(commits.isEmpty)
        XCTAssertEqual(commits[0].summary, "Initial test commit")
        XCTAssertEqual(commits[0].author, "TestUser")
        XCTAssertFalse(commits[0].hash.isEmpty)
    }

    func testGitChangeLookupMatchesFilesDirectoriesQuotesAndRenames() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        let status = GitStatusInfo(
            repoRootURL: root,
            branch: "main",
            upstream: nil,
            aheadCount: 0,
            behindCount: 0,
            modifiedCount: 1,
            untrackedCount: 2,
            stagedCount: 0,
            changedFiles: [
                GitFileChange(path: "src/main.swift", type: .modified),
                GitFileChange(path: "\"docs/my notes.md\"", type: .untracked),
                GitFileChange(path: "old.txt -> new.txt", type: .renamed),
                GitFileChange(path: "vendor/", type: .untracked)
            ]
        )

        XCTAssertEqual(
            GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/src/main.swift"), status: status),
            .modified
        )
        XCTAssertEqual(
            GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/src", isDirectory: true), status: status),
            .modified
        )
        XCTAssertEqual(
            GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/docs/my notes.md"), status: status),
            .untracked
        )
        XCTAssertEqual(
            GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/new.txt"), status: status),
            .renamed
        )
        XCTAssertEqual(
            GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/vendor/lib.js"), status: status),
            .untracked
        )
        XCTAssertNil(GitChangeLookup.changeType(for: URL(fileURLWithPath: "/repo/README.md"), status: status))
        XCTAssertNil(GitChangeLookup.changeType(for: URL(fileURLWithPath: "/other/src/main.swift"), status: status))
    }
}
