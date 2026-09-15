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
        splitView.autosaveName = "EclipseMacNavigationRail"
        sidebarItem.minimumThickness = 84
        sidebarItem.maximumThickness = 84
        sidebarItem.automaticMaximumThickness = 84
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

    @FocusState private var focusedItem: String?

    private var accent: Color {
        coordinator.isReaderMode ? settings.readerAccentColor : settings.accentColor
    }

    var body: some View {
        VStack(spacing: 12) {
            Menu {
                Button { coordinator.setMode(reader: false) } label: {
                    Label("Media", systemImage: coordinator.isReaderMode ? "film" : "checkmark")
                }
                Button { coordinator.setMode(reader: true) } label: {
                    Label("Reader", systemImage: coordinator.isReaderMode ? "checkmark" : "book")
                }
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: coordinator.isReaderMode ? "book.closed" : "play.rectangle")
                        .font(.system(size: 21, weight: .medium))
                    HStack(spacing: 3) {
                        Text(coordinator.isReaderMode ? "Reader" : "Media")
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }.font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(accent)
                .frame(width: 64, height: 56)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Switch between Media and Reader")
            .accessibilityLabel("Mode")
            .accessibilityValue(coordinator.isReaderMode ? "Reader" : "Media")
            .accessibilityIdentifier("mac.mode")

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 14)

            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    if coordinator.isReaderMode {
                        ForEach(MacReaderSection.allCases) { section in
                            railButton(title: section.title, symbol: readerSymbol(section),
                                       id: "reader.\(section.rawValue)", selected: readerSelection.wrappedValue == section) {
                                readerSelection.wrappedValue = section
                            }
                        }
                    } else {
                        ForEach(MacMediaSection.allCases) { section in
                            railButton(title: section.title, symbol: section.symbol,
                                       id: "media.\(section.rawValue)", selected: mediaSelection.wrappedValue == section) {
                                mediaSelection.wrappedValue = section
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            VStack(spacing: 4) {
                Button { coordinator.showingProfiles = true } label: {
                    VStack(spacing: 5) {
                        if let profile = profiles.activeProfile {
                            ProfileAvatarView(profile: profile, size: 26)
                            Text(profile.name).lineLimit(1)
                        } else {
                            Image(systemName: "person.crop.circle").font(.system(size: 23))
                            Text("Profiles")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 64, height: 54)
                }
                .buttonStyle(MacRailButtonStyle(selected: coordinator.showingProfiles, accent: accent, focused: focusedItem == "profiles"))
                .focusable()
                .focusEffectDisabled()
                .focused($focusedItem, equals: "profiles")
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard !coordinator.launchUnlockRequired, !coordinator.isTerminating else { return .ignored }
                    coordinator.showingProfiles = true
                    return .handled
                }
                .help("Switch profile")
                .accessibilityIdentifier("mac.profile")

                railButton(title: "Settings", symbol: "gearshape", id: "settings", selected: coordinator.showingSettings) {
                    coordinator.openSettings(nil)
                }
                .help("Settings (⌘,)")
            }
        }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .disabled(coordinator.launchUnlockRequired || coordinator.isTerminating)
        .accessibilityHidden(coordinator.launchUnlockRequired)
        .background { Color(red: 0.045, green: 0.043, blue: 0.065).ignoresSafeArea() }
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1).ignoresSafeArea() }
        .modifier(MacShellEnvironment(coordinator: coordinator, isActive: coordinator.isActive && coordinator.mainContentIsVisible))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            coordinator.open(url)
            return true
        }
    }

    private func railButton(title: String, symbol: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            focusedItem = id
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20, weight: selected ? .semibold : .regular))
                    .frame(height: 23)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64, height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(MacRailButtonStyle(selected: selected, accent: accent, focused: focusedItem == id))
        .focusable()
        .focusEffectDisabled()
        .focused($focusedItem, equals: id)
        .onKeyPress(keys: [.space, .return]) { _ in
            guard !coordinator.launchUnlockRequired, !coordinator.isTerminating else { return .ignored }
            focusedItem = id
            action()
            return .handled
        }
        .help(LocalizedStringKey(title))
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("mac.rail.\(id)")
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let focusedItem, !coordinator.launchUnlockRequired, !coordinator.isTerminating else { return .ignored }
        if coordinator.isReaderMode {
            let sections = MacReaderSection.allCases
            guard let index = sections.firstIndex(where: { "reader.\($0.rawValue)" == focusedItem }) else { return .ignored }
            let nextIndex = min(max(index + offset, 0), sections.count - 1)
            guard nextIndex != index else { return .handled }
            let section = sections[nextIndex]
            self.focusedItem = "reader.\(section.rawValue)"
            readerSelection.wrappedValue = section
        } else {
            let sections = MacMediaSection.allCases
            guard let index = sections.firstIndex(where: { "media.\($0.rawValue)" == focusedItem }) else { return .ignored }
            let nextIndex = min(max(index + offset, 0), sections.count - 1)
            guard nextIndex != index else { return .handled }
            let section = sections[nextIndex]
            self.focusedItem = "media.\(section.rawValue)"
            mediaSelection.wrappedValue = section
        }
        return .handled
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

private struct MacRailButtonStyle: ButtonStyle {
    let selected: Bool
    let accent: Color
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        RailContent(label: configuration.label, selected: selected, accent: accent, focused: focused, pressed: configuration.isPressed)
    }

    private struct RailContent: View {
        let label: ButtonStyleConfiguration.Label
        let selected: Bool
        let accent: Color
        let focused: Bool
        let pressed: Bool
        @State private var hovered = false

        var body: some View {
            label
                .foregroundStyle(selected ? accent : .white.opacity(hovered ? 0.98 : 0.62))
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? accent.opacity(pressed ? 0.24 : 0.14) : .white.opacity(pressed ? 0.12 : hovered ? 0.065 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? accent : .clear, lineWidth: 2)
                }
                .onHover { hovered = $0 }
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
