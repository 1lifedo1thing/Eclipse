import AppKit
import WebKit
import XCTest
@testable import EclipseMac

@MainActor
final class MacReaderNovelTests: XCTestCase {
    func testUnavailableLocalBookCannotStartReaderOrInjectedPageLoader() async throws {
        if MacLaunchProfileAccess.requiresUnlock || MacLaunchProfileAccess.isTerminating || !ProfileManager.shared.rosterStoreIsReadable {
            throw XCTSkip("The existing profile is unavailable; the fixture preserves its state.")
        }
        let suite = "EclipseMac.MissingLocalNovelFixture." + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = MacReaderSession(settingsStore: store)
        defer { session.close(); store.removePersistentDomain(forName: suite) }
        let payload = ReaderLocalEPUBChapterPayload(bookID: String(repeating: "0", count: 64), chapterTitle: "Preface", chapterIndex: 0, profileID: ProfileManager.shared.activeProfileID)
        let chapter = Chapter(chapterNumber: "Preface", idx: 0, chapterData: [ChapterData(params: payload, title: "Preface")])
        let item = MangaLibraryItem(aniListId: -996, title: "Missing local book", coverURL: nil, format: "NOVEL", totalChapters: 1, isNovel: true, latestChapterNumbers: ["Preface"], usesExactChapterTitles: true)
        var loads = 0
        session.open(item: item, chapters: [chapter], selected: chapter, engine: KanzenEngine()) { _, _ in
            loads += 1
            return [PageData(content: .novelDocument(try ReaderNovelDocument(bodyHTML: "<p>Text</p>")))]
        }
        await Task.yield()
        XCTAssertFalse(session.isReading)
        XCTAssertTrue(session.pages.isEmpty)
        XCTAssertEqual(loads, 0)
        XCTAssertNotNil(session.error)
    }

