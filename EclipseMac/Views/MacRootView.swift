import AppKit
import Combine
import SwiftUI

@MainActor
final class MacAppKitShellController: NSSplitViewController {
    private let coordinator: MacWindowCoordinator
    private let content: MacContentContainer
    private let sidebarHost: NSHostingController<MacSidebarView>
    private let sidebarItem: NSSplitViewItem
    private var observers: [AnyCancellable] = []
    private var updateScheduled = false
    private var settingSidebar = false

    init(coordinator: MacWindowCoordinator) {
        self.coordinator = coordinator
        content = MacContentContainer(coordinator: coordinator)
        sidebarHost = NSHostingController(rootView: MacSidebarView(coordinator: coordinator))
        sidebarHost.sceneBridgingOptions = []
        sidebarHost.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "EclipseMacSidebar"
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 290
        sidebarItem.preferredThicknessFraction = 0.19
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: content)
        detailItem.minimumThickness = 420
        addSplitViewItem(detailItem)
        coordinator.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        MacPlaybackCoordinator.shared.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        LocalizationManager.shared.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification, object: splitView)
            .sink { [weak self] _ in
                guard let self, !settingSidebar else { return }
                let visibility: NavigationSplitViewVisibility = sidebarItem.isCollapsed ? .detailOnly : .all
                if coordinator.sidebarVisibility != visibility { coordinator.sidebarVisibility = visibility }
            }.store(in: &observers)
        updateShell()
    }

    required init?(coder: NSCoder) { nil }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            updateShell()
        }
    }

    private func updateShell() {
        splitView.userInterfaceLayoutDirection = LocalizationManager.shared.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        let collapsed = coordinator.sidebarVisibility == .detailOnly
        if sidebarItem.isCollapsed != collapsed {
            settingSidebar = true
            sidebarItem.isCollapsed = collapsed
            settingSidebar = false
        }
        content.updateSelection()
    }
}

private enum MacContentRole: Hashable {
    case media, reader, settings

    @MainActor static func selected(in coordinator: MacWindowCoordinator) -> MacContentRole {
        coordinator.showingSettings ? .settings : coordinator.isReaderMode ? .reader : .media
    }
}

@MainActor
private final class MacContentContainer: NSViewController, NSToolbarDelegate {
    private let coordinator: MacWindowCoordinator
    private var hosts: [MacContentRole: NSHostingController<MacContentRootView>] = [:]
    private var selectedHost: NSHostingController<MacContentRootView>?
    private var playerHost: NSHostingController<MacPlayerRootView>?
    private var playerID: UUID?
    private weak var toolbarOwner: NSViewController?
    private let presentation: NSViewController
    private let presentationView: MacPresentationHostingView
    private var metricsScheduled = false
    private static let playerSidebarIdentifier = NSToolbarItem.Identifier("EclipseMacPlaybackSidebar")
    private lazy var playerToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "EclipseMacPlaybackToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }()

