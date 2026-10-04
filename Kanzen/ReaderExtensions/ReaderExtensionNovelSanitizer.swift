// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import ImageIO
import SwiftSoup

enum ReaderExtensionHTMLPreflight {
    private static let maximumAttributesPerTag = 256
    // A real 1,190-chapter WeebCentral list page carries 58,318 attributes
    // and 1.77 MiB of tag markup. The per-tag caps above stay tight; the
    // per-document aggregates must clear mainstream catalog pages.
    private static let maximumAttributesPerDocument = 524_288
    private static let maximumTagBytes = 64 * 1_024
    private static let maximumAggregateTagBytes = 8 * 1_024 * 1_024

    /// Bounds DOM construction before SwiftSoup sees attacker-controlled HTML.
    /// Deliberately count every raw `<` token candidate, including candidates
    /// inside comments and raw-text elements. This avoids maintaining a second
    /// HTML tokenizer whose recovery rules could diverge from SwiftSoup. A
    /// normal document may use roughly one opener and one closer per element;
    /// a small allowance covers declarations and ordinary literal text. False
    /// positives fail closed, while exact post-parse element caps remain the
    /// authority for accepted input.
    static func validate(_ html: String, maximumBytes: Int, maximumNodeTokens: Int) throws {
        let bytes = Array(html.utf8)
        guard bytes.count <= maximumBytes,
              maximumNodeTokens > 0,
              maximumNodeTokens <= (Int.max - 64) / 2 else {
            throw ReaderExtensionError.contentTooLarge
        }
        let maximumTokenCandidates = maximumNodeTokens * 2 + 64
        var tokenCandidates = 0
        for byte in bytes where byte == 0x3c { // <
            guard tokenCandidates < maximumTokenCandidates else {
                throw ReaderExtensionError.contentTooLarge
            }
            tokenCandidates += 1
        }
        try validateAttributeWork(bytes)
    }

    private static func validateAttributeWork(_ bytes: [UInt8]) throws {
        var nextCandidate = 0
        var totalAttributes = 0
        var aggregateTagBytes = 0
        while nextCandidate < bytes.count {
            let tagStart = nextCandidate
            nextCandidate += 1
            guard bytes[tagStart] == 0x3c else { continue }
            var cursor = tagStart + 1
            // SwiftSoup's tokenizer temporarily records attributes on end-tag
            // tokens before the tree builder discards them. They therefore
            // need the same pre-allocation bound as start tags.
            if cursor < bytes.count, bytes[cursor] == 0x2f {
                cursor += 1
            }
            guard cursor < bytes.count, isTagNameStartByte(bytes[cursor]) else { continue }

            while cursor < bytes.count, isTagNameByte(bytes[cursor]) { cursor += 1 }
            var tagAttributes = 0
            while cursor < bytes.count {
                guard cursor - tagStart <= maximumTagBytes else {
                    throw ReaderExtensionError.contentTooLarge
                }
                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                if bytes[cursor] == 0x3e { // >
                    cursor += 1
                    break
                }
                if bytes[cursor] == 0x2f { // optional self-closing slash
                    cursor += 1
                    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == 0x3e {
                        cursor += 1
                        break
                    }
                    continue
                }

                let nameStart = cursor
                if bytes[cursor] == 0x3d { cursor += 1 }
                while cursor < bytes.count, !isAttributeDelimiter(bytes[cursor]) { cursor += 1 }
                guard cursor > nameStart else { throw ReaderExtensionError.contentTooLarge }
                tagAttributes += 1
                totalAttributes += 1
                guard tagAttributes <= maximumAttributesPerTag,
                      totalAttributes <= maximumAttributesPerDocument else {
                    throw ReaderExtensionError.contentTooLarge
                }

                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == 0x3d { // =
                    cursor += 1
                    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                    if bytes[cursor] == 0x22 || bytes[cursor] == 0x27 { // quoted value
                        let quote = bytes[cursor]
                        cursor += 1
                        while cursor < bytes.count, bytes[cursor] != quote {
                            cursor += 1
                            guard cursor - tagStart <= maximumTagBytes else {
                                throw ReaderExtensionError.contentTooLarge
                            }
                        }
                        guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                        cursor += 1
                    } else { // quotes are ordinary parse-error bytes in unquoted values
                        while cursor < bytes.count,
                              !isWhitespace(bytes[cursor]),
                              bytes[cursor] != 0x3e {
                            cursor += 1
                            guard cursor - tagStart <= maximumTagBytes else {
                                throw ReaderExtensionError.contentTooLarge
                            }
                        }
                    }
                }
            }

            let tagBytes = cursor - tagStart
            guard tagBytes <= maximumTagBytes,
                  tagBytes <= maximumAggregateTagBytes - aggregateTagBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            aggregateTagBytes += tagBytes
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0c || byte == 0x0d || byte == 0x20
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func isTagNameStartByte(_ byte: UInt8) -> Bool {
        // SwiftSoup accepts non-ASCII HTML tag names. Treat every UTF-8 byte
        // in such a name as markup work so `<é a0=x ...>` cannot bypass the
        // same pre-allocation attribute limits applied to ordinary tags.
        isASCIILetter(byte) || byte >= 0x80
    }

    private static func isTagNameByte(_ byte: UInt8) -> Bool {
        !isWhitespace(byte) && byte != 0x2f && byte != 0x3e
    }

    private static func isAttributeDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x2f || byte == 0x3e || byte == 0x3d
    }
}

struct ReaderNovelDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumPersistedBytes = 24 * 1_024 * 1_024
    let version: Int
    let bodyHTML: String
    let plainText: String

