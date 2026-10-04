import SwiftUI
import Kingfisher

struct TrackerImportPresentation: Identifiable {
    let service: TrackerService
    var id: TrackerService { service }
}

struct TrackerImportProgressView: View {
    let service: TrackerService
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TrackerImportProgressContent(service: service, state: tracker.importState(for: service)) {
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in dismiss() }
    }
}

struct TrackerImportProgressContent: View {
    let service: TrackerService
    let state: TrackerImportState?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ScrollView {
                VStack(spacing: 20) {
                    Text(service.displayName)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    if state?.isImporting == true {
                        ProgressView()
                            .scaleEffect(1.5)
                            .padding(12)
                            .accessibilityLabel("Import in progress")
                    } else {
                        Image(systemName: state?.needsAttention == false ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(state?.needsAttention == false ? .green : .orange)
                    }
                    Text(state?.title ?? "Import Stopped")
                        .font(.title2.bold())
                        .accessibilityIdentifier("trackerImport.title")
                    Text(state?.message ?? "The active profile or tracker account changed. Start a new import from Settings.")
                        .font(.body)
                        .accessibilityIdentifier("trackerImport.message")
                    if state?.isImporting == true {
                        Text("Large libraries can take a while. You can keep browsing and check the result in Tracker settings.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if let state, case .finished(let summary) = state.phase, summary.hasSkippedItems {
                        Text("Some titles or progress could not be imported. Try importing again later to retry those items.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            Button(state?.isImporting == true ? "Keep Browsing" : "Done", action: dismiss)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("trackerImport.dismiss")
        }
        .padding(32)
        .frame(maxWidth: 560, maxHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct TrackerLibrarySourcePicker: View {
    @Binding var selection: TrackerLibrarySource

    var body: some View {
        Picker("Library Source", selection: $selection) {
            ForEach(TrackerLibrarySource.allCases.filter { $0.service != .simkl }) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("trackerLibrarySourcePicker")
        .padding(.horizontal)
    }
}

private struct TrackerLibraryLoadIdentity: Equatable {
    let session: TrackerLibrarySession?
    let kind: TrackerLibraryKind
    let status: TrackerLibraryStatus?
    let section: TrackerLibrarySection
    let revision: Int
    let isActive: Bool
    let language: String

    func preservesPresentation(for next: Self) -> Bool {
        isActive && next.isActive && session != nil && session == next.session && kind == next.kind
            && status == next.status && section == next.section && language == next.language
    }
}

@MainActor
private final class TrackerLibraryViewModel: ObservableObject {
    @Published private(set) var entries: [TrackerLibraryEntry] = []
    @Published private(set) var filteredEntries: [TrackerLibraryEntry] = []
    @Published private(set) var availableGenres: [String] = []
    private var search = ""
    private var selectedGenre: String?
    @Published private(set) var session: TrackerLibrarySession?
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    @Published private(set) var error: String?
    @Published private(set) var lists: [TrackerLibraryList] = []
    @Published private(set) var listsLoaded = false
    @Published private(set) var aniListLists: [String] = []
    @Published private(set) var listError: String?
    @Published private(set) var videos: [String: TrackerLibraryMediaResolution] = [:]
#if !os(tvOS)
    @Published private(set) var readers: [String: TrackerReaderResolution] = [:]
#endif
    @Published private(set) var resolutionErrors: [String: String] = [:]
    @Published private(set) var resolving = Set<String>()
    private var identity: TrackerLibraryLoadIdentity?
    private var consumedRefreshRevision = 0
    private var generation = UUID()
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var listTask: Task<Void, Never>?
    private var queue = TrackerLibraryResolutionQueue()
    private var animeIDs: [String: Int] = [:]
    private var manualVideos = Set<String>()
    private var manualReaders = Set<String>()
    private var idLookups = Set<String>()
    private var idLookupTasks: [String: (id: UUID, task: Task<[String: Int], Never>, entries: [TrackerLibraryEntry])] = [:]
    private var resolutionTokens: [String: UUID] = [:]
    private var interactiveDemand = Set<String>()

    func load(_ value: TrackerLibraryLoadIdentity) async {
        let visibleIDs = queue.visible
        var restoredVisibleDemand = false
        let previousIdentity = identity
        clear(preservingPresentation: previousIdentity?.preservesPresentation(for: value) == true)
        identity = value
        let token = generation
        let forceRefresh = value.revision > consumedRefreshRevision
        consumedRefreshRevision = value.revision
        guard value.isActive, let session = value.session else {
            error = TrackerLibraryError.unavailable.localizedDescription
            return
        }
        self.session = session
        isLoading = true
        let reentering = previousIdentity == value || previousIdentity?.isActive == false || previousIdentity?.session != value.session
        if forceRefresh || reentering {
            do { try TrackerManager.shared.refreshLibrarySession(session) }
            catch {
                guard current(token, session) else { return }
                self.error = error.localizedDescription
                isLoading = false
                return
            }
        }
        if session.service == .trakt {
            listTask = Task { @MainActor in
                do {
                    let lists = try await TrackerManager.shared.fetchLibraryLists(session: session)
                    guard current(token, session) else { return }
                    self.lists = lists
                    self.listsLoaded = true
                } catch {
                    guard current(token, session) else { return }
                    listError = error.localizedDescription
                }
            }
        } else if session.service == .anilist {
            listTask = Task { @MainActor in
                do {
                    let names = try await TrackerManager.shared.fetchAniListLibraryLists(session: session, kind: value.kind)
                    guard current(token, session) else { return }
                    self.aniListLists = names
                } catch {
                    guard current(token, session) else { return }
                    listError = error.localizedDescription
                }
            }
        }
        do {
            _ = try await TrackerManager.shared.fetchLibrary(session: session, kind: value.kind, status: value.status,
                section: value.section) { [weak self] snapshot in
                    guard let self, self.current(token, session) else { return }
                    var presentedEntries = snapshot.entries
                    if !snapshot.isComplete { try? TrackerLibraryPolicy.appendPreservingCache(self.entries, to: &presentedEntries) }
                    self.reconcilePresentation(presentedEntries, isComplete: snapshot.isComplete)
                    self.entries = presentedEntries
                    self.updateFilters()
                    self.isStale = snapshot.isStale || presentedEntries.count > snapshot.entries.count
                    if !restoredVisibleDemand {
                        restoredVisibleDemand = true
                        for entry in presentedEntries where visibleIDs.contains(entry.id) { self.queue.appear(entry) }
                    }
                    self.startWorkers(token: token, session: session)
                }
            guard current(token, session) else { return }
            isLoading = false
        } catch {
            guard current(token, session) else { return }
            self.error = error is CancellationError ? "This library changed while it was loading. Refresh to load its latest titles." : error.localizedDescription
            isLoading = false
        }
    }

    func filter(search: String, genre: String?) {
        self.search = search
        selectedGenre = genre
        updateFilters()
    }

    private func updateFilters() {
        filteredEntries = TrackerLibraryPolicy.filtered(entries, search: search, genre: selectedGenre)
        availableGenres = Set(entries.flatMap(\.genres)).sorted()
    }

    func prioritize(_ entry: TrackerLibraryEntry) {
        guard let session, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        interactiveDemand.insert(entry.id)
        queue.select(entry)
        startWorkers(token: generation, session: session)
    }

    func appear(_ entry: TrackerLibraryEntry) {
        guard let session, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        queue.appear(entry)
        startWorkers(token: generation, session: session)
    }

    func disappear(_ entry: TrackerLibraryEntry) { queue.disappear(entry) }

    func retry(_ entry: TrackerLibraryEntry) {
        guard let session, TrackerManager.shared.librarySessionIsCurrent(session), !resolving.contains(entry.id) else { return }
        interactiveDemand.insert(entry.id)
        resolutionErrors.removeValue(forKey: entry.id)
        idLookups.remove(entry.id)
        manualVideos.remove(entry.id)
        manualReaders.remove(entry.id)
        if entry.kind.isVideo {
            videos.removeValue(forKey: entry.id)
            TrackerLibraryMediaResolver.shared.invalidate(entry, session: session)
        } else {
#if !os(tvOS)
            readers.removeValue(forKey: entry.id)
            TrackerReaderResolver.shared.invalidate(entry: entry, session: session)
#endif
        }
        queue.retry(entry)
        startWorkers(token: generation, session: session)
    }

#if !os(tvOS)
    func selectReader(_ match: TrackerReaderMatch, entry: TrackerLibraryEntry) -> Bool {
        guard let session, TrackerReaderResolver.shared.remember(match: match, entry: entry, session: session) else { return false }
        manualReaders.insert(entry.id)
        readers[entry.id] = TrackerReaderResolution(match: match, candidates: [], message: nil)
        return true
    }
#endif

    func accept(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession) {
        guard self.session == session, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        if let status = identity?.status, entry.status != status { entries.removeAll { $0.id == entry.id } }
        else if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        updateFilters()
    }

    func select(_ result: TMDBSearchResult, for entry: TrackerLibraryEntry) -> TMDBSearchResult {
        guard let session, TrackerManager.shared.librarySessionIsCurrent(session) else { return result }
        let id = animeIDs[entry.id] ?? entry.aniListID ?? entry.malID.map { -$0 }
        let seed = entry.kind == .anime ? id.map { AnimeMediaIdentitySeed(anilistId: $0, malId: entry.malID, format: entry.format) } : nil
        let selected = result.withAnimeIdentitySeed(seed)
        manualVideos.insert(entry.id)
        videos[entry.id] = TrackerLibraryMediaResolution(match: selected, candidates: [], message: nil)
        TrackerLibraryMediaResolver.shared.remember(selected, entry: entry, session: session)
        return selected
    }

    func stop() {
        generation = UUID()
        workers.values.forEach { $0.cancel() }
        workers = [:]
        listTask?.cancel()
        listTask = nil
        idLookupTasks.values.forEach { $0.task.cancel() }
        idLookupTasks = [:]
        resolutionTokens = [:]
        interactiveDemand = []
        queue = TrackerLibraryResolutionQueue()
    }

    private func clear(preservingPresentation: Bool) {
        stop()
        identity = nil
        session = nil
        isLoading = false
        isStale = preservingPresentation && !entries.isEmpty
        error = nil
        lists = []
        listsLoaded = false
        aniListLists = []
        listError = nil
        if !preservingPresentation {
            entries = []
            filteredEntries = []
            availableGenres = []
            videos = [:]
#if !os(tvOS)
            readers = [:]
#endif
            animeIDs = [:]
            manualVideos = []
            manualReaders = []
        }
        resolutionErrors = [:]
        resolving = []
        idLookups = []
    }

    private func reconcilePresentation(_ incoming: [TrackerLibraryEntry], isComplete: Bool) {
        let previous = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incoming.map(\.id))
        if isComplete {
            for id in interactiveDemand.subtracting(incomingIDs) {
                resolutionTokens.removeValue(forKey: id)
                resolving.remove(id)
                resolutionErrors[id] = "This title is no longer in this tracker list. Refresh the library."
            }
            interactiveDemand.formIntersection(incomingIDs)
        }
        let validIDs = Set(incoming.compactMap { entry -> String? in
            guard let old = previous[entry.id], old.hasSameResolutionMetadata(as: entry) else { return nil }
            return entry.id
        })
        videos = videos.filter { validIDs.contains($0.key) }
#if os(tvOS)
        let staleReaderIDs = Set<String>()
#else
        let staleReaderIDs = Set(readers.compactMap { $0.value.match?.isCurrent == false ? $0.key : nil })
#endif
#if !os(tvOS)
        readers = readers.filter { validIDs.contains($0.key) && $0.value.match?.isCurrent != false }
#endif
        animeIDs = animeIDs.filter { validIDs.contains($0.key) }
        manualVideos.formIntersection(validIDs)
        manualReaders.formIntersection(validIDs)
#if !os(tvOS)
        manualReaders.formIntersection(Set(readers.keys))
#endif
        for entry in incoming where previous[entry.id] != nil && (!validIDs.contains(entry.id) || staleReaderIDs.contains(entry.id)) {
            resolutionTokens.removeValue(forKey: entry.id)
            resolving.remove(entry.id)
            resolutionErrors.removeValue(forKey: entry.id)
            idLookups.remove(entry.id)
            idLookupTasks.removeValue(forKey: entry.id)
#if !os(tvOS)
            if entry.kind.isManga, let session { TrackerReaderResolver.shared.invalidate(entry: entry, session: session) }
#endif
            queue.refreshMetadata(entry)
            if interactiveDemand.contains(entry.id) { queue.select(entry) }
        }
    }

    private func currentResolution(_ id: UUID, entry: TrackerLibraryEntry, token: UUID, session: TrackerLibrarySession) -> Bool {
        current(token, session) && resolutionTokens[entry.id] == id
            && entries.contains { $0.hasSameResolutionMetadata(as: entry) }
    }

    private func current(_ token: UUID, _ session: TrackerLibrarySession) -> Bool {
        !Task.isCancelled && generation == token && self.session == session && TrackerManager.shared.librarySessionIsCurrent(session)
    }

    private func startWorkers(token: UUID, session: TrackerLibrarySession) {
        guard !queue.entries.isEmpty, current(token, session) else { return }
        while workers.count < 2 {
            let id = UUID()
            workers[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.workers.removeValue(forKey: id) }
                await self.resolveQueue(token: token, session: session)
            }
        }
    }

    private func prepareAnimeIDs(_ entry: TrackerLibraryEntry, token: UUID, session: TrackerLibrarySession) async {
        if let id = entry.aniListID { animeIDs[entry.id] = id; return }
        if animeIDs[entry.id] != nil { return }
        if let pending = idLookupTasks[entry.id] {
            let ids = await pending.task.value
            guard current(token, session) else { return }
            acceptAnimeIDs(ids, for: pending.entries)
            return
        }
        guard !idLookups.contains(entry.id), current(token, session) else { return }
        let batch = [entry] + Array(queue.entries.filter { $0.kind == .anime && !idLookups.contains($0.id) && idLookupTasks[$0.id] == nil }.prefix(24))
        idLookups.formUnion(batch.map(\.id))
        let id = UUID()
        let task = Task { @MainActor in (try? await TrackerManager.shared.libraryAnimeIDs(batch, session: session)) ?? [:] }
        for item in batch { idLookupTasks[item.id] = (id, task, batch) }
        let ids = await task.value
        guard current(token, session) else { return }
        acceptAnimeIDs(ids, for: batch)
        for item in batch where idLookupTasks[item.id]?.id == id { idLookupTasks.removeValue(forKey: item.id) }
    }

    private func acceptAnimeIDs(_ ids: [String: Int], for batch: [TrackerLibraryEntry]) {
        let captured = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let validIDs = Set(entries.compactMap { entry -> String? in
            captured[entry.id]?.hasSameResolutionMetadata(as: entry) == true ? entry.id : nil
        })
        animeIDs.merge(ids.filter { validIDs.contains($0.key) }) { old, _ in old }
    }

    private func resolveQueue(token: UUID, session: TrackerLibrarySession) async {
        while current(token, session), let work = queue.next() {
            let entry = work.entry
            await TrackerRequestContext.$priority.withValue(work.priority) {
                await resolve(entry, token: token, session: session)
            }
        }
    }

    private func resolve(_ entry: TrackerLibraryEntry, token: UUID, session: TrackerLibrarySession) async {
        guard current(token, session), entries.contains(where: { $0.hasSameResolutionMetadata(as: entry) }) else { return }
        let id = UUID()
        resolutionTokens[entry.id] = id
        resolutionErrors.removeValue(forKey: entry.id)
        resolving.insert(entry.id)
        defer {
            if resolutionTokens[entry.id] == id {
                resolutionTokens.removeValue(forKey: entry.id)
                resolving.remove(entry.id)
                interactiveDemand.remove(entry.id)
            }
        }
        do {
            if entry.kind.isVideo {
                if entry.kind == .anime {
                    await prepareAnimeIDs(entry, token: token, session: session)
                    guard currentResolution(id, entry: entry, token: token, session: session) else { return }
                }
                let resolution = try await TrackerLibraryMediaResolver.shared.resolve(entry, session: session, aniListID: animeIDs[entry.id])
                guard currentResolution(id, entry: entry, token: token, session: session) else { return }
                if !manualVideos.contains(entry.id) { videos[entry.id] = resolution }
            } else {
#if !os(tvOS)
                let resolution = try await TrackerReaderResolver.shared.resolve(entry: entry, session: session)
                guard currentResolution(id, entry: entry, token: token, session: session) else { return }
                if !manualReaders.contains(entry.id) { readers[entry.id] = resolution }
#endif
            }
        } catch {
            guard currentResolution(id, entry: entry, token: token, session: session) else { return }
            resolutionErrors[entry.id] = error.localizedDescription
        }
    }
}

private struct TrackerLibraryEditingSelection: Identifiable {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    var id: String { entry.id }
}

struct TrackerLibraryView: View {
    let service: TrackerService
    var isActive: Bool = true
    @State private var kind: TrackerLibraryKind
    @State private var status: TrackerLibraryStatus?
    @State private var section: TrackerLibrarySection
    @State private var query = ""
    @State private var genre: String?
    @State private var revision = 0
    @State private var isVisible = false
    @State private var invalidationTask: Task<Void, Never>?
    @State private var editing: TrackerLibraryEditingSelection?
    @State private var choosing: TrackerLibraryEditingSelection?
    @State private var navigationResult: TMDBSearchResult?
    @State private var playbackIntent: TrackerLibraryPlaybackIntent?
    @State private var navigationActive = false
#if !os(tvOS)
    @State private var readerMatch: TrackerReaderMatch?
    @State private var readerActive = false
#endif
    @StateObject private var model = TrackerLibraryViewModel()
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = TrackerLibrarySettings.defaultEnabled
    @AppStorage(ImageDataSaverSettings.enabledKey, store: .standard) private var imageDataSaverEnabled = false
    @AppStorage("tmdbLanguage") private var metadataLanguage = "en-US"
    @ScaledMetric(relativeTo: .headline) private var cardWidthScale: CGFloat = 1

    init(service: TrackerService, initialKind: TrackerLibraryKind = .anime, isActive: Bool = true) {
        self.service = service
        self.isActive = isActive
        _kind = State(initialValue: TrackerLibraryKind.supportedKinds(for: service).contains(initialKind) ? initialKind : .movie)
        _section = State(initialValue: service == .trakt ? .watchlist : .list)
    }

    private var loadIdentity: TrackerLibraryLoadIdentity {
        TrackerLibraryLoadIdentity(session: enabled ? tracker.captureLibrarySession(service: service) : nil,
            kind: kind, status: service == .trakt ? nil : status, section: section, revision: revision,
            isActive: isActive, language: metadataLanguage)
    }
    private var availableGenres: [String] { model.availableGenres }
    private var gridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(minimum: 0), spacing: 16, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: (isTvOS ? 240 : 145) * cardWidthScale), spacing: 16, alignment: .top)]
    }
    private var authorized: Bool {
        enabled && isActive && !profiles.isKidsModeActive && model.session.map(tracker.librarySessionIsCurrent) == true
    }

    var body: some View {
        let identity = loadIdentity
        let displayedEntries = model.filteredEntries
        VStack(alignment: .leading, spacing: 16) {
            controls
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Button("Retry") { revision += 1 }.disabled(identity.session == nil)
                    if identity.session == nil { NavigationLink("Tracker Settings", destination: TrackersSettingsView()) }
                }.frame(maxWidth: .infinity).padding(24)
            }
            if authorized {
                HStack {
                    Text("\(displayedEntries.count) titles\(model.isLoading ? " loaded" : "")")
                        .lineLimit(1)
                    ProgressView()
                        .opacity(model.isLoading ? 1 : 0)
                        .accessibilityHidden(!model.isLoading)
                    Spacer()
                    if model.isStale { Text(model.isLoading ? "Cached · Refreshing" : "Cached").lineLimit(1) }
                }
                .font(.caption).foregroundColor(.secondary)
                if !displayedEntries.isEmpty {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                        ForEach(displayedEntries) { entry in entryCard(entry) }
                    }
                } else if !model.isLoading && model.error == nil {
                    Text(query.isEmpty && genre == nil ? "No titles in this list." : "No titles match these filters.")
                        .foregroundColor(.secondary).frame(maxWidth: .infinity).padding(24)
                }
            }

        }
        .padding(.horizontal)
        .padding(.bottom, 24)
        .background(navigationLinks)
        .task(id: identity) {
            navigationActive = false
            navigationResult = nil
            playbackIntent = nil
#if !os(tvOS)
            readerActive = false
            readerMatch = nil
#endif
            editing = nil
            choosing = nil
            genre = nil
            await model.load(identity)
        }
        .onChange(of: query) { model.filter(search: $0, genre: genre) }
        .onChange(of: genre) { model.filter(search: query, genre: $0) }
        .onChange(of: scenePhase) { phase in
            if phase == .active, isVisible, isActive, editing == nil, choosing == nil { revision += 1 }
        }
        .onChange(of: kind) { _ in
            if case .aniListCustomList = section { section = .list }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackerLibraryInvalidated)) { notification in
            guard let session = notification.object as? TrackerLibrarySession,
                  session == model.session, editing == nil, choosing == nil, identity.isActive, isVisible else { return }
            invalidationTask?.cancel()
            invalidationTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled, isVisible, isActive, editing == nil, choosing == nil,
                      model.session == session, tracker.librarySessionIsCurrent(session) else { return }
                revision += 1
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; invalidationTask?.cancel(); model.stop(); editing = nil; choosing = nil }
        .sheet(item: $editing, onDismiss: { revision += 1 }) { selection in
            if service == .trakt {
                TrackerTraktEditView(entry: selection.entry, session: selection.session, lists: model.lists) { revision += 1 }
            } else {
                TrackerLibraryEditView(entry: selection.entry, session: selection.session) { saved in model.accept(saved, session: selection.session) }
            }
        }
        .sheet(item: $choosing) { selection in
#if os(tvOS)
            TrackerLibraryMatchView(entry: selection.entry, session: selection.session,
                resolution: model.videos[selection.id], error: model.resolutionErrors[selection.id],
                didSelect: { select($0, selection: selection) }, retry: { model.retry(selection.entry) })
#else
            TrackerLibraryMatchView(entry: selection.entry, session: selection.session,
                resolution: model.videos[selection.id], error: model.resolutionErrors[selection.id],
                didSelect: { select($0, selection: selection) }, retry: { model.retry(selection.entry) }, readerResolution: model.readers[selection.id],
                didSelectReader: { match in
                    guard authorized, model.session == selection.session, match.isCurrent, model.selectReader(match, entry: selection.entry) else { return }
                    choosing = nil
                    readerMatch = match
                    readerActive = true
                })
#endif
        }
    }

    private func select(_ result: TMDBSearchResult, selection: TrackerLibraryEditingSelection) {
        guard authorized, model.session == selection.session else { return }
        let selected = model.select(result, for: selection.entry)
        choosing = nil
        navigationResult = selected
        playbackIntent = TrackerLibraryPlaybackIntent(entry: selection.entry, session: selection.session)
        navigationActive = true
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Media Type", selection: $kind) {
                ForEach(TrackerLibraryKind.supportedKinds(for: service)) { kind in Text(kind.title).tag(kind) }
            }.pickerStyle(.segmented).accessibilityIdentifier("trackerLibrary.mediaType")
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search library", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear Search") }
            }.padding(12).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                if service == .trakt {
                    Menu {
                        Picker("List", selection: $section) {
                            Text("Watchlist").tag(TrackerLibrarySection.watchlist)
                            Text("Watched History").tag(TrackerLibrarySection.history)
                            Text("Collection").tag(TrackerLibrarySection.collection)
                            ForEach(model.lists) { list in Text(list.name).tag(TrackerLibrarySection.customList(id: list.id, name: list.name)) }
                            if case .customList(let id, let name) = section, !model.lists.contains(where: { $0.id == id }) {
                                Text(model.listsLoaded ? "\(name) (Unavailable)" : name).tag(section)
                            }
                        }
                    } label: { filterMenuLabel("List", selection: section.title) }
                    .accessibilityIdentifier("trackerLibrary.traktSection")
                    .accessibilityLabel("List")
                    .accessibilityValue(section.title)
                } else {
                    Menu {
                        Picker("Status", selection: $status) {
                            Text("All Statuses").tag(TrackerLibraryStatus?.none)
                            ForEach(TrackerLibraryStatus.allCases) { status in Text(status.title(for: kind)).tag(Optional(status)) }
                        }
                    } label: { filterMenuLabel("Status", selection: status?.title(for: kind) ?? "All Statuses") }
                    .accessibilityIdentifier("trackerLibrary.status")
                    .accessibilityLabel("Status")
                    .accessibilityValue(status?.title(for: kind) ?? "All Statuses")
                }
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Refresh Tracker Library")
                    .accessibilityIdentifier("trackerLibrary.refresh")
                    .disabled(model.isLoading)
            }
            Menu {
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag(String?.none)
                    ForEach(availableGenres, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } label: { filterMenuLabel("Genre", selection: genre ?? "All Genres") }
            .accessibilityIdentifier("trackerLibrary.genre")
            .accessibilityLabel("Genre")
            .accessibilityValue(genre ?? "All Genres")
            if service == .anilist {
                Menu {
                    Picker("List", selection: $section) {
                        Text("All Lists").tag(TrackerLibrarySection.list)
                        ForEach(model.aniListLists, id: \.self) { name in
                            Text(name).tag(TrackerLibrarySection.aniListCustomList(name: name))
                        }
                        if case .aniListCustomList(let name) = section, !model.aniListLists.contains(name) {
                            Text(name).tag(section)
                        }
                    }
                } label: { filterMenuLabel("List", selection: section == .list ? "All Lists" : section.title) }
                .accessibilityIdentifier("trackerLibrary.anilistSection")
                .accessibilityLabel("List")
                .accessibilityValue(section == .list ? "All Lists" : section.title)
            }
            if let error = model.listError { Text("Custom lists: \(error)").font(.caption).foregroundColor(.secondary) }
        }
    }

    private func filterMenuLabel(_ title: String, selection: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(selection).font(.subheadline).foregroundColor(.primary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption).foregroundColor(.secondary)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func entryCard(_ entry: TrackerLibraryEntry) -> some View {
        let result = model.videos[entry.id]?.match
        return VStack(alignment: .leading, spacing: 8) {
            Button { open(entry) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Color.secondary.opacity(0.15)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            KFImage(entry.coverURL ?? result?.fullPosterURL.flatMap(URL.init(string:)))
                                .resizable()
                                .placeholder { Color.clear.overlay(Image(systemName: entry.kind.isManga ? "book.closed" : "film").foregroundColor(.secondary)) }
                                .scaledToFill()
                                .accessibilityHidden(true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    cardTextSlot(lines: 3) { Text(entry.title).lineLimit(3) }
                        .font(.headline)
                }.contentShape(Rectangle())
            }
#if os(tvOS)
            .buttonStyle(TVMediaCardButtonStyle())
#else
            .buttonStyle(.plain)
#endif
            .accessibilityIdentifier("trackerLibrary.open.\(entry.id)")
            .accessibilityLabel("Open \(entry.title)")
            .accessibilityValue(readiness(entry))
            entryFooter(entry)
        }
        .contextMenu {
            Button(entry.kind.isManga ? "Choose Reader Source" : "Choose Different Match") {
                guard authorized, let session = model.session else { return }
                model.prioritize(entry)
                choosing = TrackerLibraryEditingSelection(entry: entry, session: session)
            }
        }
        .onAppear { model.appear(entry) }
        .onDisappear { model.disappear(entry) }
    }

    @ViewBuilder
    private func entryFooter(_ entry: TrackerLibraryEntry) -> some View {
        let details = VStack(alignment: .leading, spacing: 4) {
            if service != .trakt {
                cardTextSlot(lines: 2) {
                    Text("\(entry.progress) / \(entry.total.flatMap { $0 > 0 ? String($0) : nil } ?? "?") \(entry.kind.unit)")
                        .lineLimit(2)
                        .accessibilityIdentifier("trackerLibrary.progress.\(entry.id)")
                }
            }
            cardTextSlot(lines: 1) {
                if entry.score > 0 {
                    Label(String(format: "%g / 10", entry.score / 10), systemImage: "star.fill")
                        .lineLimit(1).foregroundColor(.yellow)
                        .accessibilityIdentifier("trackerLibrary.score.\(entry.id)")
                }
            }
            cardTextSlot(lines: entry.kind.isVideo ? 1 : 2) {
                resolutionLabel(entry).lineLimit(entry.kind.isVideo ? 1 : 2)
            }
        }.font(.caption).foregroundColor(.secondary)
        let edit = Button {
            guard authorized, let session = model.session else { return }
            editing = TrackerLibraryEditingSelection(entry: entry, session: session)
        } label: { Image(systemName: "pencil.circle.fill").font(.title2) }
        .accessibilityIdentifier("trackerLibrary.edit.\(entry.id)")
        .accessibilityLabel("Edit \(entry.title)")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                details
                HStack { Spacer(minLength: 0); edit }
            }
        } else {
            HStack(alignment: .top) {
                details
                Spacer(minLength: 0)
                edit
            }
        }
    }

    private func cardTextSlot<Content: View>(lines: Int, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: Array(repeating: "Ag", count: lines).joined(separator: "\n"))
                .hidden()
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func readiness(_ entry: TrackerLibraryEntry) -> String {
        if model.videos[entry.id]?.match != nil { return "Ready" }
#if !os(tvOS)
        if model.readers[entry.id]?.match?.isCurrent == true { return "Ready" }
        if model.readers[entry.id] != nil { return "Choose Match" }
#endif
        if model.videos[entry.id] != nil || model.resolutionErrors[entry.id] != nil { return "Choose Match" }
        return "Matching"
    }

    @ViewBuilder
    private func resolutionLabel(_ entry: TrackerLibraryEntry) -> some View {
        if entry.kind.isVideo {
            if model.videos[entry.id]?.match == nil { Text(model.videos[entry.id] == nil && model.resolutionErrors[entry.id] == nil ? "Matching title…" : "Choose match") }
        } else {
#if !os(tvOS)
            if let match = model.readers[entry.id]?.match {
                Text(match.chapterCountVerified ? "\(match.sourceName) · \(match.chapterCount) chapters" : "\(match.sourceName) · Chapter count unavailable").lineLimit(2)
            } else { Text(model.readers[entry.id] == nil && model.resolutionErrors[entry.id] == nil ? "Finding reader source…" : "Choose source") }
#else
            Text("Read on iPhone, iPad, or Mac")
#endif
        }
    }

    private func open(_ entry: TrackerLibraryEntry) {
        guard authorized, let session = model.session else { return }
        if let result = model.videos[entry.id]?.match {
            navigationResult = result
            playbackIntent = TrackerLibraryPlaybackIntent(entry: entry, session: session)
            navigationActive = true
            return
        }
#if !os(tvOS)
        if let match = model.readers[entry.id]?.match, match.isCurrent {
            readerMatch = match
            readerActive = true
            return
        }
#endif
#if !os(tvOS)
        if entry.kind.isManga, model.readers[entry.id]?.match?.isCurrent == false { model.retry(entry) }
#endif
        model.prioritize(entry)
        choosing = TrackerLibraryEditingSelection(entry: entry, session: session)
    }

    private var navigationLinks: some View {
        Group {
            NavigationLink(isActive: $navigationActive) {
                if let navigationResult, authorized { MediaDetailView(searchResult: navigationResult, trackerPlaybackIntent: playbackIntent) }
            } label: { EmptyView() }
#if !os(tvOS)
            NavigationLink(isActive: $readerActive) {
                if let readerMatch, authorized, readerMatch.isCurrent { TrackerReaderDestinationView(match: readerMatch) }
            } label: { EmptyView() }
#endif
        }.hidden()
    }
}

