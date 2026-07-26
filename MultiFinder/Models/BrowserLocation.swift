import Foundation

struct SearchQuery: Hashable, Codable, Sendable {
    let text: String
    let scope: URL?

    init(text: String, scope: URL? = nil) {
        self.text = text
        self.scope = scope?.standardizedFileURL
    }
}

enum BrowserLocation: Hashable, Codable, Sendable {
    case directory(URL)
    case recents
    case search(SearchQuery)

    var directoryURL: URL? {
        guard case .directory(let url) = self else { return nil }
        return url
    }

    var title: String {
        switch self {
        case .directory(let url):
            return url.path == "/" ? url.path : url.lastPathComponent
        case .recents:
            return "Recents"
        case .search(let query):
            return query.text.isEmpty ? "Search" : "Search: \(query.text)"
        }
    }

    var pathDescription: String {
        switch self {
        case .directory(let url):
            return url.path
        case .recents:
            return "Recents"
        case .search(let query):
            return query.scope?.path ?? "This Mac"
        }
    }

    var supportsCreatingItems: Bool {
        directoryURL != nil
    }

}
