import AppKit
import WebKit
import XCTest
@testable import EclipseMac

@MainActor
final class MacReaderNovelTests: XCTestCase {
    func testClosingBeforeWebKitLoadPreservesSavedPosition() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.store.set(0.43, forKey: fixture.key(for: fixture.chapters[0]))
        let host = NovelHost(session: fixture.session)
        XCTAssertFalse(host.coordinator.isDocumentReady)
        host.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.store.double(forKey: fixture.key(for: fixture.chapters[0])), 0.43, accuracy: 0.000001)
        XCTAssertFalse(host.coordinator.isAutoScrolling)
    }

    func testWebKitRestoresPositionAndReportsRealDocumentScroll() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let key = fixture.key(for: fixture.chapters[0])
        fixture.store.set(0.42, forKey: key)
        fixture.store.set("Menlo", forKey: "readerFontFamily")
        fixture.store.set("700", forKey: "readerFontWeight")
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        try await wait("The isolated novel document must finish restoring its position.") { host.coordinator.isDocumentReady }
        let metrics = try await host.metrics()
        XCTAssertGreaterThan(metrics.height, 10_000)
        XCTAssertGreaterThan(metrics.offset, 1000)
        XCTAssertEqual(metrics.offset / metrics.height, 0.42, accuracy: 0.003)
        let font = try await host.webView.evaluateJavaScript("getComputedStyle(document.body).fontFamily + ':' + getComputedStyle(document.body).fontWeight") as? String
        XCTAssertTrue(font?.contains("Menlo") == true)
        XCTAssertTrue(font?.hasSuffix(":700") == true)
        let text = try await host.webView.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(text?.contains("Fixture paragraph 299") == true)
        _ = try await host.webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight * 0.63);window.dispatchEvent(new Event('resize'))")
        try await wait("The native bridge must persist the actual DOM scroll position.") { abs(fixture.store.double(forKey: key) - 0.63) < 0.003 }
        let scrolled = try await host.metrics()
        XCTAssertEqual(scrolled.offset / scrolled.height, fixture.store.double(forKey: key), accuracy: 0.003)
        XCTAssertEqual(fixture.session.reader?.mangaId, 0)
        XCTAssertNil(fixture.session.reader?.mangaRoute)
    }

    func testJumpAndTypographyReflowPreserveTheRealDocumentPosition() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        try await wait("The novel must restore before jumping.") { host.coordinator.isDocumentReady }
        fixture.session.requestNovelPosition(0.68)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        let key = fixture.key(for: fixture.chapters[0])
        try await wait("A requested jump must reach the real document and progress bridge.") { fixture.session.novelReadingProgress > 0.65 }
        let jumped = try await host.metrics()
        XCTAssertEqual(jumped.offset / (jumped.height - jumped.viewport), 0.68, accuracy: 0.003)
        let saved = fixture.store.double(forKey: key)
        fixture.store.set(30.0, forKey: "readerFontSize")
        fixture.store.set(2.4, forKey: "readerLineSpacing")
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var reflowed = try await host.metrics()
        while reflowed.height <= jumped.height * 1.4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            reflowed = try await host.metrics()
        }
        XCTAssertGreaterThan(reflowed.height, jumped.height * 1.4)
        XCTAssertEqual(reflowed.offset / reflowed.height, saved, accuracy: 0.003)
        XCTAssertEqual(fixture.store.double(forKey: key), saved, accuracy: 0.003)
        fixture.session.requestNovelPosition(1)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("Jumping to the end must update the visible reading percentage.") { fixture.session.novelReadingProgress == 1 }
        let end = try await host.metrics()
        XCTAssertGreaterThanOrEqual(end.offset + end.viewport, end.height - 1)
    }

    func testOldDocumentMessagesCannotOverwriteEitherChapterAfterReplacement() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let firstKey = fixture.key(for: fixture.chapters[0])
        let secondKey = fixture.key(for: fixture.chapters[1])
        fixture.store.set(0.21, forKey: firstKey)
        fixture.store.set(0.54, forKey: secondKey)
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        try await wait("The first document must finish restoring.") { host.coordinator.isDocumentReady }
        let oldDocument = host.coordinator.documentID
        fixture.session.select(fixture.chapters[1])
        try await wait("The replacement chapter must load through the real Reader session.") { !fixture.session.isLoading && !fixture.session.pages.isEmpty }
        try await host.postPosition(documentID: oldDocument, fraction: 0.91)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.double(forKey: firstKey), 0.21, accuracy: 0.003)
        XCTAssertEqual(fixture.store.double(forKey: secondKey), 0.54, accuracy: 0.000001)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("The second WebKit document must finish restoring.") { host.coordinator.isDocumentReady && host.coordinator.documentID != oldDocument }
        try await host.postPosition(documentID: oldDocument, fraction: 0.07)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.double(forKey: firstKey), 0.21, accuracy: 0.003)
        XCTAssertEqual(fixture.store.double(forKey: secondKey), 0.54, accuracy: 0.003)
        let secondMetrics = try await host.metrics()
        XCTAssertEqual(secondMetrics.offset / secondMetrics.height, 0.54, accuracy: 0.003)
        host.coordinator.close()
        try await host.postPosition(documentID: host.coordinator.documentID, fraction: 0.02)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.double(forKey: secondKey), 0.54, accuracy: 0.003)
    }

    func testAutoScrollMovesDocumentAndStopsItsTimerAtBottom() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        try await wait("The novel must be ready before auto-scrolling.") { host.coordinator.isDocumentReady }
        fixture.session.autoScrollSpeed = 4
        fixture.session.autoScroll = true
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        XCTAssertTrue(host.coordinator.isAutoScrolling)
        try await Task.sleep(for: .milliseconds(250))
        let moved = try await host.metrics()
        XCTAssertGreaterThan(moved.offset, 0, "The native timer must move the actual WebKit document.")
        _ = try await host.webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight);window.dispatchEvent(new Event('resize'))")
        try await wait("Reaching the bottom must stop auto-scroll and release its timer.") { !fixture.session.autoScroll && !host.coordinator.isAutoScrolling }
        let bottom = try await host.metrics()
        XCTAssertGreaterThanOrEqual(bottom.offset + bottom.viewport, bottom.height - 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(host.coordinator.isAutoScrolling)
        let stopped = try await host.metrics()
        XCTAssertEqual(stopped.offset, bottom.offset, accuracy: 0.001)
    }

    private func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw FixtureFailure.timedOut
    }

    private enum FixtureFailure: Error { case timedOut }

    @MainActor
    private final class Fixture {
        let suite = "EclipseMac.NovelFixture." + UUID().uuidString
        let store: UserDefaults
        let session: MacReaderSession
        let chapters: [Chapter]

        init() async throws {
            if MacLaunchProfileAccess.requiresUnlock || MacLaunchProfileAccess.isTerminating || !ProfileManager.shared.rosterStoreIsReadable {
                throw XCTSkip("The existing profile is locked, terminating, or unreadable; the fixture preserves its state.")
            }
            store = try XCTUnwrap(UserDefaults(suiteName: suite))
            session = MacReaderSession(settingsStore: store)
            chapters = [Chapter(chapterNumber: "Fixture 1", idx: 0, chapterData: nil), Chapter(chapterNumber: "Fixture 2", idx: 1, chapterData: nil)]
            let paragraphs = (0..<300).map { "<p>Fixture paragraph \($0). A quiet path crosses the hillside. This generated passage exists only to exercise document layout, scroll restoration, and reading progress.</p>" }.joined()
            session.open(item: MangaLibraryItem(aniListId: 0, title: "Generated Novel Fixture", coverURL: nil, format: "NOVEL", totalChapters: nil, contentRating: ReaderContentRating.safe.rawValue), chapters: chapters, selected: chapters[0], engine: KanzenEngine()) { chapter, _ in [PageData(content: .text("<h1>\(chapter.chapterNumber)</h1>" + paragraphs))] }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while session.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard !session.isLoading, session.pages.count == 1 else { close(); throw FixtureFailure.timedOut }
        }

        func key(for chapter: Chapter) -> String { MacReaderNovelPosition.storageKey(route: nil, mangaID: 0, chapter: chapter) }
        func close() { session.close(); store.removePersistentDomain(forName: suite) }
    }

    @MainActor
    private final class NovelHost {
        let window: NSWindow
        let coordinator: MacReaderNovelView.Coordinator
        let webView: MacReaderNovelWebView
        private var closed = false

        init(session: MacReaderSession) {
            coordinator = MacReaderNovelView.Coordinator(session: session)
            webView = coordinator.makeWebView(settings: MacReaderSettingsSnapshot(session: session))
            let size = CGSize(width: 900, height: 600)
            webView.frame = CGRect(origin: .zero, size: size)
            webView.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            webView.layoutSubtreeIfNeeded()
        }

        func metrics() async throws -> (offset: Double, height: Double, viewport: Double) {
            let result = try await webView.evaluateJavaScript("({offset:scrollY,height:document.documentElement.scrollHeight,viewport:innerHeight})")
            let values = try XCTUnwrap(result as? [String: Double])
            return (try XCTUnwrap(values["offset"]), try XCTUnwrap(values["height"]), try XCTUnwrap(values["viewport"]))
        }

        func postPosition(documentID: String, fraction: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
            do {
                let result = try await webView.evaluateJavaScript("window.webkit.messageHandlers.readerPosition.postMessage({documentID:'\(documentID)',fraction:\(fraction),completion:1});true;", in: nil, contentWorld: MacReaderNovelView.Coordinator.bridgeWorld)
                XCTAssertEqual(result as? Bool, true, "The real isolated WebKit document must send its position callback.", file: file, line: line)
            } catch {
                let failure = error as NSError
                XCTFail("WebKit position callback failed: \(failure.domain) code=\(failure.code), \(failure.localizedDescription)", file: file, line: line)
                throw error
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            MacReaderNovelView.dismantleNSView(webView, coordinator: coordinator)
            window.contentView = nil
            window.close()
        }
    }
}
