import Foundation

public struct GitFileChange: Identifiable, Equatable, Sendable {
    public enum ChangeType: String, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case untracked = "?"
        case renamed = "R"
        case other = "•"
    }

    public let id: String
    public let path: String
    public let type: ChangeType

    public init(path: String, type: ChangeType) {
        self.id = path
        self.path = path
        self.type = type
    }
}

public struct GitCommitInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let hash: String
    public let author: String
    public let relativeTime: String
    public let summary: String

    public init(hash: String, author: String, relativeTime: String, summary: String) {
        self.id = hash
        self.hash = hash
        self.author = author
        self.relativeTime = relativeTime
        self.summary = summary
    }
}

public struct GitStatusInfo: Equatable, Sendable {
    public let repoRootURL: URL
    public let branch: String
    public let upstream: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let modifiedCount: Int
    public let untrackedCount: Int
    public let stagedCount: Int
    public let changedFiles: [GitFileChange]

    public var totalChanges: Int {
        modifiedCount + untrackedCount + stagedCount
    }

    public var isClean: Bool {
        totalChanges == 0
    }

    public var badgeTitle: String {
        if branch.isEmpty { return "HEAD" }
        return branch
    }
}

@MainActor
public final class GitPulseStore: ObservableObject {
    public static let shared = GitPulseStore()

    @Published public private(set) var cache: [String: GitStatusInfo] = [:]
    private var inFlightPaths: Set<String> = []
    private var nonRepoPaths: Set<String> = []
    private var repoRootByDirectory: [String: URL] = [:]
    private var changeIndexes: [String: GitChangeIndex] = [:]
    private var lastCheckTime: [String: Date] = [:]

    public init() {}

    /// Returns the cached GitStatusInfo for a given directory, or initiates a background fetch.
    public func status(for url: URL?) -> GitStatusInfo? {
        guard let url = url?.standardizedFileURL else { return nil }
        guard let repoRoot = findRepoRoot(for: url) else { return nil }

        let key = repoRoot.path
        let isStale = lastCheckTime[key].map { Date().timeIntervalSince($0) > 5.0 } ?? true
        if cache[key] == nil || isStale {
            refresh(for: repoRoot)
        }
        return cache[key]
    }

    /// One index for the whole directory. Views must reuse it across rows.
    func changeIndex(for url: URL?) -> GitChangeIndex? {
        guard let status = status(for: url) else { return nil }
        let key = status.repoRootURL.path
        if let index = changeIndexes[key] {
            return index
        }
        let index = GitChangeIndex(status: status)
        changeIndexes[key] = index
        return index
    }

    /// Explicitly refreshes the status for the given repository or child directory.
    public func refresh(for url: URL?, force: Bool = false) {
        guard let url = url?.standardizedFileURL else { return }
        guard let repoRoot = findRepoRoot(for: url) else { return }

        let key = repoRoot.path
        guard !inFlightPaths.contains(key) || force else { return }

        inFlightPaths.insert(key)
        lastCheckTime[key] = Date()

        Task.detached(priority: .userInitiated) { [weak self, repoRoot, key] in
            let status = await Self.queryGitStatus(at: repoRoot)
            await MainActor.run {
                guard let self = self else { return }
                self.inFlightPaths.remove(key)
                guard let status else { return }
                guard self.cache[key] != status else { return }
                self.cache[key] = status
                self.changeIndexes[key] = GitChangeIndex(status: status)
            }
        }
    }

