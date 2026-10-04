import XCTest
import SwiftUI
import WebKit
@testable import Eclipse

@MainActor
final class ReaderNovelNavigationTests: XCTestCase {
    private var navigator: NavigationWaiter?
    private var documentWindow: UIWindow?
    private var previousWindow: UIWindow?

    override func tearDown() {
        documentWindow?.isHidden = true
        documentWindow?.rootViewController = nil
        documentWindow = nil
        previousWindow?.makeKeyAndVisible()
        previousWindow = nil
        navigator = nil
        super.tearDown()
    }

    func testPreferencesRejectStyleInjectionAndRetainExistingValues() {
        XCTAssertEqual(ReaderNovelPreferences.font("Charter"), "Charter")
        XCTAssertEqual(ReaderNovelPreferences.font("</style><script>bad()</script>"), "-apple-system")
        XCTAssertEqual(ReaderNovelPreferences.weight("700"), "700")
        XCTAssertEqual(ReaderNovelPreferences.alignment("justify"), "justify")
        XCTAssertEqual(ReaderNovelPreferences.alignment("left;position:fixed"), "left")
        XCTAssertEqual(ReaderNovelPreferences.fraction(.nan), 0)
        XCTAssertEqual(EclipseSettingsRegistry.scope(for: ReaderNovelPreferences.modeKey), .profile)
        let mode = try? PropertyListSerialization.data(fromPropertyList: "paged", format: .binary, options: 0)
        XCTAssertEqual(mode.flatMap { MediaStateSettingValueValidator.validatedValue(from: $0, forKey: ReaderNovelPreferences.modeKey) } as? String, "paged")
        XCTAssertNotNil(MediaStateSettingRegistry.scope(for: ReaderNovelPreferences.modeKey))
    }

    func testLocatorAndBookmarksRejectMalformedAndOversizedStores() throws {
        var value = ReaderNovelLocator(textIndex: 12, offset: 8, quote: "Text", fraction: 0.4)
        XCTAssertEqual(ReaderNovelLocator.decode(try JSONEncoder().encode(value)), value)
        value.offset = -1
        XCTAssertNil(ReaderNovelLocator.decode(try JSONEncoder().encode(value)))
        value.offset = 0
        value.quote = String(repeating: "a", count: 513)
        XCTAssertNil(ReaderNovelLocator.decode(try JSONEncoder().encode(value)))
        value.quote = "Text"
        let bookmark = ReaderNovelBookmark(id: UUID(), chapterKey: "chapter", chapterTitle: "Chapter I", locator: value)
        XCTAssertEqual(ReaderNovelBookmark.decode(try JSONEncoder().encode([bookmark, bookmark])).count, 1)
        XCTAssertTrue(ReaderNovelBookmark.decode(Data(repeating: 0, count: 512 * 1_024 + 1)).isEmpty)
    }

