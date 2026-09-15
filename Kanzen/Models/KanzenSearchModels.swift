#if !os(tvOS)
import SwiftUI

enum MangaSearchRecentStore {
    private static let key = "kanzenRecentSourceSearches"
    static let limit = 10

    static func load() -> [String] {
        ProfileSettingsStore.active.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var searches = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        searches.insert(trimmed, at: 0)
        searches = Array(searches.prefix(limit))
        ProfileSettingsStore.active.set(searches, forKey: key)
        return searches
    }

    static func clear() {
        ProfileSettingsStore.active.removeObject(forKey: key)
    }
}

struct MangaModuleSearchSection: Identifiable, Equatable {
    let id: String
    let source: MangaHomeSource
    let items: [MangaHomeItem]
}

struct MangaSourceSearchOutcome {
    let source: MangaHomeSource
    let items: [MangaHomeItem]
    let error: Error?
    let elapsedMs: Int
    let wasCancelled: Bool
    let timedOut: Bool

    static func success(source: MangaHomeSource, items: [MangaHomeItem], elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: items, error: nil, elapsedMs: elapsedMs, wasCancelled: false, timedOut: false)
    }

    static func failure(source: MangaHomeSource, error: Error, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: error, elapsedMs: elapsedMs, wasCancelled: false, timedOut: false)
    }

    static func cancelled(source: MangaHomeSource, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: nil, elapsedMs: elapsedMs, wasCancelled: true, timedOut: false)
    }

    static func timedOut(source: MangaHomeSource, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: nil, elapsedMs: elapsedMs, wasCancelled: false, timedOut: true)
    }
}

@MainActor
final class MangaGlobalModuleSearchViewModel: ObservableObject {
    @Published var sources: [MangaHomeSource] = []
    @Published var sections: [MangaModuleSearchSection] = []
    @Published var failedSourceNames: [String] = []
    @Published var isSearching = false
    @Published var hasSearched = false

    private static let maxConcurrentSourceSearches = 3
    private static let sourceTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let overallSearchTimeoutNanoseconds: UInt64 = 60_000_000_000
    private var searchToken = UUID()
    private var pendingSearchCount = 0
    private var searchStartedAt = Date.distantPast
    private var didLogFirstSourceResult = false
    private var queuedSources: [MangaHomeSource] = []
    private var nextSourceIndex = 0
    private var activeSourceIDs = Set<String>()
    private var sourceSearchTasks: [String: Task<Void, Never>] = [:]
    private var sourceTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var searchDeadlineTask: Task<Void, Never>?
    private var currentQuery: String?

    func refreshSources(from modules: [ModuleDataContainer], readerExtensionManager: ReaderExtensionManager) {
        MangaHomeSourceManager.shared.refreshSources(from: modules)
        let refreshedSources = MangaHomeSourceManager.shared.enabledSources(
            readerExtensionManager: readerExtensionManager,
            modules: modules
        )
        guard refreshedSources != sources else { return }
        sources = refreshedSources
        ReaderLogger.shared.log("Global search sources refreshed extensions=\(sources.filter(\.isReaderExtension).count) total=\(sources.count)", type: "ReaderSearch")
    }

    func isShowingResults(for query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && currentQuery == trimmed && hasSearched
    }

    func resetSearch() {
        cancelCurrentSearch(reason: "reset", clearResults: true)
    }

    func restrictForKidsProfile() {
        cancelCurrentSearch(reason: "kids-profile", clearResults: true)
        sources = []
    }

    func cancelSearch(keepResults: Bool = true) {
        cancelCurrentSearch(reason: "view-disappear", clearResults: !keepResults)
    }

    private func cancelCurrentSearch(reason: String, clearResults: Bool) {
        let wasSearching = isSearching
        searchToken = UUID()
        cancelOutstandingSearchTasks()
        pendingSearchCount = 0
        if clearResults {
            sections = []
            failedSourceNames = []
            hasSearched = false
            currentQuery = nil
        }
        isSearching = false
        if wasSearching {
            ReaderLogger.shared.log("Global search cancelled reason=\(reason)", type: "ReaderSearch")
        }
    }

    func searchAll(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSearch()
            return
        }

        let activeSources = sources.filter(\.isReaderExtension)
        currentQuery = trimmed
        guard !activeSources.isEmpty else {
            sections = []
            failedSourceNames = []
            isSearching = false
            hasSearched = true
            ReaderLogger.shared.log("Global search skipped no Reader Extensions queryLength=\(trimmed.count)", type: "ReaderSearch")
            return
        }

