import Foundation

struct PlaybackProgressRecoveryGuard {
    private(set) var trustedPosition: Double
    private var observedAt: TimeInterval
    private var isPaused: Bool
    private var rejectedDiscontinuity = false
    private var recoveryAdvanceEvidence = 0

    init?(position: Double, duration: Double, now: TimeInterval, isPaused: Bool) {
        guard position.isFinite, position >= 0,
              duration.isFinite, duration >= 5, position <= duration + 2,
              now.isFinite else { return nil }
        trustedPosition = min(position, duration)
        observedAt = now
        self.isPaused = isPaused
    }

    mutating func notePlaybackPaused(_ paused: Bool, now: TimeInterval) {
        guard paused != isPaused, now.isFinite else { return }
        isPaused = paused
        observedAt = now
    }

    mutating func noteForeground(now: TimeInterval) {
        guard now.isFinite, isPaused || rejectedDiscontinuity else { return }
        observedAt = now
    }

    mutating func noteRecoveryFailed(now: TimeInterval) {
        guard now.isFinite else { return }
        observedAt = now
        rejectedDiscontinuity = true
        recoveryAdvanceEvidence = 0
    }

    mutating func accepts(position: Double, duration: Double, now: TimeInterval, speed: Double) -> Bool {
        guard position.isFinite, position >= 0,
              duration.isFinite, duration >= 5, position <= duration + 2,
              now.isFinite, now >= observedAt else { return false }
        let elapsed = isPaused ? 0 : max(0, now - observedAt)
        let advancingInterval = rejectedDiscontinuity ? min(elapsed, 1) : elapsed
        let playbackRate = speed.isFinite && speed > 0 ? min(speed, 32) : 1
        let maximumAdvance = 12 + advancingInterval * playbackRate
        let candidate = min(position, duration)
        guard candidate <= trustedPosition + maximumAdvance,
              candidate >= trustedPosition - 12 else {
            observedAt = now
            rejectedDiscontinuity = true
            recoveryAdvanceEvidence = 0
            return false
        }
        let advance = candidate - trustedPosition
        if rejectedDiscontinuity, !isPaused, advance > 0.05 {
            if advance <= advancingInterval * playbackRate + 1 {
                recoveryAdvanceEvidence += 1
                if recoveryAdvanceEvidence >= 3 {
                    rejectedDiscontinuity = false
                    recoveryAdvanceEvidence = 0
                }
            } else {
                recoveryAdvanceEvidence = 0
            }
        } else if advance < -0.05 {
            recoveryAdvanceEvidence = 0
        }
        trustedPosition = candidate
        observedAt = now
        return true
    }
}

struct MPVDolbyPlaybackSettings {
    let visionEnabled: Bool
    let atmosEnabled: Bool
    let surroundEnabled: Bool

    init(defaults: UserDefaults) {
        visionEnabled = defaults.object(forKey: "mpvDolbyVisionEnabled") as? Bool ?? true
        atmosEnabled = defaults.object(forKey: "mpvDolbyAtmosEnabled") as? Bool ?? true
        surroundEnabled = defaults.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true
    }

    var videoFilterChain: String {
        visionEnabled ? "" : "@eclipse-dolby-vision:format=dolbyvision=no"
    }

    var options: [String: String] {
        let compressedAudio = atmosEnabled && surroundEnabled
        var values = [
            "apple-compressed-audio": compressedAudio ? "yes" : "no",
            "audio-spdif": compressedAudio ? "eac3" : "",
            "audio-channels": surroundEnabled ? "auto" : "stereo"
        ]
        if !visionEnabled {
            values["vf"] = videoFilterChain
        }
        return values
    }
}

enum PlaybackAudioOutputPolicy {
    static var driverList: String {
        #if os(macOS)
        return "avfoundation,coreaudio"
        #else
        return "avfoundation,audiounit"
        #endif
    }

    static func preferredChannelCount(maximum: Int, surroundEnabled: Bool) -> Int? {
        guard maximum > 0 else { return nil }
        return surroundEnabled ? maximum : min(2, maximum)
    }
}

