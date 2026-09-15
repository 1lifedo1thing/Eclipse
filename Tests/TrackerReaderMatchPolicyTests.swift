import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerReaderMatchPolicyTests: XCTestCase {
    private func candidate(_ id: String, source: String? = nil, title: String = "One Piece", language: Int = 0, chapters: Int = 100, verified: Bool = true, order: Int = 0) -> TrackerReaderMatchPolicy.Candidate {
        .init(id: id, sourceID: source ?? id, title: title, languageRank: language, chapterCount: chapters, chapterCountVerified: verified, sourceOrder: order)
    }

    func testExactAliasWinsOverWrongLongerTitle() {
        let values = [candidate("wrong", title: "One Piece Party", chapters: 5_000), candidate("right", chapters: 40)]
        XCTAssertEqual(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true), "right")
    }

    func testPreferredLanguageWinsBeforeChapterCount() {
        let values = [candidate("preferred", chapters: 20), candidate("other", language: 1, chapters: 1_200)]
        XCTAssertEqual(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true), "preferred")
    }

    func testMostDistinctChaptersWinsAmongSameLanguageExactMatches() {
        let values = [candidate("shorter", chapters: 20), candidate("longer", chapters: 1_100)]
        XCTAssertEqual(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true), "longer")
    }

    func testSameSourceDuplicateTitleNeedsManualChoice() {
        let values = [candidate("original", source: "a"), candidate("edition", source: "a", chapters: 5_000)]
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true))
    }

    func testIncompleteSourceSearchNeverChoosesAutomatically() {
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID([candidate("a")], aliases: ["One Piece"], completed: false))
    }

    func testUnverifiedPreferredSourcePreventsChapterCountSelection() {
        let values = [candidate("known", chapters: 20), candidate("unknown", chapters: 2_000, verified: false)]
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true))
    }

    func testNoChapterAndApproximateMatchesRequireManualChoice() {
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID([candidate("a", chapters: 0)], aliases: ["One Piece"], completed: true))
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID([candidate("a", title: "One Piece Party")], aliases: ["One Piece"], completed: true))
        XCTAssertNil(TrackerReaderMatchPolicy.automaticMatchID([candidate("a")], aliases: [], completed: true))
    }

    func testAliasesNormalizeTypographyWithoutDroppingSequelWords() {
        XCTAssertEqual(TrackerReaderMatchPolicy.titleScore("Café & Ｍａｇｉｃ", aliases: ["Cafe and Magic"]), 100)
        XCTAssertEqual(TrackerReaderMatchPolicy.titleScore("海賊王", aliases: ["One Piece", "海賊王"]), 100)
        XCTAssertLessThan(TrackerReaderMatchPolicy.titleScore("Tokyo Ghoul re", aliases: ["Tokyo Ghoul"]), 100)
        XCTAssertLessThan(TrackerReaderMatchPolicy.titleScore("Naruto 2", aliases: ["Naruto"]), 100)
    }

    func testChapterVariantsAndDecimalSpellingDoNotInflateCount() {
        let result = TrackerReaderMatchPolicy.distinctChapterCount(["Chapter 1 [Group 2]", "Ch. 01", "1.0 - Another scan", "Chapter 1.5", "Chapter 01.50", "Chapter 2"])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.verified)
    }

    func testChapterNumberWinsOverVolumeAndTrailingYear() {
        let result = TrackerReaderMatchPolicy.distinctChapterCount(["Vol. 7 Chapter 12 Anniversary 2026", "Chapter 12", "Chapter 13"])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.verified)
    }

    func testUnknownAndOversizedChapterListsAreNotVerified() {
        XCTAssertFalse(TrackerReaderMatchPolicy.distinctChapterCount(["Oneshot", "Bonus"]).verified)
        XCTAssertFalse(TrackerReaderMatchPolicy.distinctChapterCount([]).verified)
        XCTAssertFalse(TrackerReaderMatchPolicy.distinctChapterCount(Array(repeating: "Chapter 1", count: 20_001)).verified)
    }

    func testStableTieBreakAndDuplicateRouteDeduplication() {
        let values = [candidate("b", order: 2), candidate("a", order: 1), candidate("a", order: 1)]
        XCTAssertEqual(TrackerReaderMatchPolicy.ranked(values, aliases: ["One Piece"]).map(\.id), ["a", "b"])
        XCTAssertEqual(TrackerReaderMatchPolicy.automaticMatchID(values, aliases: ["One Piece"], completed: true), "a")
    }

    func testPreloadedChaptersEvictOldestAndRejectAnOversizedTitle() {
        var cache = TrackerReaderPreloadCache<String>()
        let old = UUID()
        let current = UUID()
        XCTAssertTrue(cache.insert("old", id: old, rows: 25_000))
        XCTAssertTrue(cache.insert("current", id: current, rows: 20_000))
        XCTAssertNil(cache.value(for: old))
        XCTAssertEqual(cache.value(for: current), "current")
        XCTAssertEqual(cache.retainedRows, 20_000)
        XCTAssertFalse(cache.insert("oversized", id: UUID(), rows: Int.max))
        XCTAssertEqual(cache.retainedRows, 20_000)
    }

    func testPreloadedTitleCountAndReplacementDoNotLeakRows() {
        var cache = TrackerReaderPreloadCache<Int>()
        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() { XCTAssertTrue(cache.insert(index, id: id, rows: 1)) }
        XCTAssertEqual(cache.count, 32)
        XCTAssertEqual(cache.retainedRows, 32)
        XCTAssertNil(cache.value(for: ids[0]))
        XCTAssertTrue(cache.insert(100, id: ids[39], rows: 100))
        XCTAssertEqual(cache.retainedRows, 131)
        cache.remove(ids[39])
        XCTAssertEqual(cache.retainedRows, 31)
    }
}
