import Foundation

enum TrackerLibrarySettings {
    static let enabledKey = "trackerDeepLibraryEnabled"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        isEnabled(defaults: ProfileSettingsStore.active)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TrackerLibrarySource: String, CaseIterable, Identifiable {
    case local
    case anilist
    case myAnimeList

    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "My Library"
        case .anilist: return "AniList"
        case .myAnimeList: return "MAL"
        }
    }
    var service: TrackerService? {
        switch self {
        case .local: return nil
        case .anilist: return .anilist
        case .myAnimeList: return .myAnimeList
        }
    }
}

enum TrackerLibraryKind: String, CaseIterable, Identifiable {
    case anime = "ANIME"
    case manga = "MANGA"

    var id: String { rawValue }
    var title: String { self == .anime ? "Anime" : "Manga" }
    var unit: String { self == .anime ? "episodes" : "chapters" }
    var malPath: String { self == .anime ? "anime" : "manga" }
    var malListKind: TrackerRemoteProgressBoundary.MALListKind {
        self == .anime ? .anime : .manga
    }

    func malFields(listStatusKey: String) -> String {
        let progress = self == .anime ? "num_episodes_watched" : "num_chapters_read"
        let repeating = self == .anime ? "is_rewatching" : "is_rereading"
        let total = self == .anime ? "num_episodes" : "num_chapters"
        return "\(listStatusKey){status,score,\(progress),\(repeating),updated_at},\(total),genres,mean,main_picture"
    }
}

enum TrackerLibraryStatus: String, CaseIterable, Identifiable {
    case current = "CURRENT"
    case planning = "PLANNING"
    case completed = "COMPLETED"
    case paused = "PAUSED"
    case dropped = "DROPPED"
    case repeating = "REPEATING"

    var id: String { rawValue }

    func title(for kind: TrackerLibraryKind) -> String {
        switch self {
        case .current: return kind == .anime ? "Watching" : "Reading"
        case .planning: return "Planning"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .dropped: return "Dropped"
        case .repeating: return kind == .anime ? "Rewatching" : "Rereading"
        }
    }

    func malValue(for kind: TrackerLibraryKind) -> String {
        switch self {
        case .current, .repeating: return kind == .anime ? "watching" : "reading"
        case .planning: return kind == .anime ? "plan_to_watch" : "plan_to_read"
        case .completed: return "completed"
        case .paused: return "on_hold"
        case .dropped: return "dropped"
        }
    }

    static func fromMAL(_ value: String, repeating: Bool) -> Self? {
        let status: Self?
        switch value {
        case "watching", "reading": status = .current
        case "plan_to_watch", "plan_to_read": status = .planning
        case "completed": status = .completed
        case "on_hold": status = .paused
        case "dropped": status = .dropped
        default: status = nil
        }
        guard let status else { return nil }
        return repeating ? .repeating : status
    }
}

struct TrackerLibrarySession: Equatable {
    let owner: UUID
    let operationGeneration: UInt64
    let accountGeneration: UInt64
    let serviceGeneration: UInt64
    let service: TrackerService
    let userID: String

    func authorizes(_ current: Self, enabled: Bool, isKids: Bool) -> Bool {
        enabled && !isKids && self == current
    }
}

struct TrackerLibraryEntry: Identifiable, Equatable {
    let service: TrackerService
    let kind: TrackerLibraryKind
    let mediaID: Int
    let entryID: Int?
    let aniListID: Int?
    let malID: Int?
    let title: String
    let alternateTitles: [String]
    let coverLarge: String?
    let coverMedium: String?
    let total: Int?
    let genres: [String]
    let averageScore: Double?
    var status: TrackerLibraryStatus
    var progress: Int
    var score: Double
    var updatedAt: Date?

    var id: String { "\(service.rawValue):\(kind.rawValue):\(mediaID)" }
    var coverURL: URL? {
        let value = ImageDataSaverSettings.isEnabled()
            ? coverMedium ?? coverLarge : coverLarge ?? coverMedium
        return value.flatMap(TrackerLibraryPolicy.imageURL)
    }
    var websiteURL: URL? {
        let host = service == .anilist ? "anilist.co" : "myanimelist.net"
        return URL(string: "https://\(host)/\(kind.malPath)/\(mediaID)")
    }
}

struct TrackerLibraryEdit: Equatable {
    var status: TrackerLibraryStatus
    var progress: Int
    var score: Double

    init(entry: TrackerLibraryEntry) {
        status = entry.status
        progress = entry.progress
        score = entry.score
    }

    func validate(against original: TrackerLibraryEntry) throws {
        guard (0...TrackerLibraryPolicy.maximumProgress).contains(progress),
              score.isFinite, (0...100).contains(score),
              original.service != .myAnimeList || score.truncatingRemainder(dividingBy: 10) == 0 else {
            throw TrackerLibraryError.invalidEdit
        }
        if progress != original.progress, let total = original.total, total > 0, progress > total {
            throw TrackerLibraryError.progressExceedsTotal
        }
    }