    /// Fetches the last N commits for the repository.
    public func fetchRecentCommits(for repoRoot: URL, maxCount: Int = 5) async -> [GitCommitInfo] {
        await Task.detached(priority: .userInitiated) {
            let format = "%h|%an|%cr|%s"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["log", "-n", "\(maxCount)", "--format=\(format)"]
            process.currentDirectoryURL = repoRoot
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return [] }

                var commits: [GitCommitInfo] = []
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let parts = trimmed.components(separatedBy: "|")
                    if parts.count >= 4 {
                        commits.append(GitCommitInfo(
                            hash: parts[0],
                            author: parts[1],
                            relativeTime: parts[2],
                            summary: parts[3...].joined(separator: "|")
                        ))
                    }
                }
                return commits
            } catch {
                return []
            }
        }.value
    }

    // MARK: - Fast Root Finder

    /// Traverses upwards to locate `.git` directory or file (for worktrees).
    public func findRepoRoot(for url: URL) -> URL? {
        let start = url.standardizedFileURL
        if let cached = repoRootByDirectory[start.path] {
            return cached
        }
        if nonRepoPaths.contains(start.path) {
            return nil
        }

        var current = start
        var visited: [URL] = []
        while current.path != "/" && current.pathComponents.count > 1 {
            if let cached = repoRootByDirectory[current.path] {
                rememberRepoRoot(cached, for: visited)
                return cached
            }
            visited.append(current)
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                rememberRepoRoot(current, for: visited)
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        for directory in visited {
            nonRepoPaths.insert(directory.path)
        }
        return nil
    }

    private func rememberRepoRoot(_ root: URL, for directories: [URL]) {
        for directory in directories {
            repoRootByDirectory[directory.path] = root
        }
    }

    // MARK: - Background Worker

    private static func queryGitStatus(at repoRoot: URL) async -> GitStatusInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain=v1", "-b"]
        process.currentDirectoryURL = repoRoot
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date(timeIntervalSinceNow: 2.0)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    return nil
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }

            return parsePorcelainStatus(raw, repoRoot: repoRoot)
        } catch {
            return nil
        }
    }

    private static func parsePorcelainStatus(_ raw: String, repoRoot: URL) -> GitStatusInfo {
        var branch = "HEAD"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var modified = 0
        var untracked = 0
        var staged = 0
        var changes: [GitFileChange] = []

        let lines = raw.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("## ") {
                // Branch line, e.g. "## theme_v2...origin/theme_v2 [ahead 1, behind 2]" or "## Initial commit on main"
                let branchSpec = String(trimmed.dropFirst(3))
                if branchSpec.contains("...") {
                    let parts = branchSpec.components(separatedBy: "...")
                    branch = parts[0]
                    if parts.count > 1 {
                        let rest = parts[1]
                        if let bracketStart = rest.firstIndex(of: "["),
                           let bracketEnd = rest.firstIndex(of: "]") {
                            upstream = String(rest[..<bracketStart]).trimmingCharacters(in: .whitespaces)
                            let countsStr = String(rest[rest.index(after: bracketStart)..<bracketEnd])
                            for chunk in countsStr.components(separatedBy: ",") {
                                let pair = chunk.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                                if pair.count == 2 {
                                    if pair[0] == "ahead", let val = Int(pair[1]) { ahead = val }
                                    if pair[0] == "behind", let val = Int(pair[1]) { behind = val }
                                }
                            }
                        } else {
                            upstream = rest.trimmingCharacters(in: .whitespaces)
                        }
                    }
                } else {
                    let parts = branchSpec.components(separatedBy: " ")
                    branch = parts.first ?? "HEAD"
                }
                continue
            }

            guard line.count >= 2 else { continue }
            let indexCode = line[line.startIndex]
            let workTreeCode = line[line.index(after: line.startIndex)]
            let filePath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)

            if indexCode == "?" && workTreeCode == "?" {
                untracked += 1
                changes.append(GitFileChange(path: filePath, type: .untracked))
            } else {
                if indexCode != " " && indexCode != "?" {
                    staged += 1
                    let type: GitFileChange.ChangeType = (indexCode == "A") ? .added : (indexCode == "D" ? .deleted : .modified)
                    changes.append(GitFileChange(path: filePath, type: type))
                }
                if workTreeCode != " " && workTreeCode != "?" {
                    modified += 1
                    let type: GitFileChange.ChangeType = (workTreeCode == "D") ? .deleted : .modified
                    if !changes.contains(where: { $0.path == filePath }) {
                        changes.append(GitFileChange(path: filePath, type: type))
                    }
                }
            }
        }

        return GitStatusInfo(
            repoRootURL: repoRoot,
            branch: branch,
            upstream: upstream,
            aheadCount: ahead,
            behindCount: behind,
            modifiedCount: modified,
            untrackedCount: untracked,
            stagedCount: staged,
            changedFiles: changes
        )
    }
}

struct GitChangeIndex: Equatable {
    private let repoRoot: URL
    private let exact: [String: GitFileChange.ChangeType]
    private let containers: [String: GitFileChange.ChangeType]

    init(status: GitStatusInfo) {
        repoRoot = status.repoRootURL
        var exact: [String: GitFileChange.ChangeType] = [:]
        var containers: [String: GitFileChange.ChangeType] = [:]
        exact.reserveCapacity(status.changedFiles.count)
        for change in status.changedFiles {
            let path = GitChangeLookup.normalizedPath(change.path)
            guard !path.isEmpty else { continue }
            exact[path] = GitChangeLookup.preferred(existing: exact[path], candidate: change.type)
            var parent = (path as NSString).deletingLastPathComponent
            while parent != ".", !parent.isEmpty {
                containers[parent] = GitChangeLookup.preferred(existing: containers[parent], candidate: change.type)
                let next = (parent as NSString).deletingLastPathComponent
                if next == parent { break }
                parent = next
            }
        }
        self.exact = exact
        self.containers = containers
    }

    func changeType(for itemURL: URL) -> GitFileChange.ChangeType? {
        guard let relative = GitChangeLookup.relativePath(of: itemURL, to: repoRoot), !relative.isEmpty else {
            return nil
        }
        if let match = exact[relative] {
            return match
        }
        var parent = (relative as NSString).deletingLastPathComponent
        while parent != ".", !parent.isEmpty {
            if let match = exact[parent] {
                return match
            }
            let next = (parent as NSString).deletingLastPathComponent
            if next == parent { break }
            parent = next
        }
        return containers[relative]
    }
}

enum GitChangeLookup {
    static func changeType(for itemURL: URL, status: GitStatusInfo?) -> GitFileChange.ChangeType? {
        guard let status else { return nil }
        return GitChangeIndex(status: status).changeType(for: itemURL)
    }

    static func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let arrow = path.range(of: " -> ") {
            path = String(path[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path = String(path.dropFirst().dropLast())
            path = path
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func relativePath(of url: URL, to repoRoot: URL) -> String? {
        let root = repoRoot.standardizedFileURL
        let item = url.standardizedFileURL
        if item == root { return "" }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard item.path.hasPrefix(prefix) else { return nil }
        return String(item.path.dropFirst(prefix.count))
    }

    static func preferred(
        existing: GitFileChange.ChangeType?,
        candidate: GitFileChange.ChangeType
    ) -> GitFileChange.ChangeType {
        guard let existing else { return candidate }
        let rank: [GitFileChange.ChangeType] = [.modified, .added, .renamed, .deleted, .untracked, .other]
        let existingRank = rank.firstIndex(of: existing) ?? rank.count
        let candidateRank = rank.firstIndex(of: candidate) ?? rank.count
        return candidateRank < existingRank ? candidate : existing
    }
}
