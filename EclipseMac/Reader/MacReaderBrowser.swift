#if os(macOS)
import AppKit
import SwiftUI
import WebKit

@MainActor
struct ReaderExtensionCloudflareVerificationWebView: NSViewRepresentable {
    let session: ReaderExtensionSignInSession
    let userAgent: String
    let onVerificationSolved: () -> Void
    let reportError: (String) -> Void
    var isPresentationCurrent: () -> Bool = { true }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            onVerificationSolved: onVerificationSolved,
            reportError: reportError,
            isPresentationCurrent: isPresentationCurrent
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: ReaderExtensionCloudflareBrowserPolicy.makeConfiguration()
        )
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let session: ReaderExtensionSignInSession
        private let onVerificationSolved: () -> Void
        private let reportError: (String) -> Void
        private weak var webView: WKWebView?
        private var monitorTask: Task<Void, Never>?
        private var mainStatusCode = 0
        private var mainHeaders: [String: String] = [:]
        private var didComplete = false
        private var closed = false
        private var generation = UUID()
        private let authority = MacDownloadStorageAuthority.capture()
        private let isPresentationCurrent: () -> Bool
        private weak var presentingWindow: NSWindow?

        init(
            session: ReaderExtensionSignInSession,
            onVerificationSolved: @escaping () -> Void,
            reportError: @escaping (String) -> Void,
            isPresentationCurrent: @escaping () -> Bool = { true }
        ) {
            self.session = session
            self.onVerificationSolved = onVerificationSolved
            self.reportError = reportError
            self.isPresentationCurrent = isPresentationCurrent
        }

        func start(_ webView: WKWebView) {
            guard !closed else { return }
            self.webView = webView
            let token = generation
            monitorTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    try validateCurrent(webView, token: token)
                    let seedCookies = ReaderExtensionCloudflareBrowserPolicy.sourceCookies(
                        from: session.authenticationStore.cookies(),
                        approvedDomains: session.approvedDomains
                    )
                    await ReaderExtensionCloudflareBrowserPolicy.install(
                        seedCookies,
                        in: webView.configuration.websiteDataStore.httpCookieStore
                    )
                    try Task.checkCancellation()
                    try validateCurrent(webView, token: token)
                    webView.load(URLRequest(
                        url: session.startURL,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 45
                    ))
                    while !Task.isCancelled, !didComplete {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        try validateCurrent(webView, token: token)
                        if try await inspectSolvedState(in: webView, token: token) { return }
                    }
                } catch is CancellationError {
                } catch {
                    if (try? validateCurrent(webView, token: token)) != nil { reportError(error.localizedDescription) }
                }
            }
        }

        func stop() {
            closed = true
            generation = UUID()
            monitorTask?.cancel()
            monitorTask = nil
            webView = nil
        }

        private func validateCurrent(_ webView: WKWebView, token: UUID) throws {
            try Task.checkCancellation()
            guard !closed, generation == token, self.webView === webView, isPresentationCurrent(), authority?.isCurrent() == true else { throw CancellationError() }
            if let presentingWindow, webView.window !== presentingWindow { throw CancellationError() }
            if presentingWindow == nil { presentingWindow = webView.window }
            try ReaderExtensionManager.shared.validateSignInSession(session)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard (try? validateCurrent(webView, token: generation)) != nil,
                  let url = navigationAction.request.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard (try? validateCurrent(webView, token: generation)) != nil,
                  let url = navigationResponse.response.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                decisionHandler(.cancel)
                return
            }
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse {
                mainStatusCode = response.statusCode
                mainHeaders = response.allHeaderFields.reduce(into: [:]) { output, pair in
                    output[String(describing: pair.key)] = String(describing: pair.value)
                }
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            guard (try? validateCurrent(webView, token: generation)) != nil,
                  let url = navigationAction.request.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation _: WKNavigation?,
            withError error: Error
        ) {
            guard (try? validateCurrent(webView, token: generation)) != nil, (error as? URLError)?.code != .cancelled else { return }
            reportError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFail _: WKNavigation?,
            withError error: Error
        ) {
            guard (try? validateCurrent(webView, token: generation)) != nil, (error as? URLError)?.code != .cancelled else { return }
            reportError(error.localizedDescription)
        }

        private func inspectSolvedState(in webView: WKWebView, token: UUID) async throws -> Bool {
            try validateCurrent(webView, token: token)
            guard !didComplete,
                  (200..<400).contains(mainStatusCode),
                  let currentURL = webView.url,
                  ReaderExtensionCloudflareBrowserPolicy.isSourcePage(
                    currentURL,
                    session: session
                  ) else {
                return false
            }
            let result = try await webView.evaluateJavaScript(
                "String(document.documentElement ? document.documentElement.outerHTML : '').slice(0, 65536)"
            )
            try validateCurrent(webView, token: token)
            let html = result as? String ?? ""
            guard !ReaderExtensionChallengeDetector.isChallenge(
                status: mainStatusCode,
                headers: mainHeaders,
                body: Data(html.utf8)
            ) else {
                return false
            }
            let browserCookies = await ReaderExtensionCloudflareBrowserPolicy.cookies(
                in: webView.configuration.websiteDataStore.httpCookieStore
            )
            try validateCurrent(webView, token: token)
            let sourceCookies = ReaderExtensionCloudflareBrowserPolicy.sourceCookies(
                from: browserCookies,
                approvedDomains: session.approvedDomains
            )
            guard ReaderExtensionBrowserChallengeSessionPolicy.hasUsableClearance(
                in: sourceCookies,
                for: session.startURL,
                approvedDomains: session.approvedDomains
            ) else {
                return false
            }
            try validateCurrent(webView, token: token)
            try session.authenticationStore.updateCookies { existing in
                ReaderExtensionCloudflareBrowserPolicy.mergingSourceCookies(
                    sourceCookies,
                    existing: existing,
                    approvedDomains: session.approvedDomains
                )
            }
            try validateCurrent(webView, token: token)
            didComplete = true
            onVerificationSolved()
            return true
        }
    }
}


