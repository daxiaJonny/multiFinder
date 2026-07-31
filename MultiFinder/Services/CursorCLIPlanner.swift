import Foundation

enum CursorCLIPlannerError: LocalizedError, Equatable {
    case notInstalled
    case timedOut
    case processFailed(String)
    case unparseableOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return L10n.string(
                "Cursor CLI (agent) is not installed. Install it or set its path in Settings."
            )
        case .timedOut:
            return L10n.string("The AI response timed out, so this task was stopped.")
        case .processFailed(let message):
            return message.isEmpty
                ? L10n.string("AI encountered an error.")
                : L10n.format("AI failed: %@", message)
        case .unparseableOutput(let message):
            return message.isEmpty
                ? L10n.string("The AI response could not be understood.")
                : L10n.format("The AI response could not be understood: %@", message)
        }
    }
}

// UserDefaults supports concurrent reads; its SDK declaration does not yet conform to Sendable.
final class CursorCLIPlanner: @unchecked Sendable, AIPlanner, AIQuestionAnswering {
    static let shared = CursorCLIPlanner()
    static let executablePathDefaultsKey = AppSettings.cursorCLIExecutablePathDefaultsKey

    private let executableURLOverride: URL?
    private let userDefaults: UserDefaults
    private let timeout: TimeInterval

    init(
        executableURL: URL? = nil,
        timeout: TimeInterval = 120,
        userDefaults: UserDefaults = .standard
    ) {
        executableURLOverride = executableURL
        self.userDefaults = userDefaults
        self.timeout = timeout
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: currentExecutableURL.path)
    }

    func plan(_ request: AIPlanRequest) async throws -> AIPlan {
        let executableURL = currentExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CursorCLIPlannerError.notInstalled
        }

        let today = Date.now
        let firstOutput = try await run(
            prompt: Self.prompt(for: request, today: today),
            in: request.scopeRoot,
            mode: "plan",
            outputFormat: "json",
            executableURL: executableURL
        )
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
        let secondOutput = try await run(
            prompt: retryPrompt,
            in: request.scopeRoot,
            mode: "plan",
            outputFormat: "json",
            executableURL: executableURL
        )
        do {
            return try Self.parsePlan(fromCLIOutput: secondOutput)
        } catch let error as AIPlanParseError {
            throw CursorCLIPlannerError.unparseableOutput(error.message)
        }
    }

    func answer(_ request: AIAssistantRequest) async throws -> String {
        let executableURL = currentExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CursorCLIPlannerError.notInstalled
        }
        let output = try await run(
            prompt: Self.answerPrompt(for: request),
            in: request.scopeRoot,
            mode: "ask",
            outputFormat: "text",
            executableURL: executableURL
        )
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw CursorCLIPlannerError.unparseableOutput(
                L10n.string("AI returned an empty response.")
            )
        }
        return answer
    }

    private var currentExecutableURL: URL {
        executableURLOverride ?? Self.resolveExecutableURL(userDefaults: userDefaults)
    }

    static func resolveExecutableURL(userDefaults: UserDefaults = .standard) -> URL {
        AppSettings.resolvedCursorCLIExecutableURL(
            from: userDefaults.string(forKey: executablePathDefaultsKey)
        )
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

        Create an organization plan and answer with a single JSON object following exactly this contract:
        {
          "kind": "organize",
          "summary": "one short sentence describing the plan for the user",
          "operations": [ ... ]
        }

        "operations" is an array whose entries take exactly one of these five forms:
        {"op": "createFolder", "path": "relative/folder"}
        {"op": "move", "source": "relative/file", "destination": "relative/target/file"}
        {"op": "copy", "source": "relative/file", "destination": "relative/target/file"}
        {"op": "rename", "source": "relative/file", "newName": "new-file-name-only"}
        {"op": "trash", "source": "relative/file"}

        Rules:
        - Inspect the directory and enumerate one concrete operation per affected file. \
        No wildcards, no shell commands, no placeholders.
        - "destination" must include the target file name, and "newName" is a bare \
        file name without any path.
        - Write "summary" in the same language as the user's request.
        - Your final answer must be ONLY the JSON object itself: no markdown code \
        fences, no explanations, no text before or after it.
        """
    }

    static func answerPrompt(for request: AIAssistantRequest) -> String {
        let history = request.previousExchanges.suffix(6).map { exchange in
            "User: \(exchange.question)\nAssistant: \(exchange.answer)"
        }.joined(separator: "\n\n")
        let historySection = history.isEmpty ? "" : """

        Recent conversation:
        \(history)

        """

        return """
        The user's current folder is \(request.scopeRoot.standardizedFileURL.path).
        Answer the user's question directly. Inspect this folder and its contents when \
        that helps. This is a read-only conversation: do not modify files. When referring \
        to local items, use paths relative to the current folder. You may answer questions \
        unrelated to the folder normally. Reply in the same language as the user's current \
        question unless the user explicitly asks for another language.
        \(historySection)Current question: \(request.question)
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

    private func run(
        prompt: String,
        in scopeRoot: URL,
        mode: String,
        outputFormat: String,
        executableURL: URL
    ) async throws -> String {
        let timeout = timeout
        let worker = Task.detached(priority: .userInitiated) {
            try Self.runProcess(
                executableURL: executableURL,
                prompt: prompt,
                currentDirectory: scopeRoot,
                timeout: timeout,
                mode: mode,
                outputFormat: outputFormat
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
        timeout: TimeInterval,
        mode: String,
        outputFormat: String
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-p", "--mode", mode, "--trust", "--output-format", outputFormat, prompt]
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