enum PlaybackAudioTrackLabel {
    static func title(
        id: Int,
        title: String,
        language: String,
        codec: String = "",
        channelLayout: String = "",
        channelCount: Int = 0
    ) -> String {
        let suppliedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = suppliedTitle.isEmpty
            || ["unknown", "unknown language", "und", "audio", "track"].contains(suppliedTitle.lowercased())
            || suppliedTitle.range(
                of: #"^(?:audio\s*)?(?:track\s*)?[#(]?\s*\d+\s*\)?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        var parts = placeholder ? [] : [suppliedTitle]
        if let languageName = languageName(language),
           !containsTerm(languageName, in: suppliedTitle),
           !containsTerm(language.replacingOccurrences(of: "_", with: "-"), in: suppliedTitle) {
            parts.append(languageName)
        }
        if parts.isEmpty { parts.append("Audio \(id)") }

        let codecName = codecName(codec)
        if !codecName.isEmpty,
           !containsTerm(codecName, in: suppliedTitle),
           !containsTerm(codec, in: suppliedTitle) {
            parts.append(codecName)
        }
        let channels = channelName(layout: channelLayout, count: channelCount)
        if !channels.isEmpty, !containsTerm(channels, in: suppliedTitle) {
            parts.append(channels)
        }
        return parts.joined(separator: " · ")
    }

    private static func languageName(_ language: String) -> String? {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        guard !tag.isEmpty, !["und", "unknown", "unk"].contains(base) else { return nil }
        let normalized: String
        switch tag {
        case "jp": normalized = "ja"
        default: normalized = tag
        }
        let locale = Locale(identifier: "en")
        return locale.localizedString(forIdentifier: normalized)
            ?? locale.localizedString(forLanguageCode: normalized)
            ?? normalized.uppercased()
    }

    private static func codecName(_ codec: String) -> String {
        let normalized = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "unknown", "und": return ""
        case "aac", "mp4a": return "AAC"
        case ".mp3": return "MP3"
        case "lpcm": return "PCM"
        case "ac3", "ac-3": return "AC-3"
        case "eac3", "e-ac3", "ec-3": return "E-AC-3"
        case "truehd": return "TrueHD"
        case "dts", "dca": return "DTS"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default: return normalized.hasPrefix("pcm_") ? "PCM" : normalized.uppercased()
        }
    }

