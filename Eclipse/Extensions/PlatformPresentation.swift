import SwiftUI
#if os(macOS)
import AppKit
typealias EclipsePresentationController = NSViewController
enum EclipseSizeClass { case compact, regular }
#else
import UIKit
typealias EclipsePresentationController = UIViewController
typealias EclipseSizeClass = UserInterfaceSizeClass
#endif

enum EclipseLifecycle {
#if os(macOS)
    static let foregroundNotification = NSApplication.didBecomeActiveNotification
#else
    static let foregroundNotification = UIApplication.willEnterForegroundNotification
#endif
}

enum EclipseViewport {
#if os(macOS)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var contentSize = CGSize(width: 1200, height: 800)
    nonisolated(unsafe) private static var backingScale: CGFloat = 2

    static var bounds: CGRect {
        lock.lock()
        defer { lock.unlock() }
        return CGRect(origin: .zero, size: contentSize)
    }

    static var scale: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return backingScale
    }

    static func updateMac(size: CGSize, scale: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        contentSize = size
        backingScale = scale
    }
#else
    static var bounds: CGRect { UIScreen.main.bounds }
    static var scale: CGFloat { UIScreen.main.scale }
#endif
}

extension EnvironmentValues {
    var eclipseVerticalSizeClass: EclipseSizeClass? {
#if os(macOS)
        macWindowSize.height < 650 ? .compact : .regular
#else
        verticalSizeClass
#endif
    }

    var eclipseHorizontalSizeClass: EclipseSizeClass? {
#if os(macOS)
        macWindowSize.width < 800 ? .compact : .regular
#else
        horizontalSizeClass
#endif
    }
}

@MainActor
enum EclipsePresentation {
    static func current(sceneIdentifier: String? = nil) -> EclipsePresentationController? {
#if os(macOS)
        guard let window = MacWindowCoordinator.shared.mainWindow, window.isVisible else { return nil }
        if let sceneIdentifier, sceneIdentifier != MacWindowCoordinator.presentationIdentifier { return nil }
        return window.contentViewController
#elseif os(tvOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)?.rootViewController
#else
        return UIApplication.shared.eclipseTopmostViewController(forSceneSessionIdentifier: sceneIdentifier)
#endif
    }

    static func openSystemSettings() {
#if os(macOS)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
#elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }
}

extension View {
    @ViewBuilder func eclipseHideTabBar() -> some View {
#if os(macOS)
        self
#else
        if #available(iOS 16.0, tvOS 16.0, *) {
            toolbar(.hidden, for: .tabBar)
        } else {
            self
        }
#endif
    }
}

extension ToolbarItemPlacement {
    static var eclipseLeading: ToolbarItemPlacement {
#if os(macOS)
        .navigation
#else
        .navigationBarLeading
#endif
    }

    static var eclipseTrailing: ToolbarItemPlacement {
#if os(macOS)
        .primaryAction
#else
        .navigationBarTrailing
#endif
    }
}

extension SearchFieldPlacement {
    static var eclipsePersistent: SearchFieldPlacement {
#if os(macOS)
        .toolbar
#elseif os(tvOS)
        .automatic
#else
        .navigationBarDrawer(displayMode: .always)
#endif
    }
}