    init(coordinator: MacWindowCoordinator) {
        self.coordinator = coordinator
        presentationView = MacPresentationHostingView(rootView: MacRootView(coordinator: coordinator))
        presentationView.sceneBridgingOptions = []
        presentationView.sizingOptions = []
        presentation = NSViewController()
        presentation.view = presentationView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        attach(presentation)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !metricsScheduled else { return }
        metricsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            metricsScheduled = false
            coordinator.updateContentMetrics(view.safeAreaRect.size)
        }
    }

    func updateSelection() {
        loadViewIfNeeded()
        let playback = MacPlaybackCoordinator.shared
        var hierarchyChanged = false
        presentationView.acceptsInput = coordinator.launchUnlockRequired || coordinator.isTerminating
        if playerID != playback.session?.id {
            hierarchyChanged = true
            if let playerHost {
                playerHost.sceneBridgingOptions = []
                detach(playerHost)
            }
            playerHost = nil
            playerID = playback.session?.id
            if let session = playback.session {
                let host = NSHostingController(rootView: MacPlayerRootView(coordinator: coordinator, session: session))
                host.sceneBridgingOptions = []
                host.sizingOptions = []
                playerHost = host
                attach(host)
            }
        }
        let inline = playback.isInlinePlaybackVisible && playerHost != nil
        let next: NSHostingController<MacContentRootView>?
        if inline {
            next = nil
        } else {
            let role = MacContentRole.selected(in: coordinator)
            if let host = hosts[role] {
                next = host
            } else {
                let host = NSHostingController(rootView: MacContentRootView(coordinator: coordinator, role: role))
                host.sceneBridgingOptions = []
                host.sizingOptions = []
                hosts[role] = host
                next = host
            }
        }
        let nextOwner: NSViewController? = inline ? playerHost : next
        let ownerChanged = toolbarOwner !== nextOwner
        if ownerChanged {
            selectedHost?.sceneBridgingOptions = []
            playerHost?.sceneBridgingOptions = []
            view.window?.toolbar = nil
            if !inline {
                view.window?.title = Bundle.main.localizedString(forKey: "Eclipse", value: "Eclipse", table: nil)
            }
        }
        if selectedHost !== next {
            hierarchyChanged = true
            if let selectedHost { detach(selectedHost) }
            selectedHost = next
            if let next {
                attach(next)
                let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    && ModeSwitchAnimationSettings.isEnabled(defaults: ProfileSettingsStore.active)
                if animated, ownerChanged, view.window?.isVisible == true {
                    next.view.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        next.view.animator().alphaValue = 1
                    }
                } else { next.view.alphaValue = 1 }
            }
        }
        if let playerHost {
            playerHost.view.setAccessibilityHidden(!inline)
        }
        if hierarchyChanged {
            if let playerHost, let selectedHost {
                view.addSubview(playerHost.view, positioned: .below, relativeTo: selectedHost.view)
            }
            view.addSubview(presentation.view, positioned: .above, relativeTo: nil)
        }
        if ownerChanged {
            toolbarOwner = nextOwner
            if !inline { selectedHost?.sceneBridgingOptions = [.title, .toolbars] }
        }
        if inline, let session = playback.session, let window = view.window {
            if window.toolbar !== playerToolbar { window.toolbar = playerToolbar }
            let title = session.request.title.isEmpty ? "Eclipse" : session.request.title
            if window.title != title { window.title = title }
            for item in playerToolbar.items where item.itemIdentifier == Self.playerSidebarIdentifier {
                let label = Bundle.main.localizedString(forKey: "Toggle Sidebar", value: "Toggle Sidebar", table: nil)
                if item.label != label {
                    item.label = label
                    item.paletteLabel = label
                    item.toolTip = label
                    (item.view as? NSButton)?.setAccessibilityLabel(label)
                }
                (item.view as? NSButton)?.isEnabled = !coordinator.isTerminating && !coordinator.launchUnlockRequired
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.playerSidebarIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.playerSidebarIdentifier else { return nil }
        let label = Bundle.main.localizedString(forKey: "Toggle Sidebar", value: "Toggle Sidebar", table: nil)
        let button = NSButton(title: label, target: coordinator, action: #selector(MacWindowCoordinator.toggleSidebar(_:)))
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
        button.imagePosition = button.image == nil ? .noImage : .imageOnly
        button.bezelStyle = .texturedRounded
        button.setAccessibilityIdentifier("mac.sidebar.toggle")
        button.setAccessibilityLabel(label)
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.view = button
        return item
    }

    private func attach(_ controller: NSViewController) {
        if controller.parent !== self { addChild(controller) }
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func detach(_ controller: NSViewController) {
        if let responder = view.window?.firstResponder as? NSView,
           responder.isDescendant(of: controller.view) {
            view.window?.makeFirstResponder(nil)
        }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }
}

@MainActor
private final class MacPresentationHostingView: NSHostingView<MacRootView> {
    var acceptsInput = false
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsInput ? super.hitTest(point) : nil }
}

private struct MacShellEnvironment: ViewModifier {
    @ObservedObject var coordinator: MacWindowCoordinator
    let isActive: Bool
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @ObservedObject private var localization = LocalizationManager.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .tint(coordinator.isReaderMode ? settings.readerAccentColor : settings.accentColor)
            .environmentObject(settings)
            .environmentObject(theme)
            .environmentObject(localization)
            .environmentObject(TrackerManager.shared)
            .environmentObject(profiles)
            .environment(\.locale, localization.locale)
            .environment(\.layoutDirection, localization.layoutDirection)
            .environment(\.scenePhase, isActive ? .active : .inactive)
            .environment(\.eclipseWindowSceneSessionIdentifier, MacWindowCoordinator.presentationIdentifier)
            .environment(\.macWindowSize, coordinator.contentSize)
            .environment(\.displayScale, coordinator.displayScale)
            .defaultAppStorage(ProfileSettingsStore.active)
    }
}

private struct MacContentRootView: View {
    @ObservedObject var coordinator: MacWindowCoordinator
    let role: MacContentRole
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var player = MacPlaybackCoordinator.shared
    @Namespace private var heroNamespace

