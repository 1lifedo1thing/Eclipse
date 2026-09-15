#if os(macOS)
import AppKit
import CloudKit
import SwiftUI

enum MacReaderSection: String, CaseIterable, Identifiable {
    case home, library, search, history, downloads, settings
    var id: String { rawValue }
    var title: String { self == .settings ? "Sources" : rawValue.capitalized }
}

private struct MacReaderActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var macReaderIsActive: Bool {
        get { self[MacReaderActivityKey.self] }
        set { self[MacReaderActivityKey.self] = newValue }
    }
}

struct MacReaderRootView: View {
    @Binding var section: MacReaderSection
    @ObservedObject var session: MacReaderSession
    var isActive = true
    @ObservedObject private var settings = Settings.shared
    @State private var selection: MangaLibraryItem?
    @State private var downloadedSelection: ReaderDownloadedTitle?
    @State private var seed: ReaderExtensionItem?
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var consent = ReaderExtensionDomainConsentCoordinator.shared
    @State private var consentError: String?
    @StateObject private var maintenance = MacReaderMaintenance()

    var body: some View {
        Group {
            if profiles.isKidsModeActive && (section == .home || section == .search) { ContentUnavailableView("Reader Discovery", systemImage: "lock", description: Text("Switch to a grown-up profile to discover Reader sources. Saved titles and completed downloads remain available.")) }
            else if session.isReading {
                MacReaderView(session: session)
            } else if let downloadedSelection {
                MacReaderDownloadedTitleView(title: downloadedSelection, session: session) { self.downloadedSelection = nil }
            } else if let selection {
                MacReaderDetailView(item: selection, seed: seed, session: session) { self.selection = nil }
            } else {
                switch section {
                case .home: MacReaderHomeView(open: open)
                case .library: MacReaderLibraryView(open: { self.selection = $0; seed = nil })
                case .search: MacReaderSearchView(open: open)
                case .history: MacReaderHistoryView(open: { self.selection = $0; seed = nil })
                case .downloads: MacReaderDownloadsView(open: { downloadedSelection = $0; selection = nil; seed = nil })
                case .settings: MacReaderSourcesSettingsView()
                }
            }
        }
        .id(profiles.activeProfileID)
        .navigationTitle(navigationTitle)
        .environment(\.macReaderIsActive, isActive)
        .disabled(!isActive)
        .background(SettingsGradientBackground(allowsAnimatedBackground: isActive))
        .preferredColorScheme(settings.effectiveAppearance == .system ? nil : settings.effectiveAppearance == .dark ? .dark : .light)
        .safeAreaInset(edge: .bottom) {
            if let error = session.persistenceError { HStack { Text(error).foregroundStyle(.red); Spacer(); Button("Retry Saving") { session.flushForMacTermination() } }.padding().background(.regularMaterial) }
        }
        .onChange(of: section) { _ in selection = nil; downloadedSelection = nil; seed = nil; session.close() }
        .task(id: "\(isActive):\(profiles.activeProfileID)") { if isActive { await maintenance.run() } }
        .onChange(of: isActive) { active in if !active { maintenance.cancel(); session.autoScroll = false; ReaderExtensionCloudflareVerificationCoordinator.shared.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in selection = nil; downloadedSelection = nil; seed = nil; session.close() }
        .onChange(of: profiles.activeProfileID) { _ in selection = nil; downloadedSelection = nil; seed = nil; session.close() }
        .alert("Allow Source Domain", isPresented: Binding(get: { isActive && consent.pendingRequest != nil }, set: { if !$0 { consent.deferCurrentRequest() } })) {
            Button("Not Now", role: .cancel) { consent.deferCurrentRequest() }
            Button("Allow") {
                guard let request = consent.pendingRequest else { return }
                do { try ReaderExtensionManager.shared.approve(request) } catch { consentError = error.localizedDescription }
                consent.deferCurrentRequest()
            }.disabled(profiles.isKidsModeActive)
        } message: {
            Text(consent.pendingRequest.map { "This Reader source needs access to \($0.host) to continue." } ?? "")
        }
        .alert("Reader", isPresented: Binding(get: { consentError != nil }, set: { if !$0 { consentError = nil } })) {
            Button("OK") { consentError = nil }
        } message: { Text(consentError ?? "") }
    }

    private var navigationTitle: Text {
        if let reader = session.reader { return Text(reader.mangaTitle) }
        if let downloadedSelection { return Text(downloadedSelection.title) }
        if let selection { return Text(selection.title) }
        return Text(LocalizedStringKey(section.title))
    }

    private func open(_ item: MangaHomeItem) {
        guard isActive, !item.isContainer, let route = item.route else { return }
        switch route {
        case .readerExtension(let source, let key, let legacy):
            selection = .fromReaderExtension(sourceID: source, itemKey: key, legacyStableKey: legacy, title: item.title, coverURL: item.imageURL, sourceName: ReaderExtensionManager.shared.source(for: source)?.name, contentRating: item.readerExtensionItem.map { ReaderContentFilter.shared.derivedReaderExtensionRating(for: $0) })
        case .legacyModule(let module, let params, let novel):
            guard let id = UUID(uuidString: module) else { return }
            selection = .fromModule(moduleId: id, contentId: params, title: item.title, coverURL: item.imageURL, isNovel: novel)
        case .aidoku: return
        }
        seed = item.readerExtensionItem
    }
}

@MainActor
private final class MacReaderMaintenance: ObservableObject {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    init() {
        observers = [Notification.Name.activeProfileDidChange, ServiceStoreScope.didChangeNotification, .CKAccountChanged, .NSUbiquityIdentityDidChange, .macMainWindowClosed].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        }
    }

