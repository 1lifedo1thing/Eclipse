import Foundation
import CryptoKit

enum RememberedPlaybackSettings {
    static let enabledKey = "rememberPlaybackSelectionEnabled"
    static let storageKey = "rememberedPlaybackSelectionsV1"

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    static func requiresSourceSelection(tmdbID: Int, season: Int?, animeID: Int?, defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        RememberedPlaybackSelection.load(
            key: RememberedPlaybackSelection.mediaKey(tmdbID: tmdbID, isMovie: false, season: season, animeID: animeID),
            defaults: defaults
        ) != nil
    }
}

enum AutoplayNextEpisodeSettings {
    static func isComplete(position: Double, duration: Double) -> Bool {
        position.isFinite && duration.isFinite && duration >= 5
            && position >= duration - min(3, max(0.5, duration * 0.005))
    }

    static let enabledKey = "autoplayNextEpisodeEnabled"

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }
}

struct RememberedPlaybackSelection: Codable, Equatable {
    let sourceID: String
    let searchHrefHash: String?
    let searchTitle: String?
    let streamLabel: String
    let savedAt: Date

    static func mediaKey(tmdbID: Int, isMovie: Bool, season: Int?, animeID: Int?) -> String? {
        guard tmdbID != 0 else { return nil }
        if isMovie { return "movie:\(tmdbID)" }
        if let animeID, animeID != 0 { return "tv:\(tmdbID):anime:\(animeID)" }
        guard let season, season >= 0 else { return nil }
        return "tv:\(tmdbID):season:\(season)"
    }

    static func normalizedLabel(_ text: String) -> String {
        let bounded = text.prefix(1_025)
        guard bounded.count <= 1_024 else { return "" }
        return String(bounded)
            .replacingOccurrences(of: #"(?i)https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bS\d{1,3}\s*E\d{1,5}\b|\b(?:episode|ep)\s*\d{1,5}\b|\bE\d{1,5}\b"#, with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hrefHash(_ href: String) -> String {
        SHA256.hash(data: Data(href.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matchingStreamIndex(labels: [String]) -> Int? {
        guard !streamLabel.isEmpty,
              streamLabel.range(of: #"^stream(?: \d+)?$"#, options: .regularExpression) == nil else { return nil }
        let matches = labels.indices.filter { Self.normalizedLabel(labels[$0]) == streamLabel }
        return matches.count == 1 ? matches.first : nil
    }

    func matchingSearchIndex(hrefs: [String], titles: [String]) -> Int? {
        guard hrefs.count == titles.count else { return nil }
        if let searchHrefHash {
            let exact = hrefs.indices.filter { Self.hrefHash(hrefs[$0]) == searchHrefHash }
            if exact.count == 1 { return exact.first }
        }
        guard let searchTitle, !searchTitle.isEmpty else { return nil }
        let matches = titles.indices.filter { Self.normalizedLabel(titles[$0]) == searchTitle }
        return matches.count == 1 ? matches.first : nil
    }

    private var isValid: Bool {
        !sourceID.isEmpty && sourceID.utf8.count <= 512
            && streamLabel.utf8.count <= 4096
            && (searchTitle?.utf8.count ?? 0) <= 4096
            && (searchHrefHash == nil || searchHrefHash?.count == 64)
            && savedAt.timeIntervalSince1970.isFinite
    }

    static func load(key: String?, defaults: UserDefaults = ProfileSettingsStore.active) -> Self? {
        guard RememberedPlaybackSettings.isEnabled(defaults: defaults), let key else { return nil }
        return read(defaults: defaults)?[key]
    }

    static func save(_ selection: Self, key: String?, defaults: UserDefaults = ProfileSettingsStore.active) {
        guard RememberedPlaybackSettings.isEnabled(defaults: defaults), let key,
              key.utf8.count <= 160, selection.isValid,
              var values = read(defaults: defaults) else { return }
        values[key] = selection
        if values.count > 200 {
            let retained = values.sorted {
                $0.value.savedAt == $1.value.savedAt ? $0.key < $1.key : $0.value.savedAt > $1.value.savedAt
            }.prefix(200)
            values = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        guard let bytes = try? JSONEncoder().encode(values), bytes.count <= 512 * 1024 else { return }
        defaults.set(bytes, forKey: RememberedPlaybackSettings.storageKey)
    }

    private static func read(defaults: UserDefaults) -> [String: Self]? {
        guard let raw = defaults.object(forKey: RememberedPlaybackSettings.storageKey) else { return [:] }
        guard let data = raw as? Data, data.count <= 512 * 1024,
              let values = try? JSONDecoder().decode([String: Self].self, from: data),
              values.count <= 200,
              values.allSatisfy({ $0.key.utf8.count <= 160 && $0.value.isValid }) else { return nil }
        return values
    }
}