    var body: some View {
        surface
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .modifier(MacNavigationToolbar())
            .disabled(coordinator.launchUnlockRequired || coordinator.isTerminating)
            .accessibilityHidden(coordinator.launchUnlockRequired)
            .modifier(MacShellEnvironment(coordinator: coordinator, isActive: isActive))
            .heroNamespace(heroNamespace)
            .id(profiles.activeProfileID)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                coordinator.open(url)
                return true
            }
    }

    @ViewBuilder private var surface: some View {
        switch role {
        case .media:
            mediaSurface.environment(\.macSearchFocusRequest, coordinator.mediaSearchFocusRequest)
        case .reader:
            NavigationStack {
                MacReaderRootView(section: $coordinator.readerSection, session: coordinator.readerSession, isActive: isActive)
            }.environment(\.macSearchFocusRequest, coordinator.readerSearchFocusRequest)
        case .settings:
            SettingsView(onRootDismiss: { coordinator.showingSettings = false })
        }
    }

    private var isActive: Bool {
        MacContentRole.selected(in: coordinator) == role && !player.isInlinePlaybackVisible
            && coordinator.isActive && coordinator.mainContentIsVisible
            && !coordinator.launchUnlockRequired && !coordinator.isTerminating
    }

    @ViewBuilder private var mediaSurface: some View {
        switch coordinator.mediaSection {
        case .home: HomeView(isActive: isActive)
        case .search: SearchView()
        case .library: LibraryView()
        case .schedule: ScheduleView(isActive: isActive)
        case .downloads: DownloadsView()
        }
    }

}

private struct MacPlayerRootView: View {
    @ObservedObject var coordinator: MacWindowCoordinator
    @ObservedObject var session: MacPlaybackSession
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        MacPlayerView(session: session)
            .opacity(session.isPictureInPicture ? 0 : 1)
            .allowsHitTesting(!session.isPictureInPicture)
            .accessibilityHidden(session.isPictureInPicture || coordinator.launchUnlockRequired)
            .disabled(coordinator.launchUnlockRequired || coordinator.isTerminating)
            .modifier(MacShellEnvironment(coordinator: coordinator,
                isActive: coordinator.isActive && coordinator.mainContentIsVisible && !session.isPictureInPicture))
            .id(profiles.activeProfileID)
    }
}

private struct MacSidebarView: View {
    @ObservedObject var coordinator: MacWindowCoordinator
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var player = MacPlaybackCoordinator.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "moonphase.waning.crescent").font(.title2).foregroundStyle(settings.accentColor)
                Text("Eclipse").font(.title2.weight(.semibold))
                Spacer()
            }.padding(.top, 18)
            Picker("Mode", selection: Binding(get: { coordinator.isReaderMode }, set: { coordinator.setMode(reader: $0) })) {
                Text("Media").tag(false)
                Text("Reader").tag(true)
            }.pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("mac.mode")
            if coordinator.isReaderMode {
                List(selection: readerSelection) {
                    ForEach(MacReaderSection.allCases) { section in
                        Label(LocalizedStringKey(section.title), systemImage: readerSymbol(section)).tag(section)
                    }
                }.listStyle(.sidebar)
            } else {
                List(selection: mediaSelection) {
                    ForEach(MacMediaSection.allCases) { section in
                        Label(LocalizedStringKey(section.title), systemImage: section.symbol).tag(section)
                    }
                }.listStyle(.sidebar)
            }
            Spacer(minLength: 0)
            Button { coordinator.showingProfiles = true } label: {
                HStack {
                    if let profile = profiles.activeProfile {
                        ProfileAvatarView(profile: profile, size: 30)
                        Text(profile.name)
                    } else { Label("Profiles", systemImage: "person.crop.circle") }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Switch profile")
            Button { coordinator.openSettings(nil) } label: {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).help("Settings (⌘,)")
        }
        .padding(16)
        .disabled(coordinator.launchUnlockRequired || coordinator.isTerminating)
        .accessibilityHidden(coordinator.launchUnlockRequired)
        .background { SettingsGradientBackground().ignoresSafeArea() }
        .modifier(MacShellEnvironment(coordinator: coordinator, isActive: coordinator.isActive && coordinator.mainContentIsVisible))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            coordinator.open(url)
            return true
        }
    }

    private var mediaSelection: Binding<MacMediaSection?> {
        Binding(get: {
            coordinator.showingSettings || player.isInlinePlaybackVisible ? nil : coordinator.mediaSection
        }, set: { section in
            guard let section, !coordinator.launchUnlockRequired, !coordinator.isTerminating else { return }
            player.stopInlinePlayback()
            coordinator.showingSettings = false
            coordinator.mediaSection = section
        })
    }

    private var readerSelection: Binding<MacReaderSection?> {
        Binding(get: {
            coordinator.showingSettings || player.isInlinePlaybackVisible ? nil : coordinator.readerSection
        }, set: { section in
            guard let section, !coordinator.launchUnlockRequired, !coordinator.isTerminating else { return }
            player.stopInlinePlayback()
            coordinator.readerSession.close()
            coordinator.showingSettings = false
            coordinator.readerSection = section
        })
    }

    private func readerSymbol(_ section: MacReaderSection) -> String {
        switch section {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .settings: return "puzzlepiece.extension"
        }
    }
}

