import Foundation
import XCTest
@testable import MultiFinder

@MainActor
final class FavoritesStoreTests: XCTestCase {
    private static let storageKey = "favorites"

    func testAddNormalizesDirectoryURLAndRejectsDuplicates() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let unnormalizedURL = URL(fileURLWithPath: "/tmp/MultiFinder/../Favorites")
        let normalizedURL = URL(fileURLWithPath: "/tmp/Favorites").standardizedFileURL

        let favorite = try XCTUnwrap(store.add(unnormalizedURL))

        XCTAssertEqual(favorite.url, normalizedURL)
        XCTAssertTrue(store.contains(normalizedURL))
        XCTAssertNil(store.add(normalizedURL))
        XCTAssertEqual(store.favorites.count, 1)
    }

    func testPersistenceRoundTripPreservesIdentityAndOrder() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let firstStore = makeStore(userDefaults: userDefaults)
        let firstURL = URL(fileURLWithPath: "/tmp/First")
        let secondURL = URL(fileURLWithPath: "/tmp/Second")
        let firstFavorite = try XCTUnwrap(firstStore.add(firstURL))
        let secondFavorite = try XCTUnwrap(firstStore.add(secondURL))

        let restoredStore = makeStore(userDefaults: userDefaults)

        XCTAssertEqual(restoredStore.favorites.map(\.id), [firstFavorite.id, secondFavorite.id])
        XCTAssertEqual(restoredStore.favorites.map(\.url), [firstURL, secondURL].map(\.standardizedFileURL))
    }

    func testToggleAndRemoveByIDPersistChanges() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let url = URL(fileURLWithPath: "/tmp/Toggle")

        XCTAssertTrue(store.toggle(url))
        let firstID = try XCTUnwrap(store.favorite(for: url)?.id)
        XCTAssertFalse(store.toggle(url))
        XCTAssertFalse(store.contains(url))

        let secondFavorite = try XCTUnwrap(store.add(url))
        XCTAssertNotEqual(secondFavorite.id, firstID)
        XCTAssertTrue(store.remove(id: secondFavorite.id))
        XCTAssertFalse(store.remove(id: secondFavorite.id))
        XCTAssertTrue(makeStore(userDefaults: userDefaults).favorites.isEmpty)
    }

    func testMoveReordersFavoritesAndPersistsOrder() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let urls = ["First", "Second", "Third"].map {
            URL(fileURLWithPath: "/tmp/\($0)")
        }
        for url in urls {
            XCTAssertNotNil(store.add(url))
        }

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let expected = [urls[1], urls[2], urls[0]].map(\.standardizedFileURL)
        XCTAssertEqual(store.favorites.map(\.url), expected)
        XCTAssertEqual(makeStore(userDefaults: userDefaults).favorites.map(\.url), expected)
    }

    func testCorruptStorageIsResetAndCanRecover() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(Data("not valid JSON".utf8), forKey: Self.storageKey)

        let store = makeStore(userDefaults: userDefaults)

        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertNil(userDefaults.data(forKey: Self.storageKey))
        XCTAssertNotNil(store.add(URL(fileURLWithPath: "/tmp/Recovered")))
        XCTAssertEqual(makeStore(userDefaults: userDefaults).favorites.count, 1)
    }

    func testInvalidAndDuplicatePersistedEntriesAreSanitized() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/Stored/../Favorite")
        let duplicateURL = URL(fileURLWithPath: "/tmp/Favorite")
        let invalidURL = try XCTUnwrap(URL(string: "https://example.com/not-a-directory"))
        let persisted = [
            FileFavorite(id: id, url: url),
            FileFavorite(url: duplicateURL),
            FileFavorite(url: invalidURL)
        ]
        userDefaults.set(try JSONEncoder().encode(persisted), forKey: Self.storageKey)

        let store = makeStore(userDefaults: userDefaults)

        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(store.favorites.first?.id, id)
        XCTAssertEqual(store.favorites.first?.url, duplicateURL.standardizedFileURL)
        XCTAssertEqual(makeStore(userDefaults: userDefaults).favorites, store.favorites)
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FavoritesStoreTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeStore(userDefaults: UserDefaults) -> FavoritesStore {
        FavoritesStore(userDefaults: userDefaults, storageKey: Self.storageKey)
    }
}
