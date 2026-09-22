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
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: errorData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitPulseServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(error)"]
            )
        }
        return output
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

    func testStatusAndChangeIndexAreCachedPerViewedDirectory() async throws {
        let root = tempRepoURL.standardizedFileURL
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let note = nested.appendingPathComponent("note.txt")
        try "Note".write(to: note, atomically: true, encoding: .utf8)
        try runGit(["add", "nested/note.txt"], in: root)
        try runGit(["commit", "-m", "Add note"], in: root)
        try "Changed note".write(to: note, atomically: true, encoding: .utf8)
        try "Changed".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let spaced = root.appendingPathComponent("my notes")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let todo = spaced.appendingPathComponent("todo.md")
        try "Todo".write(to: todo, atomically: true, encoding: .utf8)

        XCTAssertEqual(gitStore.findRepoRoot(for: nested)?.standardizedFileURL.path, root.path)
        XCTAssertEqual(gitStore.findRepoRoot(for: spaced)?.standardizedFileURL.path, root.path)

        gitStore.refresh(for: root, force: true)
        gitStore.refresh(for: nested, force: true)
        gitStore.refresh(for: spaced, force: true)

        let rootStatus = try await waitForCachedStatus(at: root) {
            let paths = self.normalizedChangePaths($0)
            return paths.contains("my notes") || paths.contains("my notes/todo.md")
        }
        let nestedStatus = try await waitForCachedStatus(at: nested)
        let spacedStatus = try await waitForCachedStatus(at: spaced) {
            let paths = self.normalizedChangePaths($0)
            return paths.contains("my notes") || paths.contains("my notes/todo.md")
        }

        XCTAssertEqual(rootStatus.repoRootURL.standardizedFileURL.path, root.path)
        XCTAssertEqual(nestedStatus.repoRootURL.standardizedFileURL.path, root.path)
        XCTAssertEqual(spacedStatus.repoRootURL.standardizedFileURL.path, root.path)

        let rootPaths = normalizedChangePaths(rootStatus)
        let nestedPaths = normalizedChangePaths(nestedStatus)
        let spacedPaths = normalizedChangePaths(spacedStatus)

        XCTAssertTrue(rootPaths.contains("readme.txt"))
        XCTAssertTrue(rootPaths.contains("nested/note.txt"))
        XCTAssertTrue(rootPaths.contains("my notes") || rootPaths.contains("my notes/todo.md"))
        XCTAssertTrue(nestedPaths.contains("nested/note.txt"))
        XCTAssertFalse(nestedPaths.contains("readme.txt"))
        XCTAssertFalse(nestedPaths.contains("my notes") || nestedPaths.contains("my notes/todo.md"))
        XCTAssertTrue(spacedPaths.contains("my notes") || spacedPaths.contains("my notes/todo.md"))
        XCTAssertFalse(spacedPaths.contains("readme.txt"))
        XCTAssertFalse(spacedPaths.contains("nested/note.txt"))

        let rootIndex = gitStore.changeIndex(for: root)
        let nestedIndex = gitStore.changeIndex(for: nested)
        let spacedIndex = gitStore.changeIndex(for: spaced)
        XCTAssertEqual(rootIndex?.changeType(for: root.appendingPathComponent("readme.txt")), .modified)
        XCTAssertEqual(rootIndex?.changeType(for: note), .modified)
        XCTAssertEqual(nestedIndex?.changeType(for: note), .modified)
        XCTAssertNil(nestedIndex?.changeType(for: root.appendingPathComponent("readme.txt")))
        XCTAssertEqual(spacedIndex?.changeType(for: todo), .untracked)
        XCTAssertNil(spacedIndex?.changeType(for: note))
        XCTAssertNotEqual(rootIndex, nestedIndex)
        XCTAssertNotEqual(rootIndex, spacedIndex)

        gitStore.refresh(for: root, force: true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let nestedAfterRefresh = try await waitForCachedStatus(at: nested)
        let rootAfterRefresh = try await waitForCachedStatus(at: root)
        XCTAssertTrue(normalizedChangePaths(nestedAfterRefresh).contains("nested/note.txt"))
        XCTAssertFalse(normalizedChangePaths(nestedAfterRefresh).contains("readme.txt"))
        XCTAssertTrue(normalizedChangePaths(rootAfterRefresh).contains("readme.txt"))
        XCTAssertTrue(normalizedChangePaths(rootAfterRefresh).contains("nested/note.txt"))
    }

    private func waitForCachedStatus(
        at url: URL,
        matching predicate: (GitStatusInfo) -> Bool = { _ in true }
    ) async throws -> GitStatusInfo {
        let key = url.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let status = gitStore.cache[key], predicate(status) {
                return status
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Timed out waiting for git status at \(key)")
        throw CocoaError(.userCancelled)
    }

    private func normalizedChangePaths(_ status: GitStatusInfo?) -> Set<String> {
        Set((status?.changedFiles ?? []).map { GitChangeLookup.normalizedPath($0.path) })
    }
}
