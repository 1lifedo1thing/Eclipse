#if !os(tvOS)
import Foundation
import Combine

@MainActor
struct TrackerReaderMatch: Identifiable {
    let item: MangaLibraryItem
    fileprivate let fallbackSeed: ReaderExtensionItem?
    let source: MangaHomeSource
    let language: String
    let chapterCount: Int
    let chapterCountVerified: Bool
    let legacyDetails: [String: Any]?
    let trackerEntryID: String
    fileprivate let preloadID: UUID
    fileprivate let authority: TrackerReaderAuthority

    var id: String { item.route?.stableKey ?? source.id }
    var sourceName: String { source.name }
    var isCurrent: Bool { authority.isCurrent }
    var seed: ReaderExtensionItem? { TrackerReaderResolver.shared.preload(for: self)?.seed ?? fallbackSeed }
    var hasPreloadedDetails: Bool { TrackerReaderResolver.shared.preload(for: self)?.seed != nil }
    var chapterGroups: [Chapters] { TrackerReaderResolver.shared.preload(for: self)?.groups ?? [] }
    var preloadedChapterGroups: [Chapters]? {
        guard let groups = TrackerReaderResolver.shared.preload(for: self)?.groups, !groups.isEmpty else { return nil }
        return groups
    }
    var extensionChapters: ReaderExtensionDetailChapterCache? { TrackerReaderResolver.shared.preload(for: self)?.extensionCache }
}

@MainActor
struct TrackerReaderResolution {
    let match: TrackerReaderMatch?
    let candidates: [TrackerReaderMatch]
    let message: String?
}

private final class TrackerReaderRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func advance() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }
}

@MainActor
fileprivate struct TrackerReaderAuthority {
    let session: TrackerLibrarySession
    let profile: ProgressManager.ProfileMutationAuthority
    let revision: UInt64
    let namespace: String
    let authentication: [ReaderExtensionSourceID: UInt64]
    let namespaceGeneration: UInt64

    var isCurrent: Bool {
        guard TrackerManager.shared.librarySessionIsCurrent(session),
              ProgressManager.shared.profileMutationAuthorityIsCurrent(profile),
              TrackerReaderResolver.shared.sourceRevision == revision,
              ReaderExtensionManager.shared.assetCacheScopeID() == namespace,
              ReaderExtensionAuthenticationGenerationRegistry.namespaceGeneration(namespace) == namespaceGeneration else { return false }
        return authentication.allSatisfy {
            ReaderExtensionAuthenticationGenerationRegistry.current(sourceID: $0.key, namespace: namespace) == $0.value
        }
    }

    func validate() throws {
        try Task.checkCancellation()
        guard isCurrent else { throw CancellationError() }
    }
}

@MainActor
private final class TrackerReaderPending<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var worker: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class TrackerReaderResolver {
    static let shared = TrackerReaderResolver()
    private static let maximumSources = 12
    private static let maximumConcurrentOperations = 3
    private static let maximumSearchRows = 60
    private static let maximumCandidatesPerSource = 2
    private static let operationTimeout: TimeInterval = 30
    private static let resolutionTimeout: TimeInterval = 90
    private let revision = TrackerReaderRevision()
    private var subscriptions = Set<AnyCancellable>()
    private var activeOperations = 0
    private var cache: [String: (expires: Date, value: TrackerReaderResolution, authority: TrackerReaderAuthority, entryID: String)] = [:]
    private var pending: [String: Task<TrackerReaderResolution, Error>] = [:]
    private var manualMatches: [String: TrackerReaderMatch] = [:]
    private var resolutionRevisions: [String: UUID] = [:]
    fileprivate struct Preload {
        let groups: [Chapters]
        let extensionCache: ReaderExtensionDetailChapterCache?
        let seed: ReaderExtensionItem?
    }
    private var preloads = TrackerReaderPreloadCache<Preload>()
    fileprivate var sourceRevision: UInt64 { revision.value }