private struct TrackerLibraryMatchView: View {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    let resolution: TrackerLibraryMediaResolution?
    let error: String?
    let didSelect: (TMDBSearchResult) -> Void
    let retry: () -> Void
#if !os(tvOS)
    let readerResolution: TrackerReaderResolution?
    let didSelectReader: (TrackerReaderMatch) -> Void
#endif
    @State private var search = ""
    @State private var searched: [TMDBSearchResult]?
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = false
    private var authorized: Bool { enabled && !profiles.isKidsModeActive && tracker.librarySessionIsCurrent(session) }

    var body: some View {
        NavigationView {
            List {
                Section { Text(entry.title).font(.headline) }
                if !authorized {
                    Text("This profile or tracker account changed. Reload the library.")
                } else if entry.kind.isVideo {
                    Section {
                        TextField("Search title", text: $search)
                        Button(searching ? "Searching…" : "Search") { searchMedia() }.disabled(searching)
                        if let message = searchError ?? error ?? resolution?.message { Text(message).foregroundColor(.secondary) }
                        if error != nil || resolution?.match == nil { Button("Retry Matching") { searched = nil; retry() } }
                        if resolution == nil && error == nil && searched == nil {
                            HStack { ProgressView(); Text("Matching title…") }
                        }
                    }
                    if let match = resolution?.match {
                        Button("Open \(match.displayTitle)") { didSelect(match) }
                    }
                    ForEach(searched ?? resolution?.candidates ?? [], id: \.stableIdentity) { result in
                        Button { didSelect(result) } label: {
                            HStack {
                                KFImage(result.fullPosterURL.flatMap(URL.init(string:))).resizable().aspectRatio(contentMode: .fit).frame(width: 48, height: 72)
                                VStack(alignment: .leading) {
                                    Text(result.displayTitle)
                                    Text("\(result.isMovie ? "Movie" : "Show") · \((result.releaseDate ?? result.firstAirDate).map { String($0.prefix(4)) } ?? "Unknown year")")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
#if !os(tvOS)
                    if let match = readerResolution?.match { readerButton(match) }
                    ForEach(readerResolution?.candidates ?? []) { match in
                        if match.id != readerResolution?.match?.id { readerButton(match) }
                    }
                    if let message = error ?? readerResolution?.message { Text(message).foregroundColor(.secondary) }
                    NavigationLink("Search Reader Sources") { TrackerReaderSearchDestinationView(entry: entry) }
                    Button("Retry Matching") { retry() }
                    if readerResolution == nil && error == nil {
                        HStack { ProgressView(); Text("Searching connected reader sources…") }
                    }
#else
                    Text("Open manga with connected reader sources on iPhone, iPad, or Mac.")
#endif
                }
#if !os(tvOS)
                if let url = entry.websiteURL { Link("Tracker Page", destination: url) }
#endif
            }
            .navigationTitle("Choose Match")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { search = entry.title }
        .onDisappear { searchTask?.cancel() }
    }

#if !os(tvOS)
    private func readerButton(_ match: TrackerReaderMatch) -> some View {
        Button { if authorized && match.isCurrent { didSelectReader(match) } } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(match.item.title)
                Text(match.chapterCountVerified ? "\(match.sourceName) · \(match.chapterCount) chapters · \(match.language)" : "\(match.sourceName) · Chapter count unavailable · \(match.language)").font(.caption).foregroundColor(.secondary)
            }
        }.disabled(!match.isCurrent)
    }
#endif

    private func searchMedia() {
        guard authorized else { return }
        searchTask?.cancel()
        searching = true
        searchError = nil
        let value = search
        searchTask = Task { @MainActor in
            do {
                let results = try await TrackerLibraryMediaResolver.shared.search(value, entry: entry, session: session)
                guard !Task.isCancelled, authorized else { return }
                searched = results
                if results.isEmpty { searchError = "No titles found." }
            } catch {
                guard !Task.isCancelled, authorized else { return }
                searchError = error.localizedDescription
            }
            searching = false
        }
    }
}

private struct TrackerTraktEditView: View {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    let lists: [TrackerLibraryList]
    let didChange: () -> Void
    @State private var rating = 0
    @State private var ratingLoaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingAction: TraktLibraryAction?
    @State private var pendingTitle = ""
    @State private var actionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = false
    private var authorized: Bool { enabled && !profiles.isKidsModeActive && tracker.librarySessionIsCurrent(session) }

    var body: some View {
        NavigationView {
            Form {
                Section { Text(entry.title).font(.headline); Text("Each action updates Trakt immediately.").font(.caption).foregroundColor(.secondary) }
                Section("Rating") {
                    if ratingLoaded {
                        Picker("Rating", selection: $rating) {
                            Text("Unrated").tag(0)
                            ForEach(1...10, id: \.self) { Text("\($0) / 10").tag($0) }
                        }
                        Button("Save Rating") { perform(.rating(rating == 0 ? nil : rating)) }
                    } else if error == nil { ProgressView("Loading rating…") }
                    else { Text("Rating unavailable. Close and reopen to retry.").foregroundColor(.secondary) }
                }.disabled(busy || !authorized)
                Section("Watchlist") {
                    Button("Add to Watchlist") { perform(.watchlist(true)) }
                    Button("Remove from Watchlist") { request(.watchlist(false), title: "Remove from Watchlist?") }
                }.disabled(busy || !authorized)
                Section("Collection") {
                    Button(entry.kind == .show ? "Collect All Episodes" : "Add to Collection") {
                        request(.collection(true), title: entry.kind == .show ? "Collect all episodes of this show?" : "Add to collection?")
                    }
                    Button(entry.kind == .show ? "Remove All Episodes from Collection" : "Remove from Collection") {
                        request(.collection(false), title: entry.kind == .show ? "Remove every episode from your collection?" : "Remove from collection?")
                    }
                }.disabled(busy || !authorized)
                Section("Watched History") {
                    Button(entry.kind == .show ? "Mark All Episodes Watched" : "Mark Watched") {
                        request(.history(true), title: entry.kind == .show ? "Mark every episode of this show watched?" : "Add a watch to your history?")
                    }
                    Button("Remove All Watch History", role: .destructive) {
                        request(.history(false), title: "Remove all watches of this \(entry.kind == .show ? "show and its episodes" : "movie")?")
                    }
                }.disabled(busy || !authorized)
                if !lists.isEmpty {
                    Section("Custom Lists") {
                        ForEach(lists) { list in
                            Menu(list.name) {
                                Button("Add to List") { perform(.customList(id: list.id, included: true)) }
                                Button("Remove from List") { request(.customList(id: list.id, included: false), title: "Remove from \(list.name)?") }
                            }
                        }
                    }.disabled(busy || !authorized)
                }
                if let error { Section { Text(error).foregroundColor(.red) } }
                if !authorized { Text("This profile or tracker account changed. Close this editor and reload the library.") }
                if busy { ProgressView("Updating Trakt…") }
            }
            .eclipseSettingsStyle()
            .navigationTitle("Edit Trakt Entry")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        }
        .interactiveDismissDisabled(busy)
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Confirm") {
                if let action = pendingAction { pendingAction = nil; perform(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
        .task {
            do {
                let value = try await tracker.fetchTraktLibraryRating(entry: entry, session: session)
                guard !Task.isCancelled, authorized else { return }
                rating = value ?? 0
                ratingLoaded = true
            } catch {
                guard !Task.isCancelled, authorized else { return }
                self.error = error.localizedDescription
            }
        }
        .onDisappear { actionTask?.cancel() }
    }

    private func request(_ action: TraktLibraryAction, title: String) {
        guard authorized, !busy else { return }
        pendingTitle = title
        pendingAction = action
    }

    private func perform(_ action: TraktLibraryAction) {
        guard authorized, !busy else { return }
        busy = true
        error = nil
        actionTask = Task { @MainActor in
            do {
                try await tracker.performTraktLibraryAction(action, entry: entry, session: session)
                guard !Task.isCancelled, authorized else { return }
                busy = false
                didChange()
                dismiss()
            } catch {
                guard !Task.isCancelled, authorized else { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
private struct TrackerLibraryEditView: View {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
    let didSave: (TrackerLibraryEntry) -> Void
    @State private var edit: TrackerLibraryEdit
    @State private var progressText: String
    @State private var saving = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(TrackerLibrarySettings.enabledKey) private var enabled = TrackerLibrarySettings.defaultEnabled

    init(entry: TrackerLibraryEntry, session: TrackerLibrarySession, didSave: @escaping (TrackerLibraryEntry) -> Void) {
        self.entry = entry
        self.session = session
        self.didSave = didSave
        _edit = State(initialValue: TrackerLibraryEdit(entry: entry))
        _progressText = State(initialValue: String(entry.progress))
    }

    private var authorized: Bool {
        enabled && !profiles.isKidsModeActive && tracker.librarySessionIsCurrent(session)
    }

    private var changed: Bool { edit != TrackerLibraryEdit(entry: entry) || progressText != String(entry.progress) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(entry.title).font(.headline)
                    Text("Save changes to \(entry.service.displayName).")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Section {
                    Picker("Status", selection: $edit.status) {
                        ForEach(TrackerLibraryStatus.allCases) { status in Text(status.title(for: entry.kind)).tag(status) }
                    }
                    HStack {
                        Text(entry.kind == .anime ? "Episodes Watched" : "Chapters Read")
                        Spacer(minLength: 12)
                        TextField(entry.kind == .anime ? "Episodes Watched" : "Chapters Read", text: $progressText)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 60, maxWidth: 120)
                            .accessibilityLabel(entry.kind == .anime ? "Episodes Watched" : "Chapters Read")
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                    }
#if os(tvOS)
                    HStack {
                        Button { edit.score = max(0, edit.score - (entry.service == .myAnimeList ? 10 : 1)) } label: { Image(systemName: "minus") }
                            .accessibilityLabel("Decrease Rating")
                        Text(edit.score == 0 ? "Rating: Unrated" : String(format: "Rating: %g / 10", edit.score / 10))
                        Button { edit.score = min(100, edit.score + (entry.service == .myAnimeList ? 10 : 1)) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Increase Rating")
                    }
#else
                    Stepper(value: $edit.score, in: 0...100, step: entry.service == .myAnimeList ? 10 : 1) {
                        Text(edit.score == 0 ? "Rating: Unrated" : String(format: "Rating: %g / 10", edit.score / 10))
                    }
#endif
                    if let total = entry.total, total > 0 {
                        Text("Total: \(total) \(entry.kind.unit)").font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(saving || !authorized)
                if let error { Section { Text(error).foregroundColor(.red) } }
                if !authorized { Section { Text("This profile or tracker account changed. Close this editor and reload the library.").foregroundColor(.secondary) } }
            }
            .eclipseSettingsStyle()
            .navigationTitle("Edit Tracker Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { saveTask?.cancel(); dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || !authorized || !changed)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .onDisappear { saveTask?.cancel() }
    }

    private func save() {
        guard authorized, !saving else { return }
        guard let progress = Int(progressText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = TrackerLibraryError.invalidEdit.localizedDescription
            return
        }
        var candidate = edit
        candidate.progress = progress
        do { try candidate.validate(against: entry) } catch { self.error = error.localizedDescription; return }
        error = nil
        saving = true
        saveTask = Task { @MainActor in
            do {
                let saved = try await tracker.updateLibraryEntry(entry, edit: candidate, session: session)
                guard !Task.isCancelled, authorized else { saving = false; return }
                didSave(saved)
                saving = false
                dismiss()
            } catch {
                guard !Task.isCancelled else { saving = false; return }
                self.error = error is CancellationError ? "This edit is no longer authorized. Reload the library." : error.localizedDescription
                saving = false
            }
        }
    }
}
