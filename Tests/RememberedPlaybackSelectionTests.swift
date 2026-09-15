import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class RememberedPlaybackSelectionTests: XCTestCase {
    func testAutomaticFeaturesDefaultOff() throws {
        try withStore { store in
            XCTAssertFalse(RememberedPlaybackSettings.isEnabled(defaults: store))
            XCTAssertFalse(AutoplayNextEpisodeSettings.isEnabled(defaults: store))
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: RememberedPlaybackSettings.enabledKey), .profile)
            XCTAssertEqual(EclipseSettingsRegistry.scope(for: AutoplayNextEpisodeSettings.enabledKey), .profile)
        }
    }

    func testSeasonAndAnimeIdentityCannotLeakToAnotherDestination() {
        let seasonOne = RememberedPlaybackSelection.mediaKey(tmdbID: 42, isMovie: false, season: 1, animeID: nil)
        XCTAssertNotEqual(seasonOne, RememberedPlaybackSelection.mediaKey(tmdbID: 42, isMovie: false, season: 2, animeID: nil))
        XCTAssertNotEqual(seasonOne, RememberedPlaybackSelection.mediaKey(tmdbID: 42, isMovie: true, season: nil, animeID: nil))
        XCTAssertNotEqual(
            RememberedPlaybackSelection.mediaKey(tmdbID: 42, isMovie: false, season: 1, animeID: 100),
            RememberedPlaybackSelection.mediaKey(tmdbID: 42, isMovie: false, season: 1, animeID: 101)
        )
        XCTAssertNil(RememberedPlaybackSelection.mediaKey(tmdbID: 0, isMovie: false, season: 1, animeID: nil))
    }

    func testStreamRequiresUniqueMatchAndRetainsQualityAndLanguage() {
        let choice = selection(label: "Server A S01E01 1080p Japanese")
        XCTAssertEqual(choice.matchingStreamIndex(labels: ["Server A S01E02 720p Japanese", "Server A S01E02 1080p Japanese"]), 1)
        XCTAssertNil(choice.matchingStreamIndex(labels: ["Server A S01E02 1080p English"]))
        XCTAssertNil(choice.matchingStreamIndex(labels: ["Server A S01E02 1080p Japanese", "Server A S01E02 1080p Japanese"]))
        XCTAssertNil(choice.matchingStreamIndex(labels: []))
        XCTAssertNil(selection(label: "").matchingStreamIndex(labels: [""]))
        XCTAssertNil(selection(label: "Stream 1").matchingStreamIndex(labels: ["Stream 1"]))
        XCTAssertNil(selection(label: "Stream").matchingStreamIndex(labels: ["Stream"]))
        XCTAssertEqual(RememberedPlaybackSelection.normalizedLabel("1080p https://media.example/video?token=private"), "1080p")
    }

    func testSearchMatchesStableHrefBeforeTitleAndRejectsAmbiguity() {
        let choice = selection(label: "1080p", href: "https://source.example/show/42?credential=private", title: "Example S01E01")
        XCTAssertEqual(choice.matchingSearchIndex(hrefs: ["changed", "https://source.example/show/42?credential=private"], titles: ["Example S01E02", "Renamed"]), 1)
        XCTAssertEqual(choice.matchingSearchIndex(hrefs: ["changed"], titles: ["Example S01E02"]), 0)
        XCTAssertNil(choice.matchingSearchIndex(hrefs: ["a", "b"], titles: ["Example S01E02", "Example S01E02"]))
        XCTAssertNil(choice.matchingSearchIndex(hrefs: [], titles: ["Example S01E02"]))
    }

    func testChoicesStayInTheirExplicitProfileStoreAndDoNotSaveURLs() throws {
        try withStore { first in
            try withStore { second in
                first.set(true, forKey: RememberedPlaybackSettings.enabledKey)
                second.set(true, forKey: RememberedPlaybackSettings.enabledKey)
                let choice = selection(label: "1080p", href: "https://source.example/secret?token=private", title: "Example")
                RememberedPlaybackSelection.save(choice, key: "tv:1:season:1", defaults: first)
                XCTAssertEqual(RememberedPlaybackSelection.load(key: "tv:1:season:1", defaults: first), choice)
                XCTAssertTrue(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: nil, defaults: first))
                XCTAssertFalse(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 2, animeID: nil, defaults: first))
                XCTAssertFalse(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: 100, defaults: first))
                XCTAssertFalse(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: nil, defaults: second))
                first.set(false, forKey: RememberedPlaybackSettings.enabledKey)
                XCTAssertFalse(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: nil, defaults: first))
                first.set(true, forKey: RememberedPlaybackSettings.enabledKey)
                XCTAssertTrue(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: nil, defaults: first))
                XCTAssertNil(RememberedPlaybackSelection.load(key: "tv:1:season:1", defaults: second))
                let data = try XCTUnwrap(first.data(forKey: RememberedPlaybackSettings.storageKey))
                let encoded = String(decoding: data, as: UTF8.self)
                XCTAssertFalse(encoded.contains("https://"))
                XCTAssertFalse(encoded.contains("private"))
            }
        }
    }

    func testDisabledFeatureDoesNotReadOrWriteSavedChoices() throws {
        try withStore { store in
            RememberedPlaybackSelection.save(selection(label: "1080p"), key: "movie:1", defaults: store)
            XCTAssertNil(store.object(forKey: RememberedPlaybackSettings.storageKey))
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            RememberedPlaybackSelection.save(selection(label: "1080p"), key: "movie:1", defaults: store)
            store.set(false, forKey: RememberedPlaybackSettings.enabledKey)
            XCTAssertNil(RememberedPlaybackSelection.load(key: "movie:1", defaults: store))
            XCTAssertNotNil(store.data(forKey: RememberedPlaybackSettings.storageKey))
        }
    }

    func testUnreadableStoreIsPreserved() throws {
        try withStore { store in
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            let original = Data("broken archive".utf8)
            store.set(original, forKey: RememberedPlaybackSettings.storageKey)
            XCTAssertNil(RememberedPlaybackSelection.load(key: "movie:1", defaults: store))
            RememberedPlaybackSelection.save(selection(label: "1080p"), key: "movie:1", defaults: store)
            XCTAssertEqual(store.data(forKey: RememberedPlaybackSettings.storageKey), original)
        }
    }

    func testBoundEvictsOldestChoice() throws {
        try withStore { store in
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            for index in 0...200 {
                let choice = selection(label: "1080p", savedAt: Date(timeIntervalSince1970: Double(index)))
                RememberedPlaybackSelection.save(choice, key: "movie:\(index)", defaults: store)
            }
            XCTAssertNil(RememberedPlaybackSelection.load(key: "movie:0", defaults: store))
            XCTAssertNotNil(RememberedPlaybackSelection.load(key: "movie:200", defaults: store))
        }
    }

    func testNaturalEndRequiresKnownNearlyCompleteMedia() {
        XCTAssertTrue(AutoplayNextEpisodeSettings.isComplete(position: 1199, duration: 1200))
        XCTAssertFalse(AutoplayNextEpisodeSettings.isComplete(position: 1190, duration: 1200))
        XCTAssertFalse(AutoplayNextEpisodeSettings.isComplete(position: 100, duration: .nan))
        XCTAssertFalse(AutoplayNextEpisodeSettings.isComplete(position: .infinity, duration: 1200))
        XCTAssertFalse(AutoplayNextEpisodeSettings.isComplete(position: 0, duration: 0))
    }

    func testOversizedLabelsCannotMatchByTheirSharedPrefix() {
        let prefix = String(repeating: "Server ", count: 150)
        let original = selection(label: prefix + "1080p Japanese")
        XCTAssertEqual(original.streamLabel, "")
        XCTAssertNil(original.matchingStreamIndex(labels: [prefix + "720p English"]))
        XCTAssertEqual(RememberedPlaybackSelection.normalizedLabel(String(repeating: "a", count: 1_024)).count, 1_024)
        XCTAssertEqual(RememberedPlaybackSelection.normalizedLabel(String(repeating: "a", count: 1_025)), "")
    }

    func testEpisodeNormalizationRetainsServerCodecQualityAndLanguageDifferences() {
        let saved = selection(label: "Sérver A Episode 01 1080p HEVC Japanese")
        XCTAssertEqual(saved.matchingStreamIndex(labels: ["SERVER A ep 02 1080p HEVC Japanese"]), 0)
        for label in ["Server B Episode 02 1080p HEVC Japanese", "Server A Episode 02 720p HEVC Japanese",
                      "Server A Episode 02 1080p AVC Japanese", "Server A Episode 02 1080p HEVC English"] {
            XCTAssertNil(saved.matchingStreamIndex(labels: [label]))
        }
        XCTAssertNil(saved.matchingStreamIndex(labels: ["Server A E02 1080p HEVC Japanese", "SERVER A S01E02 1080p HEVC Japanese"]))
    }

    func testInvalidWritesPreserveLastReadableChoice() throws {
        try withStore { store in
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            let valid = selection(label: "1080p")
            RememberedPlaybackSelection.save(valid, key: "movie:1", defaults: store)
            let original = try XCTUnwrap(store.data(forKey: RememberedPlaybackSettings.storageKey))
            let invalid = RememberedPlaybackSelection(sourceID: "", searchHrefHash: nil, searchTitle: nil,
                streamLabel: "1080p", savedAt: Date(timeIntervalSince1970: 100))
            RememberedPlaybackSelection.save(invalid, key: "movie:1", defaults: store)
            RememberedPlaybackSelection.save(valid, key: String(repeating: "k", count: 161), defaults: store)
            RememberedPlaybackSelection.save(valid, key: nil, defaults: store)
            XCTAssertEqual(store.data(forKey: RememberedPlaybackSettings.storageKey), original)
            XCTAssertEqual(RememberedPlaybackSelection.load(key: "movie:1", defaults: store), valid)
        }
    }

    func testOversizedAndInvalidDecodedStoresRemainUnwritable() throws {
        try withStore { store in
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            let valid = selection(label: "1080p")
            let tooMany = Dictionary(uniqueKeysWithValues: (0...200).map { ("movie:\($0)", valid) })
            let invalid = RememberedPlaybackSelection(sourceID: "service:test", searchHrefHash: "bad", searchTitle: nil,
                streamLabel: "1080p", savedAt: Date(timeIntervalSince1970: 100))
            let archives = [Data(repeating: 0, count: 512 * 1_024 + 1),
                            try JSONEncoder().encode(tooMany),
                            try JSONEncoder().encode(["movie:1": invalid])]
            for archive in archives {
                store.set(archive, forKey: RememberedPlaybackSettings.storageKey)
                XCTAssertNil(RememberedPlaybackSelection.load(key: "movie:1", defaults: store))
                XCTAssertFalse(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 1, season: 1, animeID: nil, defaults: store))
                RememberedPlaybackSelection.save(valid, key: "movie:1", defaults: store)
                XCTAssertEqual(store.data(forKey: RememberedPlaybackSettings.storageKey), archive)
            }
            store.set("legacy invalid value", forKey: RememberedPlaybackSettings.storageKey)
            RememberedPlaybackSelection.save(valid, key: "movie:1", defaults: store)
            XCTAssertEqual(store.string(forKey: RememberedPlaybackSettings.storageKey), "legacy invalid value")
        }
    }

    func testEqualDateEvictionIsDeterministicAndRetainsExactlyTwoHundredChoices() throws {
        try withStore { store in
            store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
            let choice = selection(label: "1080p")
            let initial = Dictionary(uniqueKeysWithValues: (0..<200).map { (String(format: "movie:%03d", $0), choice) })
            store.set(try JSONEncoder().encode(initial), forKey: RememberedPlaybackSettings.storageKey)
            RememberedPlaybackSelection.save(choice, key: "movie:zzz", defaults: store)
            let data = try XCTUnwrap(store.data(forKey: RememberedPlaybackSettings.storageKey))
            XCTAssertEqual(try JSONDecoder().decode([String: RememberedPlaybackSelection].self, from: data), initial)
        }
    }

    func testMissingOrAmbiguousSearchChoiceRequiresManualSelection() {
        let missing = selection(label: "1080p", href: "https://example.test/original", title: "Original Show")
        XCTAssertNil(missing.matchingSearchIndex(hrefs: ["https://example.test/other"], titles: ["Other Show"]))
        XCTAssertNil(missing.matchingSearchIndex(hrefs: ["https://example.test/original", "https://example.test/original"], titles: ["Original Show", "Original Show"]))
        let noIdentity = selection(label: "1080p")
        XCTAssertNil(noIdentity.matchingSearchIndex(hrefs: ["https://example.test/only"], titles: ["Only Result"]))
        XCTAssertNil(noIdentity.matchingStreamIndex(labels: ["720p"]))
    }

    @MainActor
    func testSavedChoiceAppearingDuringPrestageDiscardsTheResolvedCandidate() async throws {
        let name = "RememberedPlaybackSelectionTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: RememberedPlaybackSettings.enabledKey)
        var attempts: [Int] = []
        var discarded: [String] = []
        var accepted: [String] = []
        let choice = selection(label: "Preferred Server 1080p")
        let outcome = await OrderedSourceResolutionRunner.run(inputs: [1, 2], isCurrent: {
            !RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 42, season: 1, animeID: nil, defaults: store)
        }, resolve: { candidate -> String? in
            attempts.append(candidate)
            await Task.yield()
            RememberedPlaybackSelection.save(choice, key: "tv:42:season:1", defaults: store)
            return "unrelated first stream"
        }, onAccepted: { _, stream in accepted.append(stream) }, discardStale: { discarded.append($0) })
        XCTAssertEqual(outcome, .invalidated)
        XCTAssertEqual(attempts, [1])
        XCTAssertEqual(discarded, ["unrelated first stream"])
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(RememberedPlaybackSettings.requiresSourceSelection(tmdbID: 42, season: 1, animeID: nil, defaults: store))
    }

    private func selection(label: String, href: String? = nil, title: String? = nil, savedAt: Date = Date(timeIntervalSince1970: 100)) -> RememberedPlaybackSelection {
        RememberedPlaybackSelection(
            sourceID: "service:example",
            searchHrefHash: href.map(RememberedPlaybackSelection.hrefHash),
            searchTitle: title.map(RememberedPlaybackSelection.normalizedLabel),
            streamLabel: RememberedPlaybackSelection.normalizedLabel(label),
            savedAt: savedAt
        )
    }

    private func withStore(_ body: (UserDefaults) throws -> Void) throws {
        let name = "RememberedPlaybackSelectionTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        try body(store)
    }
}
