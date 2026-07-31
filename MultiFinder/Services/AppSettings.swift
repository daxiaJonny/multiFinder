import Combine
import Foundation

enum PreferredEditorApplication: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case systemDefault
    case sublimeText
    case visualStudioCode
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return L10n.string("Automatic (Prefer Sublime Text)")
        case .systemDefault:
            return L10n.string("System Default")
        case .sublimeText:
            return "Sublime Text"
        case .visualStudioCode:
            return "Visual Studio Code"
        case .custom:
            return L10n.string("Other Application")
        }
    }
}

enum PreferredTerminalApplication: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm2
    case warp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return L10n.string("Terminal")
        case .iTerm2: return "iTerm2"
        case .warp: return "Warp"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    nonisolated static let preferredEditorDefaultsKey = "PreferredEditorApplication"
    nonisolated static let customEditorPathDefaultsKey = "PreferredEditorApplicationPath"
    nonisolated static let preferredTerminalDefaultsKey = "PreferredTerminalApplication"
    nonisolated static let showHiddenFilesDefaultsKey = "ShowHiddenFilesByDefault"
    nonisolated static let cursorCLIExecutablePathDefaultsKey = "AIPlannerExecutablePath"

    nonisolated static var defaultCursorCLIExecutablePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/agent")
            .path
    }

    nonisolated static func resolvedCursorCLIExecutableURL(from path: String?) -> URL {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedPath = trimmed.isEmpty ? defaultCursorCLIExecutablePath : trimmed
        return URL(fileURLWithPath: (resolvedPath as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    @Published var preferredEditorApplication: PreferredEditorApplication {
        didSet {
            userDefaults.set(preferredEditorApplication.rawValue, forKey: Self.preferredEditorDefaultsKey)
        }
    }

    @Published var customEditorApplicationPath: String {
        didSet {
            userDefaults.set(customEditorApplicationPath, forKey: Self.customEditorPathDefaultsKey)
        }
    }

    @Published var preferredTerminalApplication: PreferredTerminalApplication {
        didSet {
            userDefaults.set(preferredTerminalApplication.rawValue, forKey: Self.preferredTerminalDefaultsKey)
        }
    }

    @Published var showHiddenFilesByDefault: Bool {
        didSet {
            userDefaults.set(showHiddenFilesByDefault, forKey: Self.showHiddenFilesDefaultsKey)
        }
    }

    @Published var cursorCLIExecutablePath: String {
        didSet {
            userDefaults.set(cursorCLIExecutablePath, forKey: Self.cursorCLIExecutablePathDefaultsKey)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        preferredEditorApplication = userDefaults.string(forKey: Self.preferredEditorDefaultsKey)
            .flatMap(PreferredEditorApplication.init(rawValue:))
            ?? .automatic
        customEditorApplicationPath = userDefaults.string(forKey: Self.customEditorPathDefaultsKey) ?? ""
        preferredTerminalApplication = userDefaults.string(forKey: Self.preferredTerminalDefaultsKey)
            .flatMap(PreferredTerminalApplication.init(rawValue:))
            ?? .terminal
        showHiddenFilesByDefault = userDefaults.bool(forKey: Self.showHiddenFilesDefaultsKey)
        cursorCLIExecutablePath = userDefaults.string(forKey: Self.cursorCLIExecutablePathDefaultsKey)
            ?? Self.defaultCursorCLIExecutablePath
    }

    func restoreDefaults() {
        preferredEditorApplication = .automatic
        customEditorApplicationPath = ""
        preferredTerminalApplication = .terminal
        showHiddenFilesByDefault = false
        cursorCLIExecutablePath = Self.defaultCursorCLIExecutablePath
    }
}
