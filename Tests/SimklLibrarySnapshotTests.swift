import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
private typealias SimklTestLibraryItem = EclipseMac.LibraryItem
#else
@testable import Eclipse
private typealias SimklTestLibraryItem = Eclipse.LibraryItem
#endif

final class SimklLibrarySnapshotTests: XCTestCase {
    func testExactExternalIDsAcceptIntegerStringsAndRemainSeparatedByMediaKind() throws {
        let data = Data("""
        {"shows":[{"status":"watching","watched_episodes_count":2,"total_episodes_count":12,
        "show":{"title":"Example","year":2024,"ids":{"simkl":42,"tmdb":"123"}},
        "seasons":[{"number":2,"episodes":[{"number":1},{"number":3}]}]}]}
        """.utf8)
        let rows = try SimklLibraryItem.decode(data, kind: .show)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.media?.ids.tmdb?.value, 123)
        XCTAssertEqual(try rows.first?.watchedSeasons(), [2: [1, 3]])
        XCTAssertTrue(try SimklLibraryItem.decode(data, kind: .movie).isEmpty)
    }

    func testAnimeAbsoluteProgressNeedsExactContiguousCoverage() throws {
        let contiguous = try animeItem(numbers: [1, 2, 3], count: 3)
        XCTAssertEqual(try contiguous.contiguousAnimeProgress(), 3)
        let sparse = try animeItem(numbers: [1, 3, 4], count: 3)
        XCTAssertNil(try sparse.contiguousAnimeProgress())
        let incomplete = try animeItem(numbers: [1, 2], count: 3)
        XCTAssertNil(try incomplete.contiguousAnimeProgress())
        let seasonal = try animeItem(numbers: [1, 2, 3], count: 3, season: 2)
        XCTAssertNil(try seasonal.contiguousAnimeProgress())
    }

    func testPartialMultipartAnimeFilmNeverMarksLocalMovieCompleted() throws {
        let object: [String: Any] = ["anime": [["status": "watching", "watched_episodes_count": 1,
            "total_episodes_count": 3, "anime_type": "movie", "last_watched_at": "2026-10-01T00:00:00Z",
            "show": ["title": "Film Series", "ids": ["simkl": 42]],
            "seasons": [["number": 1, "episodes": [["number": 1]]]]]]]
        let item = try XCTUnwrap(SimklLibraryItem.decode(JSONSerialization.data(withJSONObject: object), kind: .anime).first)
        XCTAssertFalse(try item.movieIsCompleted(kind: .anime))
        XCTAssertTrue(try movieItem(status: "plantowatch", watchedAt: "2026-10-01T00:00:00Z").movieIsCompleted(kind: .movie))
    }

    func testDeletionReconciliationDecodesMinimalIDsAndRejectsUnknownEnvelopeKeys() throws {
        let data = Data("""
        {"anime":[{"show":{"ids":{"simkl":42}}},{"show":{"ids":{"simkl":"43"}}}]}
        """.utf8)
        XCTAssertEqual(try SimklLibraryItem.decodeIDs(data, kind: .anime), [42, 43])
        XCTAssertTrue(try SimklLibraryItem.decodeIDs(Data("{}".utf8), kind: .show).isEmpty)
        XCTAssertThrowsError(try SimklLibraryItem.decodeIDs(Data("{\"error\":\"unavailable\"}".utf8), kind: .show))
        XCTAssertThrowsError(try SimklLibraryItem.decodeIDs(Data("{\"shows\":null}".utf8), kind: .show))
    }

    func testUnreadableNumericValuesAndMissingProgressHaveNoImportAuthority() throws {
        for rawID in ["true", "-1", "0", "1.5", "\"01\""] {
            let data = Data("{\"shows\":[{\"status\":\"watching\",\"watched_episodes_count\":0,\"show\":{\"title\":\"Example\",\"ids\":{\"simkl\":\(rawID)}}}]}".utf8)
            XCTAssertThrowsError(try SimklLibraryItem.decode(data, kind: .show))
        }
        let missing = Data("{\"shows\":[{\"status\":\"watching\",\"show\":{\"title\":\"Example\",\"ids\":{\"simkl\":42}}}]}".utf8)
        XCTAssertThrowsError(try SimklLibraryItem.decode(missing, kind: .show))
    }

    func testActivityUsesTheTVCategoryAndPreservesNullRemovalTimestamp() throws {
        let data = Data("{\"all\":\"2026-10-01T00:00:00Z\",\"tv_shows\":{\"all\":\"2026-10-01T00:00:00Z\",\"removed_from_list\":null}}".utf8)
        let activity = try SimklLibraryActivity.decode(data, kind: .show)
        XCTAssertEqual(activity.updated, "2026-10-01T00:00:00Z")
        XCTAssertNil(activity.removed)
        XCTAssertThrowsError(try SimklLibraryActivity.decode(Data("{\"tv_shows\":{\"all\":\"bad\",\"removed_from_list\":null}}".utf8), kind: .show))
    }

    func testTVDBEpisodeLookupUsesItsResolvedTMDBCoordinatesAndRejectsAmbiguity() throws {
        let exact = Data("{\"tv_episode_results\":[{\"id\":101,\"show_id\":42,\"season_number\":2,\"episode_number\":7}]}".utf8)
        let match = try XCTUnwrap(TMDBService.ExternalEpisodeMatch.decodeUnique(exact))
        XCTAssertEqual(match.showID, 42)
        XCTAssertEqual(match.season, 2)
        XCTAssertEqual(match.episode, 7)
        let ambiguous = Data("{\"tv_episode_results\":[{\"id\":101,\"show_id\":42,\"season_number\":2,\"episode_number\":7},{\"id\":102,\"show_id\":43,\"season_number\":1,\"episode_number\":1}]}".utf8)
        XCTAssertNil(try TMDBService.ExternalEpisodeMatch.decodeUnique(ambiguous))
        XCTAssertThrowsError(try TMDBService.ExternalEpisodeMatch.decodeUnique(Data("{\"tv_episode_results\":[{\"id\":101,\"show_id\":42,\"season_number\":-1,\"episode_number\":1}]}".utf8)))
        XCTAssertThrowsError(try TMDBService.ExternalEpisodeMatch.decodeUnique(Data("{}".utf8)))
    }

    func testSimklIsExcludedFromDeepLibraryKindsAndCollectionTargets() {
        XCTAssertTrue(TrackerLibraryKind.supportedKinds(for: .simkl).isEmpty)
        XCTAssertFalse(TrackerCollectionTarget(title: "Example", kind: .movie, tmdbID: 42).supports(.simkl))
    }

    @MainActor
    func testDelayedSIMKLCollectionImportExpiresOnDestructiveMutationBeforeMergeStarts() async throws {
        for mutation in ["delete-recreate", "remove-readd", "restore", "profile-aba"] {
            let owner = UUID()
            let otherOwner = UUID()
            let manager = LibraryManager(profileID: owner)
            defer {
                UserDefaults.standard.removeObject(forKey: LibraryManager.collectionsKey(for: owner))
                UserDefaults.standard.removeObject(forKey: LibraryManager.collectionsKey(for: otherOwner))
            }
            XCTAssertTrue(manager.createCollection(name: "Delayed SIMKL Fixture"))
            let collection = try XCTUnwrap(manager.collections.first { $0.name == "Delayed SIMKL Fixture" })
            let item = SimklTestLibraryItem(searchResult: TMDBSearchResult(id: 42, mediaType: "movie", title: "Example", name: nil,
                overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil,
                voteAverage: 0, popularity: 0, adult: nil, genreIds: nil))
            manager.addItem(to: collection.id, item: item)
            let authority = try XCTUnwrap(manager.importOperationAuthority(requiredOwner: owner))
            var completion: AsyncStream<Void>.Continuation?
            let metadata = AsyncStream<Void> { completion = $0 }
            let delayed = Task { @MainActor in
                for await _ in metadata { break }
                return try await manager.mergeImportedItems([.init(collectionName: "Delayed SIMKL Fixture", item: item)],
                    sourceName: "SIMKL", owner: owner) {
                    guard manager.importOperationAuthorityIsCurrent(authority) else { throw CancellationError() }
                }
            }
            switch mutation {
            case "delete-recreate":
                manager.deleteCollection(collection)
                XCTAssertTrue(manager.createCollection(name: "Delayed SIMKL Fixture"))
            case "remove-readd":
                manager.removeItem(from: collection.id, item: item)
                manager.addItem(to: collection.id, item: item)
                manager.removeItem(from: collection.id, item: item)
            case "restore":
                manager.replaceCollectionsForMediaState([])
            default:
                manager.switchProfile(to: otherOwner)
                manager.switchProfile(to: owner)
            }
            completion?.yield(())
            completion?.finish()
            do {
                _ = try await delayed.value
                XCTFail("Expired metadata must not recreate items after \(mutation)")
            } catch { XCTAssertTrue(error is CancellationError, mutation) }
            XCTAssertFalse(manager.importOperationAuthorityIsCurrent(authority), mutation)
            if mutation != "profile-aba" {
                XCTAssertFalse(manager.collections.flatMap(\.items).contains { $0.id == item.id }, mutation)
            }
            await drainCollectionWrites()
        }
    }

    @MainActor
    func testDelayedSIMKLCollectionImportRebasesAfterAdditiveLocalMutation() async throws {
        let owner = UUID()
        let manager = LibraryManager(profileID: owner)
        defer { UserDefaults.standard.removeObject(forKey: LibraryManager.collectionsKey(for: owner)) }
        XCTAssertTrue(manager.createCollection(name: "Delayed SIMKL Fixture"))
        let collection = try XCTUnwrap(manager.collections.first { $0.name == "Delayed SIMKL Fixture" })
        let authority = try XCTUnwrap(manager.importOperationAuthority(requiredOwner: owner))
        func item(_ id: Int) -> SimklTestLibraryItem {
            SimklTestLibraryItem(searchResult: TMDBSearchResult(id: id, mediaType: "movie", title: "Example", name: nil,
                overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil,
                voteAverage: 0, popularity: 0, adult: nil, genreIds: nil))
        }
        let remote = item(42)
        let local = item(43)
        var completion: AsyncStream<Void>.Continuation?
        let metadata = AsyncStream<Void> { completion = $0 }
        let delayed = Task { @MainActor in
            for await _ in metadata { break }
            return try await manager.mergeImportedItems([.init(collectionName: "Delayed SIMKL Fixture", item: remote)],
                sourceName: "SIMKL", owner: owner) {
                guard manager.importOperationAuthorityIsCurrent(authority) else { throw CancellationError() }
            }
        }
        manager.addItem(to: collection.id, item: local)
        completion?.yield(())
        completion?.finish()
        let added = try await delayed.value
        XCTAssertEqual(added, 1)
        XCTAssertEqual(Set(collection.items.map(\.id)), Set([remote.id, local.id]))
        await drainCollectionWrites()
    }

    @MainActor
    private func drainCollectionWrites() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func animeItem(numbers: [Int], count: Int, season: Int = 1, status: String = "watching") throws -> SimklLibraryItem {
        let object: [String: Any] = ["anime": [["status": status, "watched_episodes_count": count,
            "total_episodes_count": 12, "anime_type": "tv",
            "show": ["title": "Example", "ids": ["simkl": 42, "mal": "123"]],
            "seasons": [["number": season, "episodes": numbers.map { ["number": $0] }]]]]]
        let rows = try SimklLibraryItem.decode(JSONSerialization.data(withJSONObject: object), kind: .anime)
        return try XCTUnwrap(rows.first)
    }

    private func movieItem(status: String, rating: Int? = nil, watchedAt: String? = nil) throws -> SimklLibraryItem {
        var row: [String: Any] = ["status": status, "movie": ["title": "Example", "ids": ["simkl": 42]]]
        if let rating { row["user_rating"] = rating }
        if let watchedAt { row["last_watched_at"] = watchedAt }
        let data = try JSONSerialization.data(withJSONObject: ["movies": [row]])
        return try XCTUnwrap(SimklLibraryItem.decode(data, kind: .movie).first)
    }
}
