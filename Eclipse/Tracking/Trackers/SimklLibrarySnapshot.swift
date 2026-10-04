import Foundation

enum SimklLibraryKind: String, CaseIterable, Hashable {
    case movie = "movies"
    case show = "shows"
    case anime

    var activityKey: String { self == .show ? "tv_shows" : rawValue }
}

struct SimklLibraryItem: Decodable {
    struct Identifier: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let integer = try? container.decode(Int.self) { value = integer }
            else if let string = try? container.decode(String.self), string.utf8.count <= 20,
                    let integer = Int(string), string == String(integer) { value = integer }
            else { throw TrackerLibraryError.invalidResponse }
            guard TrackerRemoteProgressBoundary.positiveIdentifier(value) != nil else { throw TrackerLibraryError.invalidResponse }
        }
    }

    struct IDs: Decodable {
        let simkl: Identifier
        let tmdb: Identifier?
        let mal: Identifier?
        let anilist: Identifier?
        let imdb: String?
    }

    struct Media: Decodable {
        let title: String
        let year: Int?
        let ids: IDs

        func validate() throws {
            guard !title.isEmpty, title.utf8.count <= 4_096,
                  year.map({ (1870...2200).contains($0) }) ?? true,
                  ids.imdb.map({ $0.utf8.count <= 32 && $0.hasPrefix("tt") && $0.count > 2 && $0.dropFirst(2).allSatisfy(\.isNumber) }) ?? true else {
                throw TrackerLibraryError.invalidResponse
            }
        }
    }

    struct Episode: Decodable {
        struct IDs: Decodable { let tvdb_id: Identifier? }
        let number: Int
        let ids: IDs?
    }

    struct Season: Decodable {
        let number: Int
        let episodes: [Episode]
    }

    let status: String
    let user_rating: Int?
    let watched_episodes_count: Int?
    let total_episodes_count: Int?
    let last_watched_at: String?
    let show: Media?
    let movie: Media?
    let anime_type: String?
    let seasons: [Season]?

    var media: Media? { movie ?? show }
    var mediaID: Int? { media?.ids.simkl.value }
    var progress: Int { watched_episodes_count ?? 0 }
    func movieIsCompleted(kind: SimklLibraryKind) throws -> Bool {
        if kind == .movie { return status == "completed" || last_watched_at != nil }
        guard kind == .anime, anime_type == "movie" else { return false }
        if status == "completed" { return true }
        guard total_episodes_count == 1, progress == 1 else { return false }
        return try contiguousAnimeProgress() == 1
    }

    var normalizedStatus: String {
        switch status {
        case "watching": return "CURRENT"
        case "plantowatch": return "PLANNING"
        case "completed": return "COMPLETED"
        case "hold": return "PAUSED"
        default: return "DROPPED"
        }
    }

    func validate(kind: SimklLibraryKind) throws {
        guard let media = kind == .movie ? movie : show,
              kind == .movie ? show == nil : movie == nil,
              (kind == .movie ? ["plantowatch", "completed", "dropped", "notinteresting"] : ["watching", "plantowatch", "completed", "hold", "dropped", "notinteresting"]).contains(status),
              kind == .movie || watched_episodes_count != nil,
              user_rating.map({ (0...10).contains($0) }) ?? true,
              (0...100_000).contains(progress),
              total_episodes_count.map({ (0...100_000).contains($0) }) ?? true,
              last_watched_at.map({ $0.utf8.count <= 64 && ISO8601DateFormatter().date(from: $0) != nil }) ?? true,
              anime_type.map({ ["tv", "movie", "ova", "ona", "special", "music video"].contains($0) }) ?? true else {
            throw TrackerLibraryError.invalidResponse
        }
        try media.validate()
        _ = try watchedSeasons()
    }

    func watchedSeasons() throws -> [Int: [Int]] {
        guard let seasons else { return [:] }
        guard seasons.count <= 1_000 else { throw TrackerLibraryError.tooLarge }
        var result: [Int: [Int]] = [:]
        var count = 0
        for season in seasons {
            guard (0...10_000).contains(season.number), result[season.number] == nil,
                  season.episodes.count <= 100_000 - count,
                  season.episodes.allSatisfy({ (1...100_000).contains($0.number) }) else {
                throw TrackerLibraryError.invalidResponse
            }
            let numbers = season.episodes.map(\.number)
            guard Set(numbers).count == numbers.count else { throw TrackerLibraryError.invalidResponse }
            result[season.number] = numbers.sorted()
            count += numbers.count
        }
        return result
    }

    func contiguousAnimeProgress() throws -> Int? {
        let values = try watchedSeasons()
        guard values.keys.allSatisfy({ $0 == 1 || $0 == 0 }) else { return nil }
        let numbers = values[1] ?? []
        guard progress == numbers.count, numbers.enumerated().allSatisfy({ $0.offset + 1 == $0.element }) else { return nil }
        return progress
    }

    static func decode(_ data: Data, kind: SimklLibraryKind) throws -> [Self] {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if object is NSNull { return [] }
        guard let dictionary = object as? [String: Any], dictionary.count <= 3,
              Set(dictionary.keys).isSubset(of: Set(SimklLibraryKind.allCases.map(\.rawValue))) else {
            throw TrackerLibraryError.invalidResponse
        }
        guard let raw = dictionary[kind.rawValue] else { return [] }
        guard let rows = raw as? [Any], rows.count <= TrackerLibraryPolicy.maximumEntries else { throw TrackerLibraryError.tooLarge }
        let bytes = try JSONSerialization.data(withJSONObject: rows)
        let items = try JSONDecoder().decode([Self].self, from: bytes)
        var seen = Set<Int>()
        for item in items {
            try item.validate(kind: kind)
            guard let id = item.mediaID, seen.insert(id).inserted else { throw TrackerLibraryError.invalidResponse }
        }
        return items
    }

    static func decodeIDs(_ data: Data, kind: SimklLibraryKind) throws -> Set<Int> {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if object is NSNull { return [] }
        guard let dictionary = object as? [String: Any], dictionary.count <= 3,
              Set(dictionary.keys).isSubset(of: Set(SimklLibraryKind.allCases.map(\.rawValue))) else {
            throw TrackerLibraryError.invalidResponse
        }
        guard let raw = dictionary[kind.rawValue] else { return [] }
        guard let rows = raw as? [[String: Any]], rows.count <= TrackerLibraryPolicy.maximumEntries else { throw TrackerLibraryError.tooLarge }
        var result = Set<Int>()
        for row in rows {
            guard let media = row[kind == .movie ? "movie" : "show"] as? [String: Any],
                  let ids = media["ids"] as? [String: Any] else { throw TrackerLibraryError.invalidResponse }
            let bytes = try JSONSerialization.data(withJSONObject: ids)
            let id = try JSONDecoder().decode(IDs.self, from: bytes).simkl.value
            guard result.insert(id).inserted else { throw TrackerLibraryError.invalidResponse }
        }
        return result
    }
}

struct SimklLibraryActivity: Equatable {
    let updated: String?
    let removed: String?

    static func decode(_ data: Data, kind: SimklLibraryKind) throws -> Self {
        guard data.count <= 256 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count <= 16,
              let domain = object[kind.activityKey] as? [String: Any],
              domain.count <= 32, domain.keys.contains("all"), domain.keys.contains("removed_from_list") else {
            throw TrackerLibraryError.invalidResponse
        }
        func date(_ key: String) throws -> String? {
            if domain[key] is NSNull { return nil }
            guard let raw = domain[key] as? String, raw.utf8.count <= 64,
                  ISO8601DateFormatter().date(from: raw) != nil else { throw TrackerLibraryError.invalidResponse }
            return raw
        }
        return try Self(updated: date("all"), removed: date("removed_from_list"))
    }
}
