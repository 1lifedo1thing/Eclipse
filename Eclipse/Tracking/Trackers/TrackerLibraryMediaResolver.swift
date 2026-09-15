import Foundation

struct TrackerLibraryMediaResolution {
    let match: TMDBSearchResult?
    let candidates: [TMDBSearchResult]
    let message: String?
}

enum TrackerLibraryMediaMatchPolicy {
    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func mediaType(for entry: TrackerLibraryEntry) -> String? {
        if entry.kind == .movie || entry.format == "MOVIE" { return "movie" }
        if entry.kind == .show || entry.format.map({ ["TV", "TV_SHORT"].contains($0) }) == true { return "tv" }
        return nil
    }

    static func uniqueMatch(entry: TrackerLibraryEntry, candidates: [TMDBSearchResult]) -> TMDBSearchResult? {
        let names = Set(([entry.title] + entry.alternateTitles).map(normalized).filter { !$0.isEmpty })
        let expectedType = mediaType(for: entry)
        var unique: [String: TMDBSearchResult] = [:]
        for candidate in candidates where candidate.id > 0 && ["movie", "tv"].contains(candidate.mediaType) {
            guard expectedType == nil || candidate.mediaType == expectedType,
                  entry.kind != .anime || candidate.genreIds?.contains(16) == true || candidate.isAnimeHint == true,
                  names.contains(normalized(candidate.displayTitle)) else { continue }
            if let year = entry.year {
                let date = candidate.releaseDate ?? candidate.firstAirDate
                guard let candidateYear = date.flatMap({ Int($0.prefix(4)) }), year == candidateYear else { continue }
            }
            unique[candidate.stableIdentity] = candidate
        }
        return unique.count == 1 ? unique.values.first : nil
    }
}

@MainActor
final class TrackerLibraryMediaResolver {
    static let shared = TrackerLibraryMediaResolver()
    private struct Key: Hashable {
        let session: TrackerLibrarySession
        let identity: String
        let language: String
        let metadata: String
    }
    private struct Cached {
        let resolution: TrackerLibraryMediaResolution
        let date: Date
    }
    private var cache: [Key: Cached] = [:]
    private var selections: [Key: Cached] = [:]

    func resolve(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession, aniListID: Int?) async throws -> TrackerLibraryMediaResolution {
        try validate(entry, session: session)
        let selectionKey = key(for: entry, session: session)
        let key = key(for: entry, session: session, aniListID: aniListID)
        if let chosen = selections[selectionKey] { return chosen.resolution }
        if let cached = cache[key] {
            let age = Date().timeIntervalSince(cached.date)
            if age >= 0 && age < (cached.resolution.match == nil ? 300 : 86_400) { return cached.resolution }
        }
        let result = try await resolveUncached(entry, session: session, aniListID: aniListID)
        try validate(entry, session: session)
        guard key.language == (ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US") else { throw CancellationError() }
        if cache.count >= 3_000, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache.removeValue(forKey: oldest) }
        if let chosen = selections[selectionKey] { return chosen.resolution }
        cache[key] = Cached(resolution: result, date: Date())
        return result
    }

    func invalidate(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession) {
        guard TrackerManager.shared.librarySessionIsCurrent(session) else { return }
        cache = cache.filter { $0.key.session != session || $0.key.identity != entry.id }
    }

    func remember(_ result: TMDBSearchResult, entry: TrackerLibraryEntry, session: TrackerLibrarySession) {
        guard (try? validate(entry, session: session)) != nil, result.id > 0, ["tv", "movie"].contains(result.mediaType) else { return }
        if selections.count >= 3_000, let oldest = selections.min(by: { $0.value.date < $1.value.date })?.key { selections.removeValue(forKey: oldest) }
        selections[key(for: entry, session: session)] = Cached(resolution: TrackerLibraryMediaResolution(match: result, candidates: [], message: nil), date: Date())
    }

