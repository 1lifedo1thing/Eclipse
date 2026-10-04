import CryptoKit
import UIKit
import XCTest
import ZIPFoundation
@testable import Eclipse

#if os(iOS)
final class ReaderExtensionEPUBTests: XCTestCase {
    func testEPUB3UsesSpineOrderAndDisambiguatesTitles() throws {
        let book = try ReaderExtensionEPUBBook(data: fixture(duplicateTitles: true))
        XCTAssertEqual(book.title, "Fixture Book")
        XCTAssertEqual(book.author, "Fixture Author")
        XCTAssertEqual(book.chapters.map(\.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter I", "Chapter I (2)"])
        XCTAssertTrue(try book.chapterHTML(named: "Chapter I (2)").contains("Second body"))
    }

    func testEPUBNavigationPreservesMixedContentTextOrder() throws {
        let navigation = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="one.xhtml">A <span>B</span> C</a><a href="two.xhtml"><span>Chapter </span>II</a></nav></body></html>
        """
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8)]))
        XCTAssertEqual(book.chapters.map(\.title), ["A B C", "Chapter II"])
    }

    func testLongNavigationLabelsStayDistinctWithinProviderTitleBound() throws {
        let title = String(repeating: "章节📚", count: 300)
        let navigation = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><a href=\"one.xhtml\">" + title + "</a><a href=\"two.xhtml\">" + title + "</a></nav></body></html>"
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8)]))
        XCTAssertLessThanOrEqual(book.chapters[0].title.utf8.count, 1_024)
        XCTAssertLessThanOrEqual(book.chapters[1].title.utf8.count, 1_024)
        XCTAssertNotEqual(book.chapters[0].title, book.chapters[1].title)
        XCTAssertTrue(try book.chapterHTML(named: book.chapters[1].title).contains("Second body"))
    }

    func testVirtualChaptersUseSpineAndDOMOrderAndPreserveNestedInlineContent() throws {
        let navigation = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="two.xhtml#other">Third</a><a href="one.xhtml#middle">Second</a><a href="one.xhtml#parent">First</a><a href="one.xhtml#middle">Duplicate label</a><a href="one.xhtml#missing">Missing</a><a href="one.xhtml#ambiguous">Ambiguous</a><a href="endnotes.xhtml#note">Not in spine</a></nav></body></html>
        """
        let one = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><p>Intro marker.</p><section id="parent"><h1>First marker.</h1><p>Prefix marker <span id="middle"><em>Middle marker.</em></span> Tail marker.<img src="images/cover.png"/><a epub:type="noteref" href="endnotes.xhtml#note">Note</a></p><footer>Footer marker.</footer></section><p id="ambiguous">Duplicate A.</p><p id="ambiguous">Duplicate B.</p></body></html>
        """
        let two = "<html><body><h2 id='other'>Final marker.</h2></body></html>"
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8), "OPS/one.xhtml": Data(one.utf8), "OPS/two.xhtml": Data(two.utf8)]))
        XCTAssertEqual(book.chapters.map(\.title), ["Introduction", "First", "Second", "Third"])
        XCTAssertEqual(book.chapters.map(\.identifier), ["OPS/one.xhtml", "OPS/one.xhtml#parent", "OPS/one.xhtml#middle", "OPS/two.xhtml#other"])
        let documents = try book.chapters.map { try book.novelDocument(named: $0.title) }
        let allText = documents.map { $0.plainText }.joined(separator: " ")
        for marker in ["Intro marker.", "First marker.", "Prefix marker", "Middle marker.", "Tail marker.", "Footer marker.", "Duplicate A.", "Duplicate B.", "Final marker."] {
            XCTAssertEqual(allText.components(separatedBy: marker).count - 1, 1, marker)
        }
        XCTAssertTrue(documents[1].bodyHTML.contains("<p>Prefix marker"))
        XCTAssertFalse(documents[1].bodyHTML.contains("Middle marker"))
        XCTAssertTrue(documents[2].bodyHTML.contains("<p><span"))
        XCTAssertTrue(documents[2].bodyHTML.contains("<em>Middle marker.</em>"))
        XCTAssertTrue(documents[2].bodyHTML.contains("data:image/png;base64,"))
        XCTAssertTrue(documents[2].plainText.contains("Cross-file explanation"))
        XCTAssertFalse(documents[2].bodyHTML.contains("id=\"novel-parent\""))
    }

    func testExplicitContentsTablePromotesCrossFileTargetsAndKeepsContinuation() throws {
        let navigation = "<html><body><nav epub:type='toc'/></body></html>"
        let one = """
        <html><body><p>Preface marker.</p><table summary="Contents"><tr><td>I.</td><td>Rabbit</td><td><a href="one.xhtml#first">1</a></td></tr><tr><td>II.</td><td>Pool</td><td><a href="two.xhtml#second">12</a></td></tr></table><h2 id="first">Rabbit narrative.</h2><p>First ending.</p><a href="#ordinary">Ordinary link</a><p id="ordinary">Ordinary narrative.</p></body></html>
        """
        let two = "<html><body><p>Continued story.</p><h2 id='second'>Pool narrative.</h2><img src='images/cover.png'/></body></html>"
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8), "OPS/one.xhtml": Data(one.utf8), "OPS/two.xhtml": Data(two.utf8)]))
        XCTAssertEqual(book.chapters.map(\.title), ["Introduction", "I. Rabbit", "Continuation", "II. Pool"])
        XCTAssertEqual(book.chapters.map(\.path), ["OPS/one.xhtml", "OPS/one.xhtml", "OPS/two.xhtml", "OPS/two.xhtml"])
        XCTAssertTrue(try book.novelDocument(named: "Continuation").plainText.contains("Continued story."))
        XCTAssertFalse(try book.novelDocument(named: "Continuation").plainText.contains("Pool narrative."))
        XCTAssertTrue(try book.chapterHTML(named: "II. Pool").contains("data:image/png;base64,"))
        XCTAssertEqual(try book.novelDocument(named: "I. Rabbit").plainText.components(separatedBy: "Ordinary narrative.").count - 1, 1)
    }

    func testMissingAndAmbiguousTOCAnchorsFallBackToEntireSpineResource() throws {
        let navigation = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><a href='one.xhtml#missing'>First</a><a href='one.xhtml#repeated'>Repeated</a><a href='two.xhtml'>Second</a></nav></body></html>"
        let one = "<html><body><p id='repeated'>First occurrence.</p><p id='repeated'>Second occurrence.</p></body></html>"
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8), "OPS/one.xhtml": Data(one.utf8)]))
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertNil(book.chapters[0].fragment)
        let text = try book.novelDocument(named: book.chapters[0].title).plainText
        XCTAssertTrue(text.contains("First occurrence."))
        XCTAssertTrue(text.contains("Second occurrence."))
    }

    func testLargeSameFileFootnoteResourceIsChargedOnceForVirtualChapter() throws {
        let navigation = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><a href='one.xhtml#first'>First</a><a href='one.xhtml#appendix'>Appendix</a><a href='two.xhtml'>Second</a></nav></body></html>"
        let one = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><h1 id='first'>First marker.</h1><p>" + String(repeating: "a ", count: 1_100_000) + "</p><a epub:type='noteref' href='#note'>Note</a><h2 id='appendix'>Appendix marker.</h2><aside id='note' epub:type='footnote'>Small same-file explanation.<a href='#note'>Self</a><a href='#first'>Back</a></aside></body></html>"
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8), "OPS/one.xhtml": Data(one.utf8)]))
        let html = try book.chapterHTML(named: "First")
        XCTAssertTrue(html.contains("Small same-file explanation."))
        XCTAssertFalse(html.contains("Appendix marker."))
        XCTAssertTrue(html.contains("href=\"#novel-epub-note-"))
        XCTAssertEqual(html.components(separatedBy: "href=\"#novel-epub-note-").count - 1, 2)
        XCTAssertTrue(html.contains("href=\"#novel-first\""))
    }

    func testCapturedCommunityAliceEPUBPreservesRealTOCAndOfflineIllustrations() throws {
        guard let basename = ProcessInfo.processInfo.environment["ECLIPSE_TEST_COMMUNITY_EPUB_FIXTURE"] else { throw XCTSkip("Captured public-domain community EPUB fixture is opt-in") }
        XCTAssertEqual(basename, "eclipse-community-alice.epub")
        guard basename == "eclipse-community-alice.epub",
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw ReaderExtensionError.insecureURL }
        let file = cache.appendingPathComponent(basename)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= ReaderExtensionEPUBBook.maximumArchiveBytes else { throw ReaderExtensionError.contentTooLarge }
        let book = try ReaderExtensionEPUBBook(data: Data(contentsOf: file, options: .mappedIfSafe))
        XCTAssertTrue(book.title.lowercased().contains("alice"))
        XCTAssertTrue(book.chapters.contains(where: { $0.title == "I. Down the Rabbit-hole" }))
        XCTAssertTrue(book.chapters.contains(where: { $0.title == "IX. The Mock Turtle's Story" }))
        XCTAssertTrue(book.chapters.contains(where: { $0.title == "X. The Lobster Quadrille" }))
        let first = try book.novelDocument(named: "I. Down the Rabbit-hole")
        let second = try book.novelDocument(named: "II. The Pool of Tears")
        XCTAssertTrue(first.plainText.lowercased().contains("was beginning to get very tired"))
        XCTAssertFalse(first.plainText.lowercased().contains("curiouser and curiouser"))
        XCTAssertTrue(second.plainText.lowercased().contains("curiouser and curiouser"))
        XCTAssertTrue(first.bodyHTML.contains("data:image/"))
        XCTAssertEqual(try ReaderNovelDocument.decode(first.encoded()), first)
        let continuation = try XCTUnwrap(book.chapters.first(where: { $0.title == "Continuation" }))
        let continued = try book.novelDocument(named: continuation.title)
        XCTAssertTrue(continued.plainText.lowercased().contains("how many hours a day"))
        XCTAssertFalse(continued.plainText.lowercased().contains("lobster quadrille"))
        let ninth = try XCTUnwrap(book.chapters.firstIndex(where: { $0.title == "IX. The Mock Turtle's Story" }))
        let tenth = try XCTUnwrap(book.chapters.firstIndex(where: { $0.title == "X. The Lobster Quadrille" }))
        XCTAssertGreaterThan(tenth, ninth)
        XCTAssertEqual(book.chapters[ninth + 1], continuation)
        let note = try book.novelDocument(named: "Transcriber's Note:")
        XCTAssertTrue(note.plainText.lowercased().contains("transcriber"))
        XCTAssertEqual(try ReaderNovelDocument.decode(note.encoded()), note)
    }

    func testEPUB2NCXAndRelativeImagePathPreserveOfflineContent() throws {
        let book = try ReaderExtensionEPUBBook(data: fixture(epub2: true))
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter I", "Chapter II"])
        let html = try book.chapterHTML(named: "Chapter I")
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("onerror"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("https://untrusted.example"))
        XCTAssertTrue(html.contains("href=\"#novel-local-note\""))
        XCTAssertTrue(html.contains("id=\"novel-local-note\""))
    }

    func testCrossFileFootnotesAreEmbeddedAndRepeatedReferencesShareOneTarget() throws {
        let book = try ReaderExtensionEPUBBook(data: fixture())
        let html = try book.chapterHTML(named: "Chapter I")
        XCTAssertTrue(html.contains("Cross-file explanation"))
        XCTAssertEqual(html.components(separatedBy: "Cross-file explanation").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "href=\"#novel-epub-note-").count - 1, 2)
        XCTAssertTrue(html.contains("href=\"#novel-reference\""))
        XCTAssertFalse(html.contains("endnotes.xhtml#note"))
    }

    func testFootnoteSelfAndNestedLinksOnlyTargetEmbeddedNodes() throws {
        let notes = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><aside id="note" epub:type="footnote"><p id="nested">Cross-file explanation</p><a href="#note">Self</a><a href="#nested">Nested</a><a href="#missing">Missing</a></aside></body></html>
        """
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["OPS/endnotes.xhtml": Data(notes.utf8)]))
        let html = try book.chapterHTML(named: "Chapter I")
        XCTAssertEqual(html.components(separatedBy: "href=\"#novel-epub-note-").count - 1, 4)
        XCTAssertFalse(html.contains("href=\"#missing\""))
        XCTAssertFalse(html.contains("href=\"#novel-missing\""))
    }

