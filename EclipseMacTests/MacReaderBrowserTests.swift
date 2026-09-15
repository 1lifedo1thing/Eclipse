import AppKit
import Security
import WebKit
import XCTest
@testable import EclipseMac

@MainActor
final class MacReaderBrowserTests: XCTestCase {
    func testDetachedSignInIgnoresDelayedCookieMessagesAndKeepsCommittedCookies() async throws {
        guard MacDownloadStorageAuthority.capture() != nil else { throw XCTSkip("The existing profile cannot admit sign-in; the fixture preserves its state.") }
        let session = try makeSession()
        var writes: [String] = []
        var errors: [String] = []
        let coordinator = ReaderExtensionSignInWebView.Coordinator(session: session, reportError: { errors.append($0) }, cookieWriter: { cookie, _ in writes.append(cookie); return [:] })
        let host = try BrowserHost(session: session, coordinator: coordinator)
        defer { host.close() }
        try await wait("The local sign-in fixture must load through WebKit's custom scheme.") { host.handler.finished }
        try await host.waitUntilReady()
        _ = try await evaluate(host.webView, "window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({cookie:'fixture=committed; Path=/'});true;")
        try await wait("A live cookie message must reach the captured writer.") { writes.count == 1 }
        _ = try await evaluate(host.webView, "window.fixtureDelayed=false;setTimeout(()=>{window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({cookie:'fixture=late; Path=/'});window.fixtureDelayed=true},80);")
        coordinator.detach()
        try await Task.sleep(for: .milliseconds(300))
        let fired = try await evaluate(host.webView, "window.fixtureDelayed") as? Bool
        XCTAssertEqual(fired, true, "The delayed WebKit callback must actually run after detachment.")
        XCTAssertEqual(writes, ["fixture=committed; Path=/"])
        XCTAssertTrue(errors.isEmpty)
    }

    func testForeignWebViewCannotUseAnotherSignInCoordinatorsCookieWriter() async throws {
        guard MacDownloadStorageAuthority.capture() != nil else { throw XCTSkip("The existing profile cannot admit sign-in; the fixture preserves its state.") }
        let session = try makeSession()
        var writes: [String] = []
        let coordinator = ReaderExtensionSignInWebView.Coordinator(session: session, reportError: { _ in }, cookieWriter: { cookie, _ in writes.append(cookie); return [:] })
        let attached = try BrowserHost(session: session, coordinator: coordinator)
        defer { attached.close() }
        try await attached.waitUntilReady()
        let foreign = try BrowserHost(session: session, coordinator: coordinator, attachesCoordinator: false)
        defer { foreign.close() }
        try await foreign.waitUntilReady()
        _ = try await evaluate(foreign.webView, "window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({cookie:'fixture=foreign; Path=/'});true;")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(writes.isEmpty)
        _ = try await evaluate(attached.webView, "window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({cookie:'fixture=owned; Path=/'});true;")
        try await wait("The attached browser must retain its own writer.") { writes.count == 1 }
        XCTAssertEqual(writes, ["fixture=owned; Path=/"])
    }

    private func evaluate(_ webView: WKWebView, _ script: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
        } catch {
            let failure = error as NSError
            XCTFail("WebKit evaluation failed: \(failure.domain) code=\(failure.code), \(failure.localizedDescription)", file: file, line: line)
            throw error
        }
    }

    private func makeSession() throws -> ReaderExtensionSignInSession {
        let base = try XCTUnwrap(URL(string: "https://reader.example/"))
        let repository = base.appendingPathComponent("index.json")
        let catalog = ReaderExtensionCatalogSource(id: ReaderExtensionSourceID(repositoryURL: repository, upstreamID: "native-browser-fixture", language: "en", mediaType: .manga), upstreamID: "native-browser-fixture", repositoryID: ReaderExtensionRepositoryRecord(indexURL: repository).id, repositoryURL: repository, name: "Local Browser Fixture", baseURL: base, apiURL: nil, language: "en", mediaType: .manga, implementation: .javascript, sourceCodeURL: base.appendingPathComponent("source.js"), version: "1.0.0", maturity: .safe, hasCloudflare: false, dateFormat: nil, dateFormatLocale: nil, additionalParameters: nil, notes: nil, license: ReaderExtensionLicense(kind: .mit, name: "MIT", url: nil, textSHA256: nil, detectedAt: Date(timeIntervalSince1970: 0)))
        let source = ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
        let namespace = "EclipseMac.BrowserFixture." + UUID().uuidString
        return ReaderExtensionSignInSession(sourceID: source.id, sourceName: source.name, startURL: base, approvedDomains: ["reader.example"], auxiliaryDomains: [], baseDomain: base.host, isBrowserVerification: false, mutationScope: ReaderExtensionManagerMutationScope(scopeID: namespace, authenticationNamespace: namespace, authenticationNamespaceGeneration: 0), securityRevision: .init(source: source), network: ReaderExtensionSecureHTTPClient(keychainNamespace: namespace, emitsDomainConsentRequests: false), authenticationStore: ReaderExtensionKeychainStore(sourceID: source.id, namespace: namespace, keychain: UnusedKeychain()))
    }

    private func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw BrowserFailure.timedOut
    }

    private enum BrowserFailure: Error { case timedOut }

    private struct UnusedKeychain: ReaderExtensionKeychainAccess {
        func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus { XCTFail("The browser fixture must not read a Keychain."); return errSecItemNotFound }
        func delete(_ query: [String: Any]) -> OSStatus { XCTFail("The browser fixture must not delete Keychain values."); return errSecItemNotFound }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { XCTFail("The browser fixture must not update Keychain values."); return errSecItemNotFound }
        func add(_ attributes: [String: Any]) -> OSStatus { XCTFail("The browser fixture must not add Keychain values."); return errSecItemNotFound }
    }

    @MainActor
    private final class BrowserHost {
        let window: NSWindow
        let webView: WKWebView
        let handler = LocalHTMLHandler()
        let coordinator: ReaderExtensionSignInWebView.Coordinator
        private let attachesCoordinator: Bool

        init(session: ReaderExtensionSignInSession, coordinator: ReaderExtensionSignInWebView.Coordinator, attachesCoordinator: Bool = true) throws {
            self.coordinator = coordinator
            self.attachesCoordinator = attachesCoordinator
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(handler, forURLScheme: ReaderExtensionSignInURLProxy.secureScheme)
            configuration.userContentController.add(coordinator, name: ReaderExtensionSignInWebView.Coordinator.cookieMessageName)
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            if attachesCoordinator { coordinator.attach(webView); webView.navigationDelegate = coordinator }
            webView.load(URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(for: session.startURL)))
        }

        func waitUntilReady() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if handler.finished, let ready = try? await webView.evaluateJavaScript("document.body && document.body.textContent.includes('Local browser fixture')", in: nil, contentWorld: .page), ready as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The generated HTML document must reach the real WebKit page.")
            throw BrowserFailure.timedOut
        }

        func close() {
            if attachesCoordinator { coordinator.detach() }
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: ReaderExtensionSignInWebView.Coordinator.cookieMessageName)
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private final class LocalHTMLHandler: NSObject, WKURLSchemeHandler {
        private(set) var finished = false
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"]) else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data("<!doctype html><html><body>Local browser fixture</body></html>".utf8))
            urlSchemeTask.didFinish()
            finished = true
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }
}