struct MacRootView: View {
    @ObservedObject var coordinator: MacWindowCoordinator
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var player = MacPlaybackCoordinator.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var onboardingVisible = !UserDefaults.standard.bool(forKey: OnboardingState.completedKey)
    @State private var launchProfileChecked = false
    @AppStorage("showKanzen", store: .standard) private var requestedReaderMode = false
    @Namespace private var heroNamespace

    var body: some View {
        Color.clear
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("mac.shell")
        .overlay {
            if coordinator.launchUnlockRequired {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.largeTitle)
                    Text("Unlock your profile to continue.")
                    Button("Unlock Profile") { coordinator.showingProfiles = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .accessibilityIdentifier("mac.profile.locked")
            } else if coordinator.isTerminating {
                ProgressView("Saving Eclipse…")
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .modifier(AppPerformanceOverlayPresentation(startupReady: true, homeHydrationComplete: true, splashVisible: false, appMode: coordinator.isReaderMode ? "reader" : "media", modeSwitchActive: false))
        .id(profiles.activeProfileID)
        .onChange(of: profiles.activeProfileID) { _, _ in
            player.stopAll()
            coordinator.readerSession.close()
        }
        .onChange(of: requestedReaderMode) { _, reader in coordinator.setMode(reader: reader) }
        .onChange(of: localization.locale) { _, _ in coordinator.installMenus() }
        .onChange(of: onboardingVisible) { _, visible in
            if !visible { coordinator.showingProfiles = coordinator.launchUnlockRequired || profiles.shouldPresentLaunchPicker }
        }
        .onAppear {
            guard !launchProfileChecked else { return }
            launchProfileChecked = true
            coordinator.showingProfiles = coordinator.launchUnlockRequired || (!onboardingVisible && profiles.shouldPresentLaunchPicker)
        }
        .sheet(isPresented: $coordinator.showingProfiles) {
            ProfilePickerView(isReaderMode: coordinator.isReaderMode, autoUnlockProfile: profiles.launchProfileRequiringUnlock) {
                coordinator.launchUnlockRequired = false
                coordinator.showingProfiles = false
            }.frame(minWidth: 560, minHeight: 420)
                .interactiveDismissDisabled(coordinator.launchUnlockRequired)
        }
        .sheet(isPresented: $onboardingVisible) {
            OnboardingView { onboardingVisible = false }
                .frame(width: 720, height: 660)
                .interactiveDismissDisabled()
        }
        .modifier(MacWatchTogetherJoinPresentation())
        .alert("Eclipse", isPresented: Binding(get: { coordinator.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { coordinator.errorMessage = nil; player.errorMessage = nil } })) {
            Button("OK") { coordinator.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(coordinator.errorMessage ?? player.errorMessage ?? "") }
        .heroNamespace(heroNamespace)
        .modifier(MacShellEnvironment(coordinator: coordinator, isActive: windowIsActive))
    }

    private var windowIsActive: Bool {
        coordinator.isActive && coordinator.mainContentIsVisible
            && !coordinator.launchUnlockRequired && !coordinator.isTerminating
    }
}

private struct MacNavigationToolbar: ViewModifier {
    @ObservedObject private var coordinator = MacWindowCoordinator.shared
    @ObservedObject private var player = MacPlaybackCoordinator.shared

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                Button { coordinator.toggleSidebar(nil) } label: { Label("Toggle Sidebar", systemImage: "sidebar.left") }
                    .help("Toggle Sidebar")
                    .accessibilityIdentifier("mac.sidebar.toggle")
            }
            if !player.isInlinePlaybackVisible {
                ToolbarItem(placement: .primaryAction) {
                    Button { coordinator.focusSearch(nil) } label: { Label("Search", systemImage: "magnifyingglass") }
                        .help("Search (⌘F)")
                }
            }
        }
    }
}

private struct MacWindowSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 1200, height: 800)
}

private struct MacSearchFocusRequestKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var macSearchFocusRequest: UInt64 {
        get { self[MacSearchFocusRequestKey.self] }
        set { self[MacSearchFocusRequestKey.self] = newValue }
    }
    var macWindowSize: CGSize {
        get { self[MacWindowSizeKey.self] }
        set { self[MacWindowSizeKey.self] = newValue }
    }
}
