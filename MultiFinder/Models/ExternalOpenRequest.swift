import Foundation

struct ExternalOpenRequest: Equatable, Sendable {
    static let scheme = "multifinder"
    static let host = "open"

    let targetURL: URL

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return nil }
        targetURL = URL(fileURLWithPath: path).standardizedFileURL
    }

    static func url(for targetURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "path", value: targetURL.standardizedFileURL.path)]
        return components.url
    }
}
