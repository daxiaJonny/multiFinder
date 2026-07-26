import Combine
import Foundation

struct FileFavorite: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url.standardizedFileURL
    }

    var name: String {
        url.path == "/" ? "/" : url.lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url).standardizedFileURL
    }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    static let defaultStorageKey = "com.multifinder.favorites"

    @Published private(set) var favorites: [FileFavorite]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = FavoritesStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        guard let data = userDefaults.data(forKey: storageKey) else {
            favorites = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([FileFavorite].self, from: data)
            favorites = Self.sanitized(decoded)
            if favorites != decoded {
                persist()
            }
        } catch {
            favorites = []
            userDefaults.removeObject(forKey: storageKey)
        }
    }

    func contains(_ url: URL) -> Bool {
        guard let normalizedURL = Self.normalizedDirectoryURL(url) else { return false }
        return favorites.contains { $0.url == normalizedURL }
    }

    func favorite(for url: URL) -> FileFavorite? {
        guard let normalizedURL = Self.normalizedDirectoryURL(url) else { return nil }
        return favorites.first { $0.url == normalizedURL }
    }

    @discardableResult
    func add(_ url: URL) -> FileFavorite? {
        guard let normalizedURL = Self.normalizedDirectoryURL(url),
              !favorites.contains(where: { $0.url == normalizedURL }) else { return nil }

        let favorite = FileFavorite(url: normalizedURL)
        favorites.append(favorite)
        persist()
        return favorite
    }

    @discardableResult
    func remove(_ url: URL) -> Bool {
        guard let normalizedURL = Self.normalizedDirectoryURL(url),
              let index = favorites.firstIndex(where: { $0.url == normalizedURL }) else { return false }

        favorites.remove(at: index)
        persist()
        return true
    }

    @discardableResult
    func remove(id: FileFavorite.ID) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return false }
        favorites.remove(at: index)
        persist()
        return true
    }

    @discardableResult
    func toggle(_ url: URL) -> Bool {
        if remove(url) {
            return false
        }
        return add(url) != nil
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let validSource = source.filter { favorites.indices.contains($0) }
        guard !validSource.isEmpty, (0...favorites.count).contains(destination) else { return }

        let movedFavorites = validSource.map { favorites[$0] }
        let remainingFavorites = favorites.enumerated()
            .filter { !validSource.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = validSource.count { $0 < destination }
        let insertionIndex = min(max(0, destination - removedBeforeDestination), remainingFavorites.count)

        var reordered = remainingFavorites
        reordered.insert(contentsOf: movedFavorites, at: insertionIndex)
        guard reordered != favorites else { return }
        favorites = reordered
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private nonisolated static func normalizedDirectoryURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    private nonisolated static func sanitized(_ favorites: [FileFavorite]) -> [FileFavorite] {
        var seenURLs: Set<URL> = []
        return favorites.compactMap { favorite in
            guard let url = normalizedDirectoryURL(favorite.url), seenURLs.insert(url).inserted else {
                return nil
            }
            return FileFavorite(id: favorite.id, url: url)
        }
    }
}
