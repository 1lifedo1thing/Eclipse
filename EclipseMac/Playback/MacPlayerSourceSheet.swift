#if os(macOS)
import SwiftUI

struct MacPlayerSourceSheet: View {
    @ObservedObject var session: MacPlaybackSession
    let episode: PlayerEpisodeBrowserItem?
    @State private var handoffIdentity: WatchTogetherPlaybackHandoffIdentity

    init(session: MacPlaybackSession, episode: PlayerEpisodeBrowserItem?) {
        self.session = session
        self.episode = episode
        _handoffIdentity = State(initialValue: WatchTogetherCoordinator.shared.playbackHandoffIdentity)
    }

    var body: some View {
        if let context = PlayerServicesSelectionContext(request: session.selectionRequest(for: episode)) {
            ModulesSearchResultsSheet(mediaTitle: context.mediaTitle,
                seasonTitleOverride: context.seasonTitleOverride, originalTitle: context.originalTitle,
                isMovie: context.isMovie, isAnimeContent: context.isAnime,
                selectedEpisode: context.selectedEpisode, tmdbId: context.tmdbID, mediaYear: context.mediaYear,
                animeSeasonTitle: context.animeSeasonTitle, posterPath: context.posterPath,
                originalAudioLanguage: context.originalAudioLanguage, imdbId: context.imdbID,
                originalTMDBSeasonNumber: context.originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: context.originalTMDBEpisodeNumber,
                specialTitleOnlySearch: context.specialTitleOnlySearch,
                episodePlaybackContext: context.episodePlaybackContext,
                autoModeOnly: episode != nil && (AutoModeSettings.isEnabled() || handoffIdentity.sessionID != nil),
                ignoresAutoMode: episode == nil,
                watchTogetherExactHandoff: episode != nil && handoffIdentity.sessionID != nil,
                onResolvedPlaybackRequest: { resolved in session.replacePlayback(with: resolved, episode: episode, watchTogetherIdentity: handoffIdentity) },
                isAnimationGenre16: context.isAnimation)
                .profileScopedAppStorage()
                .frame(minWidth: 660, idealWidth: 760, minHeight: 520, idealHeight: 700)
        }
    }
}
#endif
