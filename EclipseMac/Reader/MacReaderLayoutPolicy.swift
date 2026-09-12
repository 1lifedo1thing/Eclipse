#if os(macOS)
import Foundation

enum MacReaderLayoutPolicy {
    static func group(containing index: Int, count: Int, columns: Int, offsetFirstPage: Bool) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let current = min(max(index, 0), count - 1)
        guard columns > 1 else { return current..<(current + 1) }
        if offsetFirstPage, current == 0 { return 0..<1 }
        let offset = offsetFirstPage ? 1 : 0
        let start = ((current - offset) / 2) * 2 + offset
        return start..<min(start + 2, count)
    }

    static func adjacentIndex(from index: Int, direction: Int, count: Int, columns: Int, offsetFirstPage: Bool) -> Int? {
        let current = group(containing: index, count: count, columns: columns, offsetFirstPage: offsetFirstPage)
        guard !current.isEmpty else { return nil }
        let next = direction > 0 ? current.upperBound : current.lowerBound - 1
        guard next >= 0, next < count else { return nil }
        return group(containing: next, count: count, columns: columns, offsetFirstPage: offsetFirstPage).lowerBound
    }
}

enum MacReaderNovelPosition {
    static func storageKey(route: MangaContentRoute?, mangaID: Int, chapter: Chapter) -> String {
        let identity = (chapter.chapterData?.first?.params as? ReaderExtensionChapterPayload)?.chapter.key ?? ChapterIdentityNormalizer.key(for: chapter.chapterNumber)
        return "novelScrollPos_" + NovelReaderPositionKey.make(titleIdentity: route?.stableKey ?? "manga-\(mangaID)", chapterIdentity: identity)
    }

    static func finiteFraction(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
enum MacReaderSettingsPolicy {
    static func pageOffsetStorageKey(scopeKey: String?) -> String {
        guard let scopeKey, !scopeKey.isEmpty else { return "Reader.pagedPageOffset" }
        return "Reader.pagedPageOffset." + scopeKey
    }

    static func pageOffset(store: UserDefaults, scopeKey: String?) -> Bool {
        store.object(forKey: pageOffsetStorageKey(scopeKey: scopeKey)) as? Bool ?? false
    }
}

struct MacReaderWheelNavigationPolicy {
    private var lastEvent: TimeInterval?
    private var lastAdvance: TimeInterval?
    private var accumulated = 0.0
    private var direction = 0
    private var consumed = false

    mutating func consume(deltaX: Double, deltaY: Double, precise: Bool, began: Bool, momentum: Bool, timestamp: TimeInterval, paged: Bool, rightToLeft: Bool, atEnd: Bool, continuationEnabled: Bool, magnified: Bool, modified: Bool) -> Int? {
        guard timestamp.isFinite, deltaX.isFinite, deltaY.isFinite else { return nil }
        if began || lastEvent.map({ timestamp - $0 > 0.35 || timestamp < $0 }) ?? true {
            accumulated = 0
            direction = 0
            consumed = false
        }
        lastEvent = timestamp
        guard !momentum, !magnified, !modified else { accumulated = 0; return nil }
        let horizontal = abs(deltaX) > abs(deltaY)
        let delta = horizontal ? deltaX : deltaY
        guard delta != 0 else { return nil }
        let proposed = (delta < 0 ? 1 : -1) * (horizontal && rightToLeft ? -1 : 1)
        guard paged || (!horizontal && proposed > 0 && atEnd && continuationEnabled) else { accumulated = 0; return nil }
        guard !consumed, lastAdvance.map({ timestamp - $0 >= 0.35 }) ?? true else { return nil }
        if proposed != direction { accumulated = 0; direction = proposed }
        accumulated += abs(delta)
        let threshold = precise ? (paged ? 75.0 : 120.0) : 3.0
        guard accumulated >= threshold else { return nil }
        consumed = true
        accumulated = 0
        lastAdvance = timestamp
        return proposed
    }
}

enum MacReaderChapterRangePolicy {
    enum Direction { case above, below }

    static func chapters(in displayed: [Chapter], including chapter: Chapter, direction: Direction) -> [Chapter] {
        guard let index = displayed.firstIndex(where: { $0.id == chapter.id }) else { return [] }
        switch direction {
        case .above: return Array(displayed[...index])
        case .below: return Array(displayed[index...])
        }
    }
}

enum MacReaderOfflineChapterPolicy {
    static func chapters(for route: MangaContentRoute, downloads: [ReaderDownloadItem]) -> [Chapter] {
        downloads.filter { $0.status == .completed && $0.routeKey == route.stableKey && $0.route.stableKey == route.stableKey }
            .enumerated().map { index, item in
                Chapter(chapterNumber: item.chapterNumber, idx: index, chapterData: [ChapterData(params: ReaderDownloadedChapterPayload(route: item.route, chapterNumber: item.chapterNumber), title: item.chapterTitle ?? "", scanlationGroup: item.sourceName ?? "")])
            }
    }
}
#endif