@MainActor
final class ReaderExtensionCloudflareVerificationCoordinator: NSObject, NSWindowDelegate {
    static let shared = ReaderExtensionCloudflareVerificationCoordinator()

    private struct FlowKey: Hashable {
        let namespace: String
        let sourceID: ReaderExtensionSourceID
        let host: String
    }

    private struct CompletedFlow {
        let serial: UInt64
        let result: Bool
    }

    private var activeKey: FlowKey?
    private var activeToken: UUID?
    private var activeContext: ReaderExtensionBrowserChallengeContext?
    private var activeWindow: NSPanel?
    private weak var presentingWindow: NSWindow?
    private var activeContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completionSerial: UInt64 = 0
    private var completedFlows: [FlowKey: CompletedFlow] = [:]

    private override init() { super.init() }

    func solve(_ context: ReaderExtensionBrowserChallengeContext) async -> Bool {
        guard let host = ReaderExtensionSecurityPolicy.canonicalHost(of: context.challengedURL) else {
            return false
        }
        let key = FlowKey(
            namespace: context.authenticationAdmission.namespace,
            sourceID: context.sourceID,
            host: host
        )
        let observedCompletion = completedFlows[key]?.serial ?? 0
        var joinedMatchingFlow = false
        while activeKey != nil {
            if Task.isCancelled { return false }
            if activeKey == key { joinedMatchingFlow = true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if joinedMatchingFlow,
           let completed = completedFlows[key],
           completed.serial > observedCompletion {
            return completed.result
        }
        if Task.isCancelled { return false }

        let session: ReaderExtensionSignInSession
        do {
            try context.authenticationAdmission.validate()
            session = try ReaderExtensionManager.shared.makeBrowserVerificationSession(
                for: context.sourceID,
                challengedURL: context.challengedURL
            )
            guard session.approvedDomains == context.approvedDomains,
                  session.mutationScope.authenticationNamespace
                    == context.authenticationAdmission.namespace,
                  ReaderExtensionAuthenticationGenerationRegistry.isCurrent(
                    context.authenticationAdmission.generation,
                    sourceID: context.sourceID,
                    namespace: context.authenticationAdmission.namespace
                  ) else {
                return false
            }
        } catch {
            return false
        }

        let token = UUID()
        activeKey = key
        activeToken = token
        activeContext = context
        ReaderLogger.shared.log(
            "ReaderCloudflare: started source=\(context.sourceID.rawValue.prefix(12)) host=\(host)",
            type: "ReaderExtensionNetwork"
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                activeContinuation = continuation
                present(
                    session: session,
                    userAgent: context.userAgent,
                    token: token
                )
            }
        }, onCancel: {
            Task { @MainActor in
                ReaderExtensionCloudflareVerificationCoordinator.shared.complete(
                    token: token,
                    result: false
                )
            }
        })
    }

