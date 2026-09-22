import AppKit
import Darwin
import Foundation

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("mfd: \(message)\n".utf8))
    exit(status)
}

private let usage = "Usage: mfd [--new-tab] [--] [path]"
private var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--help" || arguments.first == "-h" {
    print(usage)
    exit(0)
}
let opensInNewTab = arguments.first == "--new-tab"
if opensInNewTab { arguments.removeFirst() }
if arguments.first == "--" {
    arguments.removeFirst()
} else if let option = arguments.first, option.hasPrefix("-") {
    fail("unknown option: \(option)\n\(usage)")
}
guard arguments.count <= 1 else {
    fail("expected a single path\n\(usage)")
}

let rawPath = arguments.first ?? "."
let expandedPath = (rawPath as NSString).expandingTildeInPath
let workingDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
)
let targetURL = (expandedPath.hasPrefix("/")
    ? URL(fileURLWithPath: expandedPath)
    : workingDirectory.appendingPathComponent(expandedPath)
).standardizedFileURL

guard FileManager.default.fileExists(atPath: targetURL.path) else {
    fail("path does not exist: \(targetURL.path)")
}

var components = URLComponents()
components.scheme = "multifinder"
components.host = "open"
components.queryItems = [URLQueryItem(name: "path", value: targetURL.path)]
if opensInNewTab {
    components.queryItems?.append(URLQueryItem(name: "newTab", value: "true"))
}
guard let requestURL = components.url else {
    fail("could not encode the requested path")
}
guard NSWorkspace.shared.open(requestURL) else {
    fail("could not open MultiFinder")
}
