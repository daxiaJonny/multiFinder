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
    case aiSearch(root: URL, criteria: AISearchCriteria, title: String)

    var directoryURL: URL? {
        guard case .directory(let url) = self else { return nil }
        return url
    }

    var title: String {
        switch self {
        case .directory(let url):
            return url.path == "/" ? url.path : url.lastPathComponent
        case .recents:
            return L10n.string("Recents")
        case .search(let query):
            return query.text.isEmpty
                ? L10n.string("Search")
                : L10n.format("Search: %@", query.text)
        case .aiSearch(_, _, let title):
            return title.isEmpty ? L10n.string("AI Search") : title
        }
    }

    var pathDescription: String {
        switch self {
        case .directory(let url):
            return url.path
        case .recents:
            return L10n.string("Recents")
        case .search(let query):
            return query.scope?.path ?? L10n.string("This Mac")
        case .aiSearch(let root, _, _):
            return root.path
        }
    }

    var supportsCreatingItems: Bool {
        directoryURL != nil
    }

}
