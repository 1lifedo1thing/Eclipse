#if os(macOS)
import AppKit
import SwiftUI
import WebKit

struct MacReaderNovelView: NSViewRepresentable {
    @ObservedObject var session: MacReaderSession
    let settings: MacReaderSettingsSnapshot
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView(settings: settings) }
    func updateNSView(_ webView: WKWebView, context: Context) { context.coordinator.update(settings: settings) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.close()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readerPosition", contentWorld: Coordinator.bridgeWorld)
        webView.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeWorld = WKContentWorld.world(name: "app.eclipse.reader-extension-progress")
        weak var webView: WKWebView?
        weak var session: MacReaderSession?
        private(set) var documentID = UUID().uuidString
        private(set) var isDocumentReady = false
        private weak var documentReader: KanzenReaderSession?
        private weak var documentWindow: NSWindow?
        private var chapterID: UUID?
        private var pageIDs: [String] = []
        private var positionKey = ""
        private var positionStore: UserDefaults?
        private var owner: UUID
        private var sessionGeneration: UUID?
        private var serviceGeneration = ServiceStoreScope.generation
        private var lastSettings: MacReaderSettingsSnapshot?
        private var timer: Timer?
        private var closed = false
        private var expectedNavigation: WKNavigation?
        private var restorationTask: Task<Void, Never>?
        private var autoScrollRequestPending = false
        private var lastPositionCommandID: UUID?
        private var observers: [NSObjectProtocol] = []
        var isAutoScrolling: Bool { timer?.isValid == true }

        init(session: MacReaderSession) {
            self.session = session
            owner = session.owner
            super.init()
            observers = [Notification.Name.activeProfileDidChange, ServiceStoreScope.didChangeNotification, .macMainWindowClosed].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.suspendAutoScroll() } })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { if let self, let window = notification.object as? NSWindow, window === self.webView?.window { self.suspendAutoScroll() } }
            })
        }

        deinit { restorationTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

        func makeWebView(settings: MacReaderSettingsSnapshot) -> MacReaderNovelWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.add(self, contentWorld: Self.bridgeWorld, name: "readerPosition")
            let view = MacReaderNovelWebView(frame: .zero, configuration: configuration)
            view.readerSession = session
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            webView = view
            update(settings: settings)
            return view
        }

        func update(settings: MacReaderSettingsSnapshot) {
            guard !closed, let session, !session.isLoading, let reader = session.reader, let webView else { return }
            let currentPageIDs = session.pages.map(\.id)
            if documentReader !== reader || chapterID != reader.selectedChapter.id || pageIDs != currentPageIDs {
                restorationTask?.cancel()
                restorationTask = nil
                stopAutoScroll()
                webView.stopLoading()
                documentReader = reader
                chapterID = reader.selectedChapter.id
                pageIDs = currentPageIDs
                positionKey = MacReaderNovelPosition.storageKey(route: reader.mangaRoute, mangaID: reader.mangaId, chapter: reader.selectedChapter)
                positionStore = session.settingsStore
                owner = session.owner
                sessionGeneration = session.contentGeneration
                serviceGeneration = ServiceStoreScope.generation
                documentWindow = webView.window
                documentID = UUID().uuidString
                isDocumentReady = false
                let raw = session.pages.compactMap(\.text).joined(separator: "\n\n")
                do {
                    let body: String
                    if raw.range(of: "<\\s*/?\\s*[A-Za-z][^>]*>", options: .regularExpression) != nil, let base = URL(string: "https://reader.invalid") { body = try ReaderExtensionNovelSanitizer.sanitize(raw, baseURL: base, approvedDomains: []) }
                    else { body = "<div style='white-space:pre-wrap'>\(Self.escape(raw))</div>" }
                    let document = try ReaderExtensionNovelSanitizer.isolatedDocument(bodyHTML: body)
                    webView.configuration.userContentController.removeAllUserScripts()
                    webView.configuration.userContentController.addUserScript(WKUserScript(source: Self.positionScript(documentID), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.bridgeWorld))
                    lastSettings = settings
                    expectedNavigation = webView.loadHTMLString(document, baseURL: nil)
                } catch { session.error = error.localizedDescription }
            } else if lastSettings != settings {
                lastSettings = settings
                if isDocumentReady { applyStyle(settings) }
            }
            updateAutoScroll()
            applyPositionCommand()
        }

        func close() {
            closed = true
            isDocumentReady = false
            restorationTask?.cancel()
            restorationTask = nil
            expectedNavigation = nil
            stopAutoScroll()
        }

        private func isCurrentDocument(_ id: String) -> Bool {
            guard !closed, id == documentID, let reader = documentReader, let session,
                  session.reader === reader, !session.isLoading, session.owner == owner,
                  reader.selectedChapter.id == chapterID, session.pages.map(\.id) == pageIDs,
                  session.contentGeneration == sessionGeneration,
                  ServiceStoreScope.isCurrent(serviceGeneration), !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating else { return false }
            if let documentWindow, webView?.window !== documentWindow { return false }
            return true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard self.webView === webView, let navigation, navigation === expectedNavigation,
                  isCurrentDocument(documentID), let settings = lastSettings else { return }
            documentWindow = webView.window
            let id = documentID
            let fraction = MacReaderNovelPosition.finiteFraction(positionStore?.double(forKey: positionKey) ?? 0)
            guard let style = Self.styleScript(settings) else { return }
            restorationTask?.cancel()
            restorationTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let script = "(()=>{if(window.__eclipseNovelDocumentID !== '\(id)')return null;\(style);window.scrollTo(0, \(fraction) * document.documentElement.scrollHeight);return {fraction:scrollY/document.documentElement.scrollHeight,completion:(scrollY+innerHeight)/document.documentElement.scrollHeight}})()"
                    let result = try await webView.evaluateJavaScript(script, in: nil, contentWorld: Self.bridgeWorld)
                    try Task.checkCancellation()
                    guard self.isCurrentDocument(id), let metrics = result as? [String: Any] else { return }
                    self.isDocumentReady = true
                    self.acceptPosition(metrics, documentID: id)
                    if let latest = self.lastSettings, latest != settings { self.applyStyle(latest) }
                    self.updateAutoScroll()
                    self.applyPositionCommand()
                } catch { if !Task.isCancelled, self.isCurrentDocument(id) { self.session?.error = error.localizedDescription } }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(!closed && navigationAction.navigationType == .other && url?.scheme == "about" && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) { reportNavigationFailure(webView, navigation: navigation, error: error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) { reportNavigationFailure(webView, navigation: navigation, error: error) }

        private func reportNavigationFailure(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
            guard self.webView === webView, let navigation, navigation === expectedNavigation,
                  isCurrentDocument(documentID), (error as? URLError)?.code != .cancelled else { return }
            session?.error = error.localizedDescription
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "readerPosition", message.frameInfo.isMainFrame, message.webView === webView,
                  let body = message.body as? [String: Any], let id = body["documentID"] as? String else { return }
            acceptPosition(body, documentID: id)
        }

        private func acceptPosition(_ body: [String: Any], documentID: String) {
            guard isDocumentReady, isCurrentDocument(documentID), let fraction = body["fraction"] as? Double,
                  let completion = body["completion"] as? Double, fraction.isFinite, completion.isFinite else { return }
            positionStore?.set(MacReaderNovelPosition.finiteFraction(fraction), forKey: positionKey)
            session?.positionChanged(page: 0, completion: MacReaderNovelPosition.finiteFraction(completion))
        }

        private func stopAutoScroll() { timer?.invalidate(); timer = nil; autoScrollRequestPending = false }
        private func suspendAutoScroll() { stopAutoScroll(); session?.autoScroll = false }

        private func updateAutoScroll() {
            guard isDocumentReady, isCurrentDocument(documentID), session?.autoScroll == true else { stopAutoScroll(); return }
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.autoScrollTick() } }
        }

        private func autoScrollTick() {
            guard isDocumentReady, isCurrentDocument(documentID), let session, session.autoScroll, let webView else { stopAutoScroll(); return }
            guard !autoScrollRequestPending else { return }
            let id = documentID
            let amount = session.autoScrollSpeed.isFinite ? min(max(session.autoScrollSpeed, 0.25), 4) * 2 : 2
            autoScrollRequestPending = true
            webView.evaluateJavaScript("(()=>{if(window.__eclipseNovelDocumentID !== '\(id)')return null;window.scrollBy(0, \(amount));return scrollY+innerHeight >= document.documentElement.scrollHeight-1})()", in: nil, in: Self.bridgeWorld) { [weak self] result in
                guard let self, self.isCurrentDocument(id) else { return }
                self.autoScrollRequestPending = false
                if case .success(let value) = result, value as? Bool == true { self.suspendAutoScroll() }
                else if case .failure = result { self.suspendAutoScroll() }
            }
        }

        private func applyPositionCommand() {
            guard isDocumentReady, isCurrentDocument(documentID), let session, let command = session.novelPositionCommand,
                  command.id != lastPositionCommandID, command.contentGeneration == session.contentGeneration else { return }
            lastPositionCommandID = command.id
            let script = "(()=>{if(window.__eclipseNovelDocumentID !== '\(documentID)')return;window.scrollTo(0, Math.max(0,document.documentElement.scrollHeight-innerHeight)*\(command.fraction));window.dispatchEvent(new Event('resize'))})()"
            webView?.evaluateJavaScript(script, in: nil, in: Self.bridgeWorld, completionHandler: nil)
        }

        private func applyStyle(_ settings: MacReaderSettingsSnapshot) {
            guard isCurrentDocument(documentID), let style = Self.styleScript(settings) else { return }
            webView?.evaluateJavaScript("(()=>{if(window.__eclipseNovelDocumentID !== '\(documentID)')return;const position=document.documentElement.scrollHeight>0?scrollY/document.documentElement.scrollHeight:0;\(style);window.scrollTo(0,position*document.documentElement.scrollHeight);window.dispatchEvent(new Event('resize'))})()", in: nil, in: Self.bridgeWorld, completionHandler: nil)
        }

        private static func styleScript(_ settings: MacReaderSettingsSnapshot) -> String? {
            let colors = [("#ffffff", "#000000"), ("#f9f1e4", "#4f321c"), ("#49494d", "#d7d7d8"), ("#121212", "#eaeaea"), ("#000000", "#ffffff")]
            let palette = colors[settings.colorPreset]
            let fonts = ["-apple-system", "ui-rounded", "Menlo", "Georgia", "Times New Roman", "Helvetica", "Charter", "New York"]
            let font = fonts.contains(settings.font) ? settings.font : "-apple-system"
            let family = ["-apple-system", "ui-rounded"].contains(font) ? "\(font),system-ui" : "'\(font)',system-ui"
            let weight = ["300", "normal", "500", "600", "700", "bold"].contains(settings.fontWeight) ? settings.fontWeight : "normal"
            let alignment = ["left", "center", "right", "justify"].contains(settings.alignment) ? settings.alignment : "left"
            let css = "html{background:\(palette.0);color:\(palette.1)}body{font-family:\(family);font-size:\(settings.fontSize)px;font-weight:\(weight);line-height:\(settings.lineSpacing);text-align:\(alignment);margin:32px \(settings.margin)px;overflow-wrap:anywhere}body>*{max-width:90ch;margin-left:auto;margin-right:auto}"
            guard let data = try? JSONEncoder().encode(css), let literal = String(data: data, encoding: .utf8) else { return nil }
            return "let e=document.getElementById('eclipse-reader-style');if(!e){e=document.createElement('style');e.id='eclipse-reader-style';document.head.appendChild(e)}e.textContent=\(literal)"
        }

        private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        private static func positionScript(_ id: String) -> String {
            """
            (()=>{window.__eclipseNovelDocumentID='\(id)';let queued=false;function report(){queued=false;let h=document.documentElement.scrollHeight;let f=h>0?Math.min(1,Math.max(0,scrollY/h)):0;let p=h>0?(scrollY+innerHeight)/h:0;window.webkit.messageHandlers.readerPosition.postMessage({documentID:'\(id)',fraction:f,completion:p>0.95?1:p})}addEventListener('scroll',()=>{if(!queued){queued=true;requestAnimationFrame(report)}},{passive:true});addEventListener('resize',report);requestAnimationFrame(report)})();
            """
        }
    }
}
final class MacReaderNovelWebView: WKWebView {
    weak var readerSession: MacReaderSession?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.modifierFlags.intersection([.option, .control, .shift]).isEmpty {
            if event.keyCode == 123 { readerSession?.previousChapter(); return }
            if event.keyCode == 124 { readerSession?.nextChapter(); return }
        }
        if event.keyCode == 53 { readerSession?.close(); return }
        super.keyDown(with: event)
    }
}
#endif