    func testRasterCoverWrapperBecomesAnOfflineImage() throws {
        let book = try ReaderExtensionEPUBBook(data: fixture(cover: true))
        XCTAssertEqual(book.chapters.first?.path, "OPS/cover.xhtml")
        let html = try book.chapterHTML(named: "Chapter 1")
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("<svg"))
    }

    func testKnownFontObfuscationDoesNotBlockDRMFreeText() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="OPS/font.otf"/></CipherData></EncryptedData></encryption>
        """
        let book = try ReaderExtensionEPUBBook(data: fixture(extra: ["META-INF/encryption.xml": Data(encryption.utf8)]))
        XCTAssertTrue(try book.chapterHTML(named: "Chapter II").contains("Second body"))
        let protected = encryption.replacingOccurrences(of: "http://www.idpf.org/2008/embedding", with: "http://www.w3.org/2001/04/xmlenc#aes256-cbc")
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(extra: ["META-INF/encryption.xml": Data(protected.utf8)])))
        let encryptedChapter = encryption.replacingOccurrences(of: "OPS/font.otf", with: "OPS/one.xhtml")
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(extra: ["META-INF/encryption.xml": Data(encryptedChapter.utf8)])))
    }

    func testArchiveTraversalDuplicateEntriesAndSymlinksAreRejected() throws {
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(extra: ["../outside.txt": Data("outside".utf8)])))
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(symlink: true)))
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(duplicateEntry: true)))
        let escaped = """
        <container><rootfiles><rootfile full-path="../../outside.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(extra: ["META-INF/container.xml": Data(escaped.utf8)])))
    }

    func testXMLInternalEntitiesAndFixedLayoutAreRejected() throws {
        let unsafe = """
        <!DOCTYPE container [<!ENTITY secret SYSTEM "file:///private/secret">]><container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles>&secret;</container>
        """
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(extra: ["META-INF/container.xml": Data(unsafe.utf8)])))
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: fixture(fixedLayout: true)))
    }

    func testEntryEncryptionAndIntegrityMismatchAreRejected() throws {
        var encrypted = try fixture()
        if let central = encrypted.range(of: Data([0x50, 0x4b, 0x01, 0x02])) {
            encrypted[central.lowerBound + 8] |= 1
        }
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: encrypted))
        var damaged = try fixture()
        let marker = Data("Second body".utf8)
        if let range = damaged.range(of: marker) { damaged[range.lowerBound] = 0x58 }
        XCTAssertThrowsError(try ReaderExtensionEPUBBook(data: damaged).chapterHTML(named: "Chapter II"))
    }

    func testOrdinaryHTTPArchivePolicyRemainsClosed() throws {
        let url = try XCTUnwrap(URL(string: "https://reader.example/book.epub"))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateNotArchive(data: fixture(), response: nil, url: url))
    }

    func testRuntimeHelpersUseScopedCacheAndHostAuthoredSpineOrder() async throws {
        let body = try fixture()
        let source = try makeSource()
        let network = EPUBFixtureNetwork(data: body)
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) {
            const book = await parseEpub('Fixture', '/book.epub', {});
            return {name: book.title, author: book.author, __eclipseEPUBSpineOrder: {'Chapter I': 99}, chapters: book.chapters.map(title => ({name: title, url: '/book.epub;;;' + title}))};
          }
          async getHtmlContent(name, url) { return await parseEpubChapter('Fixture', '/book.epub', {}, url.split(';;;')[1]); }
        }
        """.utf8)
        let scope = UUID().uuidString
        func provider() throws -> JavaScriptReaderProvider {
            try JavaScriptReaderProvider(source: source, scriptData: script, network: network, approvedDomains: ["reader.example"], consentScopeID: scope, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        }
        let chapters = try await provider().chapters(itemKey: "/fixture")
        XCTAssertEqual(chapters.map(\.bookReadingOrder), [0, 1])
        let html = try await provider().chapterHTML(chapterKey: "/book.epub;;;Chapter II", chapterTitle: "Chapter II")
        XCTAssertTrue(html.contains("Second body"))
        XCTAssertEqual(network.requestCount, 1)
        network.revoke()
        do {
            _ = try await provider().chapterHTML(chapterKey: "/book.epub;;;Chapter II", chapterTitle: "Chapter II")
            XCTFail("Revoked cached EPUB must not be read")
        } catch {}
    }

    func testSourceCannotForgeHostBookOrderingWithoutEPUBHelper() async throws {
        let source = try makeSource()
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Web Novel', __eclipseEPUBSpineOrder: {'Chapter I': 0}, chapters: [{name: 'Chapter I', url: '/chapter'}]}; }
          async getHtmlContent(name, url) { return '<p>Web content</p>'; }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(source: source, scriptData: script, network: EPUBFixtureNetwork(data: Data()), approvedDomains: [], consentScopeID: UUID().uuidString, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let chapters = try await provider.chapters(itemKey: "/fixture")
        XCTAssertNil(chapters.first?.bookReadingOrder)
    }

    func testPublishedMirrorURLConstructorResolvesBoundedPureURLs() async throws {
        let source = try makeSource()
        let network = EPUBFixtureNetwork(data: try fixture())
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) {
            const base = 'https://reader.example/mirror/ads.php?old=1';
            const resolved = new URL('../get.php?name=raw space&kept=one%20two#part one', base);
            if (resolved.href !== 'https://reader.example/get.php?name=raw%20space&kept=one%20two#part%20one') throw Error('relative mirror URL mismatch');
            if (resolved.search !== '?name=raw%20space&kept=one%20two' || resolved.hash !== '#part%20one' || resolved.pathname !== '/get.php') throw Error('URL components mismatch');
            if (new URL('?next=2', base).href !== 'https://reader.example/mirror/ads.php?next=2') throw Error('query mismatch');
            if (new URL('#next', base).href !== 'https://reader.example/mirror/ads.php?old=1#next') throw Error('fragment mismatch');
            if (new URL('//reader.example/a%20b', base).toString() !== 'https://reader.example/a%20b') throw Error('authority mismatch');
            if (new URL('http://127.0.0.1/private').hostname !== '127.0.0.1') throw Error('pure URL construction incorrectly applies transport admission');
            let rejected = 0;
            for (const value of ['x'.repeat(32769), 'relative-without-base']) { try { new URL(value); } catch (_) { rejected++; } }
            try { new URL('x', 'x'.repeat(32769)); } catch (_) { rejected++; }
            if (rejected !== 3) throw Error('URL construction bounds mismatch');
            const book = await parseEpub('Fixture', resolved.href, {});
            return {name: book.title, chapters: book.chapters.map(title => ({name: title, url: resolved.href + ';;;' + title}))};
          }
          async getHtmlContent(name, url) { return await parseEpubChapter('Fixture', url.split(';;;')[0], {}, url.split(';;;')[1]); }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(source: source, scriptData: script, network: network, approvedDomains: ["reader.example"], consentScopeID: UUID().uuidString, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let chapters = try await provider.chapters(itemKey: "/fixture")
        XCTAssertEqual(chapters.map(\.bookReadingOrder), [0, 1])
        XCTAssertEqual(chapters.first?.key, "https://reader.example/get.php?name=raw%20space&kept=one%20two#part%20one;;;Chapter I")
        XCTAssertEqual(network.requestCount, 1)
    }

    func testRuntimePreservesLongOpaqueBookChapterKeys() async throws {
        let title = "Chapter / # 20% & space"
        let navigation = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><a href=\"one.xhtml\">Chapter I</a><a href=\"two.xhtml\">Chapter / # 20% &amp; space</a></nav></body></html>"
        let body = try fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8)])
        let keyPrefix = "/" + String(repeating: "b", count: 4_500) + ".epub;;;"
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) {
            const book = await parseEpub('Fixture', '/book.epub', {});
            return {name: book.title, chapters: book.chapters.map(title => ({name: title, url: '\(keyPrefix)' + title}))};
          }
          async getHtmlContent(name, url) { return await parseEpubChapter('Fixture', '/book.epub', {}, url.split(';;;')[1]); }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(source: makeSource(), scriptData: script, network: EPUBFixtureNetwork(data: body), approvedDomains: ["reader.example"], consentScopeID: UUID().uuidString, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let chapters = try await provider.chapters(itemKey: "/fixture")
        let chapter = try XCTUnwrap(chapters.last)
        XCTAssertEqual(chapter.key, keyPrefix + title)
        XCTAssertEqual(chapter.title, title)
        XCTAssertEqual(chapter.bookReadingOrder, 1)
        let html = try await provider.chapterHTML(chapterKey: chapter.key, chapterTitle: chapter.title)
        XCTAssertTrue(html.contains("Second body"))
    }

    func testRuntimeDoesNotRepeatSourceAuthoredNovelCleaning() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Novel', chapters: []}; }
          async getHtmlContent(name, url) { return this.cleanHtmlContent('<div class="entry-content"><p>Source cleaned content</p></div>'); }
          async cleanHtmlContent(html) { const content = new Document(html).selectFirst('.entry-content'); return content ? content.innerHtml : '<p>undefined</p>'; }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(source: makeSource(), scriptData: script, network: EPUBFixtureNetwork(data: Data()), approvedDomains: [], consentScopeID: UUID().uuidString, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let html = try await provider.chapterHTML(chapterKey: "/chapter", chapterTitle: "Chapter")
        XCTAssertTrue(html.contains("Source cleaned content"))
        XCTAssertFalse(html.contains("undefined"))
    }

    func testWordrainStyleRawScriptComparisonsDoNotHideReadableChapterDOM() throws {
        let html = """
        <html><head><style>.text::before { content: '< text with quoted punctuation'; }</style></head><body><div class="entry-content"><p>Readable novel content.</p></div><script>
        for (let i = 0; i < gRecaptchas.length; i++) {
            gRecaptchas[i].setAttribute('data-callback', 'wpMangaSubmitSwitch');
            gRecaptchas[i].setAttribute('data-expired-callback', 'wpMangaSubmitSwitch');
        }
        </SCRIPT ><p>After script.</p></body></html>
        """
        XCTAssertNoThrow(try ReaderExtensionHTMLPreflight.validate(html, maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes, maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument))
        let bridge = ReaderExtensionDOMBridge(baseURL: try XCTUnwrap(URL(string: "https://reader.example")))
        let handle = bridge.parse(html)
        XCTAssertNotEqual(handle, 0)
        let content = try XCTUnwrap(bridge.select(handle, selector: ".entry-content").first)
        XCTAssertTrue(bridge.string(content, property: "innerHtml").contains("Readable novel content"))
        let storm = "<div " + (0..<257).map { "a\($0)=x" }.joined(separator: " ") + ">Text</div>"
        let hostile = ["<script>x</script>" + storm, "<script>x</SCRIPT/>" + storm,
                       "<style>x</style>" + storm, "<script/>" + storm,
                       "<!--<script>--!>" + storm + "</script>",
                       "<textarea><script></textarea>" + storm + "</script>",
                       "<div " + (0..<257).map { "/a\($0)=x" }.joined(separator: " ") + ">",
                       "<div " + (0..<257).map { "<a\($0)=x" }.joined(separator: " ") + ">"]
        for payload in hostile {
            XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(payload, maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes, maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument))
        }
    }

    func testMinifiedPublicCatalogScriptsUseBoundedTokenizerRecovery() throws {
        let html = """
        <html><head><script>
        function hash(input){let value=0;for(let r=0;r<input.length;r++){value=(value<<5)-value+input.charCodeAt(r)}return value}
        function escape(input){return input.replaceAll(/[\\^$.*+?\\(\\)\\[\\]{}|\\-\\\\]/g,"\\\\$&")}
        </script></head><body><a href="/md5/public-domain-book">Alice</a></body></html>
        """
        XCTAssertNoThrow(try ReaderExtensionHTMLPreflight.validate(html, maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes, maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument))
        let bridge = ReaderExtensionDOMBridge(baseURL: try XCTUnwrap(URL(string: "https://reader.example")))
        let handle = bridge.parse(html)
        XCTAssertNotEqual(handle, 0)
        let link = try XCTUnwrap(bridge.select(handle, selector: "a").first)
        XCTAssertEqual(bridge.string(link, property: "text"), "Alice")
        for prefix in ["a", "/a", "<a", "'a", "=a", "\u{0000}a"] {
            let attributes = (0..<257).map { prefix + String($0) + "=x" }.joined(separator: " ")
            let storm = "<div " + attributes + ">Text</div>"
            for payload in [storm, "<!--<a x=\"-->" + storm + "\">", "<textarea><a x=\"</textarea>" + storm + "\">"] {
                XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(payload, maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes, maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument))
            }
        }
        let oversized = "<a " + String(repeating: "/", count: 65 * 1_024) + ">"
        XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(oversized, maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes, maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument))
    }

    func testRuntimeHydratesChapterRelativeIllustrationsWithSourceHeaders() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let network = EPUBIllustrationNetwork(data: image)
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Novel', chapters: []}; }
          getHeaders(url) { return {'X-Reader-Illustration': 'allowed'}; }
          async getHtmlContent(name, url) { return '<p>Illustrated source chapter.</p><img src="../illustration.png">'; }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(source: makeSource(), scriptData: script, network: network, approvedDomains: ["reader.example"], consentScopeID: UUID().uuidString, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let chapterKey = "https://reader.example/books/title/chapter/1"
        let document = try await provider.chapterDocument(chapterKey: chapterKey, chapterTitle: "Chapter", requiresCompleteImages: true)
        XCTAssertTrue(document.bodyHTML.contains("data:image/png;base64,"))
        let request = try XCTUnwrap(network.requests.first)
        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://reader.example/books/title/illustration.png")
        XCTAssertEqual(request.headers["X-Reader-Illustration"], "allowed")
        XCTAssertEqual(request.hostGeneratedOriginReferer?.absoluteString, chapterKey)
        XCTAssertEqual(request.approvedDomains, ["reader.example"])
        XCTAssertEqual(request.maximumResponseBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
    }

    func testLivePublicDomainEPUBThroughPinnedMangayomiHelpers() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_LIVE_EPUB"] == "1" else { throw XCTSkip("Live Reader probes are opt-in") }
        var source = try makeSource()
        source.name = "Authored Public Domain EPUB Test Provider"
        source.baseURL = try XCTUnwrap(URL(string: "https://www.gutenberg.org"))
        let scope = UUID().uuidString
        let secure = ReaderExtensionSecureHTTPClient(keychainNamespace: scope, authenticationSourceID: source.id)
        let network = EPUBRecordingNetwork(wrapping: secure)
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [{name: "Alice's Adventures in Wonderland", link: '/alice'}], hasNextPage: false}; }
          async search(query, page, filters) { return this.getPopular(page); }
          async getDetail(url) {
            const book = await parseEpub('Alice', '/ebooks/11.epub3.images', {});
            return {name: book.title, author: book.author, chapters: book.chapters.map(title => ({name: title, url: '/ebooks/11.epub3.images;;;' + title}))};
          }
          async getHtmlContent(name, url) { return await parseEpubChapter('Alice', '/ebooks/11.epub3.images', {}, url.split(';;;')[1]); }
        }
        """.utf8)
        func provider() throws -> JavaScriptReaderProvider {
            try JavaScriptReaderProvider(source: source, scriptData: script, network: network, approvedDomains: ["www.gutenberg.org", "gutenberg.org"], consentScopeID: scope, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        }
        let item = try await provider().detail(itemKey: "/alice")
        XCTAssertTrue(item.title.lowercased().contains("wonderland"))
        let chapters = try await provider().chapters(itemKey: "/alice")
        XCTAssertGreaterThan(chapters.count, 12)
        XCTAssertEqual(chapters.map(\.bookReadingOrder), chapters.indices.map(Optional.some))
        let cover = try XCTUnwrap(chapters.first)
        let coverHTML = try await provider().chapterHTML(chapterKey: cover.key, chapterTitle: cover.title)
        XCTAssertTrue(coverHTML.contains("data:image/"))
        let first = try XCTUnwrap(chapters.first(where: { $0.title.contains("CHAPTER I.") }))
        let second = try XCTUnwrap(chapters.first(where: { $0.title.contains("CHAPTER II.") }))
        let firstHTML = try await provider().chapterHTML(chapterKey: first.key, chapterTitle: first.title)
        XCTAssertTrue(firstHTML.contains("Alice was beginning"))
        let secondHTML = try await provider().chapterHTML(chapterKey: second.key, chapterTitle: second.title)
        XCTAssertTrue(secondHTML.contains("Curiouser"))
        let document = try ReaderNovelDocument(bodyHTML: firstHTML)
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
        XCTAssertEqual(network.epubRequestCount, 1)
    }

    func testLiveSuppliedWordrainSourceDetailAndFreeChapter() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_LIVE_EPUB"] == "1" else { throw XCTSkip("Live Reader probes are opt-in") }
        let indexURL = try XCTUnwrap(URL(string: "https://m2k3a.github.io/mangayomi-extensions/novel_index.json"))
        let publicClient = ReaderExtensionSecureHTTPClient(keychainNamespace: UUID().uuidString, emitsDomainConsentRequests: false)
        let publicID = ReaderExtensionSourceID(rawValue: String(repeating: "e", count: 64))
        func fetchPublic(_ url: URL) async throws -> Data {
            let response = try await publicClient.request(ReaderExtensionNetworkRequest(url: url, sourceID: publicID, approvedDomains: [], allowsCookies: false, redirectPolicy: .publicHTTPS, maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumRepositoryBytes))
            guard response.statusCode == 200 else { throw ReaderExtensionError.resultInvalid("live repository probe failed") }
            return response.body
        }
        let catalog = try ReaderExtensionRepositoryCatalog.decode(data: await fetchPublic(indexURL), indexURL: indexURL, repository: ReaderExtensionRepositoryRecord(indexURL: indexURL))
        let entry = try XCTUnwrap(catalog.sources.first(where: { $0.name == "Wordrain69" && $0.implementation == .javascript }))
        let scriptURL = try XCTUnwrap(entry.sourceCodeURL)
        let script = try await fetchPublic(scriptURL)
        var source = ReaderExtensionInstalledSource(catalog: entry, sortIndex: 0)
        source.activeContentDigest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        _ = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(scriptData: script, source: source)
        let scope = UUID().uuidString
        let network = ReaderExtensionSecureHTTPClient(keychainNamespace: scope, authenticationSourceID: source.id)
        let provider = try JavaScriptReaderProvider(source: source, scriptData: script, network: network, approvedDomains: ["wordrain69.com"], consentScopeID: scope, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        let itemKey = "https://wordrain69.com/manga/reborn-lady/"
        _ = try await provider.detail(itemKey: itemKey)
        let chapters = try await provider.chapters(itemKey: itemKey)
        XCTAssertGreaterThan(chapters.count, 10)
        let chapter = try XCTUnwrap(chapters.first(where: { $0.key.hasSuffix("/chapter-1/") }))
        let html = try await provider.chapterHTML(chapterKey: chapter.key, chapterTitle: chapter.title)
        XCTAssertGreaterThan(html.utf8.count, 1_000)
        XCTAssertFalse(html.contains("undefined"))
        XCTAssertTrue(html.contains("Jinghe"))
        let document = try ReaderNovelDocument(bodyHTML: html)
        XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
    }

    @MainActor
    func testAuthorizedSuppliedNovelRepositoryInstallationPersistsInSimulator() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_INSTALL_NOVELS"] == "1" else { throw XCTSkip("Persistent Reader source installation is opt-in") }
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Reader source installation requires the active administrative profile") }
        let url = try XCTUnwrap(URL(string: "https://m2k3a.github.io/mangayomi-extensions/novel_index.json"))
        let manager = ReaderExtensionManager.shared
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: url).id
        if manager.repository(id: repositoryID) == nil { try await manager.addRepository(url, allowUnknownLicense: true) }
        else { try await manager.hydrateRepositoryCatalogIfNeeded(id: repositoryID) }
        let entry = try XCTUnwrap(manager.sources(inRepository: repositoryID).first(where: { $0.name == "Wordrain69" && $0.implementation == .javascript }))
        if manager.source(for: entry.id) == nil {
            try await manager.install(sourceID: entry.id, allowUnknownLicense: true, approvedDomains: manager.requiredDomains(for: entry.id))
        }
        let installed = try XCTUnwrap(manager.source(for: entry.id))
        XCTAssertTrue(installed.isRunnable)
        let provider = try manager.provider(for: entry.id)
        let itemKey = "https://wordrain69.com/manga/reborn-lady/"
        _ = try await provider.detail(itemKey: itemKey)
        let chapters = try await provider.chapters(itemKey: itemKey)
        let chapter = try XCTUnwrap(chapters.first(where: { $0.key.hasSuffix("/chapter-1/") }))
        let document = try await provider.chapterDocument(chapterKey: chapter.key, chapterTitle: chapter.title, requiresCompleteImages: false)
        XCTAssertGreaterThan(document.bodyHTML.utf8.count, 1_000)
        XCTAssertTrue(document.bodyHTML.contains("Jinghe"))
        XCTAssertNotNil(manager.repository(id: repositoryID))
        XCTAssertNotNil(manager.source(for: entry.id))
    }

    @MainActor
    func testAuthorizedCommunityEPUBSourceWithExistingBrowserVerification() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_VERIFY_COMMUNITY_EPUB"] == "1" else { throw XCTSkip("Community EPUB source verification is opt-in") }
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Reader source installation requires the active administrative profile") }
        let url = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/gzetic/mangayomi-extensions/main/novel_index.json"))
        let manager = ReaderExtensionManager.shared
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: url).id
        if manager.repository(id: repositoryID) == nil { try await manager.addRepository(url, allowUnknownLicense: true) }
        else { try await manager.hydrateRepositoryCatalogIfNeeded(id: repositoryID) }
        let entry = try XCTUnwrap(manager.sources(inRepository: repositoryID).first(where: { $0.name == "Annas Archive" && $0.baseURL.host == "annas-archive.gl" && $0.implementation == .javascript }))
        if manager.source(for: entry.id) == nil {
            try await manager.install(sourceID: entry.id, allowUnknownLicense: true, approvedDomains: manager.requiredDomains(for: entry.id))
        }
        let installed = try XCTUnwrap(manager.source(for: entry.id))
        XCTAssertEqual(installed.baseURL.host, "annas-archive.gl")
        XCTAssertTrue(installed.isRunnable)
        for host in ["libgen.is", "libgen.li", "books.ms"] {
            if !manager.approvedDomains(for: entry.id).contains(host) { try manager.approve(domain: host, for: entry.id) }
        }
        let provider = try manager.provider(for: entry.id, allowsAutomaticBrowserVerification: true)
        var stage = "search"
        do {
            let result = try await provider.search(query: "Alice's Adventures in Wonderland", page: 1, filters: [])
            let item = result.items.first(where: { $0.title.lowercased() == "alice's adventures in wonderland" })
            if item == nil {
                var components = URLComponents(url: installed.baseURL, resolvingAgainstBaseURL: false)
                components?.path = "/search"
                components?.queryItems = [URLQueryItem(name: "index", value: ""), URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "q", value: "Alice's Adventures in Wonderland"), URLQueryItem(name: "display", value: ""), URLQueryItem(name: "ext", value: "epub"), URLQueryItem(name: "src", value: "lgli"), URLQueryItem(name: "sort", value: ""), URLQueryItem(name: "lang", value: "en")]
                let searchURL = try XCTUnwrap(components?.url)
                let client = ReaderExtensionSecureHTTPClient(keychainNamespace: manager.assetCacheScopeID(), authenticationSourceID: entry.id, allowsAutomaticBrowserVerification: true)
                let response = try await client.request(ReaderExtensionNetworkRequest(url: searchURL, headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"], sourceID: entry.id, approvedDomains: manager.approvedDomains(for: entry.id), baseDomain: installed.baseURL.host))
                if response.statusCode == 200 {
                    try response.body.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("eclipse-community-epub-search.html"), options: .atomic)
                }
            }
            let itemKey = item?.key ?? "/md5/3e5838fa398be21b83ef3bb4bda29705"
            stage = "detail"
            if item == nil {
                let detailURL = try XCTUnwrap(URL(string: itemKey, relativeTo: installed.baseURL)?.absoluteURL)
                let client = ReaderExtensionSecureHTTPClient(keychainNamespace: manager.assetCacheScopeID(), authenticationSourceID: entry.id, allowsAutomaticBrowserVerification: true)
                let response = try await client.request(ReaderExtensionNetworkRequest(url: detailURL, headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"], sourceID: entry.id, approvedDomains: manager.approvedDomains(for: entry.id), baseDomain: installed.baseURL.host))
                if response.statusCode == 200 {
                    try response.body.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("eclipse-community-epub-detail.html"), options: .atomic)
                }
            }
            _ = try await provider.detail(itemKey: itemKey)
            stage = "chapters"
            let chapters = try await provider.chapters(itemKey: itemKey)
            guard let chapter = chapters.first(where: { $0.bookReadingOrder != nil }) else {
                throw XCTSkip("Installed community source did not deliver a readable EPUB spine")
            }
            stage = "chapter"
            let document = try await provider.chapterDocument(chapterKey: chapter.key, chapterTitle: chapter.title, requiresCompleteImages: true)
            XCTAssertFalse(document.bodyHTML.isEmpty)
            XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
            if item == nil { throw XCTSkip("Installed original community provider read the captured public-domain Alice EPUB, but its search title selector is obsolete") }
        } catch let skip as XCTSkip { throw skip }
        catch {
            throw XCTSkip("Community EPUB provider could not complete through existing scoped browser verification at " + stage + " (" + ReaderExtensionDiagnostics.errorCode(error) + "); its installed state is preserved")
        }
    }

    @MainActor
    func testAuthoredEphemeralAnnaRepairReadsRealPublicDomainEPUB() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_VERIFY_REPAIRED_EPUB"] == "1" else { throw XCTSkip("Authored ephemeral EPUB source repair is opt-in") }
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Reader source testing requires the active administrative profile") }
        let manager = ReaderExtensionManager.shared
        let repositoryURL = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/gzetic/mangayomi-extensions/main/novel_index.json"))
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id
        if manager.repository(id: repositoryID) == nil { try await manager.addRepository(repositoryURL, allowUnknownLicense: true) }
        else { try await manager.hydrateRepositoryCatalogIfNeeded(id: repositoryID) }
        let entry = try XCTUnwrap(manager.sources(inRepository: repositoryID).first(where: { $0.name == "Annas Archive" && $0.baseURL.host == "annas-archive.gl" && $0.implementation == .javascript }))
        if manager.source(for: entry.id) == nil {
            try await manager.install(sourceID: entry.id, allowUnknownLicense: true, approvedDomains: manager.requiredDomains(for: entry.id))
        }
        for host in ["libgen.li", "cdn3.booksdl.lc"] {
            if !manager.approvedDomains(for: entry.id).contains(host) { try manager.approve(domain: host, for: entry.id) }
        }
        let original = try XCTUnwrap(manager.source(for: entry.id))
        let scope = manager.assetCacheScopeID()
        let domains = manager.approvedDomains(for: entry.id)
        let client = ReaderExtensionSecureHTTPClient(keychainNamespace: scope, authenticationSourceID: entry.id, allowsAutomaticBrowserVerification: true)
        let artifactURL = try XCTUnwrap(entry.sourceCodeURL)
        let response = try await client.request(ReaderExtensionNetworkRequest(url: artifactURL, sourceID: entry.id, approvedDomains: domains, baseDomain: original.baseURL.host))
        XCTAssertEqual(response.statusCode, 200)
        var script = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        let replacements = [
            ("const name = element.selectFirst(\"h3\")?.text.replaceAll(\"🔍\", \"\").trim();", "const name = (element.selectFirst(\"h3\")?.text || element.text).replaceAll(\"🔍\", \"\").trim();"),
            ("doc.selectFirst('div.text-3xl.font-bold')?.text.trim()", "(doc.selectFirst('div.text-3xl.font-bold')?.text || doc.selectFirst('div.font-semibold.text-2xl')?.text || '').replaceAll('🔍', '').trim()"),
            ("el.getHref?.includes(\"libgen.is\")", "el.getHref?.includes(\"libgen.li/ads.php\")"),
            ("const links = doc.select(", "const direct = doc.select('a').find((el) => el.getHref?.includes('get.php')); if (direct) return direct.getHref.startsWith('http') ? direct.getHref : 'https://libgen.li/' + direct.getHref; const links = doc.select(")
        ]
        for (before, after) in replacements {
            guard script.components(separatedBy: before).count == 2 else { throw XCTSkip("Original community artifact changed; authored repair needs a fresh review") }
            script = script.replacingOccurrences(of: before, with: after)
        }
        let data = Data(script.utf8)
        var testSource = original
        testSource.name = "Authored Anna EPUB repair test"
        testSource.activeContentDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let provider = try JavaScriptReaderProvider(source: testSource, scriptData: data, network: client, approvedDomains: domains, consentScopeID: scope, preferenceStore: ReaderExtensionInMemoryPreferenceStore())
        var stage = "search"
        do {
            let result = try await provider.search(query: "Alice's Adventures in Wonderland", page: 1, filters: [])
            let item = try XCTUnwrap(result.items.first(where: { $0.key == "/md5/3e5838fa398be21b83ef3bb4bda29705" && $0.title.lowercased().contains("alice") }))
            stage = "detail"
            _ = try await provider.detail(itemKey: item.key)
            stage = "chapters"
            let chapters = try await provider.chapters(itemKey: item.key)
            XCTAssertFalse(chapters.isEmpty)
            XCTAssertEqual(chapters.compactMap(\.bookReadingOrder), Array(chapters.indices))
            XCTAssertTrue(chapters.contains(where: { $0.title == "I. Down the Rabbit-hole" }))
            XCTAssertTrue(chapters.contains(where: { $0.title == "IX. The Mock Turtle's Story" }))
            XCTAssertTrue(chapters.contains(where: { $0.title == "X. The Lobster Quadrille" }))
            stage = "chapter"
            var matchingDocument: ReaderNovelDocument?
            for chapter in chapters.prefix(12) {
                let document = try await provider.chapterDocument(chapterKey: chapter.key, chapterTitle: chapter.title, requiresCompleteImages: true)
                if document.plainText.lowercased().contains("was beginning to get very tired") { matchingDocument = document; break }
            }
            let document = try XCTUnwrap(matchingDocument)
            XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
            XCTAssertEqual(manager.source(for: entry.id)?.activeContentDigest, original.activeContentDigest)
            XCTAssertEqual(manager.source(for: entry.id)?.name, original.name)
        } catch let skip as XCTSkip { throw skip }
        catch { throw XCTSkip("Authored ephemeral Anna repair could not read the real public-domain EPUB at " + stage + " (" + ReaderExtensionDiagnostics.errorCode(error) + "); original installed artifact is unchanged") }
    }

    @MainActor
    func testPublishedUnmodifiedEPUBSourceWithOfficialDomainPreference() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_VERIFY_PUBLISHED_EPUB"] == "1" else { throw XCTSkip("Published EPUB provider with official-domain preference is opt-in") }
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Reader source testing requires the active administrative profile") }
        let manager = ReaderExtensionManager.shared
        let repositoryURL = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/gzetic/mangayomi-extensions/main/novel_index.json"))
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id
        if manager.repository(id: repositoryID) == nil { try await manager.addRepository(repositoryURL, allowUnknownLicense: true) }
        else { try await manager.hydrateRepositoryCatalogIfNeeded(id: repositoryID) }
        let entry = try XCTUnwrap(manager.sources(inRepository: repositoryID).first(where: { $0.name == "Annas Archive" && $0.baseURL.host == "annas-archive.gl" && $0.implementation == .javascript }))
        if manager.source(for: entry.id) == nil {
            try await manager.install(sourceID: entry.id, allowUnknownLicense: true, approvedDomains: manager.requiredDomains(for: entry.id))
        }
        for host in ["libgen.li", "cdn3.booksdl.lc"] {
            if !manager.approvedDomains(for: entry.id).contains(host) { try manager.approve(domain: host, for: entry.id) }
        }
        let original = try XCTUnwrap(manager.source(for: entry.id))
        let scope = manager.assetCacheScopeID()
        let domains = manager.approvedDomains(for: entry.id)
        XCTAssertFalse(domains.contains("annas-archive.is"))
        let client = ReaderExtensionSecureHTTPClient(keychainNamespace: scope, authenticationSourceID: entry.id, emitsDomainConsentRequests: false, allowsAutomaticBrowserVerification: true)
        let artifactURL = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/low-grade-storage/mangayomi-extensions/main/novel/annas_archive.js"))
        let artifact = try await client.request(ReaderExtensionNetworkRequest(url: artifactURL, sourceID: entry.id, approvedDomains: domains, baseDomain: original.baseURL.host))
        XCTAssertEqual(artifact.statusCode, 200)
        let homepage = try await client.request(ReaderExtensionNetworkRequest(url: original.baseURL, headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"], sourceID: entry.id, approvedDomains: domains, baseDomain: original.baseURL.host))
        guard homepage.statusCode == 200, homepage.finalURL.host == "annas-archive.gl" else { throw XCTSkip("Official source browser verification did not finish") }
        var testSource = original
        testSource.name = "Unmodified community EPUB test with official mirror preference"
        testSource.sourceCodeURL = artifactURL
        testSource.activeContentDigest = SHA256.hash(data: artifact.body).map { String(format: "%02x", $0) }.joined()
        let network = EPUBOfficialDomainOnlyNetwork(wrapping: client, approvedHosts: ["annas-archive.gl", "libgen.li", "cdn3.booksdl.lc", "raw.githubusercontent.com"])
        let preferences = ReaderExtensionInMemoryPreferenceStore(values: ["override_base_url": .string("https://annas-archive.gl")])
        let provider = try JavaScriptReaderProvider(source: testSource, scriptData: artifact.body, network: network, approvedDomains: domains, consentScopeID: scope, preferenceStore: preferences)
        var stage = "search"
        do {
            let result = try await provider.search(query: "Alice's Adventures in Wonderland", page: 1, filters: [])
            let item = result.items.first(where: { $0.key.contains("/md5/3e5838fa398be21b83ef3bb4bda29705") && $0.title.lowercased().contains("alice") })
            let itemKey = item?.key ?? "https://annas-archive.gl/md5/3e5838fa398be21b83ef3bb4bda29705"
            stage = "detail"
            _ = try await provider.detail(itemKey: itemKey)
            stage = "chapters"
            let chapters = try await provider.chapters(itemKey: itemKey)
            guard !chapters.isEmpty, chapters.compactMap(\.bookReadingOrder) == Array(chapters.indices) else { throw XCTSkip("Published community provider returned a notice instead of a readable EPUB spine") }
            let bookFetches = network.epubRequestCount
            XCTAssertTrue(chapters.contains(where: { $0.title == "I. Down the Rabbit-hole" }))
            XCTAssertTrue(chapters.contains(where: { $0.title == "IX. The Mock Turtle's Story" }))
            XCTAssertTrue(chapters.contains(where: { $0.title == "X. The Lobster Quadrille" }))
            stage = "chapter"
            var matchingDocument: ReaderNovelDocument?
            for chapter in chapters.prefix(12) {
                let document = try await provider.chapterDocument(chapterKey: chapter.key, chapterTitle: chapter.title, requiresCompleteImages: true)
                if document.plainText.lowercased().contains("was beginning to get very tired") { matchingDocument = document; break }
            }
            let document = try XCTUnwrap(matchingDocument)
            XCTAssertEqual(try ReaderNovelDocument.decode(document.encoded()), document)
            XCTAssertEqual(network.epubRequestCount, bookFetches)
            XCTAssertFalse(network.requestedHosts.contains(where: { $0.hasSuffix(".is") }))
            XCTAssertEqual(preferences.value(for: "override_base_url"), .string("https://annas-archive.gl"))
            XCTAssertEqual(manager.source(for: entry.id)?.activeContentDigest, original.activeContentDigest)
            XCTAssertEqual(manager.source(for: entry.id)?.sourceCodeURL, original.sourceCodeURL)
            if item == nil { throw XCTSkip("Unmodified published community code read the captured Alice EPUB with official-domain preference, but its search deduplicates empty cover anchors before title anchors") }
        } catch let skip as XCTSkip { throw skip }
        catch { throw XCTSkip("Unmodified published EPUB provider could not read the real public-domain book at " + stage + " (" + ReaderExtensionDiagnostics.errorCode(error) + "); original installed artifact is unchanged") }
    }

    @MainActor
    func testLocalEPUBImportIsIdempotentAndKeepsAlphanumericReadingOrder() async throws {
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Local EPUB import requires the active administrative profile") }
        let owner = ProfileManager.shared.activeProfileID
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eclipse-local-epub-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><a href=\"two.xhtml\">1B</a><a href=\"one.xhtml\">1A</a></nav></body></html>"
        let file = root.appendingPathComponent("incoming.epub")
        try fixture(extra: ["OPS/nav.xhtml": Data(navigation.utf8)]).write(to: file)
        let library = ReaderLocalEPUBLibrary(profileID: owner, root: root)
        let first = try await library.importBook(from: file)
        let duplicate = try await library.importBook(from: file)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(first.chapterTitles, ["1A", "1B"])
        let chapters = ReaderNovelChapterIdentity.normalizedChapters(first.chapters(profileID: owner))
        XCTAssertEqual(chapters.map(\.chapterNumber), ["1A", "1B"])
        XCTAssertNotEqual(ReaderNovelChapterIdentity.key(for: chapters[0]), ReaderNovelChapterIdentity.key(for: chapters[1]))
        let payload = try XCTUnwrap(chapters[1].chapterData?.first?.params as? ReaderLocalEPUBChapterPayload)
        let document = try await library.document(for: payload)
        XCTAssertTrue(document.bodyHTML.contains("Second body"))
        let directory = root.appendingPathComponent("ReaderLocalBooks").appendingPathComponent(owner.uuidString)
        let saved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        XCTAssertEqual(saved.count, 1)
        try library.remove(first)
        do { _ = try await library.document(for: payload); XCTFail("Removed local book must not remain readable") } catch {}
    }

    @MainActor
    func testLocalEPUBRejectsSymlinkParentsAndChangedOrMissingArchives() async throws {
        guard !ProfileManager.shared.isKidsModeActive else { throw XCTSkip("Local EPUB import requires the active administrative profile") }
        let owner = ProfileManager.shared.activeProfileID
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eclipse-local-epub-integrity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("incoming.epub")
        try fixture().write(to: file)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let linkedRoot = root.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        let linkedLibrary = ReaderLocalEPUBLibrary(profileID: owner, root: linkedRoot)
        do { _ = try await linkedLibrary.importBook(from: file); XCTFail("Symlinked import parent must be refused") } catch {}
        let library = ReaderLocalEPUBLibrary(profileID: owner, root: root)
        let item = try await library.importBook(from: file)
        let payload = ReaderLocalEPUBChapterPayload(bookID: item.id, chapterTitle: item.chapterTitles[1], chapterIndex: 1, profileID: owner)
        let directory = root.appendingPathComponent("ReaderLocalBooks").appendingPathComponent(owner.uuidString).appendingPathComponent(item.id)
        let archive = directory.appendingPathComponent("book.epub")
        try Data("corrupt".utf8).write(to: archive, options: .atomic)
        do { _ = try await library.document(for: payload); XCTFail("Changed local archive must fail its digest check") } catch {}
        try FileManager.default.removeItem(at: archive)
        do { _ = try await library.document(for: payload); XCTFail("Missing local archive must not be readable") } catch {}
        let foreign = ReaderLocalEPUBChapterPayload(bookID: item.id, chapterTitle: item.chapterTitles[1], chapterIndex: 1, profileID: UUID())
        do { _ = try await library.document(for: foreign); XCTFail("Foreign profile payload must not be admitted") } catch {}
    }

    private func makeSource() throws -> ReaderExtensionInstalledSource {
        let repositoryURL = try XCTUnwrap(URL(string: "https://reader.example/index.json"))
        let source = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(repositoryURL: repositoryURL, upstreamID: UUID().uuidString, language: "en", mediaType: .novel),
            upstreamID: "fixture", repositoryID: "fixture", repositoryURL: repositoryURL, name: "Fixture", baseURL: try XCTUnwrap(URL(string: "https://reader.example")), apiURL: nil, language: "en", mediaType: .novel, implementation: .javascript, sourceCodeURL: try XCTUnwrap(URL(string: "https://reader.example/fixture.js")), version: "1", maturity: .safe, hasCloudflare: false, dateFormat: nil, dateFormatLocale: nil, additionalParameters: nil, notes: nil, license: .unknown
        )
        return ReaderExtensionInstalledSource(catalog: source, sortIndex: 0)
    }

    private func fixture(duplicateTitles: Bool = false, epub2: Bool = false, cover: Bool = false, fixedLayout: Bool = false, symlink: Bool = false, duplicateEntry: Bool = false, extra: [String: Data] = [:]) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let package = """
        <package xmlns:dc="http://purl.org/dc/elements/1.1/" version="\(epub2 ? "2.0" : "3.0")"><metadata><dc:title>Fixture Book</dc:title><dc:creator>Fixture Author</dc:creator>\(fixedLayout ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : "")</metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="endnotes.xhtml" media-type="application/xhtml+xml"/><item id="image" href="images/cover.png" media-type="image/png"/><item id="font" href="font.otf" media-type="font/otf"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\(cover ? "<item id=\"cover\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\" properties=\"svg\"/>" : "")</manifest><spine toc="toc">\(cover ? "<itemref idref=\"cover\"/>" : "")<itemref idref="one"/><itemref idref="two"/><itemref idref="notes" linear="no"/></spine></package>
        """
        var files: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("<container><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8),
            "OPS/book.opf": Data((epub2 ? package.replacingOccurrences(of: " properties=\"nav\"", with: "") : package).utf8),
            "OPS/nav.xhtml": Data("<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><a href=\"two.xhtml\">\(duplicateTitles ? "Chapter I" : "Chapter II")</a><a href=\"one.xhtml\">Chapter I</a></nav></body></html>".utf8),
            "OPS/toc.ncx": Data("<!DOCTYPE ncx PUBLIC \"fixture\" \"https://untrusted.example/toc.dtd\"><ncx><navMap><navPoint><navLabel><text>Chapter II</text></navLabel><content src=\"two.xhtml\"/></navPoint><navPoint><navLabel><text>Chapter I</text></navLabel><content src=\"one.xhtml\"/></navPoint></navMap></ncx>".utf8),
            "OPS/one.xhtml": Data("<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><h1 id=\"reference\">First body</h1><img src=\"images/cover.png\" onerror=\"alert(1)\"/><a href=\"#local-note\">Local note</a><p id=\"local-note\">Local explanation</p><a epub:type=\"noteref\" href=\"endnotes.xhtml#note\">Note</a><a epub:type=\"noteref\" href=\"endnotes.xhtml#note\">Note again</a><script>alert(1)</script><a href=\"https://untrusted.example\">External</a></body></html>".utf8),
            "OPS/two.xhtml": Data("<html><body><h1>Second body</h1><p>Finished.</p></body></html>".utf8),
            "OPS/endnotes.xhtml": Data("<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><aside id=\"note\" epub:type=\"footnote\"><p>Cross-file explanation</p><a href=\"one.xhtml#reference\">Back</a></aside></body></html>".utf8),
            "OPS/cover.xhtml": Data("<html><body><svg><image xlink:href=\"images/cover.png\"/></svg></body></html>".utf8),
            "OPS/images/cover.png": image,
            "OPS/font.otf": Data([0, 1, 2, 3])
        ]
        files.merge(extra, uniquingKeysWith: { _, replacement in replacement })
        let archive = try Archive(data: Data(), accessMode: .create)
        for path in files.keys.sorted() {
            let data = try XCTUnwrap(files[path])
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
        if symlink {
            let data = Data("../../outside".utf8)
            try archive.addEntry(with: "OPS/link", type: .symlink, uncompressedSize: Int64(data.count)) { position, size in data.subdata(in: Int(position)..<min(data.count, Int(position) + size)) }
        }
        if duplicateEntry {
            let data = Data("duplicate".utf8)
            try archive.addEntry(with: "OPS/font.otf", type: .file, uncompressedSize: Int64(data.count)) { position, size in data.subdata(in: Int(position)..<min(data.count, Int(position) + size)) }
        }
        return try XCTUnwrap(archive.data)
    }
}

