import Foundation
import SwiftSoup
import UIKit
import XCTest
@testable import Eclipse

#if os(iOS)
final class ReaderNovelDocumentTests: XCTestCase {
    func testFormattingAndFootnotesSurviveWhileActiveAndRemoteContentIsRemoved() throws {
        let document = try ReaderNovelDocument(bodyHTML: """
        <style>p{display:none}</style><script>window.location='https://evil.example'</script>
        <h2 id="chapter">Chapter</h2><p dir="rtl"><ruby>字<rt>ji</rt></ruby><sup><a href="#note">1</a></sup></p>
        <aside id="note">Footnote <a href="#chapter">Return</a></aside>
        <a href="https://evil.example">External</a><img src="https://evil.example/track" onerror="bad()">
        <iframe src="https://evil.example"></iframe><p style="display:none" onclick="bad()">Visible</p>
        """)
        let parsed = try SwiftSoup.parse(document.bodyHTML)
        XCTAssertEqual(try parsed.select("ruby rt").text(), "ji")
        XCTAssertEqual(try parsed.select("p[dir=rtl]").size(), 1)
        XCTAssertEqual(try parsed.select("a[href='#novel-note']").size(), 1)
        XCTAssertEqual(try parsed.select("a[href='#novel-chapter']").size(), 1)
        XCTAssertEqual(try parsed.select("#novel-note").text(), "Footnote Return")
        XCTAssertTrue(try parsed.select("script,style,iframe,img,[onclick],[onerror]").isEmpty())
        XCTAssertFalse(document.bodyHTML.contains("evil.example"))
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
        let isolated = try ReaderExtensionNovelSanitizer.isolatedDocument(bodyHTML: document.bodyHTML)
        XCTAssertTrue(isolated.contains("default-src 'none'"))
        XCTAssertTrue(isolated.contains("img-src data:"))
        XCTAssertTrue(isolated.contains("connect-src 'none'"))
    }

    func testBoundedInlineIllustrationLargerThanTagBudgetSurvivesOfflineRoundTrip() throws {
        let image = try imageData(padding: 80_000)
        let src = try ReaderExtensionNovelSanitizer.embeddedImageURL(image)
        XCTAssertGreaterThan(src.utf8.count, 64 * 1_024)
        let document = try ReaderNovelDocument(bodyHTML: "<h1>Illustration</h1><figure><img src='\(src)' alt='Illustration'><figcaption>Caption</figcaption></figure>")
        let restored = try ReaderNovelDocument.decode(document.encoded())
        XCTAssertEqual(restored, document)
        let parsed = try SwiftSoup.parse(restored.bodyHTML)
        XCTAssertEqual(try parsed.select("img").attr("src"), src)
        XCTAssertEqual(try parsed.select("figcaption").text(), "Caption")
        XCTAssertThrowsError(try ReaderExtensionNovelSanitizer.embeddedImageURL(Data("<svg/>".utf8)))
        XCTAssertThrowsError(try ReaderExtensionNovelSanitizer.embeddedImageURL(Data(repeating: 0, count: ReaderExtensionNovelSanitizer.maximumImageBytes + 1)))
    }

