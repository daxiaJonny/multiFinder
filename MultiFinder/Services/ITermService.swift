import AppKit
import Foundation

enum TerminalServiceError: LocalizedError {
    case notInstalled(String)
    case invalidDirectory
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let applicationName):
            return L10n.format("%@ is not installed.", applicationName)
        case .invalidDirectory:
            return L10n.string("The current path is not an available directory.")
        case .launchFailed(let applicationName, let message):
            return L10n.format("Could not open the current path in %@: %@", applicationName, message)
        }
    }
}

@MainActor
final class TerminalService {
    static let shared = TerminalService()

    // Retained for source compatibility while callers migrate from ITermService.
    nonisolated static let bundleIdentifier = "com.googlecode.iterm2"

    private let settings: AppSettings
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let processRunner: ([String]) throws -> Void

    init(
        settings: AppSettings? = nil,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        processRunner: @escaping ([String]) throws -> Void = TerminalService.runOpenProcess
    ) {
        self.settings = settings ?? .shared
        self.workspace = workspace
        self.fileManager = fileManager
        self.processRunner = processRunner
    }

    var selectedApplication: PreferredTerminalApplication {
        settings.preferredTerminalApplication
    }

    var applicationName: String {
        selectedApplication.displayName
    }

    var isAvailable: Bool {
        applicationURL(for: selectedApplication) != nil
    }

    func openDirectory(_ url: URL) throws {
        let application = selectedApplication
        guard let applicationURL = applicationURL(for: application) else {
            throw TerminalServiceError.notInstalled(application.displayName)
        }

        let directoryURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directoryURL.isFileURL,
              fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw TerminalServiceError.invalidDirectory }

        do {
            try processRunner(Self.launchArguments(
                applicationURL: applicationURL,
                directoryURL: directoryURL
            ))
        } catch {
            throw TerminalServiceError.launchFailed(application.displayName, error.localizedDescription)
        }
    }

    func applicationURL(for application: PreferredTerminalApplication) -> URL? {
        if let url = workspace.urlForApplication(withBundleIdentifier: application.bundleIdentifier) {
            return url.standardizedFileURL
        }

        return Self.knownApplicationURLs(for: application)
            .first { fileManager.fileExists(atPath: $0.path) }?
            .standardizedFileURL
    }

    nonisolated static func launchArguments(
        applicationURL: URL,
        directoryURL: URL
    ) -> [String] {
        ["-a", applicationURL.standardizedFileURL.path, directoryURL.standardizedFileURL.path]
    }

    private nonisolated static func knownApplicationURLs(
        for application: PreferredTerminalApplication
    ) -> [URL] {
        switch application {
        case .terminal:
            return [URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")]
        case .iTerm2:
            return [
                URL(fileURLWithPath: "/Applications/iTerm.app"),
                URL(fileURLWithPath: "/Applications/iTerm2.app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/iTerm.app")
            ]
        case .warp:
            return [
                URL(fileURLWithPath: "/Applications/Warp.app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Warp.app")
            ]
        }
    }

    private nonisolated static func runOpenProcess(arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? L10n.string("The open command failed.")
            throw NSError(
                domain: "MultiFinder.TerminalService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
}

typealias ITermService = TerminalService
typealias ITermServiceError = TerminalServiceError