    private func key(for entry: TrackerLibraryEntry, session: TrackerLibrarySession, aniListID: Int? = nil) -> Key {
        return Key(session: session, identity: entry.id,
            language: ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US",
            metadata: [entry.title, entry.alternateTitles.joined(separator: "|"), entry.format ?? "", String(entry.year ?? 0),
                       String(entry.tmdbID ?? 0), entry.imdbID ?? "", String(aniListID ?? entry.aniListID ?? 0)].joined(separator: "\u{1f}"))
    }

    func search(_ query: String, entry: TrackerLibraryEntry, session: TrackerLibrarySession) async throws -> [TMDBSearchResult] {
        try validate(entry, session: session)
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !query.isEmpty else { return [] }
        let results = try await TMDBService.shared.searchMulti(query: query, maxPages: 1)
        try validate(entry, session: session)
        let type = TrackerLibraryMediaMatchPolicy.mediaType(for: entry)
        return Array(results.filter { ["movie", "tv"].contains($0.mediaType) && (type == nil || $0.mediaType == type) }.prefix(24))
    }

    private func resolveUncached(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession, aniListID: Int?) async throws -> TrackerLibraryMediaResolution {
        let seedID = aniListID ?? entry.aniListID ?? entry.malID.map { -$0 }
        let seed = entry.kind == .anime ? seedID.map { AnimeMediaIdentitySeed(anilistId: $0, malId: entry.malID, format: entry.format) } : nil
        func resolved(_ result: TMDBSearchResult) -> TrackerLibraryMediaResolution {
            TrackerLibraryMediaResolution(match: result.withAnimeIdentitySeed(seed), candidates: [], message: nil)
        }
        if let id = entry.tmdbID, id > 0 {
            let result: TMDBSearchResult
            if entry.kind == .movie {
                let value = try await TMDBService.shared.getMovieDetails(id: id)
                result = TMDBSearchResult(id: value.id, mediaType: "movie", title: value.title, name: nil, overview: value.overview,
                    posterPath: value.posterPath, backdropPath: value.backdropPath, releaseDate: value.releaseDate, firstAirDate: nil,
                    voteAverage: value.voteAverage, popularity: value.popularity, adult: value.adult, genreIds: value.genres.map(\.id))
            } else {
                let value = try await TMDBService.shared.getTVShowDetails(id: id)
                result = TMDBSearchResult(id: value.id, mediaType: "tv", title: nil, name: value.name, overview: value.overview,
                    posterPath: value.posterPath, backdropPath: value.backdropPath, releaseDate: nil, firstAirDate: value.firstAirDate,
                    voteAverage: value.voteAverage, popularity: value.popularity, adult: value.adult, genreIds: value.genres.map(\.id))
            }
            try validate(entry, session: session)
            return resolved(result)
        }
        if let imdbID = entry.imdbID,
           let result = try await TMDBService.shared.findByIMDbId(imdbID, preferredMediaType: TrackerLibraryMediaMatchPolicy.mediaType(for: entry)),
           TrackerLibraryMediaMatchPolicy.mediaType(for: entry).map({ $0 == result.mediaType }) ?? true {
            try validate(entry, session: session)
            return resolved(result)
        }
        if let aniListID,
           let result = await AniListService.shared.resolveLibraryMapping(anilistID: aniListID, format: entry.format) {
            try validate(entry, session: session)
            return resolved(result)
        }
        var candidates: [TMDBSearchResult] = []
        for title in Array(([entry.title] + entry.alternateTitles).prefix(2)) {
            let results = try await search(title, entry: entry, session: session)
            for result in results where !candidates.contains(where: { $0.stableIdentity == result.stableIdentity }) { candidates.append(result) }
        }
        if let result = TrackerLibraryMediaMatchPolicy.uniqueMatch(entry: entry, candidates: candidates) { return resolved(result) }
        return TrackerLibraryMediaResolution(match: nil, candidates: Array(candidates.prefix(24)),
            message: candidates.isEmpty ? "No matching title found. Search to choose a match." : "Choose the matching title.")
    }

    private func validate(_ entry: TrackerLibraryEntry, session: TrackerLibrarySession) throws {
        try Task.checkCancellation()
        guard entry.kind.isVideo, entry.service == session.service, TrackerManager.shared.librarySessionIsCurrent(session) else { throw CancellationError() }
    }
}