    func testChapterDecodedPixelBudgetRejectsManyHighlyCompressedIllustrations() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 2000), format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
        }
        let png = try XCTUnwrap(image.pngData())
        let src = try ReaderExtensionNovelSanitizer.embeddedImageURL(png)
        let html = "<p>Illustrations</p>" + String(repeating: "<img src='\(src)'>", count: 7)
        XCTAssertLessThan(png.count * 7, ReaderExtensionNovelSanitizer.maximumAggregateImageBytes)
        XCTAssertThrowsError(try ReaderNovelDocument(bodyHTML: html)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
    }

    func testSourceImagesAreResolvedThroughHostFetcherAndDuplicateURLsAreReused() async throws {
        let image = try imageData()
        let baseURL = try XCTUnwrap(URL(string: "https://source.example/book/chapter"))
        var requested: [URL] = []
        let document = try await ReaderExtensionNovelSanitizer.prepareDocument(
            "<p>Text</p><img src='../illustration.png'><img src='../illustration.png'><img src='data:text/html;base64,PHNjcmlwdD4='>",
            baseURL: baseURL
        ) { url in
            requested.append(url)
            return image
        }
        XCTAssertEqual(requested.map(\.absoluteString), ["https://source.example/illustration.png"])
        let parsed = try SwiftSoup.parse(document.bodyHTML)
        XCTAssertEqual(try parsed.select("img").size(), 2)
        XCTAssertTrue(try parsed.select("img").allSatisfy { try $0.attr("src").hasPrefix("data:image/png;base64,") })
        XCTAssertFalse(document.bodyHTML.contains("source.example"))
    }

    func testFailedImageFetchRefusesAnIncompleteDownloadedDocument() async throws {
        let url = try XCTUnwrap(URL(string: "https://source.example"))
        do {
            _ = try await ReaderExtensionNovelSanitizer.prepareDocument("<p>Text</p><img src='/image.png'>", baseURL: url) { _ in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("A failed illustration must not silently become a complete offline document.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testOnlineMissingIllustrationKeepsReadableTextAndShowsRetryWithoutWeakeningOffline() async throws {
        let url = try XCTUnwrap(URL(string: "https://source.example"))
        var requests = 0
        let document = try await ReaderExtensionNovelSanitizer.prepareDocument(
            "<p>Readable chapter</p><img src='/missing.png'><img src='/missing.png'>",
            baseURL: url,
            requiresCompleteImages: false
        ) { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(document.plainText.contains("Readable chapter"))
        XCTAssertTrue(document.plainText.contains("Reload the chapter to retry"))
        XCTAssertFalse(document.bodyHTML.contains("source.example"))
        do {
            _ = try await ReaderExtensionNovelSanitizer.prepareDocument("<p>Text</p><img src='/missing.png'>", baseURL: url, requiresCompleteImages: false) { _ in
                throw ReaderExtensionError.domainConsentRequired("source.example")
            }
            XCTFail("Online image fallback must not swallow a missing source-domain approval.")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .domainConsentRequired("source.example"))
        }
    }

    func testUnsupportedVersionAndDanglingOrDuplicateFragmentsCannotBecomeNavigation() throws {
        XCTAssertThrowsError(try ReaderNovelDocument.decode(Data("{\"version\":999,\"bodyHTML\":\"<p>Text</p>\"}".utf8)))
        XCTAssertThrowsError(try ReaderNovelDocument(bodyHTML: "<script>bad()</script><img src='https://evil.example'>"))
        let document = try ReaderNovelDocument(bodyHTML: "<p id='same'>First</p><p id='same'>Second</p><a href='#same'>Found</a><a href='#missing'>Missing</a><a href='javascript:bad()'>Bad</a>")
        let parsed = try SwiftSoup.parse(document.bodyHTML)
        XCTAssertEqual(try parsed.select("#novel-same").size(), 1)
        XCTAssertEqual(try parsed.select("a[href]").size(), 1)
        XCTAssertEqual(try parsed.select("a[href]").attr("href"), "#novel-same")
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
    }

    func testUnicodeAndLiteralPercentFootnoteIDsRoundTripThroughURLFragments() throws {
        let document = try ReaderNovelDocument(bodyHTML: "<p id='élève'>Accent</p><p id='rate%done'>Percent</p><a href='#%C3%A9l%C3%A8ve'>Accent note</a><a href='#rate%25done'>Percent note</a>")
        let parsed = try SwiftSoup.parse(document.bodyHTML)
        let links = try parsed.select("a[href]")
        XCTAssertEqual(links.size(), 2)
        for link in links {
            let href = try link.attr("href")
            let url = try XCTUnwrap(URL(string: "about:blank" + href))
            let decoded = try XCTUnwrap(url.fragment?.removingPercentEncoding)
            XCTAssertNotNil(try parsed.getElementById(decoded))
        }
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
    }

    func testRichAndLegacyOfflineFormatsAreExplicitAndUnreadableRichPayloadsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-novel-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let route = MangaContentRoute.readerExtension(source: sourceID, itemKey: "book", legacyStableKey: nil)
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ReaderDownloadItem(
            id: ReaderDownloadManager.downloadId(route: route, chapterNumber: "1"),
            route: route,
            routeKey: route.stableKey,
            mangaId: route.stableNegativeId,
            mangaTitle: "Novel",
            coverURL: nil,
            sourceName: "Fixture",
            format: "Novel",
            chapterNumber: "1",
            chapterTitle: "Chapter 1",
            chapterKey: ChapterIdentityNormalizer.key(for: "1"),
            contentRating: ReaderContentRating.safe.rawValue,
            provider: ReaderDownloadProvider(kind: .readerExtension, sourceId: sourceID.rawValue, mangaKey: "book", moduleUUID: nil, contentParams: nil, isNovel: true, chapterParams: "chapter"),
            status: .completed,
            progress: 1,
            completedPages: 1,
            totalPages: 1,
            downloadedBytes: 1,
            error: nil,
            dateAdded: completedAt,
            dateCompleted: completedAt
        )
        let directory = root.appendingPathComponent(ReaderDownloadManager.stableHash(item.routeKey)).appendingPathComponent(ReaderDownloadManager.stableHash(item.chapterKey))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try ReaderExtensionNovelSanitizer.embeddedImageURL(imageData())
        let document = try ReaderNovelDocument(bodyHTML: "<p id='note'>Rich</p><img src='\(image)'><a href='#note'>Footnote</a>")
        let routeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))
        var manifest: [String: Any] = [
            "version": 1, "itemId": item.id, "route": routeObject, "mangaTitle": item.mangaTitle,
            "chapterNumber": "1", "pages": [["index": 0, "kind": "novelDocument", "fileName": "0001.novel"]],
            "dateCompleted": ISO8601DateFormatter().string(from: completedAt)
        ]
        let manifestURL = directory.appendingPathComponent("chapter.json")
        let documentURL = directory.appendingPathComponent("0001.novel")
        try document.encoded().write(to: documentURL)
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let pages = try XCTUnwrap(ReaderDownloadManager.verifiedReadOnlyPages(item, downloadsRoot: root))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.novelDocumentContent, document)
        XCTAssertNil(pages.first?.textContent)
        try Data("{\"version\":999,\"bodyHTML\":\"Rich\"}".utf8).write(to: documentURL)
        XCTAssertNil(ReaderDownloadManager.verifiedReadOnlyPages(item, downloadsRoot: root))
        manifest["pages"] = [["index": 0, "kind": "text", "fileName": "0001.txt"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let literal = "Literal <style>body{display:none}</style> & <img src=x>"
        try Data(literal.utf8).write(to: directory.appendingPathComponent("0001.txt"))
        let legacyPages = try XCTUnwrap(ReaderDownloadManager.verifiedReadOnlyPages(item, downloadsRoot: root))
        XCTAssertEqual(legacyPages.first?.textContent, literal)
        XCTAssertNil(legacyPages.first?.novelDocumentContent)
    }

    func testEPUBSpineOrderKeepsPrefaceRomanAndAlphanumericChapterTitles() throws {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "e", count: 64))
        let chapters = [
            ReaderExtensionChapter(key: "end", title: "Epilogue", bookReadingOrder: 4),
            ReaderExtensionChapter(key: "one-b", title: "Chapter 1B", bookReadingOrder: 3),
            ReaderExtensionChapter(key: "roman", title: "Chapter I", bookReadingOrder: 1),
            ReaderExtensionChapter(key: "preface", title: "Preface", bookReadingOrder: 0),
            ReaderExtensionChapter(key: "one-a", title: "Chapter 1A", bookReadingOrder: 2)
        ]
        let cache = ReaderExtensionDetailChapterCache.make(sourceID: source, mediaType: .novel, item: ReaderExtensionItem(key: "book", title: "Book"), chapters: chapters)
        let expected = ["Preface", "Chapter I", "Chapter 1A", "Chapter 1B", "Epilogue"]
        XCTAssertEqual(cache.readerChapters.map(\.chapterNumber), expected)
        XCTAssertEqual(cache.displayChapters.map(\.chapterNumber), expected)
        XCTAssertEqual(cache.readerChapters.map(\.idx), Array(0..<5))
        XCTAssertEqual(cache.readerChapters.map { ($0.chapterData?.first?.params as? ReaderExtensionChapterPayload)?.chapter.key }, ["preface", "roman", "one-a", "one-b", "end"])
    }

    func testOrdinaryWebNovelOrderingAndOldChapterDecodingRemainCompatible() throws {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "f", count: 64))
        let chapters = [
            ReaderExtensionChapter(key: "3", title: "Chapter 3"),
            ReaderExtensionChapter(key: "2", title: "Chapter 2"),
            ReaderExtensionChapter(key: "1", title: "Chapter 1")
        ]
        let cache = ReaderExtensionDetailChapterCache.make(sourceID: source, mediaType: .novel, item: ReaderExtensionItem(key: "book", title: "Book"), chapters: chapters)
        XCTAssertEqual(cache.displayChapters.map(\.chapterNumber), ["Chapter 3", "Chapter 2", "Chapter 1"])
        XCTAssertEqual(cache.readerChapters.map(\.chapterNumber), ["Chapter 1", "Chapter 2", "Chapter 3"])
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(chapters[0])) as? [String: Any])
        row.removeValue(forKey: "bookReadingOrder")
        let old = try JSONDecoder().decode(ReaderExtensionChapter.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(old.bookReadingOrder)
        row["bookReadingOrder"] = -1
        let invalid = try JSONDecoder().decode(ReaderExtensionChapter.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(invalid.bookReadingOrder)
        row["bookReadingOrder"] = "invalid"
        let malformed = try JSONDecoder().decode(ReaderExtensionChapter.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(malformed.bookReadingOrder)
    }

    func testOnlineAndDownloadedNovelPositionsUseTheSameActualChapterIdentity() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let item = ReaderExtensionItem(key: "book", title: "Book")
        let sourceChapter = ReaderExtensionChapter(key: "book_epub_Chapter I", title: "Chapter I", bookReadingOrder: 1)
        let online = sourceChapter.kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        let route = MangaContentRoute.readerExtension(source: source, itemKey: "book", legacyStableKey: nil)
        let offline = Chapter(chapterNumber: sourceChapter.title, idx: 1, chapterData: [ChapterData(params: ReaderDownloadedChapterPayload(route: route, chapterNumber: sourceChapter.title, chapterIdentity: sourceChapter.key), title: sourceChapter.title, scanlationGroup: "")])
        XCTAssertEqual(ReaderNovelChapterIdentity.key(for: online), ReaderNovelChapterIdentity.key(for: offline))
        XCTAssertEqual(NovelReaderPositionKey.make(titleIdentity: route.stableKey, chapterIdentity: ReaderNovelChapterIdentity.key(for: online)), NovelReaderPositionKey.make(titleIdentity: route.stableKey, chapterIdentity: ReaderNovelChapterIdentity.key(for: offline)))
        let old = Chapter(chapterNumber: "Chapter 4", idx: 4, chapterData: [ChapterData(params: ReaderDownloadedChapterPayload(route: route, chapterNumber: "Chapter 4"), title: "", scanlationGroup: "")])
        XCTAssertEqual(ReaderNovelChapterIdentity.key(for: old), ChapterIdentityNormalizer.key(for: "Chapter 4"))
    }

    func testEPUBDownloadStorageIdentityDoesNotCollapseAlphanumericChapterTitles() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let item = ReaderExtensionItem(key: "book", title: "Book")
        let route = MangaContentRoute.readerExtension(source: source, itemKey: item.key, legacyStableKey: nil)
        let first = ReaderExtensionChapter(key: "book_epub_one-a", title: "Chapter 1A", bookReadingOrder: 0).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 0)
        let second = ReaderExtensionChapter(key: "book_epub_one-b", title: "Chapter 1B", bookReadingOrder: 1).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        XCTAssertEqual(ChapterIdentityNormalizer.key(for: first.chapterNumber), ChapterIdentityNormalizer.key(for: second.chapterNumber))
        let firstKey = ReaderDownloadManager.chapterStorageKey(for: first)
        let secondKey = ReaderDownloadManager.chapterStorageKey(for: second)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertNotEqual(ReaderDownloadManager.downloadId(route: route, chapterNumber: first.chapterNumber, chapterKey: firstKey), ReaderDownloadManager.downloadId(route: route, chapterNumber: second.chapterNumber, chapterKey: secondKey))
        XCTAssertEqual(ReaderNovelChapterIdentity.normalizedChapters([second, first]).map(\.chapterNumber), ["Chapter 1A", "Chapter 1B"])
        let web = ReaderExtensionChapter(key: "ordinary", title: "Chapter 1").kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 0)
        XCTAssertEqual(ReaderDownloadManager.chapterStorageKey(for: web), ChapterIdentityNormalizer.key(for: web.chapterNumber))
    }

    func testNativeBookOpaqueChapterSuffixKeepsURLCharactersWithoutPersistingURLCredentials() {
        let key = "https://source.example/book.epub;;;Chapter / # 20% & space"
        XCTAssertEqual(ReaderDownloadManager.persistableReaderExtensionChapterKey(key, bookReadingOrder: 1), key)
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(key))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(key, bookReadingOrder: -1))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey("https://user:password@source.example/book.epub;;;Chapter # 1", bookReadingOrder: 1))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey("https://source.example/book.epub?access_token=secret;;;Chapter # 1", bookReadingOrder: 1))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey("https://127.0.0.1/book.epub;;;Chapter # 1", bookReadingOrder: 1))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey("https://source.example/book.epub;;;Chapter\n1", bookReadingOrder: 1))
    }

    func testOpaqueOfflinePositionKeySurvivesRemovalOfTransientChapterParams() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64))
        let item = ReaderExtensionItem(key: "book", title: "Book")
        let route = MangaContentRoute.readerExtension(source: source, itemKey: item.key, legacyStableKey: nil)
        let online = ReaderExtensionChapter(key: "book_epub_Chapter I", title: "Chapter I", bookReadingOrder: 1).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        let position = ReaderNovelChapterIdentity.positionKey(for: online, titleIdentity: route.stableKey)
        let offline = Chapter(chapterNumber: "Chapter I", idx: 1, chapterData: [ChapterData(params: ReaderDownloadedChapterPayload(route: route, chapterNumber: "Chapter I", bookReadingOrder: 1, positionKey: position), title: "Chapter I", scanlationGroup: "")])
        XCTAssertEqual(ReaderNovelChapterIdentity.positionKey(for: offline, titleIdentity: route.stableKey), position)
        XCTAssertTrue(ReaderNovelChapterIdentity.isValidPositionKey(position))
        XCTAssertFalse(ReaderNovelChapterIdentity.isValidPositionKey("v2-malformed"))
    }

    func testNativeEPUBPositionsAndDownloadsSurviveRenewedSourceURLs() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let item = ReaderExtensionItem(key: "edition-1", title: "Book")
        let route = MangaContentRoute.readerExtension(source: source, itemKey: item.key, legacyStableKey: nil)
        let original = ReaderExtensionChapter(key: "https://books.example/get.php?key=old;;;Chapter I", title: "Chapter I", bookReadingOrder: 1).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        let renewed = ReaderExtensionChapter(key: "https://books.example/get.php?key=new;;;Chapter I", title: "Chapter I", bookReadingOrder: 1).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        XCTAssertNotEqual(ReaderNovelChapterIdentity.key(for: original), ReaderNovelChapterIdentity.key(for: renewed))
        let position = ReaderNovelChapterIdentity.positionKey(for: original, titleIdentity: route.stableKey)
        XCTAssertEqual(position, ReaderNovelChapterIdentity.positionKey(for: renewed, titleIdentity: route.stableKey))
        XCTAssertEqual(ReaderDownloadManager.chapterStorageKey(for: original), ReaderDownloadManager.chapterStorageKey(for: renewed))
        let offline = Chapter(chapterNumber: "Chapter I", idx: 1, chapterData: [ChapterData(params: ReaderDownloadedChapterPayload(route: route, chapterNumber: "Chapter I", bookReadingOrder: 1, positionKey: position), title: "Chapter I", scanlationGroup: "")])
        XCTAssertEqual(position, ReaderNovelChapterIdentity.positionKey(for: offline, titleIdentity: route.stableKey))
        XCTAssertEqual(ReaderDownloadManager.chapterStorageKey(for: original), ReaderDownloadManager.chapterStorageKey(for: offline))
        let otherSection = ReaderExtensionChapter(key: "same-url", title: "Chapter I", bookReadingOrder: 2).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 2)
        XCTAssertNotEqual(ReaderDownloadManager.chapterStorageKey(for: renewed), ReaderDownloadManager.chapterStorageKey(for: otherSection))
        let longTitle = String(repeating: "L", count: 960) + " (2)"
        let longOriginal = ReaderExtensionChapter(key: "old-url", title: longTitle, bookReadingOrder: 3).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 3)
        let longRenewed = ReaderExtensionChapter(key: "new-url", title: longTitle, bookReadingOrder: 3).kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 3)
        XCTAssertNotNil(ReaderNovelChapterIdentity.stableBookKey(for: longOriginal))
        XCTAssertEqual(ReaderDownloadManager.chapterStorageKey(for: longOriginal), ReaderDownloadManager.chapterStorageKey(for: longRenewed))
        let otherRoute = MangaContentRoute.readerExtension(source: source, itemKey: "edition-2", legacyStableKey: nil)
        XCTAssertNotEqual(position, ReaderNovelChapterIdentity.positionKey(for: renewed, titleIdentity: otherRoute.stableKey))
        let web = ReaderExtensionChapter(key: "https://books.example/chapter", title: "Chapter I").kanzenChapter(sourceID: source, mediaType: .novel, item: item, index: 1)
        XCTAssertEqual(ReaderNovelChapterIdentity.positionKey(for: web, titleIdentity: route.stableKey), NovelReaderPositionKey.make(titleIdentity: route.stableKey, chapterIdentity: "https://books.example/chapter"))
    }

    func testReaderMutationAuthorityExpiresOnHistoryResetRestoreAndProfileRoundTrip() {
        let suite = "ReaderNovelAuthority-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("An isolated defaults suite is required.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let manager = MangaReadingProgressManager(profileID: owner, defaults: defaults)
        let initial = manager.captureMutationAuthority()
        XCTAssertTrue(manager.isCurrent(initial))
        manager.clearHistory()
        XCTAssertFalse(manager.isCurrent(initial))
        let unread = manager.captureMutationAuthority()
        manager.markAllUnread(mangaId: 1)
        XCTAssertFalse(manager.isCurrent(unread))
        let restore = manager.captureMutationAuthority()
        manager.replaceProgressMapForRestore([:])
        XCTAssertFalse(manager.isCurrent(restore))
        let profile = manager.captureMutationAuthority()
        manager.switchProfile(to: UUID())
        manager.switchProfile(to: owner)
        XCTAssertFalse(manager.isCurrent(profile))
        XCTAssertTrue(manager.isCurrent(manager.captureMutationAuthority()))
    }

    func testBookReadAndPageProgressKeepsAlphanumericAndDuplicateNumberTitlesDistinct() {
        let suite = "ReaderBookProgress-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("An isolated defaults suite is required.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: defaults)
        let titles = ["Preface", "Chapter 1A", "Chapter 1B", "Chapter 1", "Chapter 1 (2)"]
        manager.markChapterRead(mangaId: -991, chapterNumber: "Chapter 1A", latestChapterNumbers: titles, preservesExactChapterTitles: true)
        XCTAssertTrue(manager.isChapterRead(mangaId: -991, chapterNumber: "Chapter 1A"))
        XCTAssertFalse(manager.isChapterRead(mangaId: -991, chapterNumber: "Chapter 1B"))
        manager.markChapterRead(mangaId: -991, chapterNumber: "Chapter 1", latestChapterNumbers: titles, preservesExactChapterTitles: true)
        XCTAssertFalse(manager.isChapterRead(mangaId: -991, chapterNumber: "Chapter 1 (2)"))
        XCTAssertEqual(manager.normalizedReadChapterKeys(for: -991), ["Chapter 1A", "Chapter 1"])
        XCTAssertEqual(manager.progressMap[-991]?.totalChapters, 5)
        manager.savePagePosition(mangaId: -991, chapterNumber: "Chapter 1A", page: 4, pageCount: 20, latestChapterNumbers: titles, preservesExactChapterTitles: true)
        manager.savePagePosition(mangaId: -991, chapterNumber: "Chapter 1B", page: 9, pageCount: 20, latestChapterNumbers: titles, preservesExactChapterTitles: true)
        XCTAssertEqual(manager.pagePosition(mangaId: -991, chapterNumber: "Chapter 1A"), 4)
        XCTAssertEqual(manager.pagePosition(mangaId: -991, chapterNumber: "Chapter 1B"), 9)
        manager.markChapterUnread(mangaId: -991, chapterNumber: "Chapter 1A")
        XCTAssertFalse(manager.isChapterRead(mangaId: -991, chapterNumber: "Chapter 1A"))
        XCTAssertTrue(manager.isChapterRead(mangaId: -991, chapterNumber: "Chapter 1"))
        manager.markChapterRead(mangaId: -992, chapterNumber: "Chapter 4")
        XCTAssertTrue(manager.isChapterRead(mangaId: -992, chapterNumber: "4"))
    }

    func testBookProgressPartialMetadataCannotDeletePreviouslyReadTitles() {
        let suite = "ReaderBookPartialProgress-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("An isolated defaults suite is required.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: defaults)
        let titles = ["Preface", "Chapter 1A", "Chapter 1B", "Epilogue"]
        manager.markChapterRead(mangaId: -993, chapterNumber: "Chapter 1A")
        manager.markChapterRead(mangaId: -993, chapterNumber: "Extra read offline")
        manager.updateSourceMetadata(mangaId: -993, latestChapterNumbers: titles, preservesExactChapterTitles: true)
        XCTAssertFalse(manager.readChapters(for: -993).contains("1"))
        XCTAssertTrue(manager.isChapterRead(mangaId: -993, chapterNumber: "Extra read offline"))
        manager.markChapterRead(mangaId: -993, chapterNumber: "Epilogue", latestChapterNumbers: titles, preservesExactChapterTitles: true)
        manager.savePagePosition(mangaId: -993, chapterNumber: "Chapter 1B", page: 0, pageCount: 20, latestChapterNumbers: ["Chapter 1B"], preservesExactChapterTitles: true)
        manager.updateSourceMetadata(mangaId: -993, latestChapterNumbers: ["Chapter 1B"], preservesExactChapterTitles: true)
        manager.markAllRead(mangaId: -993, chapterNumbers: ["Preface"], latestChapterNumbers: ["Preface"], preservesExactChapterTitles: true)
        XCTAssertTrue(manager.isChapterRead(mangaId: -993, chapterNumber: "Chapter 1A"))
        XCTAssertTrue(manager.isChapterRead(mangaId: -993, chapterNumber: "Epilogue"))
        XCTAssertTrue(manager.isChapterRead(mangaId: -993, chapterNumber: "Extra read offline"))
        manager.updateSourceMetadata(mangaId: -993, latestChapterNumbers: titles, preservesExactChapterTitles: true)
        let item = MangaLibraryItem(aniListId: -993, title: "Book", coverURL: nil, format: "NOVEL", totalChapters: titles.count, latestChapterNumbers: titles)
        XCTAssertEqual(item.unreadCount(readChapters: manager.readChapters(for: -993), progress: manager.progress(for: -993)), 1)
        let ordinary = MangaLibraryItem(aniListId: -994, title: "Web Novel", coverURL: nil, format: "NOVEL", totalChapters: 2, latestChapterNumbers: ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(ordinary.unreadCount(readChapters: ["1"]), 1)
    }

    func testNumericTrackerProgressCannotTreatAliceCoverAndFrontmatterAsNarrativeChapters() throws {
        let titles = ["Chapter 1", "Chapter 2", "CHAPTER I. Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears"]
        var book = MangaProgress()
        book.usesExactChapterTitles = true
        book.latestChapterNumbers = titles
        book.totalChapters = titles.count
        book.readChapterNumbers = [titles[3]]
        book.lastReadChapter = titles[3]
        var unavailableBook = MangaProgress()
        unavailableBook.usesExactChapterTitles = true
        let records = [
            MangaReadingProgressManager.ImportRecord(mangaID: -995, throughChapter: 2, title: nil, coverURL: nil, totalChapters: 99),
            MangaReadingProgressManager.ImportRecord(mangaID: -996, throughChapter: 2, title: nil, coverURL: nil, totalChapters: nil),
            MangaReadingProgressManager.ImportRecord(mangaID: -997, throughChapter: 2, title: nil, coverURL: nil, totalChapters: nil)
        ]
        let prepared = try MangaReadingProgressManager.prepareImport(records, progress: [-995: book, -996: unavailableBook])
        XCTAssertEqual(prepared.imported, 1)
        XCTAssertEqual(prepared.rejected, 2)
        XCTAssertEqual(prepared.progress[-995]?.readChapterNumbers, [titles[3]])
        XCTAssertEqual(prepared.progress[-995]?.lastReadChapter, titles[3])
        XCTAssertEqual(prepared.progress[-995]?.totalChapters, titles.count)
        XCTAssertEqual(prepared.progress[-996]?.readChapterNumbers, [])
        let suite = "ReaderBookTrackerImport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MangaReadingProgressManager(profileID: UUID(), defaults: defaults)
        manager.replaceProgressMapForRestore([-995: book, -996: unavailableBook])
        XCTAssertFalse(manager.bulkMarkChaptersReadForImport(mangaId: -995, throughChapter: 2, totalChapters: 99))
        XCTAssertFalse(manager.bulkMarkChaptersReadForImport(mangaId: -996, throughChapter: 2))
        XCTAssertTrue(manager.bulkMarkChaptersReadForImport(mangaId: -997, throughChapter: 2))
        XCTAssertEqual(manager.readChapters(for: -995), [titles[3]])
        XCTAssertEqual(manager.lastReadChapter(for: -995), titles[3])
        XCTAssertEqual(manager.progress(for: -995)?.totalChapters, titles.count)
        XCTAssertFalse(manager.isChapterRead(mangaId: -995, chapterNumber: titles[0]))
        XCTAssertFalse(manager.isChapterRead(mangaId: -995, chapterNumber: titles[1]))
        XCTAssertEqual(manager.readChapters(for: -997), ["1", "2"])
        XCTAssertNil(manager.trackerChapterNumber(titles[0], progress: book))
        XCTAssertNil(manager.trackerChapterNumber(titles[2], progress: book))
        XCTAssertEqual(manager.trackerChapterNumber("Chapter 2", progress: MangaProgress()), 2)
    }

    func testAttachingNativeBookToTrackerIDPreservesExactReadsPagesAndSpineMetadata() throws {
        if ProfileManager.shared.isKidsModeActive { throw XCTSkip("Source linking requires a grown-up profile.") }
        let suite = "ReaderBookTrackerAttach-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let manager = MangaReadingProgressManager(profileID: owner, defaults: defaults)
        let titles = ["Preface", "Chapter 1A", "Chapter 1B", "1"]
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "f", count: 64))
        let item = MangaLibraryItem.fromReaderExtension(sourceID: source, itemKey: "book", title: "Book", coverURL: nil, latestChapterNumbers: titles, format: "NOVEL", mangaID: 99_991, preservesExactChapterTitles: true)
        let route = try XCTUnwrap(item.route)
        var tracker = MangaProgress()
        tracker.readChapterNumbers = ["1"]
        tracker.lastReadChapter = "1"
        tracker.lastReadDate = Date(timeIntervalSince1970: 1)
        var book = MangaProgress()
        book.usesExactChapterTitles = true
        book.latestChapterNumbers = titles
        book.readChapterNumbers = ["Chapter 1B"]
        book.pagePositions = ["Chapter 1B": 4]
        book.pageCounts = ["Chapter 1B": 20]
        book.lastReadChapter = "Chapter 1B"
        book.lastReadDate = Date(timeIntervalSince1970: 2)
        manager.replaceProgressMapForRestore([item.id: tracker, route.stableNegativeId: book])
        let snapshot = try XCTUnwrap(manager.captureImport(owner: owner, invalidation: nil))
        try manager.attachReaderSource(item, snapshot: snapshot)
        let linked = try XCTUnwrap(manager.progress(for: item.id))
        XCTAssertEqual(linked.usesExactChapterTitles, true)
        XCTAssertEqual(linked.latestChapterNumbers, titles)
        XCTAssertEqual(linked.totalChapters, titles.count)
        XCTAssertEqual(linked.lastReadChapter, "Chapter 1B")
        XCTAssertEqual(linked.readChapterNumbers, ["Chapter 1B"])
        XCTAssertFalse(manager.isChapterRead(mangaId: item.id, chapterNumber: "1"))
        XCTAssertEqual(manager.pagePosition(mangaId: item.id, chapterNumber: "Chapter 1B"), 4)
        XCTAssertEqual(item.unreadCount(readChapters: linked.readChapterNumbers, progress: linked), 3)
    }

    private func imageData(padding: Int = 0) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { renderer in
            UIColor.red.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        var data = try XCTUnwrap(image.pngData())
        data.append(Data(repeating: 0, count: padding))
        return data
    }
}
#endif