    func testOfflineOrderUsesBookSpineAndPreservesOrdinaryInputOrder() {
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "f", count: 64))
        let route = MangaContentRoute.readerExtension(source: source, itemKey: "book", legacyStableKey: nil)
        func download(_ title: String, date: TimeInterval, order: Int? = nil) -> ReaderDownloadItem {
            let key = ChapterIdentityNormalizer.key(for: title)
            return ReaderDownloadItem(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: title), route: route, routeKey: route.stableKey, mangaId: route.stableNegativeId, mangaTitle: "Book", coverURL: nil, sourceName: "Fixture", format: order == nil ? "MANGA" : "NOVEL", chapterNumber: title, chapterTitle: title, chapterKey: key, contentRating: ReaderContentRating.safe.rawValue, provider: ReaderDownloadProvider(kind: .readerExtension, sourceId: source.rawValue, mangaKey: "book", moduleUUID: nil, contentParams: nil, isNovel: order != nil, chapterParams: title, bookReadingOrder: order), status: .completed, progress: 1, completedPages: 1, totalPages: 1, downloadedBytes: 1, error: nil, dateAdded: Date(timeIntervalSince1970: date), dateCompleted: Date(timeIntervalSince1970: date))
        }
        let ordinary = [download("Chapter 1", date: 300), download("Chapter 2", date: 100), download("Chapter 3", date: 200)]
        XCTAssertEqual(MacReaderOfflineChapterPolicy.chapters(for: route, downloads: ordinary).map(\.chapterNumber), ["Chapter 1", "Chapter 2", "Chapter 3"])
        let book = [download("Chapter 1B", date: 100, order: 2), download("Preface", date: 300, order: 0), download("Chapter 1A", date: 200, order: 1)]
        XCTAssertEqual(MacReaderOfflineChapterPolicy.chapters(for: route, downloads: book).map(\.chapterNumber), ["Preface", "Chapter 1A", "Chapter 1B"])
    }

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
        try await host.waitUntilReady("The isolated novel document must finish restoring its position.")
        let metrics = try await host.metrics()
        XCTAssertGreaterThan(metrics.height, 10_000)
        XCTAssertGreaterThan(metrics.offset, 1000)
        XCTAssertEqual(metrics.offset / metrics.height, 0.42, accuracy: 0.003)
        let font = try await host.webView.evaluateJavaScript("getComputedStyle(document.body).fontFamily + ':' + getComputedStyle(document.body).fontWeight") as? String
        XCTAssertTrue(font?.contains("Menlo") == true)
        XCTAssertTrue(font?.hasSuffix(":700") == true)
        let text = try await host.webView.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(text?.contains("Fixture paragraph 299") == true)
        _ = try await host.webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight * 0.63);window.dispatchEvent(new Event('scroll'))")
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
        try await host.waitUntilReady("The novel must restore before jumping.")
        fixture.session.requestNovelPosition(0.68)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        let key = fixture.key(for: fixture.chapters[0])
        try await wait("A requested jump must reach the real document and progress bridge.") { fixture.session.novelReadingProgress > 0.65 }
        let jumped = try await host.metrics()
        XCTAssertEqual(jumped.offset / (jumped.height - jumped.viewport), 0.68, accuracy: 0.003)
        try await Task.sleep(for: .milliseconds(100))
        let afterFrame = try await host.metrics()
        XCTAssertEqual(afterFrame.offset / (afterFrame.height - afterFrame.viewport), 0.68, accuracy: 0.003)
        let anchor = try await host.locator()
        fixture.store.set(30.0, forKey: "readerFontSize")
        fixture.store.set(2.4, forKey: "readerLineSpacing")
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("Typography must settle before publishing its restored text position.") { !host.coordinator.styleRequestPending }
        let reflowed = try await host.metrics()
        let reflowedAnchor = try await host.locator()
        XCTAssertGreaterThan(reflowed.height, jumped.height * 1.4)
        XCTAssertEqual(reflowedAnchor.quote, anchor.quote)
        XCTAssertEqual(reflowedAnchor.textIndex, anchor.textIndex)
        XCTAssertEqual(fixture.store.double(forKey: key), reflowed.offset / reflowed.height, accuracy: 0.003)
        fixture.session.requestNovelPosition(1)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("Jumping to the end must update the visible reading percentage.") { fixture.session.novelReadingProgress == 1 }
        let end = try await host.metrics()
        XCTAssertGreaterThanOrEqual(end.offset + end.viewport, end.height - 1)
    }

    func testAnchoredResumeSurvivesTypographyAndWindowWidthChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let first = NovelHost(session: fixture.session)
        defer { first.close() }
        try await first.waitUntilReady("The initial chapter must be ready before saving an anchored position.")
        fixture.session.requestNovelPosition(0.58)
        first.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        let key = fixture.key(for: fixture.chapters[0])
        let locatorKey = "novelLocator_v1_" + String(key.dropFirst("novelScrollPos_".count))
        try await wait("Reading must persist an anchored locator.") {
            guard let locator = ReaderNovelLocator.decode(fixture.store.data(forKey: locatorKey)) else { return false }
            return locator.fraction > 0.55 && !locator.quote.isEmpty
        }
        let saved = try XCTUnwrap(ReaderNovelLocator.decode(fixture.store.data(forKey: locatorKey)))
        first.close()
        fixture.store.set(30.0, forKey: "readerFontSize")
        fixture.store.set(2.4, forKey: "readerLineSpacing")
        let restored = NovelHost(session: fixture.session)
        defer { restored.close() }
        restored.window.setContentSize(NSSize(width: 600, height: 500))
        try await restored.waitUntilReady("The resized reader must restore its text anchor.")
        let current = try XCTUnwrap(ReaderNovelLocator.decode(fixture.store.data(forKey: locatorKey)))
        XCTAssertEqual(current.quote, saved.quote)
        XCTAssertEqual(current.textIndex, saved.textIndex)
        try await Task.sleep(for: .milliseconds(100))
        let settled = try await restored.locator()
        XCTAssertEqual(settled.quote, saved.quote)
        XCTAssertEqual(settled.textIndex, saved.textIndex)
        XCTAssertNil(fixture.session.novelPositionCommand)
    }

    func testLatestTypographyAndQueuedSeekRejectOldLayoutMetrics() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        try await host.waitUntilReady("The chapter must be ready before changing layout.")
        fixture.session.requestNovelPosition(0.45)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("The initial seek must reach the actual document.") { fixture.session.novelReadingProgress > 0.44 }
        let key = fixture.key(for: fixture.chapters[0])
        let saved = fixture.store.double(forKey: key)
        let oldLayout = host.coordinator.layoutGeneration
        fixture.store.set(30.0, forKey: "readerFontSize")
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        XCTAssertTrue(host.coordinator.styleRequestPending)
        fixture.store.set(24.0, forKey: "readerFontSize")
        fixture.store.set(2.1, forKey: "readerLineSpacing")
        fixture.session.requestNovelPosition(0.77)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await host.postPosition(documentID: host.coordinator.documentID, fraction: 0.99, layoutGeneration: oldLayout)
        XCTAssertNotEqual(fixture.store.double(forKey: key), 0.99, accuracy: 0.000001)
        XCTAssertGreaterThan(saved, 0.4)
        try await wait("The newest typography must finish and apply its queued seek.") {
            !host.coordinator.styleRequestPending && fixture.session.novelReadingProgress > 0.75
        }
        let metrics = try await host.metrics()
        XCTAssertEqual(metrics.offset / (metrics.height - metrics.viewport), 0.77, accuracy: 0.003)
        let style = try await host.webView.evaluateJavaScript("({font:parseFloat(getComputedStyle(document.body).fontSize),lineHeight:parseFloat(getComputedStyle(document.body).lineHeight)})") as? [String: Double]
        XCTAssertEqual(try XCTUnwrap(style?["font"]), 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(style?["lineHeight"]), 50.4, accuracy: 0.001)
        XCTAssertNotEqual(host.coordinator.layoutGeneration, oldLayout)
        let settled = fixture.store.double(forKey: key)
        try await host.postPosition(documentID: host.coordinator.documentID, fraction: 0.99, layoutGeneration: oldLayout)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.double(forKey: key), settled, accuracy: 0.003)
    }

    func testOccludedDocumentRestoresReflowsAndReportsWithoutPainting() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let key = fixture.key(for: fixture.chapters[0])
        fixture.store.set(0.41, forKey: key)
        let host = NovelHost(session: fixture.session)
        defer { host.close() }
        host.window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(50))
        try await host.waitUntilReady("An occluded document must finish layout without waiting for painting.")
        let visibility = try await host.webView.evaluateJavaScript("document.visibilityState") as? String
        XCTAssertEqual(visibility, "hidden")
        let initial = try await host.metrics()
        XCTAssertEqual(initial.offset / initial.height, 0.41, accuracy: 0.003)
        let anchor = try await host.locator()
        fixture.store.set(30.0, forKey: "readerFontSize")
        fixture.store.set(2.4, forKey: "readerLineSpacing")
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await wait("Occluded typography must finish restoring its text anchor.") { !host.coordinator.styleRequestPending }
        let reflowed = try await host.locator()
        XCTAssertEqual(reflowed.quote, anchor.quote)
        XCTAssertEqual(reflowed.textIndex, anchor.textIndex)
        _ = try await host.webView.evaluateJavaScript("window.scrollTo(0,document.documentElement.scrollHeight*0.64);for(let i=0;i<20;i++)window.dispatchEvent(new Event('scroll'))")
        try await wait("Coalesced scroll reports must persist even while animation frames are suspended.") { abs(fixture.store.double(forKey: key) - 0.64) < 0.003 }
        let scrolled = try await host.metrics()
        XCTAssertEqual(fixture.store.double(forKey: key), scrolled.offset / scrolled.height, accuracy: 0.003)
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
        try await host.waitUntilReady("The first document must finish restoring.")
        let oldDocument = host.coordinator.documentID
        fixture.session.select(fixture.chapters[1])
        try await wait("The replacement chapter must load through the real Reader session.") { !fixture.session.isLoading && !fixture.session.pages.isEmpty }
        try await host.postPosition(documentID: oldDocument, fraction: 0.91)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.double(forKey: firstKey), 0.21, accuracy: 0.003)
        XCTAssertEqual(fixture.store.double(forKey: secondKey), 0.54, accuracy: 0.000001)
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        try await host.waitUntilReady("The second WebKit document must finish restoring.")
        XCTAssertNotEqual(host.coordinator.documentID, oldDocument)
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
        try await host.waitUntilReady("The novel must be ready before auto-scrolling.")
        fixture.session.autoScrollSpeed = 4
        fixture.session.autoScroll = true
        host.coordinator.update(settings: MacReaderSettingsSnapshot(session: fixture.session))
        XCTAssertTrue(host.coordinator.isAutoScrolling)
        try await Task.sleep(for: .milliseconds(250))
        let moved = try await host.metrics()
        XCTAssertGreaterThan(moved.offset, 0, "The native timer must move the actual WebKit document.")
        _ = try await host.webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight);window.dispatchEvent(new Event('scroll'))")
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
            session.open(item: MangaLibraryItem(aniListId: 0, title: "Generated Novel Fixture", coverURL: nil, format: "NOVEL", totalChapters: nil, contentRating: ReaderContentRating.safe.rawValue), chapters: chapters, selected: chapters[0], engine: KanzenEngine()) { chapter, _ in [PageData(content: .novelDocument(try ReaderNovelDocument(bodyHTML: "<h1>\(chapter.chapterNumber)</h1>" + paragraphs)))] }
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
        private let previousApplication: NSRunningApplication?
        private weak var previousKeyWindow: NSWindow?

        init(session: MacReaderSession) {
            previousApplication = NSWorkspace.shared.frontmostApplication
            previousKeyWindow = NSApp.keyWindow
            coordinator = MacReaderNovelView.Coordinator(session: session)
            webView = coordinator.makeWebView(settings: MacReaderSettingsSnapshot(session: session))
            let size = CGSize(width: 900, height: 600)
            webView.frame = CGRect(origin: .zero, size: size)
            webView.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Eclipse Novel Reader Test"
            window.contentView = webView
            webView.layoutSubtreeIfNeeded()
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        }

        func waitUntilReady(_ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while ContinuousClock.now < deadline {
                if coordinator.isDocumentReady { return }
                if coordinator.session?.error != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let script = "({visibility:document.visibilityState,readyState:document.readyState,documentID:window.__eclipseNovelDocumentID||'',layout:window.__eclipseNovelLayoutGeneration||'',reader:!!window.__eclipseNovelReader,style:!!document.getElementById('eclipse-reader-style'),height:document.documentElement.scrollHeight,viewport:innerHeight})"
            let state = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: MacReaderNovelView.Coordinator.bridgeWorld)
            let native = "active=\(NSApp.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), occluded=\(!window.occlusionState.contains(.visible)), layoutPending=\(coordinator.styleRequestPending), error=\(coordinator.session?.error ?? "none")"
            XCTFail(message + " " + native + " WebKit=" + String(describing: state), file: file, line: line)
            throw FixtureFailure.timedOut
        }

        func metrics() async throws -> (offset: Double, height: Double, viewport: Double) {
            let result = try await webView.evaluateJavaScript("({offset:scrollY,height:document.documentElement.scrollHeight,viewport:innerHeight})")
            let values = try XCTUnwrap(result as? [String: Double])
            return (try XCTUnwrap(values["offset"]), try XCTUnwrap(values["height"]), try XCTUnwrap(values["viewport"]))
        }

        func locator() async throws -> ReaderNovelLocator {
            let value = try await webView.evaluateJavaScript("window.__eclipseNovelReader.locate()", in: nil, contentWorld: MacReaderNovelView.Coordinator.bridgeWorld)
            let bytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value))
            return try XCTUnwrap(ReaderNovelLocator.decode(bytes))
        }

        func postPosition(documentID: String, fraction: Double, layoutGeneration: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
            do {
                let layout = layoutGeneration ?? coordinator.layoutGeneration
                let result = try await webView.evaluateJavaScript("window.webkit.messageHandlers.readerPosition.postMessage({documentID:'\(documentID)',layoutGeneration:'\(layout)',fraction:\(fraction),completion:1});true;", in: nil, contentWorld: MacReaderNovelView.Coordinator.bridgeWorld)
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
            if let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKeyAndOrderFront(nil) }
            if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}
