#if os(macOS)
import AppKit
import SwiftUI

struct ServicesSheetPresentationAnchor: NSViewRepresentable {
    let onResolve: (NSViewController) -> Void
    let onSceneActivity: (ObjectIdentifier?, Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        view.onSceneActivity = onSceneActivity
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onResolve = onResolve
        nsView.onSceneActivity = onSceneActivity
        nsView.resolveIfAttached()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.tearDown()
    }

    final class ProbeView: NSView {
        var onResolve: ((NSViewController) -> Void)?
        var onSceneActivity: ((ObjectIdentifier?, Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var mainCloseObserver: NSObjectProtocol?
        private var generation: UInt64 = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            if observedWindow !== window {
                generation &+= 1
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                observedWindow = window
                if let window {
                    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                        object: window, queue: .main) { [weak self, weak window] _ in
                            guard let self, let window, self.observedWindow === window else { return }
                            self.onSceneActivity?(ObjectIdentifier(window), false)
                        }
                }
            }
            if mainCloseObserver == nil {
                mainCloseObserver = NotificationCenter.default.addObserver(forName: .macMainWindowClosed,
                    object: nil, queue: .main) { [weak self] _ in
                        guard let self else { return }
                        self.generation &+= 1
                        self.onSceneActivity?(self.observedWindow.map(ObjectIdentifier.init), false)
                    }
            }
            guard let window, window.isVisible, !MacLaunchProfileAccess.isTerminating,
                  !MacLaunchProfileAccess.requiresUnlock else {
                onSceneActivity?(window.map(ObjectIdentifier.init), false)
                return
            }
            var responder: NSResponder? = self
            var controller: NSViewController?
            while let next = responder?.nextResponder {
                if let candidate = next as? NSViewController {
                    controller = candidate
                    break
                }
                responder = next
            }
            let capturedGeneration = generation
            let capturedWindowGeneration = MacLaunchProfileAccess.windowGeneration
            DispatchQueue.main.async { [weak self, weak window, weak controller] in
                guard let self, self.generation == capturedGeneration, let window,
                      self.window === window, window.isVisible,
                      capturedWindowGeneration == MacLaunchProfileAccess.windowGeneration,
                      !MacLaunchProfileAccess.isTerminating, !MacLaunchProfileAccess.requiresUnlock else { return }
                if let controller = controller ?? window.contentViewController {
                    self.onResolve?(controller)
                }
                self.onSceneActivity?(ObjectIdentifier(window), true)
            }
        }

        func tearDown() {
            generation &+= 1
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            if let mainCloseObserver { NotificationCenter.default.removeObserver(mainCloseObserver) }
            mainCloseObserver = nil
            observedWindow = nil
            onResolve = nil
            onSceneActivity = nil
        }

        deinit {
            if let mainCloseObserver { NotificationCenter.default.removeObserver(mainCloseObserver) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
}
#endif