    private func present(
        session: ReaderExtensionSignInSession,
        userAgent: String,
        token: UUID
    ) {
        guard NSApp.isActive, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let scene = NSApp.mainWindow ?? NSApp.keyWindow, scene.isVisible, !scene.isMiniaturized else {
            complete(token: token, result: false)
            return
        }
        let root = ReaderExtensionCloudflareVerificationView(
            session: session,
            userAgent: userAgent,
            onDismiss: { [weak self] in
                self?.complete(token: token, result: false)
            },
            onVerificationSolved: { [weak self] in
                self?.complete(token: token, result: true)
            },
            isPresentationCurrent: { [weak self] in self?.activeToken == token && NSApp.isActive }
        )
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        window.title = session.sourceName
        window.delegate = self
        presentingWindow = scene
        activeWindow = window
        scene.beginSheet(window) { [weak self] _ in
            self?.complete(token: token, result: false)
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.complete(token: token, result: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let token = activeToken else { return }
        complete(token: token, result: false)
    }

    func cancel() {
        guard let token = activeToken else { return }
        complete(token: token, result: false)
    }

    private func complete(token: UUID, result: Bool) {
        guard activeToken == token else { return }
        var finalResult = result
        if result, let context = activeContext {
            do {
                try context.authenticationAdmission.validate()
                finalResult = ReaderExtensionBrowserChallengeSessionPolicy.hasUsableClearance(
                    in: context.authenticationStore.cookies(),
                    for: context.challengedURL,
                    approvedDomains: context.approvedDomains
                )
            } catch {
                finalResult = false
            }
        }
        let key = activeKey
        let continuation = activeContinuation
        timeoutTask?.cancel()
        timeoutTask = nil
        let window = activeWindow
        activeWindow = nil
        activeToken = nil
        if let window { presentingWindow?.endSheet(window); window.orderOut(nil) }
        presentingWindow = nil
        activeContinuation = nil
        activeContext = nil
        activeToken = nil
        activeKey = nil
        if let key {
            completionSerial &+= 1
            completedFlows[key] = CompletedFlow(
                serial: completionSerial,
                result: finalResult
            )
            if completedFlows.count > 128,
               let oldest = completedFlows.min(by: { $0.value.serial < $1.value.serial })?.key {
                completedFlows.removeValue(forKey: oldest)
            }
            ReaderLogger.shared.log(
                "ReaderCloudflare: finished source=\(key.sourceID.rawValue.prefix(12)) host=\(key.host) solved=\(finalResult)",
                type: "ReaderExtensionNetwork"
            )
        }
        continuation?.resume(returning: finalResult)
    }
}


struct ReaderExtensionSignInWebView: NSViewRepresentable {
    let session: ReaderExtensionSignInSession
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, reportError: reportError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: ReaderExtensionSignInURLProxy.secureScheme)
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.cookieMessageName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        do {
            webView.load(URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(for: session.startURL)))
        } catch {
            reportError(error.localizedDescription)
        }
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.cookieMessageName)
        coordinator.detach()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let cookieMessageName = "readerExtensionAuthCookie"
        let schemeHandler: ReaderExtensionSignInSchemeHandler
        private let session: ReaderExtensionSignInSession
        private let reportError: (String) -> Void
        private weak var webView: WKWebView?
        private var cookieMessageCount = 0
        private var cookieMessageBytes = 0
        private var cookieBridgeDisabled = false
        private var closed = false
        private var generation = UUID()
        private let authority = MacDownloadStorageAuthority.capture()
        private weak var presentingWindow: NSWindow?
        private let cookieWriter: (String, URL) throws -> [String: String]

        init(
            session: ReaderExtensionSignInSession,
            reportError: @escaping (String) -> Void,
            cookieWriter: ((String, URL) throws -> [String: String])? = nil
        ) {
            self.session = session
            self.reportError = reportError
            self.cookieWriter = cookieWriter ?? { cookie, proxyURL in
                try ReaderExtensionSignInCookieBridge.persist(cookieString: cookie, proxyURL: proxyURL, session: session)
                return ReaderExtensionSignInCookieBridge.visibleCookies(for: try ReaderExtensionSignInURLProxy.originalURL(from: proxyURL, approvedDomains: session.approvedDomains), session: session)
            }
            schemeHandler = ReaderExtensionSignInSchemeHandler(session: session)
            super.init()
            schemeHandler.onError = { [weak self] message in
                DispatchQueue.main.async { if let self, self.isAttached { self.reportError(message) } }
            }
        }

        private var isAttached: Bool {
            guard !closed, let webView, authority?.isCurrent() == true else { return false }
            if let presentingWindow, webView.window !== presentingWindow { return false }
            if presentingWindow == nil { presentingWindow = webView.window }
            return true
        }

        func attach(_ webView: WKWebView) { guard !closed else { return }; self.webView = webView; presentingWindow = webView.window }
        func detach() {
            closed = true
            generation = UUID()
            schemeHandler.cancelAll()
            webView = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard isAttached, self.webView === webView, let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if ReaderExtensionSignInURLProxy.isProxyURL(url) || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false,
               let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: url) {
                webView.load(URLRequest(url: proxied))
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            guard isAttached, self.webView === webView, let url = navigationAction.request.url else { return nil }
            let proxied = ReaderExtensionSignInURLProxy.isProxyURL(url)
                ? url
                : try? ReaderExtensionSignInURLProxy.proxyURL(for: url)
            if let proxied { webView.load(URLRequest(url: proxied)) }
            return nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isAttached, message.webView === webView, message.name == Self.cookieMessageName else { return }
            cookieMessageCount += 1
            let candidateBytes = ((message.body as? [String: Any])?["cookie"] as? String)?.utf8.count ?? 0
            guard !cookieBridgeDisabled,
                  cookieMessageCount <= 128,
                  candidateBytes <= ReaderExtensionSignInCookieBridge.maximumCookieStringBytes,
                  candidateBytes <= 256 * 1_024 - cookieMessageBytes else {
                cookieBridgeDisabled = true
                controller.removeScriptMessageHandler(forName: Self.cookieMessageName)
                schemeHandler.cancelAll()
                webView?.stopLoading()
                reportError("The sign-in page exceeded its cookie-write limit.")
                return
            }
            cookieMessageBytes += candidateBytes
            guard
                  let body = message.body as? [String: Any],
                  let proxyURL = message.frameInfo.request.url,
                  ReaderExtensionSignInURLProxy.isProxyURL(proxyURL),
                  let cookie = body["cookie"] as? String else { return }
            do {
                let visible = try cookieWriter(cookie, proxyURL)
                replaceVisibleCookies(visible, in: message.frameInfo)
            } catch {
                reportError(error.localizedDescription)
            }
        }

        private func replaceVisibleCookies(_ cookies: [String: String], in frame: WKFrameInfo) {
            let token = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isAttached else { return }
                _ = try? await self.webView?.callAsyncJavaScript(
                    "window.__eclipseReplaceReaderCookies && window.__eclipseReplaceReaderCookies(cookies);",
                    arguments: ["cookies": cookies],
                    in: frame,
                    contentWorld: .page
                )
            }
        }
    }
}


struct ReaderExtensionCloudflareVerificationView: View {
    let session: ReaderExtensionSignInSession
    let userAgent: String
    let onDismiss: () -> Void
    let onVerificationSolved: () -> Void
    var isPresentationCurrent: () -> Bool = { true }
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Verify \(session.sourceName)").font(.headline)
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
            }.padding()
            if let error { Text(error).foregroundStyle(.red).padding() }
            ReaderExtensionCloudflareVerificationWebView(session: session, userAgent: userAgent, onVerificationSolved: onVerificationSolved, reportError: { error = $0 }, isPresentationCurrent: isPresentationCurrent)
        }.frame(minWidth: 650, minHeight: 500)
    }
}

struct ReaderExtensionSignInView: View {
    let session: ReaderExtensionSignInSession
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title ?? "Sign In to \(session.sourceName)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            if let error { Text(error).foregroundStyle(.red).padding() }
            ReaderExtensionSignInWebView(session: session, reportError: { error = $0 })
        }.frame(minWidth: 700, minHeight: 550)
    }
}

#endif
