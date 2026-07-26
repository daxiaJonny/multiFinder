import Foundation

enum CursorCLIPlannerError: LocalizedError, Equatable {
    case notInstalled
    case timedOut
    case processFailed(String)
    case unparseableOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The Cursor CLI (agent) is not installed. Install it or set its path in Settings."
        case .timedOut:
            return "The AI planner took too long to respond and was stopped."
        case .processFailed(let message):
            return message.isEmpty
                ? "The AI planner exited with an error."
                : "The AI planner failed: \(message)"
        case .unparseableOutput(let message):
            return message.isEmpty
                ? "The AI response could not be understood."
                : "The AI response could not be understood: \(message)"
        }
    }
}

final class CursorCLIPlanner: AIPlanner {
    static let shared = CursorCLIPlanner()
    static let executablePathDefaultsKey = "AIPlannerExecutablePath"

    private let executableURL: URL
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 120) {
        self.executableURL = executableURL ?? Self.resolveExecutableURL()
        self.timeout = timeout
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func plan(_ request: AIPlanRequest) async throws -> AIPlan {
        guard isAvailable else { throw CursorCLIPlannerError.notInstalled }

        let today = Date.now
        let firstOutput = try await run(prompt: Self.prompt(for: request, today: today), in: request.scopeRoot)
        let firstError: AIPlanParseError
        do {
            return try Self.parsePlan(fromCLIOutput: firstOutput)
        } catch let error as AIPlanParseError {
            firstError = error
        }

        let retryPrompt = Self.retryPrompt(
            for: request,
            today: today,
            previousOutput: firstOutput,
            parseError: firstError
        )
        let secondOutput = try await run(prompt: retryPrompt, in: request.scopeRoot)
        do {
            return try Self.parsePlan(fromCLIOutput: secondOutput)
        } catch let error as AIPlanParseError {
            throw CursorCLIPlannerError.unparseableOutput(error.message)
        }
    }

    private static func resolveExecutableURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: executablePathDefaultsKey),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/agent")
    }

    // MARK: - Prompt

    static func prompt(for request: AIPlanRequest, today: Date) -> String {
        """
        You are the planning backend of a macOS file manager. Today's date is \
        \(AISearchCriteria.isoDayString(from: today)); resolve relative dates like \
        "last month" against it.

        Scope root: \(request.scopeRoot.standardizedFileURL.path)
        Every path in your output must be RELATIVE to the scope root and must stay \
        inside it. Never output absolute paths, "~", or "..".

        User request: \(request.instruction)

        Answer with a single JSON object following exactly this contract:
        {
          "kind": "search" or "organize",
          "summary": "one short sentence describing the plan for the user",
          "search": { ... },      // required when kind is "search", omitted otherwise
          "operations": [ ... ]   // required when kind is "organize", omitted otherwise
        }

        "search" is a criteria object with these optional fields:
        - "nameContains": array of file-name substrings, matched as OR
        - "extensions": array of file extensions without the dot, e.g. ["png", "jpg"]
        - "modifiedAfter", "modifiedBefore": ISO dates formatted "YYYY-MM-DD"
        - "minSize", "maxSize": sizes in bytes
        - "recursive": boolean, whether to search subfolders

        "operations" is an array whose entries take exactly one of these five forms:
        {"op": "createFolder", "path": "relative/folder"}
        {"op": "move", "source": "relative/file", "destination": "relative/target/file"}
        {"op": "copy", "source": "relative/file", "destination": "relative/target/file"}
        {"op": "rename", "source": "relative/file", "newName": "new-file-name-only"}
        {"op": "trash", "source": "relative/file"}

        Rules:
        - If the request is about finding files, use kind "search" and return only \
        the criteria. Do NOT list matching files; the app runs the search itself.
        - If the request is about organizing files, use kind "organize", inspect the \
        directory, and enumerate one concrete operation per affected file. No \
        wildcards, no shell commands, no placeholders.
        - "destination" must include the target file name, and "newName" is a bare \
        file name without any path.
        - Your final answer must be ONLY the JSON object itself: no markdown code \
        fences, no explanations, no text before or after it.
        """
    }

    static func retryPrompt(
        for request: AIPlanRequest,
        today: Date,
        previousOutput: String,
        parseError: AIPlanParseError
    ) -> String {
        let truncated = String(previousOutput.prefix(4000))
        return prompt(for: request, today: today) + """


        Your previous response could not be parsed.
        Parse error: \(parseError.message)
        Previous response:
        \(truncated)

        Correct the response now. Reply with ONLY the valid JSON plan object and \
        nothing else.
        """
    }

    // MARK: - Output handling

    static func parsePlan(fromCLIOutput output: String) throws -> AIPlan {
        var lastError: AIPlanParseError
        do {
            return try AIPlan.parse(from: output)
        } catch let error as AIPlanParseError {
            lastError = error
        }

        for candidate in assistantTextCandidates(in: output) {
            do {
                return try AIPlan.parse(from: candidate)
            } catch let error as AIPlanParseError {
                lastError = error
            }
        }
        throw lastError
    }

    private static let envelopeTextKeys = [
        "result", "text", "content", "message", "response", "output", "data", "answer"
    ]

    private static func assistantTextCandidates(in output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var documents: [String] = []
        if trimmed.hasPrefix("{") {
            documents.append(trimmed)
        }
        for line in trimmed.split(separator: "\n") {
            let lineText = line.trimmingCharacters(in: .whitespaces)
            if lineText.hasPrefix("{") && lineText != trimmed {
                documents.append(lineText)
            }
        }

        var candidates: [String] = []
        for document in documents {
            guard let object = try? JSONSerialization.jsonObject(with: Data(document.utf8)) else {
                continue
            }
            collectStrings(from: object, into: &candidates)
        }
        return candidates
    }

    private static func collectStrings(from value: Any, into candidates: inout [String]) {
        if let text = value as? String {
            if text.contains("{") && !candidates.contains(text) {
                candidates.append(text)
            }
        } else if let dictionary = value as? [String: Any] {
            var remaining = dictionary
            for key in envelopeTextKeys {
                if let nested = remaining.removeValue(forKey: key) {
                    collectStrings(from: nested, into: &candidates)
                }
            }
            for key in remaining.keys.sorted() {
                if let nested = remaining[key] {
                    collectStrings(from: nested, into: &candidates)
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                collectStrings(from: element, into: &candidates)
            }
        }
    }

    // MARK: - Process

    private func run(prompt: String, in scopeRoot: URL) async throws -> String {
        let executableURL = executableURL
        let timeout = timeout
        let worker = Task.detached(priority: .userInitiated) {
            try Self.runProcess(
                executableURL: executableURL,
                prompt: prompt,
                currentDirectory: scopeRoot,
                timeout: timeout
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runProcess(
        executableURL: URL,
        prompt: String,
        currentDirectory: URL,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-p", "--mode", "plan", "--trust", "--output-format", "json", prompt]
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputReader = PipeReader(outputPipe)
        let errorReader = PipeReader(errorPipe)

        do {
            try process.run()
        } catch {
            throw CursorCLIPlannerError.processFailed(error.localizedDescription)
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                throw CursorCLIPlannerError.timedOut
            }
            usleep(50_000)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = errorReader.drain().trimmingCharacters(in: .whitespacesAndNewlines)
            throw CursorCLIPlannerError.processFailed(
                message.isEmpty ? "exit code \(process.terminationStatus)" : message
            )
        }
        return outputReader.drain()
    }

    private final class PipeReader: @unchecked Sendable {
        private let group = DispatchGroup()
        private var data = Data()

        init(_ pipe: Pipe) {
            let handle = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                data = handle.readDataToEndOfFile()
                group.leave()
            }
        }

        func drain() -> String {
            group.wait()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