    init(bodyHTML: String) throws {
        guard bodyHTML.utf8.count <= ReaderExtensionNovelSanitizer.maximumInputBytes else { throw ReaderExtensionError.contentTooLarge }
        let key = ReaderNovelDocumentCache.key(bodyHTML)
        if let cached = ReaderNovelDocumentCache.shared.document(for: key) {
            self = cached
            return
        }
        let sanitized = try ReaderExtensionNovelSanitizer.sanitizedContent(bodyHTML)
        guard !sanitized.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sanitized.hasIllustration else {
            throw ReaderExtensionError.resultInvalid("The novel chapter did not contain readable content.")
        }
        version = Self.currentVersion
        self.bodyHTML = sanitized.bodyHTML
        plainText = sanitized.plainText
        ReaderNovelDocumentCache.shared.insert(self, for: key)
        ReaderNovelDocumentCache.shared.insert(self, for: ReaderNovelDocumentCache.key(self.bodyHTML))
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case bodyHTML
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw ReaderExtensionError.resultInvalid("The downloaded novel document version is unsupported.")
        }
        try self.init(bodyHTML: values.decode(String.self, forKey: .bodyHTML))
    }

    static func decode(_ data: Data) throws -> ReaderNovelDocument {
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumPersistedBytes,
            maximumDepth: 2,
            maximumContainerEntries: 2,
            maximumTotalTokens: 8
        ))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumPersistedBytes else { throw ReaderExtensionError.contentTooLarge }
        return data
    }
}

private final class ReaderNovelDocumentCache: @unchecked Sendable {
    static let shared = ReaderNovelDocumentCache()
    private let lock = NSLock()
    private var documents: [String: (document: ReaderNovelDocument, cost: Int)] = [:]
    private var order: [String] = []
    private var totalBytes = 0
    private let maximumBytes = 32 * 1_024 * 1_024
    private let maximumCount = 4

    static func key(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func document(for key: String) -> ReaderNovelDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = documents[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.document
    }

    func insert(_ document: ReaderNovelDocument, for key: String) {
        let cost = document.bodyHTML.utf8.count + document.plainText.utf16.count * 2
        guard cost <= maximumBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = documents.removeValue(forKey: key) { totalBytes -= old.cost }
        order.removeAll { $0 == key }
        while documents.count >= maximumCount || totalBytes > maximumBytes - cost {
            guard let oldest = order.first else { return }
            order.removeFirst()
            if let removed = documents.removeValue(forKey: oldest) { totalBytes -= removed.cost }
        }
        documents[key] = (document, cost)
        totalBytes += cost
        order.append(key)
    }
}

enum ReaderExtensionNovelSanitizer {
    static let maximumInputBytes = 16 * 1_024 * 1_024
    static let maximumOutputBytes = 16 * 1_024 * 1_024
    static let maximumDOMElements = 4_096
    static let maximumImages = 32
    static let maximumImageBytes = 2 * 1_024 * 1_024
    static let maximumAggregateImageBytes = 8 * 1_024 * 1_024
    static let maximumImagePixels: Int64 = 12_000_000
    static let maximumAggregateImagePixels: Int64 = 24_000_000
    private static let imageAttributePattern = try? NSRegularExpression(
        pattern: #"(?i)(\bsrc\s*=\s*)(["'])(data:[^"']*)\2"#
    )

    static func sanitize(
        _ html: String,
        baseURL _: URL,
        approvedDomains _: Set<String>
    ) throws -> String {
        try sanitize(html)
    }

    static func sanitize(_ html: String) throws -> String {
        try sanitizedContent(html).bodyHTML
    }

