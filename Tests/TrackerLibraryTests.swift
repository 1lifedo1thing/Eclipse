import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class TrackerLibraryTests: XCTestCase {
    func testIntegrationDefaultsOffAndUsesExplicitStore() throws {
        let name = "TrackerLibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(TrackerLibrarySettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: TrackerLibrarySettings.enabledKey)
        XCTAssertTrue(TrackerLibrarySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: TrackerLibrarySettings.enabledKey), .profile)
    }

    func testSameProfileAfterABARemainsUnauthorized() {
        let initial = session()
        let returned = session(owner: initial.owner, operation: 3)
        XCTAssertFalse(initial.authorizes(returned, enabled: true, isKids: false))
        XCTAssertTrue(initial.authorizes(initial, enabled: true, isKids: false))
    }

    func testAccountReconnectAndCloudBoundaryRevokeSession() {
        let initial = session()
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, account: 2), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, service: 2), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(session(owner: initial.owner, user: "replacement"), enabled: true, isKids: false))
        XCTAssertFalse(initial.authorizes(initial, enabled: false, isKids: false))
        XCTAssertFalse(initial.authorizes(initial, enabled: true, isKids: true))
    }

    func testAniListPagePreservesCanonicalScoreAndMangaProgress() throws {
        let result = try TrackerAniListLibraryPage.decode(aniListData(kind: .manga), kind: .manga)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.kind, .manga)
        XCTAssertEqual(entry.progress, 8)
        XCTAssertEqual(entry.total, 120)
        XCTAssertEqual(entry.score, 85)
        XCTAssertEqual(entry.title, "Example")
        XCTAssertFalse(result.hasNext)
    }

    func testAniListRejectsPartialGraphQLErrorAndWrongMediaType() throws {
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(errors: true), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(kind: .manga), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(progress: -1), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(status: "NEW_UNKNOWN_STATUS"), kind: .anime))
    }

    func testMALUsesRepeatingFlagAndCorrectProgressUnits() throws {
        let anime = try XCTUnwrap(TrackerMALLibraryPage.decode(malData(kind: .anime, repeating: true), kind: .anime).entries.first)
        let manga = try XCTUnwrap(TrackerMALLibraryPage.decode(malData(kind: .manga, repeating: true), kind: .manga).entries.first)
        XCTAssertEqual(anime.status, .repeating)
        XCTAssertEqual(manga.status, .repeating)
        XCTAssertEqual(anime.progress, 8)
        XCTAssertEqual(manga.progress, 21)
        XCTAssertEqual(manga.score, 90)
        XCTAssertEqual(manga.averageScore, 82)
        XCTAssertEqual(TrackerLibraryStatus.repeating.title(for: .manga), "Rereading")
    }

    func testMALContinuationCannotSendCredentialsToAnotherEndpoint() throws {
        for next in [
            "https://attacker.example/v2/users/@me/animelist",
            "http://api.myanimelist.net/v2/users/@me/animelist",
            "https://api.myanimelist.net/v2/users/@me/mangalist",
            "https://user:secret@api.myanimelist.net/v2/users/@me/animelist",
            "https://api.myanimelist.net/v2/anime/1"
        ] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime))
        }
        let next = "https://api.myanimelist.net/v2/users/@me/animelist?offset=100&limit=100"
        let result = try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime)
        var sequence = TrackerRemoteProgressBoundary.PageSequence()
        let url = try XCTUnwrap(result.next)
        XCTAssertTrue(sequence.beginMALPage(url, listKind: .anime))
        XCTAssertFalse(sequence.beginMALPage(url, listKind: .anime))
    }

    func testUnchangedFieldsAreNeverWrittenBack() throws {
        let original = entry()
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 95
        let values = edit.aniListValues(original: original)
        XCTAssertEqual(Set(values.keys), ["scoreRaw"])
        XCTAssertEqual(values["scoreRaw"] as? Int, 95)
        XCTAssertTrue(TrackerLibraryEdit(entry: original).aniListValues(original: original).isEmpty)
    }

    func testMALRepeatingTransitionClearsFlagWithoutOverwritingProgressOrRating() {
        let original = entry(service: .myAnimeList, kind: .manga, status: .repeating)
        var edit = TrackerLibraryEdit(entry: original)
        edit.status = .paused
        XCTAssertEqual(edit.malValues(original: original), ["status": "on_hold", "is_rereading": "false"])
        edit.status = .repeating
        edit.progress = 9
        XCTAssertEqual(edit.malValues(original: original), ["num_chapters_read": "9"])
        let anime = entry(service: .myAnimeList)
        edit = TrackerLibraryEdit(entry: anime)
        edit.progress = 9
        XCTAssertEqual(edit.malValues(original: anime), ["num_watched_episodes": "9"])
    }

    func testConcurrentChangesConflictOnlyForFieldsTheUserEdited() {
        let original = entry()
        var remote = original
        remote.progress = 9
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 90
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        edit.progress = 10
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        edit.progress = 9
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
    }

    func testProgressAndScoreEditsRejectInvalidOrOverflowingNumbers() throws {
        let original = entry(service: .myAnimeList)
        var edit = TrackerLibraryEdit(entry: original)
        edit.progress = Int.max
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 13
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 0
        edit.score = .nan
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.score = 85
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.score = 80
        XCTAssertNoThrow(try edit.validate(against: original))
    }

    func testDuplicateCustomListsDoNotDuplicateRowsOrMergeDifferentServices() throws {
        let first = entry()
        let second = entry(service: .myAnimeList)
        var entries: [TrackerLibraryEntry] = []
        try TrackerLibraryPolicy.append([first, first], to: &entries)
        try TrackerLibraryPolicy.append([first, second], to: &entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testSearchUsesAlternateTitlesAndCombinesGenreFilter() {
        let item = entry()
        XCTAssertEqual(TrackerLibraryPolicy.filtered([item], search: " Japanese ", genre: "Comedy").count, 1)
        XCTAssertTrue(TrackerLibraryPolicy.filtered([item], search: "Japanese", genre: "Drama").isEmpty)
        XCTAssertTrue(TrackerLibraryPolicy.filtered([item], search: "missing", genre: nil).isEmpty)
    }

    func testImageURLsRejectCredentialsAndNonHTTPS() {
        XCTAssertNil(TrackerLibraryPolicy.imageURL("file:///tmp/image.png"))
        XCTAssertNil(TrackerLibraryPolicy.imageURL("http://images.example/cover.jpg"))
        XCTAssertNil(TrackerLibraryPolicy.imageURL("https://user:secret@images.example/cover.jpg"))
        XCTAssertNotNil(TrackerLibraryPolicy.imageURL("https://images.example/cover.jpg"))
    }

    func testSessionsCannotCrossProfilesOrTrackerServices() {
        let initial = session()
        XCTAssertFalse(initial.authorizes(session(), enabled: true, isKids: false))
        let otherService = TrackerLibrarySession(owner: initial.owner,
            operationGeneration: initial.operationGeneration, accountGeneration: initial.accountGeneration,
            serviceGeneration: initial.serviceGeneration, service: .myAnimeList, userID: initial.userID)
        XCTAssertFalse(initial.authorizes(otherService, enabled: true, isKids: false))
    }

    func testAniListEmptyCompletedPageDiffersFromMissingOrPartialData() throws {
        let empty = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 0), kind: .anime)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertFalse(empty.hasNext)
        let continued = try TrackerAniListLibraryPage.decode(aniListData(entryCount: 0, hasNext: true), kind: .anime)
        XCTAssertTrue(continued.hasNext)
        for payload in [#"{}"#, #"{"data":null}"#, #"{"data":{"MediaListCollection":null}}"#] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(Data(payload.utf8), kind: .anime))
        }
    }

    func testAniListRejectsContradictoryIdentityAndUnboundedMetadata() throws {
        for changes: [String: Any] in [["mediaId": 43], ["id": 0], ["progress": NSNull()],
                                      ["progress": TrackerLibraryPolicy.maximumProgress + 1], ["score": 101]] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryChanges: changes), kind: .anime))
        }
        for changes: [String: Any] in [["id": 0], ["episodes": -1], ["averageScore": 101],
                                      ["genres": Array(repeating: "Genre", count: 65)],
                                      ["title": ["english": String(repeating: "x", count: 4_097)]]] {
            XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(mediaChanges: changes), kind: .anime))
        }
    }

    func testAniListBoundsGroupsCombinedRowsAndResponseBytes() throws {
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(groupCount: 101), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryCount: 1_001), kind: .anime))
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(aniListData(entryCount: 501, groupCount: 2), kind: .anime))
        let bytes = Data(repeating: 0x20, count: TrackerLibraryPolicy.maximumResponseBytes + 1)
        XCTAssertThrowsError(try TrackerAniListLibraryPage.decode(bytes, kind: .anime)) { error in
            guard case TrackerLibraryError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMALRejectsMissingProgressFractionalRatingAndInvalidMetadata() throws {
        for kind in TrackerLibraryKind.allCases {
            let key = kind == .anime ? "num_episodes_watched" : "num_chapters_read"
            for changes: [String: Any] in [[key: NSNull()], [key: -1], ["score": 8.5],
                                          ["score": 11], ["status": "unknown"]] {
                XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(kind: kind, statusChanges: changes), kind: kind))
            }
            let valid = try TrackerMALLibraryPage.decode(malData(kind: kind, statusChanges: ["score": 0]), kind: kind)
            XCTAssertEqual(valid.entries.first?.score, 0)
        }
        for changes: [String: Any] in [["id": 0], ["mean": -1], ["num_episodes": -1]] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(nodeChanges: changes), kind: .anime))
        }
    }

    func testMALBoundsPagesAndRejectsFragmentsPortsAndRelativeContinuations() throws {
        XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(entryCount: TrackerLibraryPolicy.pageSize + 1), kind: .anime))
        XCTAssertTrue(try TrackerMALLibraryPage.decode(malData(entryCount: 0), kind: .anime).entries.isEmpty)
        for next in ["/v2/users/@me/animelist?offset=100",
                     "https://api.myanimelist.net:443/v2/users/@me/animelist",
                     "https://api.myanimelist.net/v2/users/@me/animelist#fragment",
                     "https://api.myanimelist.net.attacker.example/v2/users/@me/animelist"] {
            XCTAssertThrowsError(try TrackerMALLibraryPage.decode(malData(next: next), kind: .anime))
        }
        let next = "https://api.myanimelist.net/v2/users/@me/mangalist?offset=100&limit=100"
        XCTAssertEqual(try TrackerMALLibraryPage.decode(malData(kind: .manga, next: next), kind: .manga).next?.absoluteString, next)
    }

    func testRatingOnlyEditPreservesProgressAboveOutdatedTotal() throws {
        let original = entry(progress: 20, total: 12)
        var edit = TrackerLibraryEdit(entry: original)
        edit.score = 90
        XCTAssertNoThrow(try edit.validate(against: original))
        XCTAssertEqual(Set(edit.aniListValues(original: original).keys), ["scoreRaw"])
        edit.progress = 21
        XCTAssertThrowsError(try edit.validate(against: original))
        edit.progress = 12
        XCTAssertNoThrow(try edit.validate(against: original))
        for total: Int? in [nil, 0] {
            let unknownTotal = entry(total: total)
            var unknownEdit = TrackerLibraryEdit(entry: unknownTotal)
            unknownEdit.progress = TrackerLibraryPolicy.maximumProgress
            XCTAssertNoThrow(try unknownEdit.validate(against: unknownTotal))
        }
    }

    func testConflictsCoverStatusRatingAndIdentityWithoutClobberingConvergedEdits() {
        let original = entry()
        var edit = TrackerLibraryEdit(entry: original)
        edit.status = .completed
        var remote = original
        remote.status = .dropped
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        remote.status = .completed
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        edit.score = 95
        remote.score = 90
        XCTAssertTrue(edit.conflicts(original: original, current: remote))
        remote.score = 95
        XCTAssertFalse(edit.conflicts(original: original, current: remote))
        for other in [entry(mediaID: 43), entry(kind: .manga), entry(service: .myAnimeList)] {
            XCTAssertTrue(TrackerLibraryEdit(entry: original).conflicts(original: original, current: other))
        }
    }

    func testAppendLimitsDoNotEvictAlreadyLoadedEntries() throws {
        var entries = [entry()]
        XCTAssertThrowsError(try TrackerLibraryPolicy.append(Array(repeating: entry(), count: 1_001), to: &entries))
        XCTAssertEqual(entries, [entry()])
        entries = (1...TrackerLibraryPolicy.maximumEntries).map { entry(mediaID: $0) }
        XCTAssertNoThrow(try TrackerLibraryPolicy.append([entry(mediaID: 1)], to: &entries))
        XCTAssertThrowsError(try TrackerLibraryPolicy.append([entry(mediaID: TrackerLibraryPolicy.maximumEntries + 1)], to: &entries))
        XCTAssertEqual(entries.count, TrackerLibraryPolicy.maximumEntries)
        XCTAssertEqual(entries.first?.mediaID, 1)
        XCTAssertEqual(entries.last?.mediaID, TrackerLibraryPolicy.maximumEntries)
    }

    func testMALStatusRoundTripsAndRatingClearRemainKindSpecific() {
        for kind in TrackerLibraryKind.allCases {
            for status in TrackerLibraryStatus.allCases {
                XCTAssertEqual(TrackerLibraryStatus.fromMAL(status.malValue(for: kind), repeating: status == .repeating), status)
            }
            let original = entry(service: .myAnimeList, kind: kind)
            var edit = TrackerLibraryEdit(entry: original)
            edit.score = 0
            XCTAssertEqual(edit.malValues(original: original), ["score": "0"])
            edit.status = .repeating
            XCTAssertEqual(edit.malValues(original: original)[kind == .anime ? "is_rewatching" : "is_rereading"], "true")
            XCTAssertNil(edit.malValues(original: original)[kind == .anime ? "is_rereading" : "is_rewatching"])
        }
    }

    private func session(owner: UUID = UUID(), operation: UInt64 = 1, account: UInt64 = 1, service: UInt64 = 1, user: String = "42") -> TrackerLibrarySession {
        TrackerLibrarySession(owner: owner, operationGeneration: operation, accountGeneration: account, serviceGeneration: service, service: .anilist, userID: user)
    }

    private func entry(service: TrackerService = .anilist, kind: TrackerLibraryKind = .anime, status: TrackerLibraryStatus = .current, mediaID: Int = 42, progress: Int = 8, total: Int? = 12) -> TrackerLibraryEntry {
        TrackerLibraryEntry(service: service, kind: kind, mediaID: mediaID, entryID: 24, aniListID: mediaID, malID: 13, title: "Example", alternateTitles: ["Japanese Title"], coverLarge: nil, coverMedium: nil, total: total, genres: ["Comedy"], averageScore: 80, status: status, progress: progress, score: 80, updatedAt: nil)
    }

    private func aniListData(kind: TrackerLibraryKind = .anime, errors: Bool = false, progress: Int = 8, status: String = "CURRENT", entryCount: Int = 1, groupCount: Int = 1, hasNext: Bool = false, entryChanges: [String: Any] = [:], mediaChanges: [String: Any] = [:]) throws -> Data {
        var media: [String: Any] = ["id": 42, "idMal": 13, "type": kind.rawValue, "title": ["english": "Example"], "episodes": 12, "chapters": 120, "genres": ["Comedy"], "averageScore": 82]
        media.merge(mediaChanges) { _, updated in updated }
        var entry: [String: Any] = ["id": 24, "mediaId": 42, "status": status, "progress": progress, "score": 85, "media": media]
        entry.merge(entryChanges) { _, updated in updated }
        let groups = Array(repeating: ["entries": Array(repeating: entry, count: entryCount)], count: groupCount)
        var payload: [String: Any] = ["data": ["MediaListCollection": ["hasNextChunk": hasNext, "lists": groups]]]
        if errors { payload["errors"] = [["message": "Partial data"]] }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func malData(kind: TrackerLibraryKind = .anime, repeating: Bool = false, next: String? = nil, entryCount: Int = 1, nodeChanges: [String: Any] = [:], statusChanges: [String: Any] = [:]) throws -> Data {
        var node: [String: Any] = ["id": 13, "title": "Example", "num_episodes": 12, "num_chapters": 120, "genres": [["name": "Comedy"]], "mean": 8.2]
        node.merge(nodeChanges) { _, updated in updated }
        var status: [String: Any] = ["status": kind == .anime ? "watching" : "reading", "score": 9, "num_episodes_watched": 8, "num_chapters_read": 21, "is_rewatching": repeating, "is_rereading": repeating]
        status.merge(statusChanges) { _, updated in updated }
        var payload: [String: Any] = ["data": Array(repeating: ["node": node, "list_status": status], count: entryCount)]
        if let next { payload["paging"] = ["next": next] }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
