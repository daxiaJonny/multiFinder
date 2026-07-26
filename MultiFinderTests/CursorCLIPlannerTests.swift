import Foundation
import XCTest
@testable import MultiFinder

final class CursorCLIPlannerTests: XCTestCase {
    private var tempDir: URL!
    private var scopeRoot: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorCLIPlannerTests-\(UUID().uuidString)")
        scopeRoot = tempDir.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scopeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var request: AIPlanRequest {
        AIPlanRequest(instruction: "tidy up the downloads", scopeRoot: scopeRoot)
    }

    private func makeScript(_ body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("agent-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let organizePlanJSON = """
    {"kind": "organize", "summary": "clean", "operations": [{"op": "trash", "source": "junk.tmp"}]}
    """

    func testPlansFromCleanJSONOutput() async throws {
        let capture = tempDir.appendingPathComponent("prompt.txt")
        let script = try makeScript("""
        for a in "$@"; do LAST="$a"; done
        printf '%s' "$LAST" > '\(capture.path)'
        cat <<'JSON'
        \(Self.organizePlanJSON)
        JSON
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        let plan = try await planner.plan(request)

        XCTAssertEqual(plan.kind, .organize)
        XCTAssertEqual(plan.summary, "clean")
        XCTAssertEqual(plan.operations, [.trash(source: "junk.tmp")])

        let prompt = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(prompt.contains("tidy up the downloads"))
        XCTAssertTrue(prompt.contains(scopeRoot.standardizedFileURL.path))
        XCTAssertTrue(prompt.contains(AISearchCriteria.isoDayString(from: .now)))
        XCTAssertTrue(prompt.contains("ONLY the JSON object"))
    }

    func testPassesPlanModeAndJSONOutputFlags() async throws {
        let capture = tempDir.appendingPathComponent("args.txt")
        let script = try makeScript("""
        printf '%s\\n' "$@" > '\(capture.path)'
        cat <<'JSON'
        \(Self.organizePlanJSON)
        JSON
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        _ = try await planner.plan(request)

        let lines = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(5)), ["-p", "--mode", "plan", "--output-format", "json"])
        XCTAssertTrue(lines.dropFirst(5).joined(separator: "\n").contains("User request:"))
    }

    func testPlansFromEnvelopeWrappedOutput() async throws {
        let script = try makeScript("""
        cat <<'JSON'
        {"type": "result", "subtype": "success", "is_error": false, "duration_ms": 1200, "result": "{\\"kind\\": \\"search\\", \\"summary\\": \\"find pdfs\\", \\"search\\": {\\"extensions\\": [\\"pdf\\"], \\"recursive\\": true}}", "session_id": "abc123"}
        JSON
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        let plan = try await planner.plan(request)

        XCTAssertEqual(plan.kind, .search)
        XCTAssertEqual(plan.summary, "find pdfs")
        XCTAssertEqual(plan.search?.extensions, ["pdf"])
        XCTAssertEqual(plan.search?.recursive, true)
    }

    func testPlansFromEnvelopeWithNestedMessageContent() async throws {
        let script = try makeScript("""
        cat <<'JSON'
        {"message": {"role": "assistant", "content": [{"type": "text", "text": "{\\"kind\\": \\"organize\\", \\"summary\\": \\"clean\\", \\"operations\\": [{\\"op\\": \\"move\\", \\"source\\": \\"a.png\\", \\"destination\\": \\"pics/a.png\\"}]}"}]}}
        JSON
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        let plan = try await planner.plan(request)

        XCTAssertEqual(plan.operations, [.move(source: "a.png", destination: "pics/a.png")])
    }

    func testPlansFromMarkdownFencedOutput() async throws {
        let script = try makeScript("""
        cat <<'JSON'
        Here is your plan:
        ```json
        \(Self.organizePlanJSON)
        ```
        JSON
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        let plan = try await planner.plan(request)

        XCTAssertEqual(plan.kind, .organize)
        XCTAssertEqual(plan.operations, [.trash(source: "junk.tmp")])
    }

    func testRetriesOnceAfterUnparseableOutput() async throws {
        let state = tempDir.appendingPathComponent("state")
        let capture = tempDir.appendingPathComponent("retry-prompt.txt")
        let script = try makeScript("""
        if [ -f '\(state.path)' ]; then
          for a in "$@"; do LAST="$a"; done
          printf '%s' "$LAST" > '\(capture.path)'
          cat <<'JSON'
        \(Self.organizePlanJSON)
        JSON
        else
          touch '\(state.path)'
          echo 'sorry, no plan here'
        fi
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        let plan = try await planner.plan(request)

        XCTAssertEqual(plan.operations, [.trash(source: "junk.tmp")])
        let retryPrompt = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(retryPrompt.contains("Parse error:"))
        XCTAssertTrue(retryPrompt.contains("sorry, no plan here"))
    }

    func testThrowsUnparseableOutputAfterFailedRetry() async throws {
        let count = tempDir.appendingPathComponent("count")
        let script = try makeScript("""
        echo x >> '\(count.path)'
        echo 'still not json'
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        do {
            _ = try await planner.plan(request)
            XCTFail("Expected an unparseableOutput error")
        } catch let error as CursorCLIPlannerError {
            guard case .unparseableOutput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertNotNil(error.errorDescription)
        }

        let invocations = try String(contentsOf: count, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(invocations, 2)
    }

    func testThrowsProcessFailedWithStderr() async throws {
        let script = try makeScript("""
        echo 'boom: not logged in' >&2
        exit 3
        """)
        let planner = CursorCLIPlanner(executableURL: script)

        do {
            _ = try await planner.plan(request)
            XCTFail("Expected a processFailed error")
        } catch let error as CursorCLIPlannerError {
            guard case .processFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("boom: not logged in"))
        }
    }

    func testTimesOutAndTerminatesProcess() async throws {
        let script = try makeScript("exec /bin/sleep 30")
        let planner = CursorCLIPlanner(executableURL: script, timeout: 0.5)

        let start = Date()
        do {
            _ = try await planner.plan(request)
            XCTFail("Expected a timedOut error")
        } catch let error as CursorCLIPlannerError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellationTerminatesProcess() async throws {
        let script = try makeScript("exec /bin/sleep 30")
        let planner = CursorCLIPlanner(executableURL: script, timeout: 60)
        let request = request

        let start = Date()
        let task = Task { try await planner.plan(request) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testIsAvailableReflectsExecutable() async throws {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let missingPlanner = CursorCLIPlanner(executableURL: missing)
        XCTAssertFalse(missingPlanner.isAvailable)

        do {
            _ = try await missingPlanner.plan(request)
            XCTFail("Expected a notInstalled error")
        } catch let error as CursorCLIPlannerError {
            XCTAssertEqual(error, .notInstalled)
        }

        let script = try makeScript("echo hi")
        XCTAssertTrue(CursorCLIPlanner(executableURL: script).isAvailable)

        let plain = tempDir.appendingPathComponent("not-executable.txt")
        try "text".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertFalse(CursorCLIPlanner(executableURL: plain).isAvailable)
    }
}