    fileprivate static func sanitizedContent(_ html: String) throws -> (bodyHTML: String, plainText: String, hasIllustration: Bool) {
        let prepared = try parsedDocument(html)
        let dirty = prepared.document
        try dirty.select("picture, form, input, button, textarea, select, option, iframe, frame, object, embed, audio, video, source, track, canvas, svg, math, script, noscript, style, link, meta, base").remove()
        let whitelist = try Whitelist.relaxed()
            .addTags("section", "article", "aside", "figure", "figcaption", "hr", "ruby", "rt", "rp")
            .addAttributes(":all", "id", "dir", "lang")
            .removeAttributes("blockquote", "cite")
            .removeAttributes("q", "cite")
            .removeAttributes("img", "width", "height", "align")
            .removeAttributes("table", "width")
            .removeAttributes("col", "width")
            .removeAttributes("colgroup", "width")
            .removeAttributes("td", "width")
            .removeAttributes("th", "width")
            .removeProtocols("a", "href", "ftp", "http", "https", "mailto")
            .addProtocols("a", "href", "#")
            .preserveRelativeLinks(true)
        let clean = try Cleaner(headWhitelist: nil, bodyWhitelist: whitelist).clean(dirty)
        clean.outputSettings().prettyPrint(pretty: false)
        var seenIDs = Set<String>()
        for element in try clean.getAllElements() {
            let id = try element.attr("id")
            if !id.isEmpty {
                if let canonical = canonicalID(id), seenIDs.insert(canonical).inserted {
                    try element.attr("id", canonical)
                } else { try element.removeAttr("id") }
            }
            let direction = try element.attr("dir").lowercased()
            if !["ltr", "rtl", "auto"].contains(direction) { try element.removeAttr("dir") }
            let language = try element.attr("lang")
            if language.utf8.count > 64 || !language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                try element.removeAttr("lang")
            }
        }
        for link in try clean.select("a[href]") {
            let href = try link.attr("href")
            if href.hasPrefix("#"),
               let id = canonicalID(String(href.dropFirst()).removingPercentEncoding ?? String(href.dropFirst())),
               seenIDs.contains(id) {
                let encodedID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? id
                try link.attr("href", "#" + encodedID)
            } else { try link.removeAttr("href") }
        }
        for image in try clean.select("img") {
            let key = try image.attr("src")
            guard let url = prepared.images[key] else { try image.remove(); continue }
            try image.attr("src", url)
        }
        guard let body = clean.body() else { return ("", "", false) }
        let result = try body.html()
        guard result.utf8.count <= maximumOutputBytes else { throw ReaderExtensionError.contentTooLarge }
        return (result, try body.text(), try body.select("img").size() > 0)
    }