    private init() {
        let revision = revision
        ReaderExtensionManager.shared.$installedSources.removeDuplicates().dropFirst().sink { _ in revision.advance() }.store(in: &subscriptions)
        ReaderExtensionManager.shared.$showMatureSources.removeDuplicates().dropFirst().sink { _ in revision.advance() }.store(in: &subscriptions)
        ModuleManager.shared.$modules.dropFirst().sink { _ in revision.advance() }.store(in: &subscriptions)
        MangaHomeSourceManager.shared.objectWillChange.sink { revision.advance() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .activeProfileDidChange).sink { _ in revision.advance() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification).sink { _ in revision.advance() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .readerExtensionAuthenticationDidChange).sink { _ in revision.advance() }.store(in: &subscriptions)
    }

    func resolve(entry: TrackerLibraryEntry, session: TrackerLibrarySession, forceRefresh: Bool = false) async throws -> TrackerReaderResolution {
        try Task.checkCancellation()
        guard entry.kind == .manga, entry.service == session.service,
              TrackerManager.shared.librarySessionIsCurrent(session),
              !ProfileManager.shared.isKidsModeActive,
              let profile = ProgressManager.shared.profileMutationAuthority(requiredOwner: session.owner) else { throw CancellationError() }
        if forceRefresh { invalidate(entry: entry, session: session) }
        let resolutionKey = "\(session.owner):\(entry.id)"
        if resolutionRevisions[resolutionKey] == nil {
            if resolutionRevisions.count >= 512 { resolutionRevisions.removeAll() }
            resolutionRevisions[resolutionKey] = UUID()
        }
        let resolutionRevision = resolutionRevisions[resolutionKey]
        manualMatches = manualMatches.filter { $0.value.isCurrent }
        if let remembered = manualMatches["\(session.owner):\(entry.id)"], remembered.authority.session == session {
            return TrackerReaderResolution(match: remembered, candidates: [remembered], message: nil)
        }
        let sources = availableSources(isNovel: ["NOVEL", "LIGHT_NOVEL"].contains(entry.format?.uppercased() ?? ""))
        let namespace = ReaderExtensionManager.shared.assetCacheScopeID()
        let authority = TrackerReaderAuthority(
            session: session, profile: profile, revision: sourceRevision, namespace: namespace,
            authentication: Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                source.sourceID.map { ($0, ReaderExtensionAuthenticationGenerationRegistry.current(sourceID: $0, namespace: namespace)) }
            }),
            namespaceGeneration: ReaderExtensionAuthenticationGenerationRegistry.namespaceGeneration(namespace)
        )
        let aliases = Array(([entry.title] + entry.alternateTitles).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(8))
        let authenticationKey = authority.authentication.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
        let key = "\(session.owner):\(profile.storeGeneration):\(session.operationGeneration):\(session.accountGeneration):\(session.serviceGeneration):\(entry.id):\(resolutionRevision?.uuidString ?? ""):\(authority.revision):\(authority.namespaceGeneration):\(authenticationKey):\(aliases.joined(separator: "|")):\(entry.format ?? "")"
        cache = cache.filter { $0.value.expires > Date() }
        if forceRefresh { cache.removeValue(forKey: key) }
        if let stored = cache[key], stored.authority.isCurrent {
            try authority.validate()
            return stored.value
        }
        if let operation = pending[key] {
            let value = try await operation.value
            try authority.validate()
            guard resolutionRevisions[resolutionKey] == resolutionRevision else { throw CancellationError() }
            return value
        }
        guard pending.count < 24 else {
            return TrackerReaderResolution(match: nil, candidates: [], message: "Reader sources are busy. Try this title again shortly.")
        }
        let operation = Task { @MainActor in
            try await self.resolveUncached(entry: entry, aliases: aliases, sources: sources, authority: authority)
        }
        pending[key] = operation
        defer { pending[key] = nil }
        let value = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try authority.validate()
        guard resolutionRevisions[resolutionKey] == resolutionRevision else { throw CancellationError() }
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache[oldest] = nil }
        cache[key] = (Date().addingTimeInterval(value.match == nil ? 30 : 600), value, authority, entry.id)
        return value
    }

    func invalidate(entry: TrackerLibraryEntry, session: TrackerLibrarySession) {
        guard entry.service == session.service, TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        let resolutionKey = "\(session.owner):\(entry.id)"
        resolutionRevisions[resolutionKey] = UUID()
        manualMatches.removeValue(forKey: resolutionKey)
        cache = cache.filter { $0.value.authority.session != session || $0.value.entryID != entry.id }
        for (key, operation) in pending where key.hasPrefix("\(session.owner):") && key.contains(":\(entry.id):") { operation.cancel() }
    }

    @discardableResult
    func remember(match: TrackerReaderMatch, entry: TrackerLibraryEntry, session: TrackerLibrarySession) -> Bool {
        guard entry.kind == .manga, entry.service == session.service, match.trackerEntryID == entry.id,
              match.authority.session == session, match.isCurrent else { return false }
        if manualMatches.count >= 64 { manualMatches.removeAll() }
        manualMatches["\(session.owner):\(entry.id)"] = match
        return true
    }

    fileprivate func preload(for match: TrackerReaderMatch) -> Preload? {
        guard match.isCurrent else { return nil }
        return preloads.value(for: match.preloadID)
    }

    private func availableSources(isNovel: Bool) -> [MangaHomeSource] {
        let extensions = ReaderExtensionManager.shared.enabledSources
            .filter { ($0.mediaType == .novel) == isNovel }
            .sorted { $0.sortIndex == $1.sortIndex ? $0.id.rawValue < $1.id.rawValue : $0.sortIndex < $1.sortIndex }
            .enumerated().map { MangaHomeSource.readerExtension($0.element, order: $0.offset) }
        let modules = ModuleManager.shared.modules
        let legacy: [MangaHomeSource]
        if isNovel {
            legacy = modules.filter { $0.moduleData.novel == true }.enumerated().map {
                .legacyModule($0.element, preference: MangaHomeSourcePreference(isEnabled: true, order: $0.offset), orderOffset: extensions.count)
            }
        } else {
            legacy = MangaHomeSourceManager.shared.legacySources(from: modules, orderOffset: extensions.count).filter(\.isEnabled)
        }
        return ReaderContentFilter.shared.filterSources(extensions + legacy).sorted {
            let lhs = ReaderExtensionLanguageInfo.priority(language(for: $0))
            let rhs = ReaderExtensionLanguageInfo.priority(language(for: $1))
            return lhs == rhs ? $0.order < $1.order : lhs < rhs
        }
    }

    private func language(for source: MangaHomeSource) -> String {
        source.readerExtensionSource?.effectiveLanguage ?? source.module?.moduleData.language ?? ""
    }

    private struct SourceOutcome {
        var matches: [TrackerReaderMatch] = []
        var complete = true
        var requiresVerification = false
    }

    private struct SearchPage {
        let items: [MangaHomeItem]
        let complete: Bool
    }

    private func resolveUncached(entry: TrackerLibraryEntry, aliases: [String], sources: [MangaHomeSource], authority: TrackerReaderAuthority) async throws -> TrackerReaderResolution {
        try authority.validate()
        guard !sources.isEmpty else { return TrackerReaderResolution(match: nil, candidates: [], message: "Connect a compatible Reader source to find this title.") }
        guard !aliases.isEmpty else { return TrackerReaderResolution(match: nil, candidates: [], message: "This title has no searchable name. Choose it in Reader Search.") }
        let selected = Array(sources.prefix(Self.maximumSources))
        let deadline = Date().addingTimeInterval(Self.resolutionTimeout)
        var outcomes: [SourceOutcome] = []
        await withTaskGroup(of: SourceOutcome.self) { group in
            var index = 0
            for _ in 0..<min(2, selected.count) {
                let source = selected[index]
                index += 1
                group.addTask { @MainActor in await self.resolveSource(source, entry: entry, aliases: aliases, authority: authority, deadline: deadline) }
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if index < selected.count, !Task.isCancelled, authority.isCurrent, Date() < deadline {
                    let source = selected[index]
                    index += 1
                    group.addTask { @MainActor in await self.resolveSource(source, entry: entry, aliases: aliases, authority: authority, deadline: deadline) }
                }
            }
        }
        try authority.validate()
        let all = outcomes.flatMap(\.matches)
        let candidates = all.map {
            TrackerReaderMatchPolicy.Candidate(id: $0.id, sourceID: $0.source.id, title: $0.item.title,
                languageRank: ReaderExtensionLanguageInfo.priority($0.language), chapterCount: $0.chapterCount,
                chapterCountVerified: $0.chapterCountVerified, sourceOrder: $0.source.order)
        }
        let completed = sources.count == selected.count && outcomes.count == selected.count && outcomes.allSatisfy(\.complete)
        let ranked = TrackerReaderMatchPolicy.ranked(candidates, aliases: aliases)
        let matches = ranked.compactMap { candidate in all.first { $0.id == candidate.id } }
        let winner = TrackerReaderMatchPolicy.automaticMatchID(candidates, aliases: aliases, completed: completed)
        let automatic = winner.flatMap { id in matches.first { $0.id == id } }
        for candidate in all where candidate.id != automatic?.id { preloads.remove(candidate.preloadID) }
        let message: String?
        if automatic != nil { message = nil }
        else if outcomes.contains(where: \.requiresVerification) { message = "A Reader source needs sign-in or browser verification. Open Reader Search to continue." }
        else if !completed { message = "Some Reader sources could not be checked. Choose a result or try again." }
        else if matches.isEmpty { message = "No verified Reader match was found. Search your connected sources to choose this title." }
        else { message = "Choose a Reader result to confirm this title and its chapter list." }
        return TrackerReaderResolution(match: automatic, candidates: matches, message: message)
    }

    private func resolveSource(_ source: MangaHomeSource, entry: TrackerLibraryEntry, aliases: [String], authority: TrackerReaderAuthority, deadline: Date) async -> SourceOutcome {
        var outcome = SourceOutcome()
        do {
            try authority.validate()
            var items: [MangaHomeItem] = []
            var seen = Set<String>()
            for query in aliases.prefix(2) {
                let result = try await bounded(authority: authority, deadline: deadline) {
                    try await self.search(source, query: query)
                }
                try authority.validate()
                if !result.complete || result.items.count > Self.maximumSearchRows { outcome.complete = false }
                for item in result.items.prefix(Self.maximumSearchRows) where !item.isContainer && seen.insert(item.id).inserted { items.append(item) }
                if items.contains(where: { TrackerReaderMatchPolicy.titleScore($0.title, aliases: aliases) == 100 }) { break }
            }
            let ranked = items.filter { TrackerReaderMatchPolicy.titleScore($0.title, aliases: aliases) >= 40 }.sorted {
                let lhs = TrackerReaderMatchPolicy.titleScore($0.title, aliases: aliases)
                let rhs = TrackerReaderMatchPolicy.titleScore($1.title, aliases: aliases)
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
            if ranked.filter({ TrackerReaderMatchPolicy.titleScore($0.title, aliases: aliases) == 100 }).count > Self.maximumCandidatesPerSource { outcome.complete = false }
            for item in ranked.prefix(Self.maximumCandidatesPerSource) {
                do {
                    let match = try await bounded(authority: authority, deadline: deadline) {
                        try await self.verify(item: item, source: source, entry: entry, authority: authority)
                    }
                    try authority.validate()
                    if let match { outcome.matches.append(match) }
                    else { outcome.complete = false }
                } catch {
                    if error is CancellationError { throw error }
                    outcome.complete = false
                    outcome.requiresVerification = outcome.requiresVerification || requiresVerification(error)
                }
            }
        } catch {
            outcome.complete = false
            outcome.requiresVerification = outcome.requiresVerification || requiresVerification(error)
        }
        return outcome
    }

    private func requiresVerification(_ error: Error) -> Bool {
        switch error as? ReaderExtensionError {
        case .browserVerificationRequired, .domainConsentRequired, .chapterSignInRequired: return true
        default: return false
        }
    }

    private func search(_ source: MangaHomeSource, query: String) async throws -> SearchPage {
        if let sourceID = source.sourceID {
            let provider = try ReaderExtensionManager.shared.provider(for: sourceID, emitsDomainConsentRequests: false)
            let page = try await provider.search(query: query, page: 1, filters: [])
            try Task.checkCancellation()
            return SearchPage(items: ReaderContentFilter.shared.filterHomeItems(page.items.prefix(Self.maximumSearchRows + 1).map { MangaHomeItem(sourceID: sourceID, item: $0) }), complete: !page.hasNextPage)
        }
        let items = try await MangaGlobalModuleSearchViewModel.searchSource(source, query: query, page: 0)
        return SearchPage(items: items, complete: items.count < MangaHomeViewModel.maxRetainedItemsPerSection)
    }

    private func verify(item: MangaHomeItem, source: MangaHomeSource, entry: TrackerLibraryEntry, authority: TrackerReaderAuthority) async throws -> TrackerReaderMatch? {
        try authority.validate()
        var libraryItem: MangaLibraryItem
        var seed: ReaderExtensionItem?
        var extensionCache: ReaderExtensionDetailChapterCache?
        var legacyDetails: [String: Any]?
        let groups: [Chapters]
        let selectedLanguage: String
        let count: (count: Int, verified: Bool)
        if let sourceID = source.sourceID {
            let provider = try ReaderExtensionManager.shared.provider(for: sourceID, emitsDomainConsentRequests: false)
            let detail = try await provider.detail(itemKey: item.params).merging(seed: item.readerExtensionItem)
            try authority.validate()
            guard detail.key == item.params, ReaderContentFilter.shared.allows(detail) else { return nil }
            let chapters = try await provider.chapters(itemKey: detail.key)
            try authority.validate()
            guard !chapters.isEmpty, chapters.count <= 20_000 else { return nil }
            let cache = ReaderExtensionDetailChapterCache.make(sourceID: sourceID, mediaType: provider.source.mediaType, item: detail, chapters: chapters)
            count = TrackerReaderMatchPolicy.distinctChapterCount(chapters.map(\.title))
            selectedLanguage = provider.source.effectiveLanguage
            groups = [Chapters(language: selectedLanguage, chapters: cache.readerChapters)]
            extensionCache = cache
            seed = detail
            libraryItem = .fromReaderExtension(sourceID: sourceID, itemKey: detail.key, title: detail.title,
                coverURL: ReaderExtensionSafeMetadata.sanitizedURLString(detail.coverURL), sourceName: source.name,
                latestChapterNumbers: cache.latestChapterNumbers, format: provider.source.mediaType == .novel ? "NOVEL" : "MANGA",
                contentRating: ReaderContentFilter.shared.derivedReaderExtensionRating(for: detail))
        } else if let module = source.module {
            let engine = KanzenEngine()
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try await engine.loadScript(script, module: module)
            try authority.validate()
            guard let raw = try await engine.extractChapters(params: item.params) else { return nil }
            try authority.validate()
            let snapshot = await LegacyReaderChapterSnapshot.prepare(Self.legacyChapters(raw))
            try authority.validate()
            let available = snapshot.groups.map { Chapters(language: $0.original.language, chapters: $0.readerChapters) }
            let preferred = language(for: source)
            groups = available.sorted {
                let lhs = ReaderExtensionLanguageInfo.priority($0.language, preferredLanguages: [preferred] + Locale.preferredLanguages)
                let rhs = ReaderExtensionLanguageInfo.priority($1.language, preferredLanguages: [preferred] + Locale.preferredLanguages)
                return lhs == rhs ? $0.language < $1.language : lhs < rhs
            }
            guard let first = groups.first, !first.chapters.isEmpty else { return nil }
            selectedLanguage = ["default", ""].contains(first.language.lowercased()) ? preferred : first.language
            count = TrackerReaderMatchPolicy.distinctChapterCount(first.chapters.map(\.chapterNumber))
            let detail = try await engine.extractDetails(params: item.params)
            try authority.validate()
            legacyDetails = Self.cachedLegacyDetails(detail)
            let title = detail?["title"] as? String ?? item.title
            let tags = detail?["tags"] as? [String] ?? item.tags
            let description = detail?["description"] as? String ?? detail?["synopsis"] as? String
            guard ReaderContentFilter.shared.allowsLegacy(title: title, tags: tags, description: description) else { return nil }
            libraryItem = .fromModule(moduleId: module.id, contentId: item.params, title: title,
                coverURL: item.imageURL, isNovel: module.moduleData.novel == true, sourceName: source.name,
                latestChapterNumbers: first.chapters.map(\.chapterNumber), contentRating: ReaderContentFilter.shared.derivedLegacyRating(tags: tags, description: description))
        } else { return nil }
        libraryItem.totalChapters = count.count
        libraryItem.latestChapterNumbers = nil
        libraryItem.trackerAniListId = entry.aniListID
        libraryItem.trackerMALId = entry.malID
        let preloadID = UUID()
        let rows = groups.reduce(0) { $0 + $1.chapters.count } + (extensionCache?.displayChapters.count ?? 0)
        preloads.insert(Preload(groups: groups, extensionCache: extensionCache, seed: seed), id: preloadID, rows: rows)
        var fallbackSeed = seed
        fallbackSeed?.description = nil
        fallbackSeed?.tags = []
        return TrackerReaderMatch(item: libraryItem, fallbackSeed: fallbackSeed, source: source,
            language: selectedLanguage, chapterCount: count.count,
            chapterCountVerified: count.verified, legacyDetails: legacyDetails, trackerEntryID: entry.id,
            preloadID: preloadID, authority: authority)
    }

    private static func cachedLegacyDetails(_ raw: [String: Any]?) -> [String: Any]? {
        guard let raw else { return nil }
        var result: [String: Any] = [:]
        for key in ["title", "description", "synopsis", "status"] {
            if let value = raw[key] as? String { result[key] = String(value.prefix(key == "description" || key == "synopsis" ? 32_768 : 1_024)) }
        }
        for key in ["tags", "authorArtist"] {
            if let values = raw[key] as? [String] { result[key] = values.prefix(64).map { String($0.prefix(256)) } }
        }
        return result
    }

    private func bounded<Value>(authority: TrackerReaderAuthority, deadline: Date, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let timeout = min(deadline, Date().addingTimeInterval(Self.operationTimeout))
        while activeOperations >= Self.maximumConcurrentOperations {
            try authority.validate()
            guard Date() < timeout else { throw ReaderExtensionError.runtimeTimedOut }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try authority.validate()
        guard Date() < timeout else { throw ReaderExtensionError.runtimeTimedOut }
        activeOperations += 1
        let pending = TrackerReaderPending<Value>()
        return try await withTaskCancellationHandler {
            if Task.isCancelled {
                activeOperations -= 1
                throw CancellationError()
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.worker = Task { @MainActor in
                    defer { self.activeOperations -= 1; pending.worker = nil }
                    do {
                        try authority.validate()
                        let value = try await operation()
                        try authority.validate()
                        pending.finish(.success(value))
                    } catch { pending.finish(.failure(error)) }
                }
                pending.timer = Task { @MainActor in
                    while Date() < timeout {
                        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                        if !authority.isCurrent {
                            pending.worker?.cancel()
                            pending.finish(.failure(CancellationError()))
                            return
                        }
                    }
                    pending.worker?.cancel()
                    pending.finish(.failure(ReaderExtensionError.runtimeTimedOut))
                }
            }
        } onCancel: {
            Task { @MainActor in
                pending.worker?.cancel()
                pending.finish(.failure(CancellationError()))
            }
        }
    }

    private static func legacyChapters(_ result: Any) -> [Chapters] {
        if let dictionary = result as? [String: Any] {
            return dictionary.keys.sorted().prefix(32).compactMap { key in
                guard let rows = dictionary[key] as? [Any], rows.count <= 20_000 else { return nil }
                let chapters = rows.enumerated().compactMap { index, value -> Chapter? in
                    guard let row = value as? [Any], row.count >= 2, let title = row[0] as? String,
                          let data = row[1] as? [[String: Any]], !data.isEmpty else { return nil }
                    let pages = data.compactMap(ChapterData.init(dict:))
                    guard !pages.isEmpty else { return nil }
                    return Chapter(chapterNumber: title, idx: index, chapterData: pages)
                }
                return chapters.isEmpty ? nil : Chapters(language: key, chapters: chapters)
            }
        }
        guard let rows = result as? [[String: Any]], rows.count <= 20_000 else { return [] }
        let chapters = rows.enumerated().compactMap { index, row -> Chapter? in
            guard let data = ChapterData(dict: row),
                  let title = (row["number"] as? NSNumber)?.stringValue ?? row["title"] as? String else { return nil }
            return Chapter(chapterNumber: title, idx: index, chapterData: [data])
        }
        return [Chapters(language: "default", chapters: chapters)]
    }
}
#endif