    func testLiteralSearchKeepsUnicodeOffsetsAndTreatsPatternsAsText() async throws {
        let webView = try await document("<p>İİX literal . [a] X</p><p>X</p>")
        let result = try await evaluate("window.__eclipseNovelReader.find('X',1)", in: webView) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 3)
        let selection = try await evaluate("getSelection().toString()", in: webView) as? String
        XCTAssertEqual(selection, "X")
        let dot = try await evaluate("window.__eclipseNovelReader.find('.',1)", in: webView) as? [String: Any]
        XCTAssertEqual(dot?["count"] as? Int, 1)
        let brackets = try await evaluate("window.__eclipseNovelReader.find('[a]',1)", in: webView) as? [String: Any]
        XCTAssertEqual(brackets?["count"] as? Int, 1)
        let last = try await evaluate("window.__eclipseNovelReader.find('X',-1)", in: webView) as? [String: Any]
        XCTAssertEqual(last?["index"] as? Int, 3)
    }

    func testSearchSpansInlineFormattingWithoutJoiningParagraphs() async throws {
        let webView = try await document("<p>She is <em>very</em> <strong>happy.</strong></p><p>Separate</p><p>paragraph.</p>")
        let result = try await evaluate("window.__eclipseNovelReader.find('very happy',1)", in: webView) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 1)
        let selected = try await evaluate("getSelection().toString()", in: webView) as? String
        XCTAssertEqual(selected, "very happy")
        let separate = try await evaluate("window.__eclipseNovelReader.find('Separateparagraph',1)", in: webView) as? [String: Any]
        XCTAssertEqual(separate?["count"] as? Int, 0)
    }

    func testTextAnchorQuoteDoesNotSplitEmojiAtBoundary() async throws {
        let text = String(repeating: "a", count: 127) + "😀 tail"
        let webView = try await document("<p>\(text)</p>")
        let value = try await evaluate("window.__eclipseNovelReader.locate()", in: webView) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value))
        let locator = try XCTUnwrap(ReaderNovelLocator.decode(data))
        XCTAssertEqual(locator.quote, String(repeating: "a", count: 127))
        _ = try await evaluate("document.body.style.fontSize='30px';window.__eclipseNovelReader.restore(\(ReaderNovelScripts.literal(locator)))", in: webView)
        let restored = try await evaluate("window.__eclipseNovelReader.locate()", in: webView) as? [String: Any]
        XCTAssertEqual(restored?["quote"] as? String, locator.quote)
    }

    func testTextAnchorSurvivesTypographyAndViewportChange() async throws {
        let body = (0..<80).map { "<p>Paragraph \($0). " + String(repeating: "Words in this paragraph. ", count: 12) + "</p>" }.joined()
        let webView = try await document(body)
        _ = try await evaluate("window.__eclipseNovelReader.seek(.55)", in: webView)
        let original = try await evaluate("window.__eclipseNovelReader.locate()", in: webView) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(original))
        let locator = try XCTUnwrap(ReaderNovelLocator.decode(data))
        _ = try await evaluateAsync("document.body.style.fontSize='30px';document.body.style.lineHeight='2.4';await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));window.__eclipseNovelReader.restore(\(ReaderNovelScripts.literal(locator)));await new Promise(resolve=>requestAnimationFrame(resolve))", in: webView)
        let resized = try await evaluate("window.__eclipseNovelReader.locate()", in: webView) as? [String: Any]
        XCTAssertEqual(resized?["quote"] as? String, locator.quote)
        webView.frame.size.width = 390
        _ = try await evaluateAsync("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));window.__eclipseNovelReader.restore(\(ReaderNovelScripts.literal(locator)));await new Promise(resolve=>requestAnimationFrame(resolve))", in: webView)
        let narrower = try await evaluate("window.__eclipseNovelReader.locate()", in: webView) as? [String: Any]
        XCTAssertEqual(narrower?["quote"] as? String, locator.quote)
    }

    func testTypographyChangesKeepDocumentIdentityAndStaleAuthorityBlocksCommands() throws {
        let suite = "ReaderNovelNavigationTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        func make(size: CGFloat, key: String, current: Bool) -> NovelHTMLView {
            NovelHTMLView(htmlContent: "<p>Text</p>", fontSize: size, fontFamily: "Charter", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.6, margin: 4, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Pure", "#ffffff", "#000000"), chapterKey: key, settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: NovelScrollRequest(percentage: 0.9), mutationIsCurrent: { current })
        }
        let first = make(size: 16, key: "one", current: true)
        let coordinator = first.makeCoordinator()
        coordinator.recordDocument(first)
        XCTAssertFalse(coordinator.documentHasChanged(make(size: 24, key: "one", current: true)))
        XCTAssertTrue(coordinator.settingsHaveChanged(make(size: 24, key: "one", current: true)))
        XCTAssertTrue(coordinator.documentHasChanged(make(size: 16, key: "two", current: true)))
        let view = WKWebView(frame: .zero)
        coordinator.webView = view
        coordinator.parent = make(size: 16, key: "one", current: false)
        var scripts = 0
        coordinator.scriptEvaluator = { _, _, _ in scripts += 1 }
        coordinator.applyScrollRequest(view)
        coordinator.startAutoScroll(view)
        XCTAssertEqual(scripts, 0)
        XCTAssertNil(coordinator.scrollTimer)
        coordinator.tearDown()
    }

    func testTypographyChangeRejectsMetricsQueuedBeforeCommittedLayout() throws {
        let suite = "ReaderNovelMetrics.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        var published: [Double] = []
        let view = NovelHTMLView(htmlContent: "<p>A long chapter</p>", fontSize: 18, fontFamily: "Georgia", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.6, margin: 4, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Warm", "#f9f1e4", "#4f321c"), chapterKey: "chapter", settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: nil, onProgressChanged: { published.append($0) })
        let coordinator = view.makeCoordinator()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: webView.frame)
        if let scene = previousWindow?.windowScene { window.windowScene = scene }
        let controller = UIViewController()
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        documentWindow = window
        coordinator.webView = webView
        coordinator.recordDocument(view)
        defer { coordinator.tearDown() }
        var reports: [(Any?, Error?) -> Void] = []
        var styleFinished: ((Any?, Error?) -> Void)?
        coordinator.scriptEvaluator = { script, _, completion in
            if script.contains("eclipse-reader-style") { styleFinished = completion }
            else if let completion { reports.append(completion) }
        }
        coordinator.updateProgress(webView)
        XCTAssertEqual(reports.count, 1)
        coordinator.applyStyle(webView)
        coordinator.updateProgress(webView)
        XCTAssertEqual(reports.count, 1)
        let stale: [String: Any] = ["progress": 0.99, "scrollPos": 0.99]
        reports[0](stale, nil)
        XCTAssertTrue(published.isEmpty)
        XCTAssertNil(store.object(forKey: "novelScrollPos_chapter"))
        try XCTUnwrap(styleFinished)(nil, nil)
        XCTAssertEqual(reports.count, 2)
        reports[1](["progress": 0.4, "scrollPos": 0.4], nil)
        reports[0](stale, nil)
        XCTAssertEqual(published, [0.4])
        XCTAssertEqual(store.double(forKey: "novelScrollPos_chapter"), 0.4)
    }

    func testIsolatedCanvasPaginatesAndKeepsAnchorDuringReflowAndChapterReplacement() async throws {
        let body = (0..<100).map { "<p id='paragraph-\($0)'>Paragraph \($0). " + String(repeating: "Words in this paragraph. ", count: 12) + "</p>" }.joined()
        let suite = "ReaderNovelCanvas.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        var view = NovelHTMLView(htmlContent: body, fontSize: 18, fontFamily: "Georgia", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.6, margin: 4, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Warm", "#f9f1e4", "#4f321c"), chapterKey: "first", settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: nil)
        let host = CanvasHost(view)
        defer { host.close() }
        try await wait { host.coordinator.isDocumentReady }
        _ = try await host.evaluate("window.__eclipseNovelReader.seek(.55)")
        let anchor = try await host.locator()
        view = NovelHTMLView(htmlContent: body, fontSize: 30, fontFamily: "Charter", fontWeight: "normal", textAlignment: "justify", lineSpacing: 2.4, margin: 16, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Warm", "#f9f1e4", "#4f321c"), chapterKey: "first", settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: nil)
        host.coordinator.parent = view
        host.coordinator.applyStyle(host.webView)
        try await wait { !host.coordinator.styleRequestPending }
        let reflowed = try await host.locator()
        XCTAssertEqual(reflowed.quote, anchor.quote)
        view.readingMode = .paged
        host.coordinator.parent = view
        host.coordinator.applyStyle(host.webView)
        try await wait { !host.coordinator.styleRequestPending }
        let metrics = try await host.evaluate("window.__eclipseNovelReader.report()") as? [String: Any]
        XCTAssertGreaterThan(metrics?["pages"] as? Int ?? 0, 2)
        let page = metrics?["page"] as? Int ?? 0
        _ = try await host.evaluate("window.__eclipseNovelReader.page(1)")
        let afterPage = try await host.evaluate("window.__eclipseNovelReader.report()") as? [String: Any]
        XCTAssertEqual(afterPage?["page"] as? Int, page + 1)
        let vertical = try await host.evaluate("window.scrollY") as? Double
        XCTAssertEqual(vertical ?? -1, 0, accuracy: 1)
        attach(host.window, name: "Novel canvas paged on current device")
        _ = try await host.evaluate("window.__eclipseNovelReader.seek(.9)")
        let saved = try await host.locator()
        store.set(try JSONEncoder().encode(saved), forKey: "novelLocator_v1_first")
        host.coordinator.beginDocumentReplacement()
        host.coordinator.recordDocument(view)
        host.coordinator.registerNavigation(host.webView.loadHTMLString(view.documentHTML, baseURL: nil))
        try await wait { host.coordinator.isDocumentReady }
        let restored = try await host.locator()
        XCTAssertEqual(restored.quote, saved.quote)
        let second = NovelHTMLView(htmlContent: body, fontSize: 18, fontFamily: "Georgia", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.6, margin: 4, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Pure", "#ffffff", "#000000"), chapterKey: "second", settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: nil)
        host.coordinator.parent = second
        host.coordinator.beginDocumentReplacement()
        host.coordinator.recordDocument(second)
        host.coordinator.registerNavigation(host.webView.loadHTMLString(second.documentHTML, baseURL: nil))
        try await wait { host.coordinator.isDocumentReady }
        let newPosition = try await host.locator()
        XCTAssertLessThan(newPosition.fraction, 0.02)
        XCTAssertEqual(newPosition.quote, "Paragraph 0. " + String(repeating: "Words in this paragraph. ", count: 12).prefix(115))
    }

    func testLiveIllustratedLocalEPUBInFullNovelReader() async throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_TEST_INSTALL_NOVELS"] == "1" else { throw XCTSkip("Persistent live simulator setup is opt-in") }
        let url = try XCTUnwrap(URL(string: "https://www.gutenberg.org/ebooks/11.epub3.images"))
        let source = ReaderExtensionSourceID(rawValue: String(repeating: "f", count: 64))
        let client = ReaderExtensionSecureHTTPClient(keychainNamespace: UUID().uuidString, emitsDomainConsentRequests: false)
        let response = try await client.requestEPUB(ReaderExtensionNetworkRequest(url: url, sourceID: source, approvedDomains: ["www.gutenberg.org", "gutenberg.org"], allowsCookies: false, redirectPolicy: .approvedDomainsOnly, maximumResponseBytes: ReaderExtensionEPUBBook.maximumArchiveBytes))
        XCTAssertEqual(response.statusCode, 200)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try response.body.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try await ReaderLocalEPUBLibrary.shared.importBook(from: file)
        let chapters = item.chapters(profileID: ProfileManager.shared.activeProfileID)
        let chapter = try XCTUnwrap(chapters.first { $0.chapterNumber.contains("CHAPTER I.") })
        let reader = NovelReaderView(kanzen: KanzenEngine(), chapters: chapters, initialChapter: chapter, mangaId: item.mangaID, mangaTitle: item.title, mangaCoverURL: "", mangaFormat: "NOVEL", totalChapters: chapters.count, latestChapterNumbers: item.chapterTitles)
        let controller = UIHostingController(rootView: reader)
        let window = UIWindow(frame: UIScreen.main.bounds)
        let previous = UIApplication.shared.windows.first(where: \.isKeyWindow)
        if let scene = previous?.windowScene { window.windowScene = scene }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await wait {
            guard let web = self.webView(in: controller.view), let coordinator = web.navigationDelegate as? NovelHTMLView.Coordinator else { return false }
            return coordinator.isDocumentReady
        }
        let web = try XCTUnwrap(webView(in: controller.view))
        let coordinator = try XCTUnwrap(web.navigationDelegate as? NovelHTMLView.Coordinator)
        let text: Any? = try await withCheckedThrowingContinuation { continuation in
            coordinator.evaluateReaderScript("document.body.innerText", in: web) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
        XCTAssertTrue((text as? String)?.contains("Alice was beginning") == true)
        let painted = try await snapshot(web)
        let attachment = XCTAttachment(image: painted)
        attachment.name = "Live Alice chapter in EPUB reader"
        attachment.lifetime = .keepAlways
        add(attachment)
        attach(window, name: "Live EPUB full novel reader controls")
        let native = try ReaderExtensionEPUBBook(data: response.body)
        let cover = try native.novelDocument(named: try XCTUnwrap(native.chapters.first).title)
        let suite = "ReaderNovelCover.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let coverView = NovelHTMLView(htmlContent: cover.bodyHTML, fontSize: 18, fontFamily: "Georgia", fontWeight: "normal", textAlignment: "left", lineSpacing: 1.6, margin: 4, isAutoScrolling: .constant(false), autoScrollSpeed: 1, colorPreset: ("Warm", "#f9f1e4", "#4f321c"), chapterKey: "cover", settingsStore: store, isolatesReaderExtensionHTML: true, scrollRequest: nil)
        let host = CanvasHost(coverView)
        defer { host.close() }
        try await wait { host.coordinator.isDocumentReady }
        var images: [[String: Any]] = []
        for _ in 0..<50 {
            images = try await host.evaluate("Array.from(document.images).map(i=>({complete:i.complete,width:i.naturalWidth,height:i.naturalHeight}))") as? [[String: Any]] ?? []
            if !images.isEmpty, images.allSatisfy({ $0["complete"] as? Bool == true && ($0["width"] as? Int ?? 0) > 0 }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(images.isEmpty)
        XCTAssertTrue(images.allSatisfy { $0["complete"] as? Bool == true && ($0["width"] as? Int ?? 0) > 0 })
        let coverAttachment = XCTAttachment(image: try await snapshot(host.webView))
        coverAttachment.name = "Live EPUB embedded cover"
        coverAttachment.lifetime = .keepAlways
        add(coverAttachment)
    }

    private func snapshot(_ webView: WKWebView) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ReaderExtensionError.resultInvalid("Reader snapshot unavailable")) }
            }
        }
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate())
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.compactMap { webView(in: $0) }.first
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private final class CanvasHost {
        let webView: WKWebView
        let coordinator: NovelHTMLView.Coordinator
        let window: UIWindow
        private let previous: UIWindow?

        init(_ parent: NovelHTMLView) {
            previous = UIApplication.shared.windows.first(where: \.isKeyWindow)
            window = UIWindow(frame: UIScreen.main.bounds)
            if let scene = previous?.windowScene { window.windowScene = scene }
            let controller = UIViewController()
            window.rootViewController = controller
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            webView = WKWebView(frame: window.bounds, configuration: configuration)
            controller.view.addSubview(webView)
            window.makeKeyAndVisible()
            coordinator = parent.makeCoordinator()
            coordinator.webView = webView
            webView.navigationDelegate = coordinator
            coordinator.recordDocument(parent)
            coordinator.registerNavigation(webView.loadHTMLString(parent.documentHTML, baseURL: nil))
        }

        func evaluate(_ script: String) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.evaluateReaderScript(script, in: webView) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
        }

        func locator() async throws -> ReaderNovelLocator {
            let value = try await evaluate("window.__eclipseNovelReader.locate()")
            let dictionary = try XCTUnwrap(value as? [String: Any])
            return try XCTUnwrap(ReaderNovelLocator.decode(JSONSerialization.data(withJSONObject: dictionary)))
        }

        func close() {
            coordinator.tearDown()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    private func document(_ body: String) async throws -> WKWebView {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        let webView = WKWebView(frame: frame)
        previousWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: frame)
        if let scene = previousWindow?.windowScene { window.windowScene = scene }
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        documentWindow = window
        let loaded = expectation(description: "Novel document loaded")
        let waiter = NavigationWaiter(loaded: loaded)
        navigator = waiter
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{font-size:18px;line-height:1.6;padding:64px 20px}p{margin-bottom:24px}</style></head><body>\(body)</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await evaluate(ReaderNovelScripts.install, in: webView)
        return webView
    }

    private func evaluateAsync(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) { loaded.fulfill() }
    }
}
