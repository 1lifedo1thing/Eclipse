import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import EclipseMac

@MainActor
final class MacReaderViewportTests: XCTestCase {
    func testLargeChapterPreservesSourceAndFractionWhenResizedAndMagnified() async throws {
        try requireAvailableReader()
        let fixtures = try [
            image(width: 600, height: 5400, seed: 1),
            image(width: 600, height: 900, seed: 2),
            image(width: 900, height: 450, seed: 3),
            image(width: 512, height: 512, seed: 4)
        ]
        let pages = (0..<240).map { PageData(content: .imageData(fixtures[$0 % fixtures.count])) }
        let session = try await open(pages: pages)
        defer { session.close() }
        let host = try ViewportHost(session: session, size: CGSize(width: 700, height: 600))
        defer { host.close() }
        let scroll = try await scrollView(in: host)
        let coordinator = try XCTUnwrap(scroll.readerCoordinator)
        try await wait("The initial page must decode through the native image pipeline.", host: host) { coordinator.images[0] != nil }
        XCTAssertEqual(Set(coordinator.display.map(\.source)), Set(0..<240))
        XCTAssertNil(session.reader?.mangaRoute)
        XCTAssertEqual(session.reader?.mangaId, 0)
        XCTAssertNil(session.offlineLease)

        coordinator.scrollToSource(120)
        try await wait("Page 120 and its surrounding pages must settle after decoding.", host: host) {
            coordinator.images[120] != nil && session.page == 120 && self.visibleSources(scroll: scroll, coordinator: coordinator).allSatisfy { coordinator.images[$0] != nil }
        }
        try await settle(host)
        let page = try XCTUnwrap(coordinator.display.first { $0.source == 120 })
        let decoded = try XCTUnwrap(coordinator.images[120])
        XCTAssertEqual(page.frame.width / page.frame.height, CGFloat(decoded.width) / CGFloat(decoded.height), accuracy: 0.002)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: page.frame.minY + page.frame.height * 0.31))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.viewportChanged()
        try await settle(host)
        let beforeResize = try anchor(scroll: scroll, coordinator: coordinator)
        XCTAssertEqual(beforeResize.source, 120)
        XCTAssertEqual(beforeResize.fraction, 0.31, accuracy: 0.003)

        host.resize(to: CGSize(width: 1200, height: 800))
        try await settle(host)
        XCTAssertEqual(scroll.contentSize.width, 1200, accuracy: 20)
        XCTAssertEqual(scroll.contentSize.height, 800, accuracy: 20)
        let afterResize = try anchor(scroll: scroll, coordinator: coordinator)
        XCTAssertEqual(afterResize.source, beforeResize.source)
        XCTAssertEqual(afterResize.fraction, beforeResize.fraction, accuracy: 0.003)

        for zoom: CGFloat in [1.5, 2, 5, 1] {
            let bounds = scroll.contentView.bounds
            let beforeZoom = try anchor(scroll: scroll, coordinator: coordinator, atY: bounds.midY)
            scroll.setMagnification(zoom, centeredAt: CGPoint(x: bounds.midX, y: bounds.midY))
            coordinator.viewportChanged()
            try await settle(host)
            let afterZoom = try anchor(scroll: scroll, coordinator: coordinator, atY: scroll.contentView.bounds.midY)
            XCTAssertEqual(scroll.magnification, zoom, accuracy: 0.001)
            XCTAssertEqual(afterZoom.source, beforeZoom.source)
            XCTAssertEqual(afterZoom.fraction, beforeZoom.fraction, accuracy: 0.01)
            assertFiniteGeometry(scroll: scroll, coordinator: coordinator)
            XCTAssertLessThanOrEqual(coordinator.images.count, 32)
            XCTAssertTrue(coordinator.errors.isEmpty)
        }
        XCTAssertNil(coordinator.images[0], "Pages far outside the viewport must be evicted from the renderer.")
        XCTAssertNotNil(coordinator.images[120])
        XCTAssertLessThan(coordinator.images.count, pages.count)
        try assertVisibleImageDraws(scroll: scroll, coordinator: coordinator)
    }

    func testChapterReplacementClearsFailedPageAndRendersNewLocalImage() async throws {
        try requireAvailableReader()
        let valid = try image(width: 640, height: 1600, seed: 8)
        let chapters = [Chapter(chapterNumber: "1", idx: 0, chapterData: nil), Chapter(chapterNumber: "2", idx: 1, chapterData: nil)]
        let session = MacReaderSession()
        defer { session.close() }
        session.open(item: fixtureItem(), chapters: chapters, selected: chapters[0], engine: KanzenEngine()) { chapter, _ in
            [PageData(content: .imageData(chapter.chapterNumber == "1" ? Data([0, 1, 2, 3]) : valid))]
        }
        try await wait("The synthetic chapter must load.") { !session.isLoading && session.pages.count == 1 }
        session.reader?.mode = .webtoon
        let host = try ViewportHost(session: session, size: CGSize(width: 700, height: 600))
        defer { host.close() }
        let scroll = try await scrollView(in: host)
        let coordinator = try XCTUnwrap(scroll.readerCoordinator)
        try await wait("A corrupt page must expose a retryable page error.", host: host) { coordinator.errors[0] != nil }
        XCTAssertNil(coordinator.images[0])
        session.select(chapters[1])
        try await wait("Replacing the chapter must clear its old failure and display the new image.", host: host) {
            session.reader?.selectedChapter.chapterNumber == "2" && coordinator.images[0] != nil && coordinator.errors.isEmpty
        }
        let rendered = try XCTUnwrap(coordinator.images[0])
        XCTAssertEqual(CGFloat(rendered.width) / CGFloat(rendered.height), 0.4, accuracy: 0.002)
        XCTAssertEqual(coordinator.display.map(\.source), [0])
        assertFiniteGeometry(scroll: scroll, coordinator: coordinator)
        try assertVisibleImageDraws(scroll: scroll, coordinator: coordinator)
    }

    func testClosingViewportDiscardsInFlightDecodeAndPositionPublication() async throws {
        try requireAvailableReader()
        let data = try image(width: 768, height: 8192, seed: 15)
        let session = try await open(pages: (0..<240).map { _ in PageData(content: .imageData(data)) })
        defer { session.close() }
        let host = try ViewportHost(session: session, size: CGSize(width: 700, height: 600))
        defer { host.close() }
        let scroll = try await scrollView(in: host)
        let coordinator = try XCTUnwrap(scroll.readerCoordinator)
        coordinator.scrollToSource(120)
        let pageBeforeClose = session.page
        coordinator.close()
        host.close()
        XCTAssertNil(scroll.readerCoordinator)
        XCTAssertNil(coordinator.canvas?.coordinator)
        XCTAssertTrue(coordinator.images.isEmpty)
        XCTAssertNil(coordinator.observer)
        _ = try await MacReaderImagePipeline.shared.image(page: PageData(content: .imageData(data)), request: nil, settings: MacReaderSettingsSnapshot(session: session), width: 900, scope: session.owner, storageLocation: nil)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(coordinator.images.isEmpty, "A decode that finishes after teardown must not repopulate the old canvas.")
        XCTAssertEqual(session.page, pageBeforeClose, "A queued position update must not publish after teardown.")
        XCTAssertNil(scroll.readerCoordinator)
    }

    func testRetryWorksWithContextMenusDisabledAndRejectsReplacedChapterCommand() async throws {
        try requireAvailableReader()
        let suite = "EclipseMac.ReaderRetry." + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: "Reader.disableQuickActions")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try Data([0, 1, 2, 3]).write(to: first)
        try Data([4, 5, 6, 7]).write(to: second)
        let chapters = [Chapter(chapterNumber: "1", idx: 0, chapterData: nil), Chapter(chapterNumber: "2", idx: 1, chapterData: nil)]
        let session = MacReaderSession(settingsStore: store)
        defer { session.close() }
        session.open(item: fixtureItem(), chapters: chapters, selected: chapters[0], engine: KanzenEngine()) { chapter, _ in
            [PageData(content: .url((chapter.chapterNumber == "1" ? first : second).absoluteString))]
        }
        try await wait("The local retry fixture must load.") { !session.isLoading && session.pages.count == 1 }
        session.reader?.mode = .webtoon
        let host = try ViewportHost(session: session, size: CGSize(width: 700, height: 600))
        defer { host.close() }
        let scroll = try await scrollView(in: host)
        let coordinator = try XCTUnwrap(scroll.readerCoordinator)
        try await wait("The first local page must expose its decode failure.", host: host) { coordinator.errors[0] != nil }
        let frame = try XCTUnwrap(coordinator.display.first?.frame)
        XCTAssertNil(coordinator.menu(at: CGPoint(x: frame.midX, y: frame.midY)))
        try image(width: 600, height: 1600, seed: 4).write(to: first, options: .atomic)
        session.requestPageRetry()
        try await wait("The visible retry command must reload the repaired local image without a context menu.", host: host) { coordinator.images[0] != nil && coordinator.errors.isEmpty }
        let stale = MacReaderRetryPageCommand(page: 0, contentGeneration: session.contentGeneration)
        session.select(chapters[1])
        try await wait("The replacement chapter must expose its own failure.", host: host) { session.reader?.selectedChapter.chapterNumber == "2" && coordinator.errors[0] != nil }
        session.retryPageCommand = stale
        coordinator.update(settings: MacReaderSettingsSnapshot(session: session))
        XCTAssertNotNil(coordinator.errors[0], "A retry captured for the old chapter must not clear the replacement chapter's error.")
        XCTAssertNil(coordinator.images[0])
    }

    private func requireAvailableReader() throws {
        if MacLaunchProfileAccess.requiresUnlock || MacLaunchProfileAccess.isTerminating || !ProfileManager.shared.rosterStoreIsReadable {
            throw XCTSkip("The existing profile is locked, terminating, or unreadable; viewport tests preserve that state.")
        }
    }

    func testFocusedImageZoomAndRTLKeysPreserveAnchorAndLeaveTextEditingAlone() async throws {
        try requireAvailableReader()
        let suite = "EclipseMac.ReaderKeyboard." + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set("single", forKey: "Reader.pagedPageLayout")
        let data = try image(width: 600, height: 1800, seed: 7)
        let session = MacReaderSession(settingsStore: store)
        defer { session.close() }
        let chapter = Chapter(chapterNumber: "1", idx: 0, chapterData: nil)
        session.open(item: fixtureItem(), chapters: [chapter], selected: chapter, engine: KanzenEngine()) { _, _ in (0..<4).map { _ in PageData(content: .imageData(data)) } }
        try await wait("The generated keyboard fixture must load.") { !session.isLoading && session.pages.count == 4 }
        session.reader?.mode = .rtl
        let host = try ViewportHost(session: session, size: CGSize(width: 700, height: 600))
        defer { host.close() }
        let scroll = try await scrollView(in: host)
        let coordinator = try XCTUnwrap(scroll.readerCoordinator)
        let canvas = try XCTUnwrap(coordinator.canvas)
        coordinator.scrollToSource(1)
        try await wait("The selected image must be ready for real keyboard zoom.", host: host) { coordinator.images[1] != nil && session.page == 1 }
        XCTAssertTrue(host.window.makeFirstResponder(canvas))
        let before = try anchor(scroll: scroll, coordinator: coordinator, atY: scroll.contentView.bounds.midY)
        let plus = try keyEvent(code: 24, text: "=", modifiers: .command, window: host.window)
        canvas.keyDown(with: plus)
        try await settle(host)
        XCTAssertEqual(scroll.magnification, 1.25, accuracy: 0.001)
        let after = try anchor(scroll: scroll, coordinator: coordinator, atY: scroll.contentView.bounds.midY)
        XCTAssertEqual(after.source, before.source)
        XCTAssertEqual(after.fraction, before.fraction, accuracy: 0.01)
        for _ in 0..<20 { canvas.keyDown(with: plus) }
        XCTAssertEqual(scroll.magnification, 5, accuracy: 0.001)
        canvas.keyDown(with: try keyEvent(code: 29, text: "0", modifiers: .command, window: host.window))
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        canvas.keyDown(with: try keyEvent(code: 124, text: "", modifiers: [], window: host.window))
        try await wait("Right Arrow must move backward in RTL mode.", host: host) { session.page == 0 }
        canvas.keyDown(with: try keyEvent(code: 123, text: "", modifiers: [], window: host.window))
        try await wait("Left Arrow must move forward in RTL mode.", host: host) { session.page == 1 }
        let editor = NSTextField(frame: CGRect(x: 10, y: 10, width: 180, height: 24))
        host.hosting.addSubview(editor)
        defer { editor.removeFromSuperview() }
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        XCTAssertFalse(coordinator.key(plus), "A field editor must retain its keyboard shortcuts.")
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
    }

    private func keyEvent(code: UInt16, text: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private func fixtureItem() -> MangaLibraryItem {
        MangaLibraryItem(aniListId: 0, title: "Generated Geometry Fixture", coverURL: nil, format: "MANGA", totalChapters: nil, contentRating: ReaderContentRating.safe.rawValue)
    }

    private func open(pages: [PageData]) async throws -> MacReaderSession {
        let session = MacReaderSession()
        let chapter = Chapter(chapterNumber: "1", idx: 0, chapterData: nil)
        session.open(item: fixtureItem(), chapters: [chapter], selected: chapter, engine: KanzenEngine()) { _, _ in pages }
        do {
            try await wait("The generated chapter must enter the actual Reader session.") { !session.isLoading && session.pages.count == pages.count }
            session.reader?.mode = .webtoon
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private func image(width: Int, height: Int, seed: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 32) {
            for x in stride(from: 0, to: width, by: 32) {
                let alternate = ((x / 32) + (y / 32) + seed) % 2 == 0
                context.setFillColor(CGColor(red: alternate ? 0.8 : 0.15, green: alternate ? 0.2 : 0.7, blue: CGFloat(seed % 5 + 2) / 8, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 32, height: 32))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func scrollView(in host: ViewportHost) async throws -> MacReaderScrollView {
        try await wait("NSHostingView must mount the real AppKit Reader viewport.", host: host) { self.findScroll(in: host.hosting) != nil }
        return try XCTUnwrap(findScroll(in: host.hosting))
    }

    private func findScroll(in view: NSView) -> MacReaderScrollView? {
        if let scroll = view as? MacReaderScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
        return nil
    }

    private func visibleSources(scroll: MacReaderScrollView, coordinator: MacReaderImageViewport.Coordinator) -> Set<Int> {
        Set(coordinator.display.filter { $0.frame.intersects(scroll.contentView.bounds) }.map(\.source))
    }

    private func anchor(scroll: MacReaderScrollView, coordinator: MacReaderImageViewport.Coordinator, atY: CGFloat? = nil) throws -> (source: Int, fraction: CGFloat) {
        let y = atY ?? scroll.contentView.bounds.minY
        let page = try XCTUnwrap(coordinator.display.first { $0.frame.minY <= y && $0.frame.maxY > y })
        return (page.source, (y - page.frame.minY) / page.frame.height)
    }

    private func assertFiniteGeometry(scroll: MacReaderScrollView, coordinator: MacReaderImageViewport.Coordinator, file: StaticString = #filePath, line: UInt = #line) {
        let canvas = coordinator.canvas?.frame ?? .null
        XCTAssertTrue(canvas.width.isFinite && canvas.height.isFinite && canvas.width > 0 && canvas.height > 0, file: file, line: line)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.maxY, canvas.maxY + 1, file: file, line: line)
        for page in coordinator.display {
            XCTAssertTrue(page.frame.minX.isFinite && page.frame.minY.isFinite && page.frame.width.isFinite && page.frame.height.isFinite, file: file, line: line)
            XCTAssertGreaterThan(page.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(page.frame.height, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(page.frame.maxY, canvas.maxY, file: file, line: line)
        }
    }

    private func assertVisibleImageDraws(scroll: MacReaderScrollView, coordinator: MacReaderImageViewport.Coordinator) throws {
        let canvas = try XCTUnwrap(coordinator.canvas)
        let visible = scroll.contentView.bounds
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: visible))
        canvas.cacheDisplay(in: visible, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        var colored = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 10)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 10)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), abs(color.redComponent - color.greenComponent) > 0.1 { colored += 1 }
            }
        }
        XCTAssertGreaterThan(colored, 0, "The actual canvas must draw the generated colored image, beyond a loading label or background.")
    }

    private func wait(_ message: String, host: ViewportHost? = nil, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            host?.hosting.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw ViewportFailure.timedOut
    }

    private func settle(_ host: ViewportHost) async throws {
        for _ in 0..<8 {
            host.hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum ViewportFailure: Error { case timedOut }

    @MainActor
    private final class ViewportHost {
        let window: NSWindow
        let hosting: NSHostingView<MacReaderImageViewport>

        init(session: MacReaderSession, size: CGSize) throws {
            let settings = MacReaderSettingsSnapshot(session: session)
            if settings.upscale { throw XCTSkip("The existing profile has enabled an imported upscaler; geometry tests preserve that model and its settings.") }
            hosting = NSHostingView(rootView: MacReaderImageViewport(session: session, settings: settings))
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
        }

        func resize(to size: CGSize) {
            window.setContentSize(size)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