    private static func channelName(layout: String, count: Int) -> String {
        let normalized = layout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "mono": return "Mono"
        case "stereo": return "Stereo"
        case "", "unknown", "und": break
        default:
            if !normalized.hasPrefix("unknown") { return normalized }
        }
        return count > 0 ? "\(count) \(count == 1 ? "channel" : "channels")" : ""
    }

    private static func containsTerm(_ term: String, in title: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trimmed)
            + "(?![\\p{L}\\p{N}])"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum PlaybackAttachedSubtitleAdmission {
    static func allows(
        sourceKind: PlaybackSourceKind?,
        sourceID: String?,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> Bool {
        guard sourceKind == .stremio else { return true }
        guard let sourceID else { return false }
        return StremioAddonComponentSettings.allowsSubtitles(sourceID: sourceID, defaults: defaults)
    }
}

enum PlaybackSubtitlePrefetchPolicy {
    enum Source: Hashable {
        case addon
        case openSubtitles
    }

    struct Candidate {
        let url: String
        let source: Source
        let matchesPreferredLanguage: Bool
    }

    static func urls(
        candidates: [Candidate],
        enabledSources: Set<Source>,
        subtitlesEnabled: Bool,
        automaticFallbackEnabled: Bool,
        warmupEnabled: Bool,
        menuIsOpen: Bool,
        resourceConstrained: Bool
    ) -> [String] {
        guard !resourceConstrained,
              menuIsOpen || (subtitlesEnabled && automaticFallbackEnabled && warmupEnabled) else {
            return []
        }
        var seen = Set<String>()
        var sourceCounts: [Source: Int] = [:]
        var result: [String] = []
        for candidate in candidates {
            guard enabledSources.contains(candidate.source),
                  menuIsOpen || candidate.matchesPreferredLanguage,
                  sourceCounts[candidate.source, default: 0] < 2,
                  let url = URL(string: candidate.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false,
                  seen.insert(candidate.url).inserted else { continue }
            result.append(candidate.url)
            sourceCounts[candidate.source, default: 0] += 1
            if result.count == 4 { break }
        }
        return result
    }
}

struct PlaybackMediaSelectionIntent: Equatable {
    let preferredAudioLanguage: String?
    let preferredSubtitleLanguage: String?
    let subtitlesEnabled: Bool

    static func currentDefaults(isAnime: Bool, defaults: UserDefaults = ProfileSettingsStore.active) -> Self {
        Self(
            preferredAudioLanguage: isAnime
                ? normalizedLanguage(defaults.string(forKey: "preferredAnimeAudioLanguage") ?? "jpn")
                : normalizedLanguage(defaults.string(forKey: "preferredAutoAudioLanguage") ?? "eng"),
            preferredSubtitleLanguage: normalizedLanguage(
                defaults.string(forKey: "defaultSubtitleLanguage")
            ),
            subtitlesEnabled: defaults.bool(forKey: "enableSubtitlesByDefault")
        )
    }

    func overridingRendererSelection(
        audioLanguage: String?,
        subtitleLanguage: String?,
        hasSelectedSubtitle: Bool?
    ) -> Self {
        Self(
            preferredAudioLanguage: Self.normalizedLanguage(audioLanguage)
                ?? preferredAudioLanguage,
            preferredSubtitleLanguage: Self.normalizedLanguage(subtitleLanguage)
                ?? preferredSubtitleLanguage,
            subtitlesEnabled: hasSelectedSubtitle ?? subtitlesEnabled
        )
    }

    static func normalizedLanguage(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty || normalized == "und" ? nil : normalized
    }
}

enum PlaybackLanguageSelectionPolicy {
    struct Option: Equatable {
        let languageTag: String?
        let displayName: String
    }

    static func preferredIndex(
        in options: [Option],
        preferredLanguage: String?
    ) -> Int? {
        guard !options.isEmpty else { return nil }
        guard let preferred = PlaybackMediaSelectionIntent.normalizedLanguage(preferredLanguage) else {
            return nil
        }
        if let exact = options.firstIndex(where: {
            PlaybackMediaSelectionIntent.normalizedLanguage($0.languageTag) == preferred
        }) {
            return exact
        }
        let preferredID = MediaLanguageCatalog.canonicalID(for: preferred)
        let taggedIDs = options.map { option in
            option.languageTag.flatMap(MediaLanguageCatalog.canonicalID(for:))
        }
        if let preferredID {
            if let canonicalExact = taggedIDs.firstIndex(where: { $0 == preferredID }) {
                return canonicalExact
            }
            if let baseMatch = taggedIDs.firstIndex(where: {
                guard let languageID = $0 else { return false }
                return languagesAreCompatible(preferredID: preferredID, languageID: languageID)
            }) {
                return baseMatch
            }
        }

        let preferredNames = languageSearchTerms(for: preferred)
        return options.indices.first { index in
            if let preferredID, let languageID = taggedIDs[index],
               !languagesAreCompatible(preferredID: preferredID, languageID: languageID) {
                return false
            }
            let name = normalizedDisplayName(options[index].displayName)
            let nameTokens = Set(name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            if let preferredID {
                let displayedIDs = displayLanguageIDs(in: name, tokens: nameTokens)
                if !displayedIDs.isEmpty {
                    return displayedIDs.contains { languagesAreCompatible(preferredID: preferredID, languageID: $0) }
                }
            }
            return preferredNames.contains {
                containsDisplayTerm($0.value, in: name, tokens: nameTokens, requiresTagContext: $0.requiresTagContext)
            }
        }
    }

    private static func languagesAreCompatible(preferredID: String, languageID: String) -> Bool {
        if preferredID == languageID { return true }
        let preferredBase = preferredID.split(separator: "-").first.map(String.init) ?? preferredID
        let languageBase = languageID.split(separator: "-").first.map(String.init) ?? languageID
        if preferredBase == languageBase,
           preferredID == preferredBase || languageID == languageBase {
            return true
        }
        return MediaLanguageCatalog.matches(ruleID: preferredID, languageID: languageID)
            || (languageID.count == 2 && MediaLanguageCatalog.matches(ruleID: languageID, languageID: preferredID))
    }

    private static func languageSearchTerms(for normalizedLanguage: String) -> [(value: String, requiresTagContext: Bool)] {
        if let language = MediaLanguageCatalog.language(for: normalizedLanguage) {
            return languageDisplayTerms(for: language)
        }
        let value = normalizedDisplayName(normalizedLanguage)
        return [(value, isDisplayCode(value))]
    }

    private static func languageDisplayTerms(
        for language: MediaLanguageCatalog.Entry
    ) -> [(value: String, requiresTagContext: Bool)] {
        let names = Set([language.name, language.nativeName].map(normalizedDisplayName))
        return ([language.id, language.name, language.nativeName] + language.aliases)
            .filter { MediaLanguageCatalog.canonicalID(for: $0) == language.id }
            .map {
                let value = normalizedDisplayName($0)
                return (value, isDisplayCode(value) && !names.contains(value))
            }
    }

    private static func isDisplayCode(_ value: String) -> Bool {
        let components = value.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count),
              let first = components.first,
              (2...3).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return components.dropFirst().allSatisfy {
            (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    private static let displayAliases: [(id: String, value: String, requiresTagContext: Bool)] = {
        MediaLanguageCatalog.languages.flatMap { language in
            languageDisplayTerms(for: language).map {
                (id: language.id, value: $0.value, requiresTagContext: $0.requiresTagContext)
            }
        }.sorted { $0.value.count > $1.value.count }
    }()

    private static let displayCodeContextMatcher = try? NSRegularExpression(
        pattern: #"[\[({]\s*([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3})\s*[\])}]|\b(?:audio(?:\s+language)?|language|lang|track)\s*[:：=]\s*([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3})(?![A-Za-z0-9_-])"#
    )

    private static func displayLanguageIDs(in name: String, tokens: Set<String>) -> Set<String> {
        if let exact = MediaLanguageCatalog.canonicalID(for: name) { return [exact] }
        if let displayCodeContextMatcher {
            let ids = displayCodeContextMatcher.matches(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name))
                .compactMap { match -> String? in
                    for index in 1...2 {
                        guard let range = Range(match.range(at: index), in: name) else { continue }
                        if let id = MediaLanguageCatalog.canonicalID(for: String(name[range])) { return id }
                    }
                    return nil
                }
            if !ids.isEmpty { return Set(ids) }
        }
        var longestMatch = 0
        var ids = Set<String>()
        for alias in displayAliases {
            if alias.value.count < longestMatch { break }
            if containsDisplayTerm(alias.value, in: name, tokens: tokens, requiresTagContext: alias.requiresTagContext) {
                longestMatch = alias.value.count
                ids.insert(alias.id)
            }
        }
        return ids
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        String(value.prefix(1_024)).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func containsDisplayTerm(
        _ term: String,
        in name: String,
        tokens: Set<String>,
        requiresTagContext: Bool
    ) -> Bool {
        if requiresTagContext {
            guard let displayCodeContextMatcher else { return false }
            return displayCodeContextMatcher.matches(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)).contains { match in
                (1...2).contains { index in
                    guard let range = Range(match.range(at: index), in: name) else { return false }
                    return name[range] == term
                }
            }
        }
        if term.count <= 3 { return tokens.contains(term) }
        let isPhrase = term.contains(where: { $0.isWhitespace })
        let searchTerm = isPhrase ? normalizedDisplayPhrase(term) : term
        let searchName = isPhrase ? normalizedDisplayPhrase(name) : name
        var searchStart = searchName.startIndex
        while let range = searchName.range(of: searchTerm, range: searchStart..<searchName.endIndex) {
            let leadingBoundary = range.lowerBound == searchName.startIndex
                || !searchName[searchName.index(before: range.lowerBound)].isLetter
            let trailingBoundary = range.upperBound == searchName.endIndex || !searchName[range.upperBound].isLetter
            if leadingBoundary && trailingBoundary { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func normalizedDisplayPhrase(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct PlaybackEpisodeCoordinate: Equatable {
    let seasonNumber: Int
    let episodeNumber: Int

    init?(seasonNumber: Int?, episodeNumber: Int?) {
        guard let seasonNumber,
              let episodeNumber,
              seasonNumber >= 0 || AnimeSyntheticSeasonKey.isSynthetic(seasonNumber),
              episodeNumber > 0 else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

enum PlayerServicesButtonSettings {
    static let key = "showPlayerServicesButton"

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: key) == nil ? false : defaults.bool(forKey: key)
    }
}

struct PlayerServicesSelectionContext {
    let mediaTitle: String
    let seasonTitleOverride: String?
    let originalTitle: String?
    let isMovie: Bool
    let isAnime: Bool
    let selectedEpisode: TMDBEpisode?
    let tmdbID: Int
    let mediaYear: Int?
    let animeSeasonTitle: String?
    let posterPath: String?
    let originalAudioLanguage: String?
    let imdbID: String?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let specialTitleOnlySearch: Bool
    let episodePlaybackContext: EpisodePlaybackContext?
    let isAnimation: Bool

    init?(request: PlaybackRequest) {
        guard let mediaInfo = request.mediaInfo else { return nil }
        let fallbackPoster = request.artworkURL?.absoluteString
        switch mediaInfo {
        case .movie(let id, let title, let posterURL, let mediaIsAnime):
            mediaTitle = title
            seasonTitleOverride = nil
            originalTitle = request.servicesOriginalTitle
            isMovie = true
            isAnime = request.isAnime || mediaIsAnime
            selectedEpisode = nil
            tmdbID = id
            animeSeasonTitle = nil
            posterPath = posterURL ?? fallbackPoster
        case .episode(let showID, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let mediaIsAnime):
            let resolvedTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = resolvedTitle?.isEmpty == false ? resolvedTitle! : (requestTitle.isEmpty ? "Show" : requestTitle)
            let resolvedIsAnime = request.isAnime || mediaIsAnime || request.episodePlaybackContext?.hasAnimeMediaId == true
            mediaTitle = title
            isMovie = false
            isAnime = resolvedIsAnime
            seasonTitleOverride = resolvedIsAnime ? requestTitle.nilIfEmpty : nil
            originalTitle = request.servicesOriginalTitle
            selectedEpisode = TMDBEpisode(
                id: RemoteMediaNumericBoundary.syntheticIdentifier([
                    (showID, 1_000_000),
                    (max(0, seasonNumber), 10_000),
                    (max(1, episodeNumber), 1)
                ]),
                name: request.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                overview: nil,
                stillPath: nil,
                episodeNumber: episodeNumber,
                seasonNumber: seasonNumber,
                airDate: nil,
                runtime: nil,
                voteAverage: 0,
                voteCount: 0
            )
            tmdbID = showID
            animeSeasonTitle = resolvedIsAnime ? (requestTitle.nilIfEmpty ?? title) : nil
            posterPath = showPosterURL ?? fallbackPoster
        }
        originalAudioLanguage = request.servicesOriginalAudioLanguage
        mediaYear = request.mediaYear
        imdbID = request.imdbID
        originalTMDBSeasonNumber = request.episodePlaybackContext?.resolvedTMDBSeasonNumber
            ?? request.originalTMDBSeasonNumber
        originalTMDBEpisodeNumber = request.episodePlaybackContext?.resolvedTMDBEpisodeNumber
            ?? request.originalTMDBEpisodeNumber
        specialTitleOnlySearch = request.episodePlaybackContext?.titleOnlySearch ?? false
        episodePlaybackContext = request.episodePlaybackContext
        isAnimation = request.isAnimation
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct PlaybackExternalAudioTrack: Equatable, Sendable {
    let url: URL
    let label: String
    let headers: [String: String]

    init(url: URL, label: String, headers: [String: String] = [:]) {
        self.url = url
        self.label = String(label.prefix(256))
        self.headers = PlaybackRequest.sanitizedHeaders(headers)
    }
}

enum PlaybackExternalAudioTransport {
    struct Prepared {
        let url: URL
        let headers: [String: String]
        let launchContext: PlaybackLaunchContext?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidSource
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidSource: return "The source returned an unsupported external audio URL."
            case .unavailable: return "The external audio transport could not start."
            }
        }
    }

    static let mpvReason = "This source uses separate video and audio files and requires MPV."

    static func isCompound(_ url: URL) -> Bool {
        guard let target = MPVHeaderProxy.shared.originalTargetURL(for: url) else { return false }
        return target.host == "eclipse.invalid" && ["m3u8", "edl"].contains(target.pathExtension)
    }

    static func requiresMPV(_ url: URL) -> Bool {
        guard let target = MPVHeaderProxy.shared.originalTargetURL(for: url) else { return false }
        return target.host == "eclipse.invalid" && target.pathExtension == "edl"
    }

    static func usesHLS(video: URL, tracks: [PlaybackExternalAudioTrack]) -> Bool {
        !tracks.isEmpty && ([video] + tracks.map(\.url)).allSatisfy {
            ["m3u8", "m3u"].contains($0.pathExtension.lowercased())
        }
    }

    static func prepare(_ request: PlaybackRequest) throws -> PlaybackRequest {
        guard !request.externalAudioTracks.isEmpty else { return request }
        let prepared = try prepare(
            url: request.url, headers: request.headers, tracks: request.externalAudioTracks,
            launchContext: request.launchContext, mediaSelectionIntent: request.mediaSelectionIntent
        )
        guard let context = prepared.launchContext else { throw Failure.unavailable }
        return request.replacingResolvedTransport(
            url: prepared.url, headers: prepared.headers, subtitles: request.subtitles,
            subtitleNames: request.subtitleNames, subtitleHeadersByURL: request.subtitleHeadersByURL,
            externalAudioTracks: [], launchContext: context, resumePosition: request.resumePosition
        )
    }

    static func prepare(
        url: URL,
        headers: [String: String],
        tracks: [PlaybackExternalAudioTrack],
        launchContext: PlaybackLaunchContext?,
        mediaSelectionIntent: PlaybackMediaSelectionIntent
    ) throws -> Prepared {
        guard !tracks.isEmpty else {
            return Prepared(url: url, headers: headers, launchContext: launchContext)
        }
        guard tracks.count <= 32 else { throw Failure.invalidSource }
        for resource in [url] + tracks.map(\.url) {
            do {
                _ = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                    resource.absoluteString, purpose: .streamRoot
                )
            } catch { throw Failure.invalidSource }
        }
        let proxy = MPVHeaderProxy.shared
        var proxyURLs: [URL] = []
        var committed = false
        defer {
            if !committed { proxyURLs.forEach { proxy.invalidateSession(for: $0) } }
        }
        guard let videoURL = proxy.makeProxyURL(
            for: url, headers: headers, traceID: launchContext?.traceID, requiresPublicHTTP: true
        ) else { throw Failure.unavailable }
        proxyURLs.append(videoURL)
        var audio: [PlaybackExternalAudioTrack] = []
        for track in tracks {
            guard let audioURL = proxy.makeProxyURL(
                for: track.url, headers: track.headers, traceID: launchContext?.traceID,
                requiresPublicHTTP: true
            ) else { throw Failure.unavailable }
            proxyURLs.append(audioURL)
            audio.append(PlaybackExternalAudioTrack(url: audioURL, label: track.label))
        }
        let hls = usesHLS(video: url, tracks: tracks)
        let manifest = hls
            ? hlsManifest(video: videoURL, tracks: audio, preferredLanguage: mediaSelectionIntent.preferredAudioLanguage)
            : edlManifest(video: videoURL, tracks: audio)
        guard let compoundURL = proxy.makeLocalManifestURL(
            body: Data(manifest.utf8),
            contentType: hls ? "application/vnd.apple.mpegurl" : "application/x-mpv-edl",
            fileExtension: hls ? "m3u8" : "edl", compositeVideoURL: hls ? videoURL : nil,
            compositePreferredLanguage: mediaSelectionIntent.preferredAudioLanguage
        ) else { throw Failure.unavailable }
        proxyURLs.append(compoundURL)
        let priorLease = launchContext?.ephemeralProxyOwnership?.acquireLease()
        let ownership = PlaybackProxySessionOwnership(proxyURLs: proxyURLs) { proxyURL in
            proxy.invalidateSession(for: proxyURL)
            priorLease?.release()
        }
        let context = launchContext ?? PlaybackLaunchContext(
            sourceId: "direct-playback", sourceName: "Direct Stream", sourceKind: .service,
            autoMode: false, streamURL: url.absoluteString, headers: headers,
            subtitles: [], subtitleNames: nil, retryCount: 0
        )
        let ownedContext = PlaybackLaunchContext(
            traceID: context.traceID, traceCreatedAt: context.traceCreatedAt,
            sourceId: context.sourceId, sourceName: context.sourceName, sourceKind: context.sourceKind,
            autoMode: context.autoMode, streamURL: context.streamURL, streamName: context.streamName,
            headers: context.headers, subtitles: context.subtitles, subtitleNames: context.subtitleNames,
            subtitleHeadersByURL: context.subtitleHeadersByURL,
            headersDroppedBySanitizer: context.headersDroppedBySanitizer,
            retryCount: context.retryCount, titleCandidates: context.titleCandidates,
            serviceContentHref: context.serviceContentHref, providerContentReference: context.providerContentReference,
            ephemeralProxyOwnership: ownership
        )
        committed = true
        return Prepared(url: compoundURL, headers: [:], launchContext: ownedContext)
    }

    static func hlsManifest(
        video: URL, tracks: [PlaybackExternalAudioTrack], preferredLanguage: String?
    ) -> String {
        let preferred = PlaybackLanguageSelectionPolicy.preferredIndex(
            in: tracks.map { .init(languageTag: nil, displayName: $0.label) },
            preferredLanguage: preferredLanguage
        ) ?? 0
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
        for (index, track) in tracks.enumerated() {
            let name = hlsAttribute(track.label.isEmpty ? "Audio \(index + 1)" : track.label)
            let language = hlsLanguageTag(track.label).map { ",LANGUAGE=\"\($0)\"" } ?? ""
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name) (\(index + 1))\"\(language),DEFAULT=\(index == preferred ? "YES" : "NO"),AUTOSELECT=\(index == preferred ? "YES" : "NO"),URI=\"\(hlsAttribute(track.url.absoluteString))\"")
        }
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO=\"audio\"")
        lines.append(video.absoluteString)
        return lines.joined(separator: "\n") + "\n"
    }

    static func mergedHLSMaster(
        _ source: String, externalManifest: String, preferredLanguage: String? = nil
    ) throws -> String {
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U", source.utf8.count <= 128 * 1024 else { throw Failure.invalidSource }
        let variants = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        guard !variants.isEmpty else {
            guard lines.contains(where: { $0.hasPrefix("#EXTINF:") }) else { throw Failure.invalidSource }
            return externalManifest
        }
        guard variants.count <= 256,
              lines.filter({ !$0.isEmpty && !$0.hasPrefix("#") }).count == variants.count,
              !lines.contains(where: { $0.hasPrefix("#EXTINF:") }) else {
            throw Failure.invalidSource
        }
        let existingAudio = lines.filter {
            $0.hasPrefix("#EXT-X-MEDIA:") && hlsAttributeValue("TYPE", in: $0) == "AUDIO"
        }
        let externalAudio = externalManifest.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        guard !externalAudio.isEmpty else { throw Failure.invalidSource }
        var fallbackGroup = "eclipse-external-audio"
        while existingAudio.contains(where: { hlsAttributeValue("GROUP-ID", in: $0) == fallbackGroup }) {
            fallbackGroup += "-external"
        }
        var muxedGroup = fallbackGroup + "-original"
        while existingAudio.contains(where: { hlsAttributeValue("GROUP-ID", in: $0) == muxedGroup }) {
            muxedGroup += "-original"
        }
        func audioGroup(for variant: String) -> String {
            if let group = hlsAttributeValue("AUDIO", in: variant) { return group }
            let codecs = (hlsAttributeValue("CODECS", in: variant) ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let hasDeclaredAudio = codecs.contains { codec in
                codec.hasPrefix("mp4a.") || ["ac-3", "ec-3", "opus", "flac", "alac"].contains(codec)
            }
            return hasDeclaredAudio ? muxedGroup : fallbackGroup
        }
        let groups = Array(Set(variants.map { audioGroup(for: $0) })).sorted()
        var output = ["#EXTM3U"]
        for group in groups {
            var originals = existingAudio.filter { hlsAttributeValue("GROUP-ID", in: $0) == group }
            if group == muxedGroup {
                originals.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"" + muxedGroup + "\",NAME=\"Original audio\",DEFAULT=NO,AUTOSELECT=NO")
            }
            var names = Set(originals.compactMap { hlsAttributeValue("NAME", in: $0) })
            let additions = externalAudio.map { line -> String in
                var name = hlsAttributeValue("NAME", in: line) ?? "External audio"
                while names.contains(name) { name += " (external)" }
                names.insert(name)
                return settingHLSAttribute("NAME", value: "\"" + hlsAttribute(name) + "\"", in:
                    settingHLSAttribute("GROUP-ID", value: "\"" + hlsAttribute(group) + "\"", in: line)
                )
            }
            let combined = originals + additions
            let preferred = PlaybackLanguageSelectionPolicy.preferredIndex(in: combined.map {
                .init(languageTag: hlsAttributeValue("LANGUAGE", in: $0), displayName: hlsAttributeValue("NAME", in: $0) ?? "")
            }, preferredLanguage: preferredLanguage)
                ?? combined.firstIndex(where: { hlsAttributeValue("DEFAULT", in: $0) == "YES" }) ?? 0
            output += combined.enumerated().map { index, line in
                let selected = settingHLSAttribute("DEFAULT", value: index == preferred ? "YES" : "NO", in: line)
                return index == preferred ? settingHLSAttribute("AUTOSELECT", value: "YES", in: selected) : selected
            }
        }
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-MEDIA:"), hlsAttributeValue("TYPE", in: line) == "AUDIO",
               let group = hlsAttributeValue("GROUP-ID", in: line), groups.contains(group) { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let group = audioGroup(for: line)
                output.append(settingHLSAttribute("AUDIO", value: "\"" + hlsAttribute(group) + "\"", in:
                    settingHLSAttribute("CODECS", value: nil, in: line)
                ))
            } else if !line.isEmpty {
                output.append(line)
            }
        }
        let result = output.joined(separator: "\n") + "\n"
        guard result.utf8.count <= 128 * 1024 else { throw Failure.invalidSource }
        return result
    }

    private static func hlsAttributeValue(_ name: String, in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":"),
              let expression = try? NSRegularExpression(pattern: "(?:^|,)" + name + #"=("[^"]*"|[^,]*)"#) else { return nil }
        let attributes = String(line[line.index(after: colon)...])
        guard let match = expression.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func settingHLSAttribute(_ name: String, value: String?, in line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let prefix = String(line[...colon])
        var attributes = String(line[line.index(after: colon)...]).replacingOccurrences(
            of: "(?:^|,)" + name + #"=(?:"[^"]*"|[^,]*)"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: ","))
        if let value { attributes += (attributes.isEmpty ? "" : ",") + name + "=" + value }
        return prefix + attributes
    }

    private static func hlsLanguageTag(_ label: String) -> String? {
        let options = [PlaybackLanguageSelectionPolicy.Option(languageTag: nil, displayName: label)]
        return Locale.isoLanguageCodes.filter { $0.count == 2 }.sorted().first {
            PlaybackLanguageSelectionPolicy.preferredIndex(in: options, preferredLanguage: $0) != nil
        }
    }

    static func edlManifest(video: URL, tracks: [PlaybackExternalAudioTrack]) -> String {
        var lines = ["# mpv EDL v0", edlValue(video.absoluteString)]
        for (index, track) in tracks.enumerated() {
            lines.append("!new_stream")
            lines.append("!track_meta,title=" + edlValue(track.label.isEmpty ? "Audio \(index + 1)" : track.label))
            lines.append(edlValue(track.url.absoluteString))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func edlValue(_ value: String) -> String {
        "%\(value.utf8.count)%\(value)"
    }

    private static func hlsAttribute(_ value: String) -> String {
        String(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || $0 == "\"" || $0 == "\\" ? " " : String($0)
        }.joined())
    }
}

extension PlaybackLaunchContext {
    var usesMangayomiSource: Bool {
        guard sourceKind == .service, let href = serviceContentHref else { return false }
        if sourceId.hasPrefix("service:"), sourceId.utf8.count <= 128,
           let source = UUID(uuidString: String(sourceId.dropFirst(8))),
           (try? MangayomiMediaKey.decode(href, source: source, kind: "title")) != nil
                || (try? MangayomiMediaKey.decode(href, source: source, kind: "episode")) != nil {
            return true
        }
        return String(href.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("mangayomi:")
    }
}

struct PlaybackRequest {
    var usesMangayomiSource: Bool { launchContext?.usesMangayomiSource == true }

    let url: URL
    let preset: PlayerPreset
    let headers: [String: String]
    let subtitles: [String]
    let subtitleNames: [String]?
    let subtitleHeadersByURL: [String: [String: String]]?
    let externalAudioTracks: [PlaybackExternalAudioTrack]
    let mediaSelectionIntent: PlaybackMediaSelectionIntent
    let mediaInfo: MediaInfo?

    let kidsPolicyDetails: KidsPolicyDetails?
    let mediaYear: Int?
    let imdbID: String?
    let episodePlaybackContext: EpisodePlaybackContext?
    let launchContext: PlaybackLaunchContext?
    let resumePosition: Double?
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isAnime: Bool
    let isAnimation: Bool
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let servicesOriginalTitle: String?
    let servicesOriginalAudioLanguage: String?
    let onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)?
    let onRequestResolvedNextEpisode: ((ResolvedNextEpisodeTarget) -> Void)?
    let onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    let localNextEpisodeFallback: PlaybackEpisodeCoordinate?

    init(
        url: URL,
        preset: PlayerPreset? = nil,
        headers: [String: String] = [:],
        subtitles: [String] = [],
        subtitleNames: [String]? = nil,
        subtitleHeadersByURL: [String: [String: String]]? = nil,
        externalAudioTracks: [PlaybackExternalAudioTrack] = [],
        mediaSelectionIntent: PlaybackMediaSelectionIntent? = nil,
        mediaInfo: MediaInfo? = nil,
        kidsPolicyDetails: KidsPolicyDetails? = nil,
        mediaYear: Int? = nil,
        imdbID: String? = nil,
        episodePlaybackContext: EpisodePlaybackContext? = nil,
        launchContext: PlaybackLaunchContext? = nil,
        resumePosition: Double? = nil,
        title: String = "",
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isAnime: Bool = false,
        isAnimation: Bool = false,
        originalTMDBSeasonNumber: Int? = nil,
        originalTMDBEpisodeNumber: Int? = nil,
        servicesOriginalTitle: String? = nil,
        servicesOriginalAudioLanguage: String? = nil,
        onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = nil,
        onRequestResolvedNextEpisode: ((ResolvedNextEpisodeTarget) -> Void)? = nil,
        onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)? = nil,
        localNextEpisodeFallback: PlaybackEpisodeCoordinate? = nil
    ) {
        self.url = url
        self.preset = preset
            ?? PlayerPreset.presets.first
            ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        self.headers = Self.sanitizedHeaders(headers)
        self.subtitles = subtitles
        self.subtitleNames = subtitleNames
        self.subtitleHeadersByURL = subtitleHeadersByURL
        self.externalAudioTracks = Array(externalAudioTracks.prefix(32))
        self.mediaSelectionIntent = mediaSelectionIntent
            ?? PlaybackMediaSelectionIntent.currentDefaults(isAnime: isAnime)
        self.mediaInfo = mediaInfo
        self.kidsPolicyDetails = kidsPolicyDetails
        self.mediaYear = mediaYear.flatMap { (1800...3000).contains($0) ? $0 : nil }
        self.imdbID = imdbID
        self.episodePlaybackContext = episodePlaybackContext
        self.launchContext = launchContext
        if let resumePosition, resumePosition.isFinite, resumePosition > 0 {
            self.resumePosition = resumePosition
        } else {
            self.resumePosition = nil
        }
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isAnime = isAnime
        self.isAnimation = isAnimation
        self.originalTMDBSeasonNumber = originalTMDBSeasonNumber
        self.originalTMDBEpisodeNumber = originalTMDBEpisodeNumber
        self.servicesOriginalTitle = servicesOriginalTitle
        self.servicesOriginalAudioLanguage = servicesOriginalAudioLanguage
        self.onRequestNextEpisode = onRequestNextEpisode
        self.onRequestResolvedNextEpisode = onRequestResolvedNextEpisode
        self.onPlaybackStartupFailure = onPlaybackStartupFailure
        self.localNextEpisodeFallback = localNextEpisodeFallback
    }

    fileprivate static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty,
                  key.rangeOfCharacter(from: .newlines) == nil,
                  value.rangeOfCharacter(from: .newlines) == nil else { return }
            result[key] = value
        }
    }

    func replacingMediaSelectionIntent(_ mediaSelectionIntent: PlaybackMediaSelectionIntent) -> PlaybackRequest {
        PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            externalAudioTracks: externalAudioTracks,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: mediaInfo,
            kidsPolicyDetails: kidsPolicyDetails,
            mediaYear: mediaYear,
            imdbID: imdbID,
            episodePlaybackContext: episodePlaybackContext,
            launchContext: launchContext,
            resumePosition: resumePosition,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isAnime: isAnime,
            isAnimation: isAnimation,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            servicesOriginalTitle: servicesOriginalTitle,
            servicesOriginalAudioLanguage: servicesOriginalAudioLanguage,
            onRequestNextEpisode: onRequestNextEpisode,
            onRequestResolvedNextEpisode: onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: onPlaybackStartupFailure,
            localNextEpisodeFallback: localNextEpisodeFallback
        )
    }

    func replacingResolvedTransport(
        url: URL,
        headers: [String: String],
        subtitles: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]?,
        externalAudioTracks: [PlaybackExternalAudioTrack]? = nil,
        launchContext: PlaybackLaunchContext,
        resumePosition: Double?
    ) -> PlaybackRequest {
        PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            externalAudioTracks: externalAudioTracks ?? self.externalAudioTracks,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: mediaInfo,
            kidsPolicyDetails: kidsPolicyDetails,
            mediaYear: mediaYear,
            imdbID: imdbID,
            episodePlaybackContext: episodePlaybackContext,
            launchContext: launchContext,
            resumePosition: resumePosition,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isAnime: isAnime,
            isAnimation: isAnimation,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            servicesOriginalTitle: servicesOriginalTitle,
            servicesOriginalAudioLanguage: servicesOriginalAudioLanguage,
            onRequestNextEpisode: onRequestNextEpisode,
            onRequestResolvedNextEpisode: onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: onPlaybackStartupFailure,
            localNextEpisodeFallback: localNextEpisodeFallback
        )
    }
}
