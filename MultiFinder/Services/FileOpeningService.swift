import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileOpenApplication: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDefault: Bool

    var id: URL { url }
}

@MainActor
final class FileOpeningService {
    static let shared = FileOpeningService()

    nonisolated static let sublimeTextBundleIdentifiers = [
        "com.sublimetext.4",
        "com.sublimetext.3"
    ]

    nonisolated static let visualStudioCodeBundleIdentifiers = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders"
    ]

    private nonisolated static let textExtensions: Set<String> = [
        "bash", "c", "cc", "cfg", "conf", "config", "cpp", "css", "csv",
        "cxx", "dart", "env", "fish", "go", "graphql", "h", "hpp", "htm",
        "html", "ini", "java", "js", "json", "jsonl", "jsx", "kt", "less",
        "log", "lua", "m", "markdown", "md", "mm", "php", "properties", "proto",
        "py", "r", "rb", "rs", "rst", "scss", "sh", "sql", "swift", "text",
        "toml", "ts", "tsv", "tsx", "txt", "vue", "xml", "yaml", "yml", "zsh"
    ]

    private nonisolated static let extensionlessTextFileNames: Set<String> = [
        ".bash_profile", ".bashrc", ".editorconfig", ".env", ".gitattributes",
        ".gitignore", ".npmrc", ".profile", ".vimrc", ".zprofile", ".zshrc",
        "dockerfile", "gemfile", "license", "makefile", "podfile", "readme"
    ]

    private let workspace: NSWorkspace
    private let settings: AppSettings

    init(
        workspace: NSWorkspace = .shared,
        settings: AppSettings? = nil
    ) {
        self.workspace = workspace
        self.settings = settings ?? .shared
    }

    nonisolated static func prefersSublimeText(for url: URL) -> Bool {
        let fileName = url.lastPathComponent.lowercased()
        let pathExtension = url.pathExtension.lowercased()

        if pathExtension.isEmpty {
            return extensionlessTextFileNames.contains(fileName)
        }
        if textExtensions.contains(pathExtension) {
            return true
        }

        guard let contentType = UTType(filenameExtension: pathExtension) else { return false }
        return contentType.conforms(to: .plainText) || contentType.conforms(to: .sourceCode)
    }

    func preferredTextEditorURL(for url: URL) -> URL? {
        guard Self.prefersSublimeText(for: url) else { return nil }
        return configuredTextEditorURL
    }

    func applications(for urls: [URL]) -> [FileOpenApplication] {
        let urls = urls.map(\.standardizedFileURL)
        guard let firstURL = urls.first else { return [] }

        var candidates = workspace.urlsForApplications(toOpen: firstURL)
            .map(\.standardizedFileURL)

        for url in urls.dropFirst() {
            let compatibleURLs = Set(
                workspace.urlsForApplications(toOpen: url).map(\.standardizedFileURL)
            )
            candidates.removeAll { !compatibleURLs.contains($0) }
        }

        let preferredURL = preferredApplicationURL(for: urls)
        if let preferredURL,
           !candidates.contains(preferredURL) {
            candidates.append(preferredURL)
        }

        var seen = Set<URL>()
        let uniqueCandidates = candidates.filter { seen.insert($0).inserted }
        return uniqueCandidates
            .map { url in
                FileOpenApplication(
                    url: url,
                    name: applicationName(at: url),
                    isDefault: url == preferredURL
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var sublimeTextApplicationURL: URL? {
        installedApplicationURL(
            bundleIdentifiers: Self.sublimeTextBundleIdentifiers,
            knownLocations: [
                URL(fileURLWithPath: "/Applications/Sublime Text.app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Sublime Text.app")
            ]
        )
    }

    private var visualStudioCodeApplicationURL: URL? {
        installedApplicationURL(
            bundleIdentifiers: Self.visualStudioCodeBundleIdentifiers,
            knownLocations: [
                URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Visual Studio Code.app"),
                URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")
            ]
        )
    }

    private var customEditorApplicationURL: URL? {
        let path = settings.customEditorApplicationPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var configuredTextEditorURL: URL? {
        switch settings.preferredEditorApplication {
        case .automatic, .sublimeText:
            return sublimeTextApplicationURL
        case .systemDefault:
            return nil
        case .visualStudioCode:
            return visualStudioCodeApplicationURL
        case .custom:
            return customEditorApplicationURL
        }
    }

    private func installedApplicationURL(
        bundleIdentifiers: [String],
        knownLocations: [URL]
    ) -> URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url.standardizedFileURL
            }
        }

        return knownLocations.first { FileManager.default.fileExists(atPath: $0.path) }?
            .standardizedFileURL
    }

    private func preferredApplicationURL(for urls: [URL]) -> URL? {
        if urls.allSatisfy(Self.prefersSublimeText), let configuredTextEditorURL {
            return configuredTextEditorURL
        }

        let systemDefaults = urls.compactMap { workspace.urlForApplication(toOpen: $0) }
            .map(\.standardizedFileURL)
        guard systemDefaults.count == urls.count,
              let firstDefault = systemDefaults.first,
              systemDefaults.allSatisfy({ $0 == firstDefault }) else { return nil }
        return firstDefault
    }

    private func applicationName(at url: URL) -> String {
        if let bundle = Bundle(url: url),
           let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