    deinit { task?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    func run() async {
        guard task == nil, let authority = MacDownloadStorageAuthority.capture() else { return }
        let token = UUID()
        generation = token
        let pending = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.task = nil } }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, token == self.generation, authority.isCurrent() else { return }
            await ModuleManager.shared.autoUpdateModulesIfNeeded()
            guard !Task.isCancelled, token == self.generation, authority.isCurrent() else { return }
            await ReaderExtensionManager.shared.performMacAutomaticMaintenance()
        }
        task = pending
        await pending.value
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        ModuleManager.shared.cancelMacAutomaticUpdates()
    }
}

struct MacReaderPoster: View {
    let title: String
    let url: String?
    var sourceID: ReaderExtensionSourceID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReaderScopedRemoteImage(url: url.flatMap(URL.init(string:)), readerExtensionSourceID: sourceID) {
                RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.15)).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }
            .scaledToFill().frame(height: 220).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 148).contentShape(Rectangle())
    }
}

private struct MacReaderFeaturedCard: View {
    let item: MangaHomeItem
    let source: ReaderExtensionSourceID?
    var body: some View {
        ReaderScopedRemoteImage(url: URL(string: item.imageURL), readerExtensionSourceID: source) { Color.purple.opacity(0.15) }
            .scaledToFill().frame(width: 320, height: 210).clipped()
            .overlay(alignment: .bottomLeading) {
                Text(item.title).font(.title2.bold()).foregroundStyle(.white).lineLimit(3).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            }.clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel(item.title)
    }
}