    static func prepareDocument(
        _ html: String,
        baseURL: URL,
        requiresCompleteImages: Bool = true,
        fetchImage: (URL) async throws -> Data
    ) async throws -> ReaderNovelDocument {
        let prepared = try parsedDocument(html)
        let document = prepared.document
        try document.select("script, noscript, style, iframe, frame, object, embed, svg, math, picture").remove()
        let images = try document.select("img")
        guard images.size() <= maximumImages else { throw ReaderExtensionError.contentTooLarge }
        var loaded: [String: String] = [:]
        var failed = Set<String>()
        var aggregateBytes = 0
        var aggregatePixels: Int64 = 0
        for image in images {
            try Task.checkCancellation()
            let value = try image.attr("src")
            let dataURL: String
            if let embedded = prepared.images[value] { dataURL = embedded }
            else if prepared.embeddedKeys.contains(value) {
                try image.remove()
                continue
            } else {
                guard !value.isEmpty,
                      let url = ReaderExtensionMangayomiURLParser.url(value, relativeTo: baseURL) else {
                    try image.remove()
                    continue
                }
                try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url)
                if failed.contains(url.absoluteString) {
                    try image.before("<p>Illustration could not be loaded. Reload the chapter to retry.</p>")
                    try image.remove()
                    continue
                }
                if let existing = loaded[url.absoluteString] { dataURL = existing }
                else {
                    do {
                        let data = try await fetchImage(url)
                        try Task.checkCancellation()
                        dataURL = try embeddedImageURL(data)
                        loaded[url.absoluteString] = dataURL
                    } catch {
                        try Task.checkCancellation()
                        let recoverable: Bool
                        if let failure = error as? URLError { recoverable = failure.code != .cancelled }
                        else if case ReaderExtensionError.resultInvalid = error { recoverable = true }
                        else { recoverable = false }
                        guard !requiresCompleteImages, recoverable else { throw error }
                        failed.insert(url.absoluteString)
                        try image.before("<p>Illustration could not be loaded. Reload the chapter to retry.</p>")
                        try image.remove()
                        continue
                    }
                }
            }
            guard let encoded = dataURL.split(separator: ",", maxSplits: 1).last,
                  let bytes = Data(base64Encoded: String(encoded)),
                  bytes.count <= maximumAggregateImageBytes - aggregateBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            aggregateBytes += bytes.count
            let pixels = try imagePixelCost(bytes)
            guard pixels <= maximumAggregateImagePixels - aggregatePixels else { throw ReaderExtensionError.contentTooLarge }
            aggregatePixels += pixels
            try image.attr("src", dataURL)
        }
        return try ReaderNovelDocument(bodyHTML: document.body()?.html() ?? "")
    }

    static func embeddedImageURL(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumImageBytes else { throw ReaderExtensionError.contentTooLarge }
        let mime: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { mime = "image/png" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { mime = "image/jpeg" }
        else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { mime = "image/gif" }
        else if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) { mime = "image/webp" }
        else { throw ReaderExtensionError.resultInvalid("The novel illustration has an unsupported image format.") }
        _ = try imagePixelCost(data)
        return "data:" + mime + ";base64," + data.base64EncodedString()
    }

    static func isolatedDocument(bodyHTML: String) throws -> String {
        let body = try ReaderNovelDocument(bodyHTML: bodyHTML).bodyHTML
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; connect-src 'none'">
          <style>img{display:block;max-width:100%;height:auto;margin:1em auto}a{color:inherit;text-decoration:underline}table{max-width:100%;border-collapse:collapse}td,th{overflow-wrap:anywhere}pre{white-space:pre-wrap}ruby{ruby-position:over}rt{font-size:0.65em}figure{margin:1em 0}</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static func escapedPlainText(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<div>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    }

    private static func imagePixelCost(_ data: Data) throws -> Int64 {
        _ = try ReaderExtensionImageSafety.validate(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ReaderExtensionError.resultInvalid("The novel illustration could not be inspected.")
        }
        var aggregate: Int64 = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
                throw ReaderExtensionError.resultInvalid("The novel illustration dimensions were unavailable.")
            }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels > 0, pixels <= maximumImagePixels,
                  pixels <= maximumAggregateImagePixels - aggregate else { throw ReaderExtensionError.contentTooLarge }
            aggregate += pixels
        }
        return aggregate
    }

    private static func canonicalID(_ value: String) -> String? {
        let lengthLimit = value.hasPrefix("novel-") ? 262 : 256
        guard !value.isEmpty, value.utf8.count <= lengthLimit,
              value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) && !"<>&\"'".unicodeScalars.contains($0) }) else { return nil }
        return value.hasPrefix("novel-") ? value : "novel-" + value
    }

    private static func parsedDocument(_ html: String) throws -> (document: Document, images: [String: String], embeddedKeys: Set<String>) {
        guard html.utf8.count <= maximumInputBytes else { throw ReaderExtensionError.contentTooLarge }
        var masked = html
        var images: [String: String] = [:]
        var embeddedKeys = Set<String>()
        var aggregateBytes = 0
        var aggregatePixels: Int64 = 0
        let marker = UUID().uuidString
        let matches = imageAttributePattern?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        guard matches.count <= maximumImages else { throw ReaderExtensionError.contentTooLarge }
        for (index, match) in matches.enumerated().reversed() {
            guard let valueRange = Range(match.range(at: 3), in: masked) else { continue }
            let value = String(masked[valueRange])
            let key = "https://reader-image.invalid/" + marker + "/" + String(index)
            masked.replaceSubrange(valueRange, with: key)
            embeddedKeys.insert(key)
            guard let separator = value.firstIndex(of: ","),
                  ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(String(value[..<separator]).lowercased()),
                  let data = Data(base64Encoded: String(value[value.index(after: separator)...])) else { continue }
            guard data.count <= maximumAggregateImageBytes - aggregateBytes else { throw ReaderExtensionError.contentTooLarge }
            aggregateBytes += data.count
            let pixels = try imagePixelCost(data)
            guard pixels <= maximumAggregateImagePixels - aggregatePixels else { throw ReaderExtensionError.contentTooLarge }
            aggregatePixels += pixels
            let canonical = try embeddedImageURL(data)
            images[key] = canonical
        }
        try ReaderExtensionHTMLPreflight.validate(masked, maximumBytes: maximumInputBytes, maximumNodeTokens: maximumDOMElements - 4)
        let document = try SwiftSoup.parse(masked)
        document.outputSettings().prettyPrint(pretty: false)
        guard try document.getAllElements().size() <= maximumDOMElements else { throw ReaderExtensionError.contentTooLarge }
        return (document, images, embeddedKeys)
    }
}
