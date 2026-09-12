import AppKit
import CloudKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum MacMediaSection: String, CaseIterable, Identifiable {
    case home, search, library, schedule, downloads
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "rectangle.stack"
        case .schedule: return "calendar"
        case .downloads: return "arrow.down.circle"
        }
    }
}

@MainActor
final class MacWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate, NSMenuItemValidation {
    enum ShowReason: String {
        case launch, reopen, pictureInPictureRestore, playbackPresented, notification, watchTogether
        case errorPresentation, debugRoute, localVideo, filePicker, settings, search
    }

    static let shared = MacWindowCoordinator()
    static let presentationIdentifier = "eclipse-mac-main"
    @Published private(set) var isReaderMode = UserDefaults.standard.bool(forKey: "showKanzen")
    @Published var mediaSection: MacMediaSection = .home
    @Published var readerSection: MacReaderSection = .home
    @Published private(set) var mediaSearchFocusRequest: UInt64 = 0
    @Published private(set) var readerSearchFocusRequest: UInt64 = 0
    @Published var showingSettings = false
    @Published var showingProfiles = false
    @Published private(set) var isTerminating = false
    @Published var launchUnlockRequired = MacLaunchProfileAccess.requiresUnlock {
        didSet { MacLaunchProfileAccess.requiresUnlock = launchUnlockRequired }
    }
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var isActive = true
    @Published private(set) var mainContentIsVisible = false
    @Published var errorMessage: String?
    @Published var windowSize = CGSize(width: 1200, height: 800)
    @Published private(set) var contentSize = CGSize(width: 960, height: 800)
    @Published var displayScale: CGFloat = 2
    let readerSession = MacReaderSession()
    private(set) var mainWindow: NSWindow?
    private var observers: [AnyCancellable] = []
    private var accountObservers: [NSObjectProtocol] = []
    private var openVideoPanel: NSOpenPanel?

    private var canOpenLocalFiles: Bool {
        !isTerminating && !launchUnlockRequired && ProfileManager.shared.rosterStoreIsReadable
            && ProfileManager.shared.activeProfile?.isKidsProfile == false
    }

