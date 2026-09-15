import Foundation

struct TrackerReaderPreloadCache<Value> {
    static var maximumRows: Int { 40_000 }
    static var maximumTitles: Int { 32 }
    private var entries: [UUID: (value: Value, rows: Int)] = [:]
    private var order: [UUID] = []
    private(set) var retainedRows = 0

    var count: Int { entries.count }

    func value(for id: UUID) -> Value? { entries[id]?.value }

    @discardableResult
    mutating func insert(_ value: Value, id: UUID, rows: Int) -> Bool {
        remove(id)
        guard rows > 0, rows <= Self.maximumRows else { return false }
        while entries.count >= Self.maximumTitles || retainedRows > Self.maximumRows - rows {
            guard let first = order.first else { return false }
            remove(first)
        }
        entries[id] = (value, rows)
        order.append(id)
        retainedRows += rows
        return true
    }

    mutating func remove(_ id: UUID) {
        if let previous = entries.removeValue(forKey: id) { retainedRows -= previous.rows }
        order.removeAll { $0 == id }
    }
}

enum TrackerReaderMatchPolicy {
    struct Candidate: Equatable {
        let id: String
        let sourceID: String
        let title: String
        let languageRank: Int
        let chapterCount: Int
        let chapterCountVerified: Bool
        let sourceOrder: Int
    }

    static func normalizedTitle(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func titleScore(_ title: String, aliases: [String]) -> Int {
        let candidate = normalizedTitle(title)
        guard !candidate.isEmpty else { return 0 }
        let targets = aliases.prefix(8).map(normalizedTitle).filter { !$0.isEmpty }
        if targets.contains(candidate) { return 100 }
        let words = Set(candidate.split(separator: " "))
        return targets.map { target in
            let other = Set(target.split(separator: " "))
            let union = words.union(other).count
            guard union > 0 else { return 0 }
            return Int(Double(words.intersection(other).count) / Double(union) * 80)
        }.max() ?? 0
    }

    static func ranked(_ candidates: [Candidate], aliases: [String]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted && titleScore($0.title, aliases: aliases) >= 40 }
            .sorted { lhs, rhs in
                let leftScore = titleScore(lhs.title, aliases: aliases)
                let rightScore = titleScore(rhs.title, aliases: aliases)
                if leftScore != rightScore { return leftScore > rightScore }
                if lhs.languageRank != rhs.languageRank { return lhs.languageRank < rhs.languageRank }
                if lhs.chapterCountVerified != rhs.chapterCountVerified { return lhs.chapterCountVerified }
                if lhs.chapterCount != rhs.chapterCount { return lhs.chapterCount > rhs.chapterCount }
                if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
                return lhs.id < rhs.id
            }
    }

    static func automaticMatchID(_ candidates: [Candidate], aliases: [String], completed: Bool) -> String? {
        guard completed, let first = ranked(candidates, aliases: aliases).first,
              titleScore(first.title, aliases: aliases) == 100,
              first.chapterCountVerified, first.chapterCount > 0 else { return nil }
        let exact = candidates.filter { titleScore($0.title, aliases: aliases) == 100 }
        let sameSource = exact.filter { $0.sourceID == first.sourceID }
        guard Set(sameSource.map(\.id)).count == 1,
              !exact.contains(where: { $0.languageRank <= first.languageRank && !$0.chapterCountVerified }) else { return nil }
        return first.id
    }

    static func distinctChapterCount(_ titles: [String]) -> (count: Int, verified: Bool) {
        guard !titles.isEmpty, titles.count <= 20_000 else { return (0, false) }
        let pattern = #"(?:\b(?:chapter|chap|ch)\.?\s*|^\s*)(\d+(?:\.\d+)?)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (0, false) }
        var keys = Set<String>()
        var verified = true
        for title in titles {
            let bounded = String(title.prefix(1024))
            let range = NSRange(bounded.startIndex..., in: bounded)
            if let match = expression.firstMatch(in: bounded, range: range),
               let numberRange = Range(match.range(at: 1), in: bounded),
               let number = Decimal(string: String(bounded[numberRange]), locale: Locale(identifier: "en_US_POSIX")) {
                keys.insert(NSDecimalNumber(decimal: number).stringValue)
            } else {
                verified = false
                let normalized = normalizedTitle(bounded)
                if !normalized.isEmpty { keys.insert("title:\(normalized)") }
            }
        }
        return (keys.count, verified && !keys.isEmpty)
    }
}
