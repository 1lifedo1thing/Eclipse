import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerLibraryContextTests: XCTestCase {
    func testVideoLibrariesExcludeReaderKinds() {
        XCTAssertEqual(TrackerLibraryContext.video.kinds(for: .anilist), [.anime])
        XCTAssertEqual(TrackerLibraryContext.video.kinds(for: .myAnimeList), [.anime])
        XCTAssertEqual(TrackerLibraryContext.video.kinds(for: .trakt), [.movie, .show])
        XCTAssertTrue(TrackerLibraryContext.video.kinds(for: .simkl).isEmpty)
        XCTAssertEqual(TrackerLibraryContext.video.sources, [.local, .anilist, .myAnimeList, .trakt])
    }

    func testReaderLibrariesExposeOnlyReadingTrackers() {
#if os(tvOS)
        XCTAssertTrue(TrackerLibraryContext.reader.kinds(for: .anilist).isEmpty)
        XCTAssertTrue(TrackerLibraryContext.reader.kinds(for: .myAnimeList).isEmpty)
        XCTAssertEqual(TrackerLibraryContext.reader.sources, [.local])
#else
        XCTAssertEqual(TrackerLibraryContext.reader.kinds(for: .anilist), [.manga, .lightNovel])
        XCTAssertEqual(TrackerLibraryContext.reader.kinds(for: .myAnimeList), [.manga, .lightNovel])
        XCTAssertEqual(TrackerLibraryContext.reader.sources, [.local, .anilist, .myAnimeList])
#endif
        XCTAssertTrue(TrackerLibraryContext.reader.kinds(for: .trakt).isEmpty)
        XCTAssertTrue(TrackerLibraryContext.reader.kinds(for: .simkl).isEmpty)
    }
}

final class TrackerLibraryMediaMatchTests: XCTestCase {
    func testTitleNormalizationRetainsNumbersAndSeasonIdentity() {
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.normalized("Café: Ｈｅｒｏ 2"), "cafe hero 2")
        XCTAssertNotEqual(TrackerLibraryMediaMatchPolicy.normalized("Hero 2"), TrackerLibraryMediaMatchPolicy.normalized("Hero"))
    }

    func testExactUniqueAliasMatchesRegardlessOfPopularity() throws {
        let match = TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(alternates: ["Hero's Journey"]), candidates: [result(id: 1, title: "Popular Hero", popularity: 1000), result(id: 2, title: "Hero’s Journey")])
        XCTAssertEqual(try XCTUnwrap(match).id, 2)
    }

    func testSubstringAndPopularityNeverAuthorizeMatch() {
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [result(id: 1, title: "Hero Academy", popularity: 1000)]))
    }

    func testAmbiguousRemakesRequireManualChoiceWithoutYear() {
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [result(id: 1, year: 1999), result(id: 2, year: 2024)]))
    }

    func testKnownYearDisambiguatesAndUnknownYearFailsOpenToChoice() {
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(year: 2024), candidates: [result(id: 1, year: 1999), result(id: 2, year: 2024)])?.id, 2)
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(year: 2024), candidates: [result(id: 1, year: nil)]))
    }

    func testAnimeMovieCannotResolveToSeriesWithSameName() {
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(format: "MOVIE"), candidates: [result(id: 1), result(id: 2, type: "movie")])?.id, 2)
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(format: "MOVIE"), candidates: [result(id: 1)]))
    }

    func testUnknownAnimeFormatDoesNotSilentlyPreferTVToMovie() {
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [result(id: 1), result(id: 2, type: "movie")]))
    }

    func testAnimeTitleDoesNotMatchUnrelatedLiveActionNamesake() {
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [result(id: 1, genres: [18])]))
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [result(id: 1, genres: nil)]))
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(kind: .show), candidates: [result(id: 1, genres: [18])])?.id, 1)
    }

    func testDuplicateSearchRowsDoNotCreateFalseAmbiguity() {
        let value = result(id: 1)
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: [value, value])?.id, 1)
    }

    func testTraktKindRestrictsSearchMediaType() {
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(kind: .movie), candidates: [result(id: 1)]))
        XCTAssertNil(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(kind: .show), candidates: [result(id: 1, type: "movie")]))
    }

    func testHundredsOfPopularNearMatchesCannotHideExactMatch() {
        let rows = (1...1_000).map { result(id: $0, title: "Hero \($0)", popularity: 1_000) } + [result(id: 2_000)]
        XCTAssertEqual(TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry(), candidates: rows)?.id, 2_000)
    }

    func testResolutionMetadataPreservesProgressAndStatusUpdates() {
        let original = entry()
        var updated = original
        updated.progress = 12
        updated.status = .completed
        updated.score = 80
        updated.updatedAt = Date()
        updated.customLists = ["Favorites"]
        updated.customListMembershipIsKnown = true
        XCTAssertTrue(original.hasSameResolutionMetadata(as: updated))
    }

    func testResolutionMetadataRejectsChangedMappingAndSearchMetadata() {
        let original = entry()
        XCTAssertFalse(original.hasSameResolutionMetadata(as: entry(title: "Hero 2")))
        XCTAssertFalse(original.hasSameResolutionMetadata(as: entry(alternates: ["Different Hero"])))
        XCTAssertFalse(original.hasSameResolutionMetadata(as: entry(format: "MOVIE")))
        XCTAssertFalse(original.hasSameResolutionMetadata(as: entry(year: 2024)))
        XCTAssertFalse(original.hasSameResolutionMetadata(as: entry(malID: 20)))
        var changedMapping = original
        changedMapping.tmdbID = 42
        XCTAssertFalse(original.hasSameResolutionMetadata(as: changedMapping))
        changedMapping = original
        changedMapping.imdbID = "tt1234567"
        XCTAssertFalse(original.hasSameResolutionMetadata(as: changedMapping))
    }

    func testResolutionMetadataKeepsDistinctTrackerSeasonsSharingTMDBSeriesSeparate() {
        var first = entry()
        var second = entry(mediaID: 2)
        first.tmdbID = 42
        second.tmdbID = 42
        XCTAssertFalse(first.hasSameResolutionMetadata(as: second))
    }

    private func entry(kind: TrackerLibraryKind = .anime, alternates: [String] = [], format: String? = nil, year: Int? = nil,
                       title: String = "Hero", mediaID: Int = 1, malID: Int? = nil) -> TrackerLibraryEntry {
        TrackerLibraryEntry(service: .anilist, kind: kind, mediaID: mediaID, entryID: nil, aniListID: mediaID, malID: malID, title: title, alternateTitles: alternates,
            coverLarge: nil, coverMedium: nil, total: nil, genres: [], averageScore: nil, status: .current, progress: 0, score: 0, updatedAt: nil, format: format, year: year)
    }

    private func result(id: Int, title: String = "Hero", type: String = "tv", year: Int? = nil, popularity: Double = 1, genres: [Int]? = [16]) -> TMDBSearchResult {
        let date = year.map { "\($0)-01-01" }
        return TMDBSearchResult(id: id, mediaType: type, title: type == "movie" ? title : nil, name: type == "tv" ? title : nil,
            overview: nil, posterPath: nil, backdropPath: nil, releaseDate: type == "movie" ? date : nil, firstAirDate: type == "tv" ? date : nil,
            voteAverage: nil, popularity: popularity, adult: false, genreIds: genres)
    }
}