    private override init() {
        super.init()
        for name in [Notification.Name.CKAccountChanged, .NSUbiquityIdentityDidChange, .mediaStateWillChangeCurrentUser] {
            accountObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    MacLaunchProfileAccess.windowGeneration &+= 1
                    self.openVideoPanel?.cancel(nil)
                    self.openVideoPanel = nil
                    MacPlaybackCoordinator.shared.stopAll()
                    self.readerSession.close()
                    MacProviderMaintenance.shared.cancel()
                    TrackerManager.shared.cancelMacAuthentication()
                    ExperimentalCloudSyncManager.shared.cancelMacWindowAuthentication()
                }
            })
        }
        let player = MacPlaybackCoordinator.shared
        player.onRestoreMainWindow = { [weak self] in
            guard let self else { return }
            Logger.shared.log("MacLifecycle event=pip-restore-callback visible=\(mainWindow?.isVisible == true) explicitPiP=\(MacPlaybackCoordinator.shared.session?.isPictureInPicture == true)", type: "Lifecycle")
            readerSession.close()
            isReaderMode = false
            UserDefaults.standard.set(false, forKey: "showKanzen")
            showingSettings = false
            showMainWindow(reason: .pictureInPictureRestore)
        }
        player.onPlaybackPresented = { [weak self] in
            guard let self else { return }
            readerSession.close()
            isReaderMode = false
            UserDefaults.standard.set(false, forKey: "showKanzen")
            showingSettings = false
            showMainWindow(reason: .playbackPresented)
        }
        NotificationCenter.default.publisher(for: .openScheduleFromLocalNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                setMode(reader: false)
                MacPlaybackCoordinator.shared.stopInlinePlayback()
                mediaSection = .schedule
                showingSettings = false
                showMainWindow(reason: .notification)
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: .watchTogetherJoinRequested)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setMode(reader: false)
                self?.showingSettings = false
                self?.showMainWindow(reason: .watchTogether)
            }.store(in: &observers)
    }

    func showMainWindow(reason: ShowReason) {
        Logger.shared.log("MacLifecycle event=main-show reason=\(reason.rawValue) exists=\(mainWindow != nil) visible=\(mainWindow?.isVisible == true) minimized=\(mainWindow?.isMiniaturized == true) explicitPiP=\(MacPlaybackCoordinator.shared.session?.isPictureInPicture == true) terminating=\(isTerminating)", type: "Lifecycle")
        guard !isTerminating else { return }
        if mainWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Eclipse"
            window.identifier = NSUserInterfaceItemIdentifier(Self.presentationIdentifier)
            window.setFrameAutosaveName("EclipseMainWindow")
            window.minSize = CGSize(width: 720, height: 520)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            window.contentViewController = MacAppKitShellController(coordinator: self)
            if !window.setFrameUsingName("EclipseMainWindow") { window.center() }
            mainWindow = window
            WatchTogetherCoordinator.shared.registerPresentationWindow(window)
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        mainContentIsVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        if launchUnlockRequired { showingProfiles = true }
        updateWindowMetrics()
    }

    func setMode(reader: Bool) {
        guard !isTerminating, !launchUnlockRequired, reader != isReaderMode else { return }
        readerSession.close()
        MacPlaybackCoordinator.shared.stopInlinePlayback()
        isReaderMode = reader
        UserDefaults.standard.set(reader, forKey: "showKanzen")
        showingSettings = false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        Logger.shared.log("MacLifecycle event=main-will-close explicitPiP=\(MacPlaybackCoordinator.shared.session?.isPictureInPicture == true) visible=\(mainWindow?.isVisible == true) terminating=\(isTerminating)", type: "Lifecycle")
        MacLaunchProfileAccess.windowGeneration &+= 1
        openVideoPanel?.cancel(nil)
        openVideoPanel = nil
        mainContentIsVisible = false
        readerSession.close()
        MacPlaybackCoordinator.shared.mainWindowClosed()
        MacProviderMaintenance.shared.cancel()
        TrackerManager.shared.cancelMacAuthentication()
        ExperimentalCloudSyncManager.shared.cancelMacWindowAuthentication()
        let progressSaved = ProgressManager.shared.flushForMacTermination()
        let localResumeSaved = MacLocalPlaybackResumeStore.shared.flushForMacTermination()
        if !progressSaved || !localResumeSaved {
            errorMessage = "Playback progress could not be saved. Eclipse has kept the pending changes; check available storage before quitting."
        }
        showingSettings = false
        showingProfiles = false
        NotificationCenter.default.post(name: .macMainWindowClosed, object: mainWindow)
    }

    func windowDidResize(_ notification: Notification) { updateWindowMetrics() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateWindowMetrics() }
    func windowDidMiniaturize(_ notification: Notification) {
        Logger.shared.log("MacLifecycle event=main-minimized explicitPiP=\(MacPlaybackCoordinator.shared.session?.isPictureInPicture == true)", type: "Lifecycle")
        mainContentIsVisible = false
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        Logger.shared.log("MacLifecycle event=main-deminiaturized explicitPiP=\(MacPlaybackCoordinator.shared.session?.isPictureInPicture == true)", type: "Lifecycle")
        mainContentIsVisible = true
    }

    private func updateWindowMetrics() {
        guard let mainWindow else { return }
        windowSize = mainWindow.contentLayoutRect.size
        displayScale = mainWindow.backingScaleFactor
        EclipseViewport.updateMac(size: contentSize, scale: displayScale)
    }

    func updateContentMetrics(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if contentSize != size { contentSize = size }
        EclipseViewport.updateMac(size: size, scale: displayScale)
    }

    func prepareForTermination() {
        isTerminating = true
        MacLaunchProfileAccess.isTerminating = true
        MacLaunchProfileAccess.windowGeneration &+= 1
        openVideoPanel?.cancel(nil)
        openVideoPanel = nil
        MacPlaybackCoordinator.shared.beginMacTermination()
        readerSession.close()
        MacProviderMaintenance.shared.cancel()
        TrackerManager.shared.cancelMacAuthentication()
        ExperimentalCloudSyncManager.shared.cancelMacWindowAuthentication()
        NotificationCenter.default.post(name: .macMainWindowClosed, object: mainWindow)
    }

    func cancelTermination() {
        isTerminating = false
        MacLaunchProfileAccess.isTerminating = false
    }

    func presentError(_ message: String) {
        errorMessage = message
        showMainWindow(reason: .errorPresentation)
    }

    func open(_ url: URL) {
#if DEBUG
        if url.scheme?.lowercased() == "luna", url.host?.lowercased() == "open" {
            guard !isTerminating else { return }
            showMainWindow(reason: .debugRoute)
            guard !launchUnlockRequired else { return }
            let components = Array(url.pathComponents.dropFirst())
            switch components.first?.lowercased() {
            case "reader": setMode(reader: true)
            case "video": setMode(reader: false)
            case "settings": openSettings(nil)
            case "tab":
                guard let raw = components.dropFirst().first?.lowercased(), let section = MacMediaSection(rawValue: raw) else { return }
                setMode(reader: false)
                MacPlaybackCoordinator.shared.stopInlinePlayback()
                mediaSection = section
                showingSettings = false
            default: break
            }
            return
        }
#endif
        guard url.isFileURL else { return }
        guard canOpenLocalFiles else {
            presentError("Local files are unavailable on this profile.")
            return
        }
        if MacPlaybackFileTypes.subtitleExtensions.contains(url.pathExtension.lowercased()) {
            guard let session = MacPlaybackCoordinator.shared.session else {
                presentError("Open a video before adding subtitles.")
                return
            }
            session.addSubtitle(url)
            return
        }
        let allowedExtensions = Set(["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ogv", "vob"])
        guard allowedExtensions.contains(url.pathExtension.lowercased())
                || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else {
            presentError("This file is not a supported video or subtitle.")
            return
        }
        showMainWindow(reason: .localVideo)
        MacPlaybackCoordinator.shared.present(PlaybackRequest(url: url, title: url.deletingPathExtension().lastPathComponent))
    }

    @objc func openVideo(_ sender: Any?) {
        guard canOpenLocalFiles, openVideoPanel == nil else { return }
        showMainWindow(reason: .filePicker)
        guard let mainWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video] + ["mkv", "webm", "ts", "m2ts"].compactMap { UTType(filenameExtension: $0) }
        let owner = ProfileManager.shared.activeProfileID
        let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner)
        let windowGeneration = MacLaunchProfileAccess.windowGeneration
        openVideoPanel = panel
        panel.beginSheetModal(for: mainWindow) { [weak self] response in
            self?.openVideoPanel = nil
            guard response == .OK, let url = panel.url, let authority,
                  ProgressManager.shared.profileMutationAuthorityIsCurrent(authority), mainWindow.isVisible,
                  windowGeneration == MacLaunchProfileAccess.windowGeneration else { return }
            self?.open(url)
        }
    }

    @objc func openSettings(_ sender: Any?) {
        guard !isTerminating else { return }
        showMainWindow(reason: .settings)
        guard !launchUnlockRequired else { showingProfiles = true; return }
        MacPlaybackCoordinator.shared.stopInlinePlayback()
        showingSettings = true
    }

    @objc func focusSearch(_ sender: Any?) {
        guard !isTerminating else { return }
        showMainWindow(reason: .search)
        guard !launchUnlockRequired else { showingProfiles = true; return }
        MacPlaybackCoordinator.shared.stopInlinePlayback()
        showingSettings = false
        if isReaderMode {
            readerSession.close()
            readerSection = .search
            readerSearchFocusRequest &+= 1
        } else {
            mediaSection = .search
            mediaSearchFocusRequest &+= 1
        }
    }

    @objc func toggleSidebar(_ sender: Any?) { sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all }
    @objc func toggleFullscreen(_ sender: Any?) { mainWindow?.toggleFullScreen(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isTerminating else { return false }
        if menuItem.action == #selector(openVideo(_:)) { return canOpenLocalFiles }
        if menuItem.action == #selector(toggleFullscreen(_:)) {
            menuItem.title = localizedMenuTitle(mainWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen")
            return mainWindow?.isVisible == true
        }
        return true
    }

    func installMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let title = localizedMenuTitle(title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            bar.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: localizedMenuTitle(title), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        let app = menu("Eclipse")
        item(app, "About Eclipse", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Settings…", #selector(openSettings(_:)), ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: localizedMenuTitle("Services"))
        let servicesItem = NSMenuItem(title: localizedMenuTitle("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApplication.shared.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide Eclipse", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit Eclipse", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "Open Video…", #selector(openVideo(_:)), "o", target: self)
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find", #selector(focusSearch(_:)), "f", target: self)
        let view = menu("View")
        item(view, "Toggle Sidebar", #selector(toggleSidebar(_:)), "s", [.command, .option], target: self)
        item(view, "Enter Full Screen", #selector(toggleFullscreen(_:)), "f", [.command, .control], target: self)
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApplication.shared.windowsMenu = window
        NSApplication.shared.mainMenu = bar
    }

    private func localizedMenuTitle(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

extension Notification.Name {
    static let macMainWindowClosed = Notification.Name("EclipseMacMainWindowClosed")
}
