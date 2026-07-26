import AppKit
import Foundation

enum ITermServiceError: LocalizedError {
    case notInstalled
    case invalidDirectory
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "iTerm2 is not installed."
        case .invalidDirectory:
            return "The current path is not an available directory."
        case .scriptFailed(let message):
            return "Could not open the path in iTerm2: \(message)"
        }
    }
}

@MainActor
final class ITermService {
    static let shared = ITermService()
    nonisolated static let bundleIdentifier = "com.googlecode.iterm2"

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var isAvailable: Bool {
        workspace.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
    }

    func openDirectory(_ url: URL) throws {
        guard isAvailable else { throw ITermServiceError.notInstalled }

        let directoryURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directoryURL.isFileURL,
              FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ITermServiceError.invalidDirectory }

        guard let script = NSAppleScript(source: Self.script(forPath: directoryURL.path)) else {
            throw ITermServiceError.scriptFailed("The automation script could not be created.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown automation error."
            throw ITermServiceError.scriptFailed(message)
        }
    }

    nonisolated static func script(forPath path: String) -> String {
        let escapedPath = appleScriptLiteral(path)
        return """
        set targetPath to \(escapedPath)
        tell application id "\(bundleIdentifier)"
            activate
            if (count of windows) is 0 then
                set targetWindow to (create window with default profile)
                set targetSession to current session of targetWindow
            else
                tell current window
                    set targetTab to (create tab with default profile)
                end tell
                set targetSession to current session of targetTab
            end if
            tell targetSession
                write text "cd " & quoted form of targetPath
            end tell
        end tell
        """
    }

    private nonisolated static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