    func conflicts(original: TrackerLibraryEntry, current: TrackerLibraryEntry) -> Bool {
        original.id != current.id
            || (status != original.status && current.status != original.status && current.status != status)
            || (progress != original.progress && current.progress != original.progress && current.progress != progress)
            || (score != original.score && current.score != original.score && current.score != score)
    }

    func aniListValues(original: TrackerLibraryEntry) -> [String: Any] {
        var values: [String: Any] = [:]
        if status != original.status { values["status"] = status.rawValue }
        if progress != original.progress { values["progress"] = progress }
        if score != original.score { values["scoreRaw"] = Int(score.rounded()) }
        return values
    }

    func malValues(original: TrackerLibraryEntry) -> [String: String] {
        var values: [String: String] = [:]
        if status != original.status {
            values["status"] = status.malValue(for: original.kind)
            values[original.kind == .anime ? "is_rewatching" : "is_rereading"] = status == .repeating ? "true" : "false"
        }
        if progress != original.progress {
            values[original.kind == .anime ? "num_watched_episodes" : "num_chapters_read"] = String(progress)
        }
        if score != original.score { values["score"] = String(Int((score / 10).rounded())) }
        return values
    }
}

enum TrackerLibraryError: LocalizedError {
    case unavailable
    case invalidResponse
    case tooLarge
    case invalidEdit
    case progressExceedsTotal
    case conflict
    case missingEntry
    case noMatch
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Enable Deep Library Integration and connect this tracker in Settings to view its library."
        case .invalidResponse: return "The tracker returned an unreadable response. Refresh the library before trying again."
        case .tooLarge: return "This list exceeds the supported library limit. Select a status to load a smaller list."
        case .invalidEdit: return "Enter a valid progress count and rating."
        case .progressExceedsTotal: return "Progress cannot exceed the known episode or chapter total."
        case .conflict: return "This entry changed on the tracker while you were editing. Refresh the library before saving again."
        case .missingEntry: return "This entry is no longer on your tracker list. Refresh the library."
        case .noMatch: return "This title could not be matched to Eclipse metadata. You can still edit it or open its tracker page."
        case .requestFailed(let status): return "The tracker could not complete the request (\(status)). Try again later."
        }
    }
}