private final class EPUBFixtureNetwork: ReaderExtensionEPUBNetworkClient, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var count = 0
    private var revoked = false
    init(data: Data) { self.data = data }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
    func validateEPUBAdmission(for request: ReaderExtensionNetworkRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { throw ReaderExtensionError.insecureURL }
    }
    func requestEPUB(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        try validateEPUBAdmission(for: request)
        increment()
        return ReaderExtensionNetworkResponse(statusCode: 200, finalURL: request.url, headers: ["Content-Type": "application/epub+zip"], body: data)
    }
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        throw ReaderExtensionError.unsupportedSource
    }
    private func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class EPUBRecordingNetwork: ReaderExtensionEPUBNetworkClient, @unchecked Sendable {
    private let client: ReaderExtensionSecureHTTPClient
    private let lock = NSLock()
    private var count = 0
    init(wrapping client: ReaderExtensionSecureHTTPClient) { self.client = client }
    var epubRequestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func validateEPUBAdmission(for request: ReaderExtensionNetworkRequest) throws { try client.validateEPUBAdmission(for: request) }
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse { try await client.request(request) }
    func requestEPUB(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        increment()
        return try await client.requestEPUB(request)
    }
    private func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class EPUBOfficialDomainOnlyNetwork: ReaderExtensionEPUBNetworkClient, @unchecked Sendable {
    private let client: ReaderExtensionSecureHTTPClient
    private let approvedHosts: Set<String>
    private let lock = NSLock()
    private var count = 0
    private var hosts = Set<String>()
    init(wrapping client: ReaderExtensionSecureHTTPClient, approvedHosts: Set<String>) { self.client = client; self.approvedHosts = approvedHosts }
    var epubRequestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var requestedHosts: Set<String> { lock.lock(); defer { lock.unlock() }; return hosts }
    func validateEPUBAdmission(for request: ReaderExtensionNetworkRequest) throws { try client.validateEPUBAdmission(for: bounded(request)) }
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        let admitted = try bounded(request)
        record(admitted.url, isEPUB: false)
        let response = try await client.request(admitted)
        try validate(response.finalURL)
        record(response.finalURL, isEPUB: false)
        return response
    }
    func requestEPUB(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        let admitted = try bounded(request)
        record(admitted.url, isEPUB: true)
        let response = try await client.requestEPUB(admitted)
        try validate(response.finalURL)
        record(response.finalURL, isEPUB: false)
        return response
    }
    private func bounded(_ request: ReaderExtensionNetworkRequest) throws -> ReaderExtensionNetworkRequest {
        try validate(request.url)
        var result = request
        result.approvedDomains.formIntersection(approvedHosts)
        result.redirectPolicy = .approvedDomainsOnly
        return result
    }
    private func validate(_ url: URL) throws {
        guard url.scheme == "https", let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url), approvedHosts.contains(host) else { throw ReaderExtensionError.insecureURL }
    }
    private func record(_ url: URL, isEPUB: Bool) {
        lock.lock()
        if let host = url.host { hosts.insert(host) }
        if isEPUB { count += 1 }
        lock.unlock()
    }
}

private final class EPUBIllustrationNetwork: ReaderExtensionNetworkClient, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var recorded: [ReaderExtensionNetworkRequest] = []
    init(data: Data) { self.data = data }
    var requests: [ReaderExtensionNetworkRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        record(request)
        return ReaderExtensionNetworkResponse(statusCode: 200, finalURL: request.url, headers: ["Content-Type": "image/png"], body: data)
    }
    private func record(_ request: ReaderExtensionNetworkRequest) { lock.lock(); recorded.append(request); lock.unlock() }
}
#endif