private struct MacReaderHomeView: View {
    let open: (MangaHomeItem) -> Void
    @Environment(\.macReaderIsActive) private var isActive
    @StateObject private var model = MangaHomeViewModel()
    @ObservedObject private var sources = ReaderExtensionManager.shared
    @ObservedObject private var modules = ModuleManager.shared
    @State private var expanded: MangaHomeSection?
    @ObservedObject private var catalogs = KanzenCustomCatalogManager.shared
    @State private var catalogsChanged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Discover").font(.largeTitle.bold())
                    Spacer()
                    Picker("Source", selection: Binding(get: { model.selectedSourceID ?? "" }, set: { value in if let source = model.sources.first(where: { $0.id == value }) { model.selectSource(source) } })) {
                        ForEach(model.sources) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 320)
                    Button { if let source = model.selectedSource { model.loadHome(for: source, force: true, allowsAutomaticBrowserVerification: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh source")
                }
                if model.sources.isEmpty {
                    ContentUnavailableView("Add a Reader Source", systemImage: "books.vertical", description: Text("Install a source from a repository in Reader settings to discover manga and novels."))
                } else if let source = model.selectedSource {
                    if let state = model.loadStates[source.id] {
                        switch state {
                        case .loading: ProgressView("Loading \(source.name)…")
                        case .failed(let error), .browserVerificationRequired(let error): Text(error).foregroundStyle(.secondary)
                        case .unsupported: Text("This source has no Discover feed.").foregroundStyle(.secondary)
                        default: EmptyView()
                        }
                    }
                    ForEach(model.sectionsBySource[source.id] ?? []) { row in
                        VStack(alignment: .leading, spacing: 14) {
                            Button { expanded = row } label: { HStack { Text(row.title).font(.title2.bold()); Image(systemName: "chevron.right"); Spacer() } }.buttonStyle(.plain)
                            if row.items.isEmpty { Text(row.placeholderMessage ?? "No results").foregroundStyle(.secondary) }
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 18) {
                                    ForEach(row.items.prefix(MangaHomeViewModel.maxVisibleItemsPerSection)) { item in
                                        Button {
                                            if item.isContainer {
                                                expanded = MangaHomeSection.section(title: item.title, id: item.id, kind: .custom, items: [], readerExtensionQuery: item.readerExtensionQuery)
                                            } else { open(item) }
                                        } label: {
                                            if item.isContainer { Text(item.title).font(.headline).padding(22).background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 12)) }
                                            else if row.displayStyle == .featured { MacReaderFeaturedCard(item: item, source: source.sourceID) }
                                            else { MacReaderPoster(title: item.title, url: item.imageURL, sourceID: source.sourceID) }
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(28)
        }
        .task { refresh() }
        .onReceive(sources.$installedSources) { _ in refresh() }
        .onReceive(catalogs.$catalogs) { _ in if isActive { model.reloadForCatalogChange() } else { catalogsChanged = true } }
        .onChange(of: isActive) { active in if active { refresh() } else { model.suspendMacLoads(); expanded = nil } }
        .onDisappear { model.suspendMacLoads(); expanded = nil }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in model.discardCachedSections(); expanded = nil }
        .sheet(item: $expanded) { row in
            if let source = model.selectedSource { MacReaderSectionView(source: source, section: row, open: { expanded = nil; open($0) }) }
        }
    }

    private func refresh() {
        guard isActive else { return }
        model.updateSources(MangaHomeSourceManager.shared.enabledSources(readerExtensionManager: sources, modules: modules.modules))
        if catalogsChanged { catalogsChanged = false; model.reloadForCatalogChange() }
        else { model.loadSelectedSource() }
    }
}

private struct MacReaderSectionView: View {
    let source: MangaHomeSource
    let section: MangaHomeSection
    let open: (MangaHomeItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macReaderIsActive) private var isActive
    @State private var items: [MangaHomeItem] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack {
            HStack { Text(section.title).font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 18)], spacing: 22) {
                    ForEach(items) { item in Button { open(item) } label: { MacReaderPoster(title: item.title, url: item.imageURL, sourceID: source.sourceID) }.buttonStyle(.plain) }
                }.padding()
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView() }
                if hasMore, !loading { Button("Load More", action: startLoading).padding() }
            }
        }.frame(minWidth: 700, minHeight: 550).onAppear(perform: startLoading)
        .onDisappear(perform: cancel)
        .onChange(of: isActive) { active in if !active { cancel(); dismiss() } }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancel(); dismiss() }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
    private func startLoading() {
        guard isActive, !loading, hasMore, let authority = MacDownloadStorageAuthority.capture() else { return }
        loading = true
        let token = generation
        task = Task { @MainActor in
            defer { if token == generation { loading = false; task = nil } }
            do {
                let result = try await MangaHomeViewModel.loadSectionItems(source: source, section: section, page: page + 1)
                try Task.checkCancellation()
                guard token == generation, authority.isCurrent() else { return }
                var ids = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { ids.insert($0.id).inserted }.prefix(max(0, 300 - items.count)))
                page += 1
                hasMore = result.sourceHasMore && page < 20 && items.count < 300
                error = nil
            } catch { if !Task.isCancelled, token == generation, authority.isCurrent() { self.error = error.localizedDescription } }
        }
    }
}