enum TrackerLibraryPolicy {
    static let maximumProgress = 100_000
    static let maximumEntries = 20_000
    static let maximumPageCount = 200
    static let pageSize = 100
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func imageURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8_192,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    static func allowsMALPage(_ url: URL, kind: TrackerLibraryKind) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil else { return false }
        return TrackerRemoteProgressBoundary.isAllowedMALPageURL(url, listKind: kind.malListKind)
    }

    static func validate(_ entry: TrackerLibraryEntry) throws {
        guard TrackerRemoteProgressBoundary.positiveIdentifier(entry.mediaID) != nil,
              !entry.title.isEmpty, entry.title.utf8.count <= 4_096,
              entry.alternateTitles.count <= 3,
              entry.alternateTitles.allSatisfy({ $0.utf8.count <= 4_096 }),
              (0...maximumProgress).contains(entry.progress),
              entry.total.map({ (0...maximumProgress).contains($0) }) ?? true,
              entry.score.isFinite, (0...100).contains(entry.score),
              entry.service != .myAnimeList || entry.score.truncatingRemainder(dividingBy: 10) == 0,
              entry.averageScore.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              entry.genres.count <= 64,
              entry.genres.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw TrackerLibraryError.invalidResponse
        }
    }

    static func append(_ page: [TrackerLibraryEntry], to entries: inout [TrackerLibraryEntry]) throws {
        guard page.count <= pageSize * 10 else { throw TrackerLibraryError.tooLarge }
        var seen = Set(entries.map(\.id))
        for entry in page where seen.insert(entry.id).inserted {
            guard entries.count < maximumEntries else { throw TrackerLibraryError.tooLarge }
            entries.append(entry)
        }
    }

    static func filtered(_ entries: [TrackerLibraryEntry], search: String, genre: String?) -> [TrackerLibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (genre.map { entry.genres.contains($0) } ?? true)
                && (query.isEmpty || ([entry.title] + entry.alternateTitles).contains {
                    $0.localizedStandardContains(query)
                })
        }.sorted {
            let left = $0.updatedAt ?? .distantPast
            let right = $1.updatedAt ?? .distantPast
            if left != right { return left > right }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

struct TrackerAniListLibraryPage: Decodable {
    let data: Body?
    let errors: [GraphQLError]?

    struct GraphQLError: Decodable { let message: String? }
    struct Body: Decodable {
        let MediaListCollection: Collection?
        let MediaList: Entry?
        let SaveMediaListEntry: Entry?
    }
    struct Collection: Decodable {
        let hasNextChunk: Bool
        let lists: [Group]
    }
    struct Group: Decodable { let entries: [Entry] }
    struct Entry: Decodable {
        let id: Int
        let mediaId: Int
        let status: String
        let progress: Int
        let score: Double
        let updatedAt: Int?
        let media: Media
    }
    struct Media: Decodable {
        let id: Int
        let idMal: Int?
        let type: String
        let title: Title
        let coverImage: Cover?
        let episodes: Int?
        let chapters: Int?
        let genres: [String]?
        let averageScore: Double?
    }
    struct Title: Decodable { let english: String?; let romaji: String?; let native: String? }
    struct Cover: Decodable { let large: String?; let medium: String? }

    static let entryFields = """
        id mediaId status progress score(format: POINT_100) updatedAt
        media { id idMal type title { english romaji native } coverImage { large medium } episodes chapters genres averageScore }
        """

    static func decode(_ bytes: Data, kind: TrackerLibraryKind) throws -> (entries: [TrackerLibraryEntry], hasNext: Bool) {
        guard bytes.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.errors?.isEmpty != false,
              let collection = value.data?.MediaListCollection,
              collection.lists.count <= 100 else { throw TrackerLibraryError.invalidResponse }
        var entries: [TrackerLibraryEntry] = []
        for group in collection.lists {
            guard group.entries.count <= TrackerLibraryPolicy.pageSize * 10 else { throw TrackerLibraryError.tooLarge }
            for entry in group.entries {
                guard entries.count < TrackerLibraryPolicy.pageSize * 10 else { throw TrackerLibraryError.tooLarge }
                entries.append(try entry.normalized(kind: kind))
            }
        }
        return (entries, collection.hasNextChunk)
    }
}

extension TrackerAniListLibraryPage.Entry {
    func normalized(kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
        guard mediaId == media.id,
              media.type == kind.rawValue,
              TrackerRemoteProgressBoundary.positiveIdentifier(id) != nil,
              let normalizedStatus = TrackerLibraryStatus(rawValue: status) else { throw TrackerLibraryError.invalidResponse }
        let titles = [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let entry = TrackerLibraryEntry(
            service: .anilist, kind: kind, mediaID: mediaId, entryID: id,
            aniListID: media.id, malID: TrackerRemoteProgressBoundary.positiveIdentifier(media.idMal),
            title: titles.first ?? "Untitled", alternateTitles: titles,
            coverLarge: media.coverImage?.large, coverMedium: media.coverImage?.medium,
            total: kind == .anime ? media.episodes : media.chapters,
            genres: media.genres ?? [], averageScore: media.averageScore,
            status: normalizedStatus, progress: progress, score: score,
            updatedAt: updatedAt.map { Date(timeIntervalSince1970: Double($0)) }
        )
        try TrackerLibraryPolicy.validate(entry)
        return entry
    }
}

struct TrackerMALLibraryPage: Decodable {
    let data: [Entry]
    let paging: Paging?
    struct Entry: Decodable { let node: Node; let list_status: Status }
    struct Paging: Decodable { let next: String? }
    struct Node: Decodable {
        let id: Int
        let title: String
        let main_picture: Picture?
        let num_episodes: Int?
        let num_chapters: Int?
        let genres: [Genre]?
        let mean: Double?
        let my_list_status: Status?
    }
    struct Picture: Decodable { let large: String?; let medium: String? }
    struct Genre: Decodable { let name: String }
    struct Status: Decodable {
        let status: String
        let score: Double
        let num_episodes_watched: Int?
        let num_chapters_read: Int?
        let is_rewatching: Bool?
        let is_rereading: Bool?
        let updated_at: String?
    }

    static func decode(_ bytes: Data, kind: TrackerLibraryKind) throws -> (entries: [TrackerLibraryEntry], next: URL?) {
        guard bytes.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.data.count <= TrackerLibraryPolicy.pageSize else { throw TrackerLibraryError.tooLarge }
        let entries = try value.data.map { try $0.node.normalized(status: $0.list_status, kind: kind) }
        var next: URL?
        if let raw = value.paging?.next {
            guard raw.utf8.count <= 8_192,
                  let url = URL(string: raw),
                  TrackerLibraryPolicy.allowsMALPage(url, kind: kind) else {
                throw TrackerLibraryError.invalidResponse
            }
            next = url
        }
        return (entries, next)
    }
}

extension TrackerMALLibraryPage.Node {
    func normalized(status: TrackerMALLibraryPage.Status, kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
        guard let normalizedStatus = TrackerLibraryStatus.fromMAL(
            status.status,
            repeating: (kind == .anime ? status.is_rewatching : status.is_rereading) ?? false
        ) else { throw TrackerLibraryError.invalidResponse }
        let progress = kind == .anime ? status.num_episodes_watched : status.num_chapters_read
        guard let progress else { throw TrackerLibraryError.invalidResponse }
        let entry = TrackerLibraryEntry(
            service: .myAnimeList, kind: kind, mediaID: id, entryID: nil,
            aniListID: nil, malID: id, title: title, alternateTitles: [],
            coverLarge: main_picture?.large, coverMedium: main_picture?.medium,
            total: kind == .anime ? num_episodes : num_chapters,
            genres: genres?.map(\.name) ?? [], averageScore: mean.map { $0 * 10 },
            status: normalizedStatus, progress: progress, score: status.score * 10,
            updatedAt: status.updated_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
        try TrackerLibraryPolicy.validate(entry)
        return entry
    }
}