        let token = UUID()
        cancelOutstandingSearchTasks()
        searchToken = token
        isSearching = true
        hasSearched = true
        sections = []
        failedSourceNames = []
        pendingSearchCount = activeSources.count
        searchStartedAt = Date()
        didLogFirstSourceResult = false
        ReaderLogger.shared.log(
            "Global search started queryLength=\(trimmed.count) sources=\(activeSources.count)",
            type: "ReaderSearch"
        )
        ReaderLogger.shared.log(
            "Global search concurrency limit=\(Self.maxConcurrentSourceSearches)",
            type: "ReaderSearch"
        )

        queuedSources = activeSources
        nextSourceIndex = 0
        searchDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.overallSearchTimeoutNanoseconds)
            } catch {
                return
            }
            self?.searchDeadlineReached(token: token)
        }
        startQueuedSearches(query: trimmed, token: token)
    }

    private func startQueuedSearches(query: String, token: UUID) {
        guard searchToken == token, isSearching else { return }

        while activeSourceIDs.count < Self.maxConcurrentSourceSearches,
              nextSourceIndex < queuedSources.count {
            let source = queuedSources[nextSourceIndex]
            nextSourceIndex += 1
            activeSourceIDs.insert(source.id)

            let sourceStartedAt = Date()
            ReaderLogger.shared.log("Global search source started source=\(source.id)", type: "ReaderSearch")
            sourceSearchTasks[source.id] = Task { @MainActor [weak self] in
                let outcome = await Self.makeSearchOutcome(
                    source: source,
                    query: query,
                    startedAt: sourceStartedAt
                )
                self?.sourceSearchFinished(outcome, query: query, token: token)
            }
            sourceTimeoutTasks[source.id] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.sourceTimeoutNanoseconds)
                } catch {
                    return
                }
                self?.sourceSearchTimedOut(
                    source: source,
                    query: query,
                    token: token,
                    startedAt: sourceStartedAt
                )
            }
        }
    }

    private static func makeSearchOutcome(
        source: MangaHomeSource,
        query: String,
        startedAt: Date
    ) async -> MangaSourceSearchOutcome {
        do {
            try Task.checkCancellation()
            let items = try await searchSource(source, query: query, page: 1)
            try Task.checkCancellation()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .success(source: source, items: items, elapsedMs: elapsed)
        } catch is CancellationError {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .cancelled(source: source, elapsedMs: elapsed)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .failure(source: source, error: error, elapsedMs: elapsed)
        }
    }

    private func sourceSearchFinished(
        _ outcome: MangaSourceSearchOutcome,
        query: String,
        token: UUID
    ) {
        guard searchToken == token, activeSourceIDs.remove(outcome.source.id) != nil else { return }
        sourceSearchTasks.removeValue(forKey: outcome.source.id)
        sourceTimeoutTasks.removeValue(forKey: outcome.source.id)?.cancel()
        pendingSearchCount = max(0, pendingSearchCount - 1)
        handleSearchOutcome(outcome, token: token)
        startQueuedSearches(query: query, token: token)
        finishSearchIfNeeded(token: token)
    }

    private func sourceSearchTimedOut(
        source: MangaHomeSource,
        query: String,
        token: UUID,
        startedAt: Date
    ) {
        guard searchToken == token, activeSourceIDs.remove(source.id) != nil else { return }
        sourceSearchTasks.removeValue(forKey: source.id)?.cancel()
        sourceTimeoutTasks.removeValue(forKey: source.id)
        pendingSearchCount = max(0, pendingSearchCount - 1)
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        handleSearchOutcome(.timedOut(source: source, elapsedMs: elapsed), token: token)
        startQueuedSearches(query: query, token: token)
        finishSearchIfNeeded(token: token)
    }

    private func searchDeadlineReached(token: UUID) {
        guard searchToken == token, isSearching else { return }
        let unfinishedNames = queuedSources.enumerated().compactMap { index, source in
            (activeSourceIDs.contains(source.id) || index >= nextSourceIndex) ? source.name : nil
        }
        failedSourceNames = Array(Set(failedSourceNames + unfinishedNames)).sorted()
        let unfinishedCount = pendingSearchCount
        cancelOutstandingSearchTasks()
        pendingSearchCount = 0
        ReaderLogger.shared.log(
            "Global search deadline reached unfinished=\(unfinishedCount)",
            type: "ReaderSearch"
        )
        completeSearch(token: token)
    }

    private func finishSearchIfNeeded(token: UUID) {
        guard pendingSearchCount == 0,
              activeSourceIDs.isEmpty,
              nextSourceIndex >= queuedSources.count else { return }
        completeSearch(token: token)
    }

    private func completeSearch(token: UUID) {
        guard searchToken == token else { return }
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
        isSearching = false
        pendingSearchCount = 0
        let elapsed = Int(Date().timeIntervalSince(searchStartedAt) * 1000)
        ReaderLogger.shared.log(
            "Global search completed sections=\(sections.count) failures=\(failedSourceNames.count) elapsedMs=\(elapsed)",
            type: "ReaderSearch"
        )
    }

    private func cancelOutstandingSearchTasks() {
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
        sourceSearchTasks.values.forEach { $0.cancel() }
        sourceSearchTasks.removeAll()
        sourceTimeoutTasks.values.forEach { $0.cancel() }
        sourceTimeoutTasks.removeAll()
        activeSourceIDs.removeAll()
        queuedSources = []
        nextSourceIndex = 0
    }

    private func handleSearchOutcome(_ outcome: MangaSourceSearchOutcome, token: UUID) {
        guard searchToken == token else { return }

        if outcome.wasCancelled {
            ReaderLogger.shared.log("Global search source cancelled source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
            return
        }

        if outcome.timedOut {
            failedSourceNames.append(outcome.source.name)
            failedSourceNames.sort()
            ReaderLogger.shared.log("Global search source timed out source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
            return
        }

        if let error = outcome.error {
            failedSourceNames.append(outcome.source.name)
            failedSourceNames.sort()
            ReaderLogger.shared.log("Global search source failed source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            return
        }

        ReaderLogger.shared.log("Global search source finished source=\(outcome.source.id) count=\(outcome.items.count) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
        guard !outcome.items.isEmpty else { return }

        if !didLogFirstSourceResult {
            didLogFirstSourceResult = true
            let firstElapsed = Int(Date().timeIntervalSince(searchStartedAt) * 1000)
            ReaderLogger.shared.log("Global search first visible section source=\(outcome.source.id) elapsedMs=\(firstElapsed)", type: "ReaderSearch")
        }
        sections.append(MangaModuleSearchSection(id: outcome.source.id, source: outcome.source, items: outcome.items))
    }

    static func searchSource(_ source: MangaHomeSource, query: String, page: Int, filters: [ReaderExtensionFilter] = []) async throws -> [MangaHomeItem] {
        ReaderContentFilter.shared.filterHomeItems(
            try await searchSourceUnfiltered(source, query: query, page: page, filters: filters)
        )
    }

    private static func searchSourceUnfiltered(
        _ source: MangaHomeSource,
        query: String,
        page: Int,
        filters: [ReaderExtensionFilter]
    ) async throws -> [MangaHomeItem] {
        try Task.checkCancellation()
        switch source.kind {
        case .readerExtension:
            guard let sourceID = source.sourceID else { throw ReaderExtensionError.sourceNotFound }
            let provider = try ReaderExtensionManager.shared.provider(
                for: sourceID,
                allowsAutomaticBrowserVerification: true
            )
            let result = try await provider.search(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                page: max(page, 1),
                filters: filters
            )
            try Task.checkCancellation()
            return result.items
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { MangaHomeItem(sourceID: sourceID, item: $0) }

        case .aidoku:
            throw ReaderExtensionError.sourceNotFound

        case .legacyModule:
            guard let module = source.module else { return [] }
            let engine = KanzenEngine()
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try await engine.loadScript(script, module: module)
            let rawItems = try await engine.searchInput(query, page: page)
            return (rawItems ?? [])
                .compactMap { MangaHomeItem(dict: $0, module: module, sectionKind: .custom) }
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { $0 }
        }
    }
}


@MainActor
final class MangaReaderExtensionAdvancedSearchViewModel: ObservableObject {
    @Published var items: [MangaHomeItem] = []
    @Published var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published var hasSearched = false
    @Published var errorMessage: String?
    @Published var paginationErrorMessage: String?
    @Published private(set) var currentPage = 0
    @Published private(set) var hasNextPage = false

    private struct AppliedSearchSnapshot {
        let query: String
        let filters: [ReaderExtensionFilter]
    }

    private struct SearchPage {
        let items: [MangaHomeItem]
        let hasNextPage: Bool
    }

    private static let maxRetainedResults = 120
    private static let maxPageCount = 10

    private var searchToken = UUID()
    private var searchTask: Task<Void, Never>?
    private var appliedSearchSnapshot: AppliedSearchSnapshot?

    /// A catalog may only be built from a search that actually ran, so the
    /// saved row is guaranteed to reproduce what the user just looked at.
    var appliedCatalogDraft: (query: String, filters: [ReaderExtensionFilter])? {
        guard hasSearched, !isSearching, errorMessage == nil, let appliedSearchSnapshot else { return nil }
        return (appliedSearchSnapshot.query, appliedSearchSnapshot.filters)
    }

    var canLoadMore: Bool {
        hasSearched
            && hasNextPage
            && currentPage > 0
            && currentPage < Self.maxPageCount
            && items.count < Self.maxRetainedResults
            && !isSearching
            && !isLoadingMore
            && appliedSearchSnapshot != nil
    }

    var didReachResultLimit: Bool {
        hasSearched
            && hasNextPage
            && (currentPage >= Self.maxPageCount || items.count >= Self.maxRetainedResults)
    }

    func search(source: MangaHomeSource, query: String, filters: [ReaderExtensionFilter]) {
        let token = UUID()
        searchTask?.cancel()
        searchToken = token
        let snapshot = AppliedSearchSnapshot(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            filters: filters
        )
        appliedSearchSnapshot = snapshot
        isSearching = true
        isLoadingMore = false
        hasSearched = true
        errorMessage = nil
        paginationErrorMessage = nil
        items = []
        currentPage = 0
        hasNextPage = false
        ReaderLogger.shared.log("Advanced search started source=\(source.id) queryLength=\(snapshot.query.count) filters=\(snapshot.filters.count)", type: "ReaderSearch")

        searchTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let result = try await Self.searchPage(source: source, snapshot: snapshot, page: 1)
                try Task.checkCancellation()
                guard searchToken == token else { return }
                items = Self.merging([], with: result.items)
                currentPage = 1
                hasNextPage = result.hasNextPage
                isSearching = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search finished source=\(source.id) page=1 count=\(items.count) hasNext=\(result.hasNextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard searchToken == token else { return }
                isSearching = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search cancelled source=\(source.id) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard searchToken == token else { return }
                items = []
                errorMessage = error.localizedDescription
                isSearching = false
                currentPage = 0
                hasNextPage = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search failed source=\(source.id) elapsedMs=\(elapsed) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            }
        }
    }

    func loadMore(source: MangaHomeSource) {
        guard canLoadMore, let snapshot = appliedSearchSnapshot else { return }

        let token = searchToken
        let nextPage = currentPage + 1
        isLoadingMore = true
        paginationErrorMessage = nil
        ReaderLogger.shared.log("Advanced search load more started source=\(source.id) page=\(nextPage)", type: "ReaderSearch")

        searchTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let result = try await Self.searchPage(source: source, snapshot: snapshot, page: nextPage)
                try Task.checkCancellation()
                guard searchToken == token, appliedSearchSnapshot != nil else { return }
                items = Self.merging(items, with: result.items)
                currentPage = nextPage
                hasNextPage = result.hasNextPage
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more finished source=\(source.id) page=\(nextPage) received=\(result.items.count) retained=\(items.count) hasNext=\(result.hasNextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard searchToken == token else { return }
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more cancelled source=\(source.id) page=\(nextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard searchToken == token else { return }
                paginationErrorMessage = error.localizedDescription
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more failed source=\(source.id) page=\(nextPage) elapsedMs=\(elapsed) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            }
        }
    }

    func cancel() {
        let wasSearching = isSearching || isLoadingMore
        searchToken = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isLoadingMore = false
        if wasSearching {
            ReaderLogger.shared.log("Advanced search cancelled reason=view-disappear", type: "ReaderSearch")
        }
    }

    private static func searchPage(
        source: MangaHomeSource,
        snapshot: AppliedSearchSnapshot,
        page: Int
    ) async throws -> SearchPage {
        guard let sourceID = source.sourceID else { throw ReaderExtensionError.sourceNotFound }
        try Task.checkCancellation()
        let provider = try ReaderExtensionManager.shared.provider(
            for: sourceID,
            allowsAutomaticBrowserVerification: true
        )
        let result = try await provider.search(
            query: snapshot.query,
            page: max(page, 1),
            filters: snapshot.filters
        )
        try Task.checkCancellation()
        let mappedItems = result.items
            .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
            .map { MangaHomeItem(sourceID: sourceID, item: $0) }
        return SearchPage(
            items: ReaderContentFilter.shared.filterHomeItems(mappedItems),
            hasNextPage: result.hasNextPage
        )
    }

    private static func merging(
        _ existingItems: [MangaHomeItem],
        with newItems: [MangaHomeItem]
    ) -> [MangaHomeItem] {
        var merged = Array(existingItems.prefix(Self.maxRetainedResults))
        var retainedIDs = Set(merged.map(\.id))
        for item in newItems where merged.count < Self.maxRetainedResults {
            guard retainedIDs.insert(item.id).inserted else { continue }
            merged.append(item)
        }
        return merged
    }
}


#endif