struct MacReaderSearchView: View {
    let open: (MangaHomeItem) -> Void
    var initialQuery = ""
    var includeLegacyModules = false
    @Environment(\.macReaderIsActive) private var isActive
    @StateObject private var global = MangaGlobalModuleSearchViewModel()
    @StateObject private var advanced = MangaReaderExtensionAdvancedSearchViewModel()
    @StateObject private var filters = ReaderExtensionFilterEditorModel()
    @State private var query = ""
    @State private var selectedSource = ""
    @State private var showsFilters = false
    @State private var catalogName = ""
    @State private var saveCatalog = false
    @State private var error: String?
    @State private var recent: [String] = []
    @State private var needsSearch = false
    @State private var submittedQuery: String?
    @State private var appliedInitialQuery = false
    @FocusState private var searchFocused: Bool
    @Environment(\.macSearchFocusRequest) private var searchFocusRequest
    @ObservedObject private var manager = ReaderExtensionManager.shared
    private var source: MangaHomeSource? { global.sources.first { $0.id == selectedSource } }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                TextField("Search manga and novels", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit(search).accessibilityIdentifier("mac.reader.search")
                Picker("Source", selection: $selectedSource) {
                    Text("All Sources").tag("")
                    ForEach(global.sources.filter(\.isReaderExtension)) { Text($0.name).tag($0.id) }
                }.frame(width: 240)
                if source?.sourceID != nil { Button("Filters") { showsFilters.toggle() } }
                Button("Search", action: search)
            }
            if showsFilters { ScrollView { ReaderExtensionFilterEditorList(filters: $filters.filters).padding() }.frame(maxHeight: 240) }
            if query.isEmpty, !recent.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Searches").font(.headline)
                        ForEach(recent, id: \.self) { value in Button(value) { query = value; search() }.buttonStyle(.plain) }
                    }
                    Spacer()
                    Button("Clear") { MangaSearchRecentStore.clear(); recent = [] }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let source {
                        if advanced.isSearching { ProgressView("Searching…") }
                        if let error = advanced.errorMessage { Text(error).foregroundStyle(.secondary) }
                        grid(advanced.items)
                        if advanced.canLoadMore { Button("Load More") { advanced.loadMore(source: source) } }
                        if advanced.appliedCatalogDraft != nil, !ProfileManager.shared.isKidsModeActive { Button("Save as Catalog") { saveCatalog = true } }
                    } else {
                        if global.isSearching { ProgressView("Searching sources…") }
                        ForEach(global.sections) { section in Text(section.source.name).font(.title2.bold()); grid(section.items) }
                        ForEach(global.failedSourceNames, id: \.self) { Text("\($0) could not finish searching.").foregroundStyle(.secondary) }
                    }
                }
            }
        }.padding(28)
        .task {
            if isActive {
                recent = MangaSearchRecentStore.load()
                global.refreshSources(from: ModuleManager.shared.modules, readerExtensionManager: manager, includeLegacyModules: includeLegacyModules)
                if !appliedInitialQuery {
                    appliedInitialQuery = true
                    query = initialQuery
                }
            }
        }
        .task(id: "\(isActive):\(query)") {
            guard isActive, query != submittedQuery || needsSearch else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, isActive else { return }
            search()
        }
        .onChange(of: selectedSource) { _ in
            filters.cancel()
            filters.filters = []
            saveCatalog = false
            if isActive, let id = source?.sourceID { filters.reload(sourceID: id, label: source?.name ?? "Source") }
            search()
        }
        .onDisappear(perform: suspend)
        .onChange(of: isActive) { active in
            if active {
                global.refreshSources(from: ModuleManager.shared.modules, readerExtensionManager: manager, includeLegacyModules: includeLegacyModules)
                if needsSearch { search() }
            } else { suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in global.cancelSearch(); advanced.cancel(); filters.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MacReaderFocusSearch"))) { _ in if isActive { searchFocused = true } }
        .task(id: "\(isActive):\(searchFocusRequest)") {
            await Task.yield()
            guard !Task.isCancelled, isActive else { return }
            searchFocused = searchFocusRequest != 0
        }
        .alert("Save Catalog", isPresented: $saveCatalog) {
            TextField("Catalog name", text: $catalogName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let id = source?.sourceID, let draft = advanced.appliedCatalogDraft else { return }
                do { try KanzenCustomCatalogManager.shared.save(KanzenCustomCatalog(title: catalogName, sourceID: id, query: draft.query, filters: draft.filters)) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Reader", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func search() {
        guard isActive, !ProfileManager.shared.isKidsModeActive else { return }
        global.refreshSources(from: ModuleManager.shared.modules, readerExtensionManager: manager, includeLegacyModules: includeLegacyModules)
        needsSearch = false
        submittedQuery = query
        if let source { global.cancelSearch(); advanced.search(source: source, query: query, filters: filters.filters) }
        else { advanced.cancel(); global.searchAll(query) }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recent = MangaSearchRecentStore.add(query) }
    }
    private func suspend() {
        needsSearch = needsSearch || global.isSearching || advanced.isSearching
        global.cancelSearch()
        advanced.cancel()
        filters.cancel()
        searchFocused = false
        saveCatalog = false
    }
    private func grid(_ items: [MangaHomeItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 18)], spacing: 22) {
            ForEach(items) { item in Button { open(item) } label: { MacReaderPoster(title: item.title, url: item.imageURL, sourceID: item.route?.readerExtensionSourceID) }.buttonStyle(.plain) }
        }
    }
}

