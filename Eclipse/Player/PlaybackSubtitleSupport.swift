import AVFoundation
import Foundation

@MainActor
enum AVPlayerMediaSelectionAdapter {
    static func apply(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        externalSubtitleSelected: Bool,
        currentExternalSubtitleSelection: (() -> Bool)? = nil,
        isStillCurrent: () -> Bool = { true }
    ) async {
        await applyAudioIntent(intent, to: item, isStillCurrent: isStillCurrent)
        guard !Task.isCancelled, isStillCurrent() else { return }
        await applySubtitleIntent(
            intent,
            to: item,
            externalSubtitleSelected: externalSubtitleSelected,
            currentExternalSubtitleSelection: currentExternalSubtitleSelection,
            isStillCurrent: isStillCurrent
        )
    }

    static func applySubtitleIntent(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        externalSubtitleSelected: Bool,
        currentExternalSubtitleSelection: (() -> Bool)? = nil,
        isStillCurrent: () -> Bool = { true }
    ) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            return
        }
        guard !Task.isCancelled, isStillCurrent() else { return }
        guard intent.subtitlesEnabled,
              !(currentExternalSubtitleSelection?() ?? externalSubtitleSelected) else {
            if group.allowsEmptySelection {
                item.select(nil, in: group)
            }
            return
        }

        if let option = preferredOption(
            in: group,
            preferredLanguage: intent.preferredSubtitleLanguage
        ) {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
    }

    private static func applyAudioIntent(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        isStillCurrent: () -> Bool
    ) async {
        guard let preferredLanguage = intent.preferredAudioLanguage,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              !Task.isCancelled,
              isStillCurrent(),
              let option = preferredOption(in: group, preferredLanguage: preferredLanguage) else {
            return
        }
        item.select(option, in: group)
    }

    private static func preferredOption(
        in group: AVMediaSelectionGroup,
        preferredLanguage: String?
    ) -> AVMediaSelectionOption? {
        let descriptors = group.options.map {
            PlaybackLanguageSelectionPolicy.Option(
                languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier,
                displayName: $0.displayName
            )
        }
        guard let index = PlaybackLanguageSelectionPolicy.preferredIndex(
            in: descriptors,
            preferredLanguage: preferredLanguage
        ) else { return nil }
        return group.options[index]
    }
}

struct TVExternalSubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum TVExternalSubtitleParser {
    private static let maximumCueCount = 20_000
    private static let maximumCueTextLength = 4_000

    static func parse(_ data: Data) -> [TVExternalSubtitleCue] {
        guard let source = decodeText(data) else { return [] }
        let normalized = source
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.range(of: "[Events]", options: .caseInsensitive) != nil {
            return parseASS(normalized)
        }
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [TVExternalSubtitleCue] = []
        cues.reserveCapacity(min(blocks.count, maximumCueCount))

        for block in blocks where cues.count < maximumCueCount {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count >= 2,
                  let start = parseTimestamp(timingParts[0]),
                  let end = parseTimestamp(
                    timingParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                  ),
                  start.isFinite,
                  end.isFinite,
                  end > start else {
                continue
            }
            let rawText = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            let text = sanitizedCueText(rawText)
            guard !text.isEmpty else { continue }
            cues.append(TVExternalSubtitleCue(start: max(0, start), end: end, text: text))
        }
        return cues.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
    }

    private static func parseASS(_ source: String) -> [TVExternalSubtitleCue] {
        var inEvents = false
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [TVExternalSubtitleCue] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard cues.count < maximumCueCount else { break }
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = format.firstIndex(of: "start"),
                  let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text"),
                  format.count >= 3 else { continue }
            let payload = line.dropFirst("dialogue:".count)
            let fields = payload.split(
                separator: ",",
                maxSplits: max(0, format.count - 1),
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.indices.contains(startIndex),
                  fields.indices.contains(endIndex),
                  fields.indices.contains(textIndex),
                  let start = parseTimestamp(fields[startIndex]),
                  let end = parseTimestamp(fields[endIndex]),
                  start.isFinite,
                  end.isFinite,
                  end > start else { continue }
            let assText = fields[textIndex]
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            let withoutOverrides: String
            if let expression = try? NSRegularExpression(pattern: "\\{[^}]{0,1024}\\}") {
                withoutOverrides = expression.stringByReplacingMatches(
                    in: assText,
                    range: NSRange(assText.startIndex..<assText.endIndex, in: assText),
                    withTemplate: ""
                )
            } else {
                withoutOverrides = assText
            }
            let text = sanitizedCueText(withoutOverrides)
            guard !text.isEmpty else { continue }
            cues.append(TVExternalSubtitleCue(start: max(0, start), end: end, text: text))
        }
        return cues.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let components = cleaned.split(separator: ":").map(String.init)
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last ?? "") else { return nil }
        let minutesIndex = components.count - 2
        guard let minutes = Double(components[minutesIndex]) else { return nil }
        let hours: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]) else { return nil }
            hours = parsedHours
        } else {
            hours = 0
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func sanitizedCueText(_ rawValue: String) -> String {
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        let withoutTags: String
        if let expression = try? NSRegularExpression(pattern: "<[^>]{1,256}>") {
            withoutTags = expression.stringByReplacingMatches(
                in: rawValue,
                range: range,
                withTemplate: ""
            )
        } else {
            withoutTags = rawValue
        }
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoded.prefix(maximumCueTextLength))
    }
}

final class TVBoundedSubtitleDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let maximumBytes = 4 * 1_024 * 1_024

    private let originURL: URL
    private let headers: [String: String]
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var redirectCount = 0

    init(url: URL, headers: [String: String]) {
        originURL = url
        self.headers = headers
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        guard session == nil else { return }
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue.main
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let request = makeRequest(url: originURL)
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel(reportCancellation: Bool = false) {
        let completion = self.completion
        self.completion = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if reportCancellation {
            completion?(.failure(URLError(.cancelled)))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.expectedContentLength <= 0
                || response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= Self.maximumBytes else {
            task?.cancel()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              redirectCount < 10 else {
            completionHandler(nil)
            finish(.failure(URLError(.httpTooManyRedirects)))
            return
        }
        redirectCount += 1
        completionHandler(makeRequest(url: url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(body))
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        AVPlayerResourceLoader.httpHeaders(
            headers,
            for: url,
            credentialOriginURL: originURL
        ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }
}
