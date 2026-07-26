import AppKit
import Darwin
import Foundation

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("mfd: \(message)\n".utf8))
    exit(status)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--help" || arguments.first == "-h" {
    print("Usage: mfd [path]")
    exit(0)
}
guard arguments.count <= 1 else {
    fail("expected a single path\nUsage: mfd [path]")
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
guard let requestURL = components.url else {
    fail("could not encode the requested path")
}
guard NSWorkspace.shared.open(requestURL) else {
    fail("could not open MultiFinder")
}