private struct MacReaderLibraryView: View {
    @State private var trackerLibrarySource: TrackerLibrarySource = .local
    @AppStorage(TrackerLibrarySettings.enabledKey) private var deepLibraryEnabled = TrackerLibrarySettings.defaultEnabled
    @ObservedObject private var profiles = ProfileManager.shared
    let open: (MangaLibraryItem) -> Void
    @Environment(\.macReaderIsActive) private var isActive
    @ObservedObject private var library = MangaLibraryManager.shared
    @ObservedObject private var progress = MangaReadingProgressManager.shared
    @ObservedObject private var downloads = ReaderDownloadManager.shared
    @State private var collection: UUID?
    @State private var name = ""
    @State private var creating = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var query = ""
    @State private var refreshing = false
    @State private var refreshStatus: String?
    @State private var refreshTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Library").font(.largeTitle.bold())
                    Spacer()
                    Picker("Collection", selection: $collection) { Text("All Titles").tag(UUID?.none); ForEach(library.collections) { Text($0.name).tag(Optional($0.id)) } }.frame(width: 220)
                    TextField("Filter library", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Menu("Collections") {
                        Button("New Collection") { name = ""; creating = true }
                        if let current = library.collections.first(where: { $0.id == collection }), current.name != "Bookmarks" {
                            Button("Rename Collection") { name = current.name; renaming = true }
                            Button("Delete Collection", role: .destructive) { deleting = true }
                        }
                    }
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }.disabled(refreshing).help("Refresh saved sources")
                }
                if deepLibraryEnabled && !profiles.isKidsModeActive {
                    TrackerLibrarySourcePicker(selection: $trackerLibrarySource)
                }
                if deepLibraryEnabled && !profiles.isKidsModeActive, let service = trackerLibrarySource.service {
                    TrackerLibraryView(service: service, initialKind: .manga, isActive: isActive)
                        .id(service.rawValue)
                } else {
                if let refreshStatus { Text(refreshStatus).font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 18)], spacing: 22) {
                    ForEach(items) { item in
                        Button { open(item) } label: { MacReaderPoster(title: item.title, url: item.coverURL, sourceID: item.route?.readerExtensionSourceID) }.buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) {
                                let count = item.unreadCount(readChapters: progress.readChapters(for: item.id))
                                if count > 0 { Text(count.formatted()).font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4).background(.red, in: Capsule()).padding(6) }
                            }
                            .overlay(alignment: .topLeading) {
                                if downloads.isDownloaded(route: item.route) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white).padding(6).background(.black.opacity(0.6), in: Circle()).padding(6).accessibilityLabel("Downloaded") }
                            }
                            .contextMenu {
                                ForEach(library.collections) { destination in
                                    Button(library.isItemInCollection(destination.id, item: item) ? "Remove from \(destination.name)" : "Add to \(destination.name)") {
                                        if library.isItemInCollection(destination.id, item: item) { library.removeItem(from: destination.id, item: item) }
                                        else { library.addItem(to: destination.id, item: item) }
                                    }
                                }
                            }
                    }
                }
                if items.isEmpty { ContentUnavailableView("Your Library", systemImage: "books.vertical", description: Text("Save titles from Reader sources to keep them here.")) }
                }
            }.padding(28)
        }.alert("New Collection", isPresented: $creating) { TextField("Name", text: $name); Button("Cancel", role: .cancel) {}; Button("Create") { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { library.createCollection(name: value) }; name = "" } }
        .alert("Rename Collection", isPresented: $renaming) { TextField("Name", text: $name); Button("Save") { if let current = library.collections.first(where: { $0.id == collection }) { library.renameCollection(current, name: name) } }; Button("Cancel", role: .cancel) {} }
        .confirmationDialog("Delete Collection?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete", role: .destructive) { if let current = library.collections.first(where: { $0.id == collection }) { library.deleteCollection(current); collection = nil } }; Button("Cancel", role: .cancel) {} }
        .onDisappear(perform: cancelRefresh)
        .onChange(of: deepLibraryEnabled) { enabled in if !enabled { trackerLibrarySource = .local } }
        .onChange(of: isActive) { active in if !active { cancelRefresh(); creating = false; renaming = false; deleting = false } }

    }
    private func refresh() {
        guard isActive, !refreshing, let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: ProfileManager.shared.activeProfileID) else { return }
        refreshing = true
        refreshStatus = "Refreshing saved sources…"
        refreshTask = Task { @MainActor in
            let summary = await library.refreshAllSources()
            guard !Task.isCancelled, ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
            refreshStatus = summary.statusText
            refreshing = false
            refreshTask = nil
        }
    }
    private func cancelRefresh() { refreshTask?.cancel(); refreshTask = nil; refreshing = false }
    private var items: [MangaLibraryItem] {
        var seen = Set<Int>()
        return library.collections.filter { collection == nil || $0.id == collection }.flatMap(\.items).filter { seen.insert($0.id).inserted && ReaderContentFilter.shared.allows(libraryItem: $0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
}

private struct MacReaderHistoryView: View {
    let open: (MangaLibraryItem) -> Void
    @Environment(\.macReaderIsActive) private var isActive
    @ObservedObject private var progress = MangaReadingProgressManager.shared
    @State private var clearing = false
    @State private var clearAuthority: ProgressManager.ProfileMutationAuthority?
    var body: some View {
        List {
            ForEach(progress.recentlyReadMangaIds(), id: \.id) { entry in
                let item = MangaLibraryItem(aniListId: entry.id, title: entry.progress.title ?? "Untitled", coverURL: entry.progress.coverURL, format: entry.progress.format, totalChapters: entry.progress.totalChapters, moduleUUID: entry.progress.moduleUUID, contentParams: entry.progress.contentParams, isNovel: entry.progress.isNovel, route: entry.progress.route, latestChapterNumbers: entry.progress.latestChapterNumbers, trackerAniListId: entry.progress.trackerAniListId, trackerMALId: entry.progress.trackerMALId)
                if ReaderContentFilter.shared.allows(libraryItem: item) {
                    Button { open(item) } label: {
                        HStack { Text(item.title); Spacer(); Text(entry.progress.lastReadChapter ?? "").foregroundStyle(.secondary); if let date = entry.progress.lastReadDate { Text(date, style: .relative).foregroundStyle(.secondary) } }
                    }.buttonStyle(.plain).contextMenu { Button("Remove from History", role: .destructive) { progress.removeFromHistory(mangaId: entry.id) } }
                }
            }
        }.navigationTitle("Reader History")
        .safeAreaInset(edge: .top) {
            HStack { Text("History").font(.largeTitle.bold()); Spacer(); Button("Clear History") { clearAuthority = ProgressManager.shared.profileMutationAuthority(requiredOwner: ProfileManager.shared.activeProfileID); clearing = clearAuthority != nil }.disabled(progress.recentlyReadMangaIds().isEmpty) }.padding()
        }
        .confirmationDialog("Clear Reader History?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { if let clearAuthority, ProgressManager.shared.profileMutationAuthorityIsCurrent(clearAuthority) { progress.clearHistory() }; clearAuthority = nil }
            Button("Cancel", role: .cancel) { clearAuthority = nil }
        } message: { Text("This clears reading history while keeping read chapters and library items.") }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in clearing = false; clearAuthority = nil }
        .onChange(of: isActive) { active in if !active { clearing = false; clearAuthority = nil } }
    }
}

struct MacReaderDownloadsView: View {
    let open: (ReaderDownloadedTitle) -> Void
    @Environment(\.macReaderIsActive) private var isActive
    @ObservedObject private var downloads = ReaderDownloadManager.shared
    @State private var observation = UUID()
    @State private var deleteAll = false
    @State private var deleteFailed = false
    @State private var deletingTitle: ReaderDownloadedTitle?
    @State private var deletionAuthority: MacDownloadStorageAuthority?
    @AppStorage("readerDownloadsParallelLimit") private var parallelLimit = 2
    @AppStorage("readerDownloadsBackgroundEnabled") private var backgroundEnabled = true
    @AppStorage("readerDownloadsWifiOnly") private var wifiOnly = false
    @ObservedObject private var profiles = ProfileManager.shared
    var body: some View {
        List {
            Section("Queue Settings") {
                Picker("Parallel Downloads", selection: $parallelLimit) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }
                Toggle("Background Downloads", isOn: $backgroundEnabled)
                Toggle("Wi-Fi Only", isOn: $wifiOnly)
                LabeledContent("Stored on Disk", value: ByteCountFormatter.string(fromByteCount: downloads.totalDownloadedBytes, countStyle: .file))
                HStack {
                    Button("Clear Failed Downloads") { deletionAuthority = MacDownloadStorageAuthority.capture(); deleteFailed = deletionAuthority != nil }.disabled(downloads.failedDownloads.isEmpty || profiles.isKidsModeActive)
                    Button("Delete All Downloads", role: .destructive) { deletionAuthority = MacDownloadStorageAuthority.capture(); deleteAll = deletionAuthority != nil }.disabled(downloads.downloads.isEmpty || profiles.isKidsModeActive)
                }
            }
            ForEach(downloads.downloadedTitles.filter { ReaderContentFilter.shared.allows(downloadedTitle: $0) }) { title in
                Section(title.title) {
                    HStack {
                        Button("Open Downloaded Chapters") { if isActive { open(title) } }.disabled(title.completedCount == 0)
                        Spacer()
                        Button("Delete Title Downloads", role: .destructive) { deletionAuthority = MacDownloadStorageAuthority.capture(); if deletionAuthority != nil { deletingTitle = title } }.disabled(profiles.isKidsModeActive)
                    }
                    ForEach(downloads.downloads.filter { $0.routeKey == title.route.stableKey }) { chapter in
                        HStack {
                            Text(chapter.displayChapterTitle)
                            Spacer()
                            if chapter.status == .downloading { ProgressView(value: chapter.progress).frame(width: 120) }
                            Text(chapter.error ?? chapter.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            if chapter.status == .paused { Button("Resume") { downloads.resumeDownload(id: chapter.id) } }
                            if chapter.status == .failed { Button("Retry") { downloads.retryDownload(id: chapter.id) } }
                            if chapter.status == .downloading || chapter.status == .queued { Button("Pause") { downloads.pauseDownload(id: chapter.id) } }
                            Button(role: .destructive) { downloads.removeDownload(id: chapter.id) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
        }.navigationTitle("Reader Downloads")
        .onAppear { if isActive { downloads.beginStorageSnapshotObservation(observation) } }
        .onDisappear { downloads.endStorageSnapshotObservation(observation) }
        .onChange(of: isActive) { active in
            if active { downloads.beginStorageSnapshotObservation(observation) }
            else { downloads.endStorageSnapshotObservation(observation); deleteAll = false; deleteFailed = false; deletingTitle = nil; deletionAuthority = nil }
        }
        .onChange(of: parallelLimit) { _ in downloads.applyQueueSettingsChanged() }
        .onChange(of: wifiOnly) { _ in downloads.applyQueueSettingsChanged() }
        .onChange(of: backgroundEnabled) { _ in downloads.applyQueueSettingsChanged() }
        .confirmationDialog("Delete Downloads for This Title?", isPresented: Binding(get: { deletingTitle != nil }, set: { if !$0 { deletingTitle = nil } }), titleVisibility: .visible) {
            Button("Delete Title Downloads", role: .destructive) { if let deletingTitle, deletionAuthority?.isCurrent() == true { downloads.deleteTitle(route: deletingTitle.route) }; deletingTitle = nil; deletionAuthority = nil }
            Button("Cancel", role: .cancel) { deletingTitle = nil; deletionAuthority = nil }
        } message: { Text(deletingTitle.map { "This cancels active downloads and removes the downloaded chapters of \($0.title)." } ?? "") }
        .confirmationDialog("Delete All Reader Downloads?", isPresented: $deleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { if deletionAuthority?.isCurrent() == true { downloads.deleteAll() }; deletionAuthority = nil }
            Button("Cancel", role: .cancel) { deletionAuthority = nil }
        } message: { Text("This cancels active Reader downloads and removes the files owned by Eclipse.") }
        .confirmationDialog("Clear Failed Reader Downloads?", isPresented: $deleteFailed, titleVisibility: .visible) {
            Button("Clear Failed", role: .destructive) { if deletionAuthority?.isCurrent() == true { downloads.deleteFailed() }; deletionAuthority = nil }
            Button("Cancel", role: .cancel) { deletionAuthority = nil }
        }
        .alert("Reader Downloads", isPresented: Binding(get: { downloads.enqueueErrorMessage != nil }, set: { if !$0 { downloads.clearEnqueueError() } })) { Button("OK") { downloads.clearEnqueueError() } } message: { Text(downloads.enqueueErrorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in deleteAll = false; deleteFailed = false; deletingTitle = nil; deletionAuthority = nil }
    }
}

private struct MacReaderDownloadedTitleView: View {
    let title: ReaderDownloadedTitle
    @ObservedObject var session: MacReaderSession
    let back: () -> Void
    @Environment(\.macReaderIsActive) private var isActive
    @ObservedObject private var downloads = ReaderDownloadManager.shared
    @ObservedObject private var progress = MangaReadingProgressManager.shared
    @StateObject private var engine = KanzenEngine()

    var body: some View {
        let chapters = MacReaderOfflineChapterPolicy.chapters(for: title.route, downloads: downloads.chapters(for: title.route))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                Spacer()
                if let chapter = resumeChapter(in: chapters) { Button("Continue Reading") { read(chapter, chapters: chapters) }.buttonStyle(.borderedProminent) }
            }.padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) {
                Text(title.title).font(.largeTitle.bold()).textSelection(.enabled)
                Text("\(chapters.count) Downloaded Chapters").foregroundStyle(.secondary)
                if let source = title.sourceName { Text(source).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal)
            if chapters.isEmpty {
                ContentUnavailableView("No Downloaded Chapters", systemImage: "book.closed", description: Text("The completed downloads for this title are no longer in the download list."))
            } else {
                List(chapters) { chapter in
                    Button { read(chapter, chapters: chapters) } label: {
                        HStack {
                            Image(systemName: progress.normalizedReadChapterKeys(for: title.mangaId).contains(ChapterIdentityNormalizer.key(for: chapter.chapterNumber)) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.chapterNumber).font(.headline)
                                if let label = chapter.chapterData?.first?.title, !label.isEmpty { Text(label).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.top, 20).navigationTitle(title.title)
    }

    private func resumeChapter(in chapters: [Chapter]) -> Chapter? {
        let read = progress.normalizedReadChapterKeys(for: title.mangaId)
        let saved = progress.lastReadChapter(for: title.mangaId).map(ChapterIdentityNormalizer.key(for:))
        return chapters.first { ChapterIdentityNormalizer.key(for: $0.chapterNumber) == saved && !read.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }
            ?? chapters.first { !read.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) } ?? chapters.first
    }

    private func read(_ chapter: Chapter, chapters: [Chapter]) {
        guard isActive, ReaderContentFilter.shared.allows(downloadedTitle: title) else { return }
        let item = MangaLibraryItem(aniListId: title.mangaId, title: title.title, coverURL: title.coverURL, format: title.format, totalChapters: nil, route: title.route, sourceName: title.sourceName, contentRating: title.contentRating)
        session.open(item: item, chapters: chapters, selected: chapter, engine: engine)
    }
}
#endif
