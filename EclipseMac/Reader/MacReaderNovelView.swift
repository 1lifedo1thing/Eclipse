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
        private(set) var layoutGeneration = UUID().uuidString
        private(set) var styleRequestPending = false
        private weak var documentReader: KanzenReaderSession?
        private weak var documentWindow: NSWindow?
        private var chapterID: UUID?
        private var pageIDs: [String] = []
        private var positionKey = ""
        private var locatorKey = ""
        private var positionStore: UserDefaults?
        private var owner: UUID
        private var progressAuthority = MangaReadingProgressManager.shared.captureMutationAuthority()
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
                locatorKey = "novelLocator_v1_" + String(positionKey.dropFirst("novelScrollPos_".count))
                positionStore = session.settingsStore
                owner = session.owner
                progressAuthority = MangaReadingProgressManager.shared.captureMutationAuthority()
                sessionGeneration = session.contentGeneration
                serviceGeneration = ServiceStoreScope.generation
                documentWindow = webView.window
                documentID = UUID().uuidString
                isDocumentReady = false
                layoutGeneration = UUID().uuidString
                styleRequestPending = false
                do {
                    let body = session.pages.map { page in
                        page.novelDocument?.bodyHTML ?? ReaderExtensionNovelSanitizer.escapedPlainText(page.text ?? "")
                    }.joined(separator: "\n\n")
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
            layoutGeneration = UUID().uuidString
            styleRequestPending = false
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
                  MangaReadingProgressManager.shared.isCurrent(progressAuthority),
                  ServiceStoreScope.isCurrent(serviceGeneration), !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating else { return false }
            if let documentWindow, webView?.window !== documentWindow { return false }
            if let payload = reader.selectedChapter.chapterData?.first?.params as? ReaderLocalEPUBChapterPayload {
                guard payload.profileID == owner, ProfileManager.shared.isStillActive(owner), !ProfileManager.shared.isKidsModeActive,
                      ReaderLocalEPUBLibrary.shared.books.contains(where: { $0.id == payload.bookID }) else { return false }
            }
            return true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard self.webView === webView, let navigation, navigation === expectedNavigation,
                  isCurrentDocument(documentID), let settings = lastSettings else { return }
            documentWindow = webView.window
            let id = documentID
            let fraction = MacReaderNovelPosition.finiteFraction(positionStore?.double(forKey: positionKey) ?? 0)
            let locator = ReaderNovelLocator.decode(positionStore?.data(forKey: locatorKey))
            guard isCurrentDocument(id) else { return }
            let restoration = locator.map { "r.restore(\(ReaderNovelScripts.literal($0)))" }
                ?? "r.seek(\(fraction) * document.documentElement.scrollHeight / Math.max(1,document.documentElement.scrollHeight-innerHeight))"
            applyStyle(settings, restoration: restoration, completesDocument: true)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            if !closed, isMainFrame, isDocumentReady, navigationAction.navigationType == .linkActivated,
               let url, url.scheme == "about", url.path == "blank", let encodedFragment = url.fragment,
               let fragment = encodedFragment.removingPercentEncoding,
               fragment.hasPrefix("novel-"), isCurrentDocument(documentID),
               let data = try? JSONEncoder().encode(fragment), let literal = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.__eclipseNovelReader?.fragment(\(literal))", in: nil, in: Self.bridgeWorld, completionHandler: nil)
            }
            decisionHandler(!closed && navigationAction.navigationType == .other && url?.scheme == "about" && isMainFrame ? .allow : .cancel)
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
            guard isDocumentReady, !styleRequestPending, isCurrentDocument(documentID),
                  body["layoutGeneration"] as? String == layoutGeneration, let fraction = body["fraction"] as? Double,
                  let completion = body["completion"] as? Double, fraction.isFinite, completion.isFinite else { return }
            if let commandID = body["positionCommandID"] as? String,
               let command = session?.novelPositionCommand, command.id.uuidString == commandID {
                session?.consumeNovelPositionCommand(command.id)
            }
            positionStore?.set(MacReaderNovelPosition.finiteFraction(fraction), forKey: positionKey)
            if let value = body["locator"], JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let locator = ReaderNovelLocator.decode(data), let encoded = try? JSONEncoder().encode(locator) {
                positionStore?.set(encoded, forKey: locatorKey)
            }
            session?.positionChanged(page: 0, completion: MacReaderNovelPosition.finiteFraction(completion))
        }

        private func stopAutoScroll() { timer?.invalidate(); timer = nil; autoScrollRequestPending = false }
        private func suspendAutoScroll() { stopAutoScroll(); session?.autoScroll = false }

        private func updateAutoScroll() {
            guard isDocumentReady, !styleRequestPending, isCurrentDocument(documentID), session?.autoScroll == true else { stopAutoScroll(); return }
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.autoScrollTick() } }
        }

        private func autoScrollTick() {
            guard isDocumentReady, !styleRequestPending, isCurrentDocument(documentID), let session, session.autoScroll, let webView else { stopAutoScroll(); return }
            guard !autoScrollRequestPending else { return }
            let id = documentID
            let layout = layoutGeneration
            let amount = session.autoScrollSpeed.isFinite ? min(max(session.autoScrollSpeed, 0.25), 4) * 2 : 2
            autoScrollRequestPending = true
            webView.evaluateJavaScript("(()=>{if(window.__eclipseNovelDocumentID !== '\(id)'||window.__eclipseNovelLayoutGeneration!=='\(layout)')return null;const r=window.__eclipseNovelReader;r.seek((scrollY+\(amount))/Math.max(1,document.documentElement.scrollHeight-innerHeight));return window.__eclipseNovelPositionReport()})()", in: nil, in: Self.bridgeWorld) { [weak self] result in
                guard let self, self.isCurrentDocument(id), !self.styleRequestPending, self.layoutGeneration == layout else { return }
                self.autoScrollRequestPending = false
                if case .success(let value) = result, let metrics = value as? [String: Any] {
                    self.acceptPosition(metrics, documentID: id)
                    if metrics["atBottom"] as? Bool == true { self.suspendAutoScroll() }
                }
                else if case .failure = result { self.suspendAutoScroll() }
            }
        }

        private func applyPositionCommand() {
            guard isDocumentReady, !styleRequestPending, isCurrentDocument(documentID), let webView, let session,
                  let command = session.novelPositionCommand, command.id != lastPositionCommandID,
                  command.contentGeneration == session.contentGeneration else { return }
            lastPositionCommandID = command.id
            let id = documentID
            let layout = layoutGeneration
            let script = """
            if(window.__eclipseNovelDocumentID!=='\(id)'||window.__eclipseNovelLayoutGeneration!=='\(layout)')return null;
            window.__eclipseNovelPositionCommandID='\(command.id.uuidString)';
            window.__eclipseNovelReader.seek(\(command.fraction));
            await window.__eclipseNovelLayoutFrame();
            if(window.__eclipseNovelDocumentID!=='\(id)'||window.__eclipseNovelLayoutGeneration!=='\(layout)')return null;
            document.documentElement.getBoundingClientRect();
            return window.__eclipseNovelPositionReport();
            """
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: Self.bridgeWorld) { [weak self] result in
                guard let self, self.isCurrentDocument(id), !self.styleRequestPending, self.layoutGeneration == layout,
                      self.lastPositionCommandID == command.id else { return }
                if case .success(let value) = result, let metrics = value as? [String: Any] {
                    self.session?.consumeNovelPositionCommand(command.id)
                    self.acceptPosition(metrics, documentID: id)
                }
            }
        }

        private func applyStyle(_ settings: MacReaderSettingsSnapshot, restoration: String? = nil, completesDocument: Bool = false) {
            guard !styleRequestPending, isCurrentDocument(documentID), let webView, let style = Self.styleScript(settings) else { return }
            stopAutoScroll()
            styleRequestPending = true
            layoutGeneration = UUID().uuidString
            let id = documentID
            let layout = layoutGeneration
            let restore = restoration ?? "if(locator)r.restore(locator)"
            restorationTask = Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                do {
                    let script = """
                    if(window.__eclipseNovelDocumentID!=='\(id)')return null;
                    window.__eclipseNovelLayoutGeneration='\(layout)';
                    const r=window.__eclipseNovelReader,locator=r.locate(),revision=r.version();
                    \(style);
                    await window.__eclipseNovelLayoutFrame();
                    await window.__eclipseNovelLayoutFrame();
                    if(window.__eclipseNovelDocumentID!=='\(id)'||window.__eclipseNovelLayoutGeneration!=='\(layout)')return null;
                    document.documentElement.getBoundingClientRect();
                    document.body.getBoundingClientRect();
                    if(r.version()===revision){\(restore)}
                    await window.__eclipseNovelLayoutFrame();
                    if(window.__eclipseNovelDocumentID!=='\(id)'||window.__eclipseNovelLayoutGeneration!=='\(layout)')return null;
                    document.documentElement.getBoundingClientRect();
                    return window.__eclipseNovelPositionReport();
                    """
                    let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: Self.bridgeWorld)
                    try Task.checkCancellation()
                    guard let self, self.isCurrentDocument(id), self.layoutGeneration == layout, let metrics = result as? [String: Any] else { return }
                    self.styleRequestPending = false
                    self.restorationTask = nil
                    if let latest = self.lastSettings, latest != settings {
                        self.applyStyle(latest, restoration: restoration, completesDocument: completesDocument)
                        return
                    }
                    if completesDocument { self.isDocumentReady = true }
                    self.acceptPosition(metrics, documentID: id)
                    self.updateAutoScroll()
                    self.applyPositionCommand()
                } catch {
                    guard let self, !Task.isCancelled, self.isCurrentDocument(id), self.layoutGeneration == layout else { return }
                    self.styleRequestPending = false
                    self.restorationTask = nil
                    self.session?.error = error.localizedDescription
                }
            }
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

        private static func positionScript(_ id: String) -> String {
            """
            \(ReaderNovelScripts.install)
            (()=>{
              window.__eclipseNovelDocumentID='\(id)';
              window.__eclipseNovelLayoutFrame=()=>document.visibilityState!=='visible'?Promise.resolve():new Promise(resolve=>{
                let frame=0,timer=0,done=false;
                const finish=()=>{if(done)return;done=true;cancelAnimationFrame(frame);clearTimeout(timer);resolve()};
                frame=requestAnimationFrame(finish);timer=setTimeout(finish,120);
              });
              window.__eclipseNovelPositionReport=()=>{
                let h=document.documentElement.scrollHeight,f=h>0?Math.min(1,Math.max(0,scrollY/h)):0,p=h>0?(scrollY+innerHeight)/h:0;
                return {documentID:'\(id)',layoutGeneration:window.__eclipseNovelLayoutGeneration||'',positionCommandID:window.__eclipseNovelPositionCommandID||'',fraction:f,completion:p>0.95?1:p,locator:window.__eclipseNovelReader.locate(),atBottom:scrollY+innerHeight>=h-1};
              };
              let queued=false,frame=0,timer=0;
              function cancelReport(){queued=false;cancelAnimationFrame(frame);clearTimeout(timer);frame=timer=0}
              function report(){if(!queued)return;cancelReport();document.documentElement.getBoundingClientRect();window.webkit.messageHandlers.readerPosition.postMessage(window.__eclipseNovelPositionReport())}
              function scheduleReport(){if(queued)return;queued=true;if(document.visibilityState==='visible')frame=requestAnimationFrame(report);timer=setTimeout(report,document.visibilityState==='visible'?120:0)}
              addEventListener('scroll',scheduleReport,{passive:true});
              addEventListener('resize',scheduleReport);
              addEventListener('visibilitychange',scheduleReport);
              addEventListener('pagehide',cancelReport);
              scheduleReport();
            })();
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
