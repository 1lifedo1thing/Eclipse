#if os(macOS)
import Foundation

struct MacOnlineSubtitle: Identifiable {
    let id: String
    let title: String
    let language: String?
    let url: String
    let sourceID: String?
}

@MainActor
enum MacOnlineSubtitleResolver {
    static func resolve(request: PlaybackRequest, includesOpenSubtitles: Bool,
                        isStillCurrent: () -> Bool) async -> [MacOnlineSubtitle] {
        guard let media = request.mediaInfo, isStillCurrent() else { return [] }
        let id: Int
        let type: String
        let season: Int?
        let episode: Int?
        switch media {
        case .movie(let movieID, _, _, _):
            id = movieID; type = "movie"; season = nil; episode = nil
        case .episode(let showID, let seasonNumber, let episodeNumber, _, _, _):
            id = showID; type = "series"
            season = request.episodePlaybackContext?.resolvedTMDBSeasonNumber ?? request.originalTMDBSeasonNumber ?? seasonNumber
            episode = request.episodePlaybackContext?.resolvedTMDBEpisodeNumber ?? request.originalTMDBEpisodeNumber ?? episodeNumber
        }
        var imdb = request.imdbID
        if imdb == nil {
            if type == "movie" { imdb = try? await TMDBService.shared.getMovieDetails(id: id).imdbId }
            else { imdb = try? await TMDBService.shared.getTVShowDetails(id: id).externalIds?.imdbId }
        }
        guard isStillCurrent() else { return [] }
        let addons = await StremioAddonManager.shared.fetchSubtitlesFromAddons(tmdbId: id, imdbId: imdb,
            type: type, season: season, episode: episode,
            anilistId: request.episodePlaybackContext?.positiveAniListMediaId ?? request.episodePlaybackContext?.anilistMediaId,
            playbackContext: request.episodePlaybackContext,
            titleCandidates: [request.title, request.servicesOriginalTitle].compactMap { $0 }.filter { !$0.isEmpty })
        guard isStillCurrent() else { return [] }
        var results: [MacOnlineSubtitle] = []
        var seen = Set<String>()
        func append(_ subtitle: StremioSubtitle, source: String, sourceID: String?) {
            guard let raw = subtitle.url, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(raw).inserted else { return }
            let label = subtitle.name ?? subtitle.title ?? subtitle.lang ?? "Subtitle"
            results.append(.init(id: raw, title: "\(label) · \(source)", language: subtitle.lang, url: raw, sourceID: sourceID))
        }
        for result in addons.prefix(200) {
            let sourceID = SourceHealth.stremioId(result.addon)
            if StremioAddonComponentSettings.allowsSubtitles(sourceID: sourceID) {
                append(result.subtitle, source: result.addon.manifest.name, sourceID: sourceID)
            }
        }
        if includesOpenSubtitles, let imdb, !imdb.isEmpty {
            let subtitles = (try? await StremioClient.shared.fetchOpenSubtitlesV3(tmdbId: id,
                imdbId: imdb, type: type, season: season, episode: episode)) ?? []
            guard isStillCurrent() else { return [] }
            for subtitle in subtitles.prefix(200) { append(subtitle, source: "OpenSubtitles", sourceID: nil) }
        }
        let language = request.mediaSelectionIntent.preferredSubtitleLanguage
        let descriptors = results.map { PlaybackLanguageSelectionPolicy.Option(languageTag: $0.language, displayName: $0.title) }
        if let index = PlaybackLanguageSelectionPolicy.preferredIndex(in: descriptors, preferredLanguage: language) {
            let preferred = results.remove(at: index)
            results.insert(preferred, at: 0)
        }
        return Array(results.prefix(200))
    }
}
#endif
