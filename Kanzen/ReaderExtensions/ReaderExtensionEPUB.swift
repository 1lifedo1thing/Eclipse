import CryptoKit
import Foundation
import SwiftSoup
import ZIPFoundation

protocol ReaderExtensionEPUBNetworkClient: ReaderExtensionNetworkClient {
    func requestEPUB(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse
    func validateEPUBAdmission(for request: ReaderExtensionNetworkRequest) throws
}

final class ReaderExtensionEPUBOperationState {
    var chapterOrder: [String: Int]?
}

final class ReaderExtensionEPUBService: @unchecked Sendable {
    private static let sharedLock = NSLock()
    private nonisolated(unsafe) static var sharedScope: String?
    private nonisolated(unsafe) static var sharedService: ReaderExtensionEPUBService?
    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedBook: ReaderExtensionEPUBBook?
    private var cachedAt: Date?

    static func shared(scopeID: String, sourceID: ReaderExtensionSourceID, digest: String) -> ReaderExtensionEPUBService {
        let generation = ReaderExtensionAuthenticationGenerationRegistry.current(sourceID: sourceID, namespace: scopeID)
        let namespaceGeneration = ReaderExtensionAuthenticationGenerationRegistry.namespaceGeneration(scopeID)
        let scope = scopeID + ":" + sourceID.rawValue + ":" + digest + ":\(generation):\(namespaceGeneration)"
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if sharedScope == scope, let sharedService { return sharedService }
        let service = ReaderExtensionEPUBService()
        sharedScope = scope
        sharedService = service
        return service
    }

    func cachedBook(for request: ReaderExtensionNetworkRequest, network: ReaderExtensionEPUBNetworkClient) throws -> ReaderExtensionEPUBBook? {
        try network.validateEPUBAdmission(for: request)
        let key = Self.key(request)
        lock.lock()
        defer { lock.unlock() }
        let age = cachedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        return cachedKey == key && age >= 0 && age < 3_600 ? cachedBook : nil
    }

    func store(_ book: ReaderExtensionEPUBBook, for request: ReaderExtensionNetworkRequest, network: ReaderExtensionEPUBNetworkClient) throws {
        try network.validateEPUBAdmission(for: request)
        lock.lock()
        defer { lock.unlock() }
        cachedKey = Self.key(request)
        cachedBook = book
        cachedAt = Date()
    }

    private static func key(_ request: ReaderExtensionNetworkRequest) -> String {
        let material = request.url.absoluteString + "\u{1f}" + request.sourceID.rawValue
            + "\u{1f}" + request.approvedDomains.sorted().joined(separator: "\u{1f}")
            + "\u{1f}" + request.headers.keys.sorted().map { $0 + ":" + (request.headers[$0] ?? "") }.joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class ReaderExtensionEPUBBook: @unchecked Sendable {
    struct Chapter: Equatable, Sendable {
        let title: String
        let path: String
        let identifier: String
        let fragment: String?
    }

    static let maximumArchiveBytes = 32 * 1_024 * 1_024
    static let maximumExpandedBytes = 128 * 1_024 * 1_024
    static let maximumEntries = 8_192
    static let maximumChapters = 4_096
    static let maximumChapterBytes = 4 * 1_024 * 1_024
    private static let maximumXMLBytes = 2 * 1_024 * 1_024
    private static let maximumImageBytes = 2 * 1_024 * 1_024
    private static let maximumChapterImageBytes = 8 * 1_024 * 1_024
    private let archiveBytes: Data
    private let manifest: [String: Resource]
    private let navigation: [NavigationTarget]
    private let sectionLock = NSLock()
    private var cachedSectionPath: String?
    private var cachedSections: [String: String] = [:]
    let title: String
    let author: String?
    let chapters: [Chapter]

    private struct Resource {
        let identifier: String
        let path: String
        let mediaType: String
        let properties: Set<String>
    }

    private struct NavigationTarget {
        let path: String
        let fragment: String?
        let label: String
    }

    private struct Section {
        let fragment: String?
        let label: String?
        let html: String
    }

    init(data: Data) throws {
        let expectedEntries = try Self.validateZIP(data)
        let archive = try Archive(data: data, accessMode: .read)
        var paths = Set<String>()
        var total: UInt64 = 0
        for entry in archive {
            guard paths.count < Self.maximumEntries,
                  Self.isSafeEntryPath(entry.path),
                  paths.insert(entry.path).inserted,
                  entry.type != .symlink,
                  entry.uncompressedSize <= UInt64(Self.maximumExpandedBytes) - total else {
                throw Self.invalid("archive entries exceed supported bounds")
            }
            total += entry.uncompressedSize
        }
        guard paths.count == expectedEntries else { throw Self.invalid("archive entries disagree with the index") }
        let mimetype = try Self.extract("mimetype", from: archive, maximumBytes: 128)
        guard String(data: mimetype, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw Self.invalid("archive is not an EPUB book")
        }
        let container = try ReaderExtensionEPUBXML.parse(
            Self.extract("META-INF/container.xml", from: archive, maximumBytes: Self.maximumXMLBytes)
        )
        guard let rootfile = container.descendants(named: "rootfile").first(where: {
            $0.attributes["media-type"] == "application/oebps-package+xml"
        }) ?? container.descendants(named: "rootfile").first,
              let packagePath = Self.resolve(rootfile.attributes["full-path"] ?? "", relativeTo: "")?.path else {
            throw Self.invalid("book package is missing")
        }
        let package = try ReaderExtensionEPUBXML.parse(
            Self.extract(packagePath, from: archive, maximumBytes: Self.maximumXMLBytes)
        )
        guard let packageNode = package.descendants(named: "package").first,
              let spine = packageNode.children.first(where: { $0.name == "spine" }),
              let manifestNode = packageNode.children.first(where: { $0.name == "manifest" }) else {
            throw Self.invalid("book reading order is missing")
        }
        guard packageNode.attributes["rendition:layout"] != "pre-paginated",
              !packageNode.descendants(named: "meta").contains(where: {
                  ($0.attributes["property"] == "rendition:layout" && $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated")
                      || ($0.attributes["name"] == "fixed-layout" && $0.attributes["content"]?.lowercased() == "true")
              }), !spine.children.contains(where: {
                  ($0.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).contains("rendition:layout-pre-paginated")
              }) else { throw Self.invalid("fixed-layout EPUB books are unsupported") }
        let metadata = packageNode.children.first(where: { $0.name == "metadata" })
        let parsedTitle = metadata?.descendants(named: "title").first?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        title = Self.boundedText(parsedTitle?.isEmpty == false ? parsedTitle ?? "Untitled" : "Untitled", maximumUTF8Bytes: 8_192)
        author = metadata?.descendants(named: "creator").first.map { Self.boundedText($0.textContent, maximumUTF8Bytes: 8_192) }
        var resources: [String: Resource] = [:]
        for item in manifestNode.children where item.name == "item" {
            guard resources.count < Self.maximumEntries,
                  let identifier = item.attributes["id"], !identifier.isEmpty,
                  resources[identifier] == nil,
                  let reference = Self.resolve(item.attributes["href"] ?? "", relativeTo: packagePath),
                  reference.fragment == nil,
                  paths.contains(reference.path) else {
                throw Self.invalid("book resource reference is invalid")
            }
            resources[identifier] = Resource(
                identifier: identifier,
                path: reference.path,
                mediaType: item.attributes["media-type"]?.lowercased() ?? "",
                properties: Set((item.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            )
        }
        if paths.contains("META-INF/encryption.xml") {
            let encryption = try ReaderExtensionEPUBXML.parse(Self.extract("META-INF/encryption.xml", from: archive, maximumBytes: Self.maximumXMLBytes))
            let encryptedEntries = encryption.descendants(named: "encrypteddata")
            let permittedAlgorithms: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
            let fontTypes: Set<String> = ["application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff", "application/x-font-ttf", "application/x-font-opentype"]
            guard !encryptedEntries.isEmpty, encryptedEntries.allSatisfy({ entry in
                guard let algorithm = entry.descendants(named: "encryptionmethod").first?.attributes["Algorithm"],
                      permittedAlgorithms.contains(algorithm),
                      let rawPath = entry.descendants(named: "cipherreference").first?.attributes["URI"],
                      let reference = Self.resolve(rawPath, relativeTo: "") else { return false }
                let candidates = resources.values.filter { $0.path == reference.path }
                return !candidates.isEmpty && candidates.allSatisfy { $0.mediaType.hasPrefix("font/") || fontTypes.contains($0.mediaType) }
            }) else { throw Self.invalid("encrypted or DRM-protected EPUB content is unsupported") }
        }
        var targets: [NavigationTarget] = []
        if let nav = resources.values.first(where: { $0.properties.contains("nav") }) {
            let navigation = try ReaderExtensionEPUBXML.parse(Self.extract(nav.path, from: archive, maximumBytes: Self.maximumXMLBytes))
            let contents = navigation.descendants(named: "nav").first(where: {
                ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").split(whereSeparator: \.isWhitespace).contains("toc")
            }) ?? navigation
            for link in contents.descendants(named: "a") {
                guard let reference = Self.resolve(link.attributes["href"] ?? "", relativeTo: nav.path) else { continue }
                let label = link.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let bounded = Self.boundedText(label, maximumUTF8Bytes: 960)
                if !bounded.isEmpty {
                    guard targets.count < Self.maximumChapters else { throw ReaderExtensionError.contentTooLarge }
                    targets.append(NavigationTarget(path: reference.path, fragment: reference.fragment, label: bounded))
                }
            }
        } else if let ncx = resources[spine.attributes["toc"] ?? ""] ?? resources.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let navigation = try ReaderExtensionEPUBXML.parse(Self.extract(ncx.path, from: archive, maximumBytes: Self.maximumXMLBytes))
            for point in navigation.descendants(named: "navpoint") {
                guard let content = point.children.first(where: { $0.name == "content" }),
                      let reference = Self.resolve(content.attributes["src"] ?? "", relativeTo: ncx.path),
                      let label = point.children.first(where: { $0.name == "navlabel" })?.textContent.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else { continue }
                let bounded = Self.boundedText(label, maximumUTF8Bytes: 960)
                if !bounded.isEmpty {
                    guard targets.count < Self.maximumChapters else { throw ReaderExtensionError.contentTooLarge }
                    targets.append(NavigationTarget(path: reference.path, fragment: reference.fragment, label: bounded))
                }
            }
        }
        var readingResources: [Resource] = []
        var usedPaths = Set<String>()
        for item in spine.children where item.name == "itemref" && item.attributes["linear"]?.lowercased() != "no" {
            guard readingResources.count < Self.maximumChapters,
                  let resource = resources[item.attributes["idref"] ?? ""],
                  ["application/xhtml+xml", "text/html"].contains(resource.mediaType) else {
                throw Self.invalid("book reading order contains an unsupported chapter")
            }
            guard usedPaths.insert(resource.path).inserted else { continue }
            readingResources.append(resource)
        }
        var navigationBytes = 0
        var navigationNodes = 0
        for resource in readingResources {
            let bytes = try Self.extract(resource.path, from: archive, maximumBytes: Self.maximumChapterBytes)
            guard bytes.count <= Self.maximumExpandedBytes - navigationBytes,
                  let html = Self.string(bytes) else { throw ReaderExtensionError.contentTooLarge }
            navigationBytes += bytes.count
            guard html.range(of: "summary\\s*=\\s*['\"]contents['\"]", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let document = try Self.chapterDocument(html)
            navigationNodes += try document.getAllElements().size()
            guard navigationNodes <= 262_144 else { throw ReaderExtensionError.contentTooLarge }
            for table in try document.select("table[summary]") where try table.attr("summary").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "contents" {
                for link in try table.select("a[href]") {
                    guard let reference = Self.resolve(try link.attr("href"), relativeTo: resource.path),
                          usedPaths.contains(reference.path), let fragment = reference.fragment, !fragment.isEmpty else { continue }
                    var label = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cell = link.parent(), cell.tagName() == "td", let row = cell.parent(), row.tagName() == "tr" {
                        let leadingCells = row.children().array().prefix { $0 !== cell }
                        let rowLabel = try leadingCells.map { try $0.text() }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rowLabel.isEmpty { label = rowLabel }
                    }
                    guard !label.isEmpty else { continue }
                    guard targets.count < Self.maximumChapters else { throw ReaderExtensionError.contentTooLarge }
                    targets.append(NavigationTarget(path: reference.path, fragment: fragment, label: Self.boundedText(label, maximumUTF8Bytes: 960)))
                }
            }
        }
        var parsedChapters: [Chapter] = []
        var usedTitles = Set<String>()
        var lastSectionPath: String?
        var lastSections: [String: String] = [:]
        for resource in readingResources {
            let resourceTargets = targets.filter { $0.path == resource.path }
            let label = resourceTargets.first?.label ?? "Chapter \(parsedChapters.count + 1)"
            let sections: [Section]
            if resourceTargets.contains(where: { $0.fragment?.isEmpty == false }) {
                let bytes = try Self.extract(resource.path, from: archive, maximumBytes: Self.maximumChapterBytes)
                guard let html = Self.string(bytes) else { throw Self.invalid("chapter text encoding is unsupported") }
                let document = try Self.chapterDocument(html)
                navigationNodes += try document.getAllElements().size()
                guard navigationNodes <= 262_144 else { throw ReaderExtensionError.contentTooLarge }
                sections = try Self.sections(in: document, targets: resourceTargets)
                lastSectionPath = resource.path
                lastSections = Dictionary(uniqueKeysWithValues: sections.map { ($0.fragment ?? "", $0.html) })
            } else { sections = [Section(fragment: nil, label: nil, html: "")] }
            for section in sections {
                guard parsedChapters.count < Self.maximumChapters else { throw ReaderExtensionError.contentTooLarge }
                let prefixLabel = parsedChapters.isEmpty ? "Introduction" : "Continuation"
                let sectionLabel = section.label ?? (section.fragment == nil && sections.count > 1 ? prefixLabel : label)
                var unique = sectionLabel
                var suffix = 2
                while usedTitles.contains(unique) {
                    unique = "\(sectionLabel) (\(suffix))"
                    suffix += 1
                }
                usedTitles.insert(unique)
                parsedChapters.append(Chapter(title: unique, path: resource.path, identifier: resource.path + (section.fragment.map { "#" + $0 } ?? ""), fragment: section.fragment))
            }
        }
        guard !parsedChapters.isEmpty else { throw Self.invalid("book has no readable chapters") }
        archiveBytes = data
        manifest = resources
        navigation = targets
        chapters = parsedChapters
        cachedSectionPath = lastSectionPath
        cachedSections = lastSections
    }

    func chapterHTML(named name: String) throws -> String {
        guard let chapter = chapters.first(where: { $0.title == name })
            ?? chapters.first(where: { $0.path == name || $0.identifier == name || $0.path == manifest[name]?.path }) else {
            throw Self.invalid("requested chapter is absent from the book")
        }
        let archive = try Archive(data: archiveBytes, accessMode: .read)
        let bytes = try Self.extract(chapter.path, from: archive, maximumBytes: Self.maximumChapterBytes)
        guard let originalHTML = Self.string(bytes) else { throw Self.invalid("chapter text encoding is unsupported") }
        let html = try sectionHTML(chapter, originalHTML: originalHTML)
        let document = try Self.chapterDocument(html)
        for svg in try document.select("svg") {
            let rasterImages = try svg.select("image").array()
            if rasterImages.count == 1, let raster = rasterImages.first {
                let raw = try raster.attr("href").isEmpty ? raster.attr("xlink:href") : raster.attr("href")
                if let reference = Self.resolve(raw, relativeTo: chapter.path) {
                    try raster.tagName("img")
                    try raster.attr("src", "eclipse-epub-asset:" + reference.path)
                    try svg.before(raster)
                }
            }
        }
        try Self.embedFootnotes(in: document, chapter: chapter, archive: archive, resources: manifest, originalHTML: originalHTML, initialBytes: bytes.count)
        var imageBytes = 0
        var imageCount = 0
        var images: [String: String] = [:]
        let imageResources = Dictionary(manifest.values.filter { $0.mediaType.hasPrefix("image/") }.map { ($0.path, $0.mediaType) }, uniquingKeysWith: { first, _ in first })
        for image in try document.select("img") {
            let source = try image.attr("src")
            let resourcePath = source.hasPrefix("eclipse-epub-asset:")
                ? String(source.dropFirst("eclipse-epub-asset:".count))
                : Self.resolve(source, relativeTo: chapter.path)?.path
            guard imageCount < 32,
                  let resourcePath,
                  let mime = imageResources[resourcePath],
                  ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime) else {
                throw Self.invalid("chapter contains an unsupported image resource")
            }
            let embedded: String
            if let cached = images[resourcePath] {
                embedded = cached
            } else {
                let data = try Self.extract(resourcePath, from: archive, maximumBytes: Self.maximumImageBytes)
                guard data.count <= Self.maximumChapterImageBytes - imageBytes else { throw ReaderExtensionError.contentTooLarge }
                imageBytes += data.count
                embedded = try ReaderExtensionNovelSanitizer.embeddedImageURL(data)
                images[resourcePath] = embedded
            }
            try image.attr("src", embedded)
            try image.removeAttr("srcset")
            imageCount += 1
        }
        for link in try document.select("a[href]") {
            let raw = try link.attr("href")
            if let reference = Self.resolve(raw, relativeTo: chapter.path),
               reference.path == chapter.path,
               let fragment = reference.fragment, !fragment.isEmpty {
                try link.attr("href", "#\(fragment)")
            } else {
                try link.removeAttr("href")
            }
        }
        guard let body = document.body() else { throw Self.invalid("chapter body is missing") }
        return try ReaderExtensionNovelSanitizer.sanitize(body.html(), baseURL: URL(fileURLWithPath: "/"), approvedDomains: [])
    }

    func novelDocument(named name: String) throws -> ReaderNovelDocument {
        try ReaderNovelDocument(bodyHTML: chapterHTML(named: name))
    }

    private func sectionHTML(_ chapter: Chapter, originalHTML: String) throws -> String {
        guard chapters.contains(where: { $0.path == chapter.path && $0.fragment != nil }) else { return originalHTML }
        sectionLock.lock()
        defer { sectionLock.unlock() }
        if cachedSectionPath != chapter.path {
            let sections = try Self.sections(in: Self.chapterDocument(originalHTML), targets: navigation.filter { $0.path == chapter.path })
            cachedSections = Dictionary(uniqueKeysWithValues: sections.map { ($0.fragment ?? "", $0.html) })
            cachedSectionPath = chapter.path
        }
        guard let html = cachedSections[chapter.fragment ?? ""] else { throw Self.invalid("book section is unavailable") }
        return html
    }

    private static func chapterDocument(_ html: String) throws -> Document {
        try ReaderExtensionHTMLPreflight.validate(html, maximumBytes: maximumChapterBytes, maximumNodeTokens: 32_768)
        let document = try SwiftSoup.parse(html)
        guard try document.getAllElements().size() <= 32_768 else { throw ReaderExtensionError.contentTooLarge }
        return document
    }

    private static func sections(in document: Document, targets: [NavigationTarget]) throws -> [Section] {
        guard let body = document.body() else { throw invalid("chapter body is missing") }
        var identifierCounts: [String: Int] = [:]
        for element in try body.getAllElements() {
            let identifier = try element.attr("id")
            if !identifier.isEmpty { identifierCounts[identifier, default: 0] += 1 }
        }
        var labels: [String: String] = [:]
        for target in targets {
            guard let fragment = target.fragment, !fragment.isEmpty,
                  identifierCounts[fragment] == 1, labels[fragment] == nil,
                  try body.attr("id") != fragment else { continue }
            labels[fragment] = target.label
        }
        guard !labels.isEmpty else { return [Section(fragment: nil, label: nil, html: try body.html())] }
        let ignoredNames: Set<String> = ["script", "style", "noscript", "template", "iframe", "object", "embed"]
        var stack = body.getChildNodes().reversed().map { (node: $0, exiting: false, depth: 1) }
        var ancestors: [(opening: String, closing: String, ignored: Bool)] = []
        var ignoredDepth = 0
        var current = ""
        var currentBytes = 0
        var totalBytes = 0
        var readable = false
        var fragment: String?
        var label: String?
        var output: [Section] = []
        func append(_ value: String) throws {
            let bytes = value.utf8.count
            guard bytes <= maximumChapterBytes - currentBytes,
                  bytes <= 8 * 1_024 * 1_024 - totalBytes else { throw ReaderExtensionError.contentTooLarge }
            current.append(value)
            currentBytes += bytes
            totalBytes += bytes
        }
        func finish() throws {
            for ancestor in ancestors.reversed() { try append(ancestor.closing) }
            if readable {
                guard output.count < maximumChapters else { throw ReaderExtensionError.contentTooLarge }
                output.append(Section(fragment: fragment, label: label, html: current))
            }
            current = ""
            currentBytes = 0
            readable = false
        }
        while let event = stack.popLast() {
            guard event.depth <= 128 else { throw ReaderExtensionError.contentTooLarge }
            if event.exiting {
                guard let ancestor = ancestors.popLast() else { throw invalid("book section ancestry is invalid") }
                try append(ancestor.closing)
                if ancestor.ignored { ignoredDepth -= 1 }
                continue
            }
            if let element = event.node as? Element {
                let identifier = try element.attr("id")
                if ignoredDepth == 0, let targetLabel = labels[identifier] {
                    try finish()
                    fragment = identifier
                    label = targetLabel
                    for ancestor in ancestors { try append(ancestor.opening) }
                }
                let attributes = element.getAttributes()?.copy(with: nil) as? Attributes ?? Attributes()
                let attributeHTML = StringBuilder()
                try attributes.html(accum: attributeHTML, out: OutputSettings().prettyPrint(pretty: false))
                let tag = element.tagName()
                let opening = "<" + tag + attributeHTML.toString() + ">"
                let closing = element.tag().isEmpty() ? "" : "</" + tag + ">"
                try append(opening)
                let reopened = Element(element.tag(), [], attributes)
                try reopened.removeAttr("id")
                let reopenedHTML = StringBuilder()
                try reopened.getAttributes()?.html(accum: reopenedHTML, out: OutputSettings().prettyPrint(pretty: false))
                let ignored = ignoredNames.contains(tag)
                ancestors.append((opening: "<" + tag + reopenedHTML.toString() + ">", closing: closing, ignored: ignored))
                if ignored { ignoredDepth += 1 }
                if ignoredDepth == 0, tag == "img" || tag == "image" { readable = true }
                stack.append((node: element, exiting: true, depth: event.depth))
                for child in element.getChildNodes().reversed() { stack.append((node: child, exiting: false, depth: event.depth + 1)) }
            } else {
                if ignoredDepth == 0, let text = event.node as? TextNode,
                   !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { readable = true }
                try append(event.node.outerHtml())
            }
        }
        try finish()
        return output.isEmpty ? [Section(fragment: nil, label: nil, html: try body.html())] : output
    }

    private static func embedFootnotes(in document: Document, chapter: Chapter, archive: Archive, resources: [String: Resource], originalHTML: String, initialBytes: Int) throws {
        guard let body = document.body() else { return }
        let chapterPaths = Set(resources.values.filter { ["application/xhtml+xml", "text/html"].contains($0.mediaType) }.map(\.path))
        var documents: [String: Document] = [:]
        var embedded = Set<String>()
        var inputBytes = initialBytes
        for link in try document.select("a[href]").array() {
            guard let reference = resolve(try link.attr("href"), relativeTo: chapter.path),
                  chapterPaths.contains(reference.path),
                  let fragment = reference.fragment, !fragment.isEmpty else { continue }
            if reference.path == chapter.path, try document.getElementById(fragment) != nil { continue }
            let identity = reference.path + "#" + fragment
            let prefix = "epub-note-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            if embedded.contains(identity) {
                try link.attr("href", "#" + prefix)
                continue
            }
            let linkType = try link.attr("epub:type").split(whereSeparator: \.isWhitespace)
            let hint = reference.path.lowercased()
            let linkRole = try link.attr("role")
            let linkClass = try link.className()
            let explicitReference = linkType.contains("noteref") || linkRole == "doc-noteref"
                || linkClass.lowercased().contains("footnote") || link.parent()?.tagName() == "sup"
                || hint.contains("endnote") || hint.contains("footnote")
            guard explicitReference else { continue }
            let targetDocument: Document
            if let existing = documents[reference.path] { targetDocument = existing }
            else if reference.path == chapter.path {
                targetDocument = try chapterDocument(originalHTML)
                documents[reference.path] = targetDocument
            }
            else {
                let data = try extract(reference.path, from: archive, maximumBytes: maximumChapterBytes)
                guard data.count <= maximumChapterBytes - inputBytes,
                      let html = string(data) else { throw ReaderExtensionError.contentTooLarge }
                inputBytes += data.count
                try ReaderExtensionHTMLPreflight.validate(html, maximumBytes: maximumChapterBytes, maximumNodeTokens: 32_768)
                targetDocument = try SwiftSoup.parse(html)
                guard try targetDocument.getAllElements().size() <= 32_768 else { throw ReaderExtensionError.contentTooLarge }
                documents[reference.path] = targetDocument
            }
            guard let note = try targetDocument.getElementById(fragment) else { continue }
            try link.attr("href", "#" + prefix)
            guard embedded.count < 32 else { throw ReaderExtensionError.contentTooLarge }
            embedded.insert(identity)
            var identifiers: [String: String] = [:]
            for element in try note.getAllElements() {
                let identifier = try element.attr("id")
                if !identifier.isEmpty {
                    let target = element === note ? prefix
                        : prefix + "-" + SHA256.hash(data: Data(identifier.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                    identifiers[identifier] = target
                    try element.attr("id", target)
                }
            }
            for image in try note.select("img") {
                if let asset = resolve(try image.attr("src"), relativeTo: reference.path) {
                    try image.attr("src", "eclipse-epub-asset:" + asset.path)
                }
            }
            for backlink in try note.select("a[href]") {
                guard let target = resolve(try backlink.attr("href"), relativeTo: reference.path), let fragment = target.fragment else {
                    try backlink.removeAttr("href")
                    continue
                }
                if target.path == reference.path, let identifier = identifiers[fragment] { try backlink.attr("href", "#" + identifier) }
                else if target.path == chapter.path { try backlink.attr("href", "#" + fragment) }
                else { try backlink.removeAttr("href") }
            }
            try body.appendChild(note)
        }
    }

    private static func extract(_ path: String, from archive: Archive, maximumBytes: Int) throws -> Data {
        guard let entry = archive[path], entry.type == .file, entry.uncompressedSize <= UInt64(maximumBytes) else {
            throw invalid("book resource is missing or exceeds supported bounds")
        }
        var output = Data()
        output.reserveCapacity(Int(entry.uncompressedSize))
        let checksum = try archive.extract(entry, bufferSize: 64 * 1_024) { chunk in
            guard chunk.count <= maximumBytes - output.count else { throw ReaderExtensionError.contentTooLarge }
            output.append(chunk)
        }
        guard output.count == Int(entry.uncompressedSize), checksum == entry.checksum else { throw invalid("book resource failed its integrity check") }
        return output
    }

    private static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 2_048,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, value in
            value != "." && value != ".." && (!value.isEmpty || index == components.count - 1)
        }
    }

    private static func resolve(_ reference: String, relativeTo base: String) -> (path: String, fragment: String?)? {
        guard !reference.isEmpty, reference.utf8.count <= 4_096,
              !reference.contains(":"), !reference.contains("\\"), !reference.hasPrefix("/"),
              !reference.contains("?") else { return nil }
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pathPart = parts.first?.removingPercentEncoding,
              !pathPart.hasPrefix("/"), !pathPart.contains("\\"), !pathPart.contains(":"),
              !pathPart.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        var components = base.split(separator: "/").dropLast().map(String.init)
        if pathPart.isEmpty { components = base.split(separator: "/").map(String.init) }
        for component in pathPart.isEmpty ? [] : pathPart.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                guard !component.isEmpty else { return nil }
                components.append(String(component))
            }
        }
        let path = components.joined(separator: "/")
        guard isSafeEntryPath(path) else { return nil }
        let fragment = parts.count > 1 ? parts[1].removingPercentEncoding : nil
        guard fragment?.utf8.count ?? 0 <= 512,
              fragment?.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) != true else { return nil }
        return (path, fragment)
    }

    fileprivate static func string(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8)
    }

    private static func boundedText(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        var remaining = maximumUTF8Bytes
        for scalar in value.unicodeScalars {
            let bytes = scalar.value <= 0x7f ? 1 : scalar.value <= 0x7ff ? 2 : scalar.value <= 0xffff ? 3 : 4
            guard bytes <= remaining else { break }
            result.unicodeScalars.append(scalar)
            remaining -= bytes
        }
        return result
    }

    private static func validateZIP(_ data: Data) throws -> Int {
        guard data.count >= 22, data.count <= maximumArchiveBytes else { throw ReaderExtensionError.contentTooLarge }
        let bytes = [UInt8](data)
        func integer(_ offset: Int, _ count: Int) -> UInt64? {
            guard offset >= 0, count <= bytes.count - offset else { return nil }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        let lower = max(0, bytes.count - 65_557)
        guard let end = stride(from: bytes.count - 22, through: lower, by: -1).first(where: {
            integer($0, 4) == 0x06054b50 && integer($0 + 20, 2) == UInt64(bytes.count - $0 - 22)
        }), integer(end + 4, 2) == 0, integer(end + 6, 2) == 0,
              let count = integer(end + 10, 2), count > 0, count <= maximumEntries,
              integer(end + 8, 2) == count,
              let centralBytes = integer(end + 12, 4), let centralOffset = integer(end + 16, 4),
              centralOffset + centralBytes == UInt64(end) else {
            throw invalid("ZIP64, split or malformed EPUB archives are unsupported")
        }
        var offset = Int(centralOffset)
        var total: UInt64 = 0
        for _ in 0..<Int(count) {
            guard integer(offset, 4) == 0x02014b50,
                  let flags = integer(offset + 8, 2), flags & 0x41 == 0,
                  let method = integer(offset + 10, 2), method == 0 || method == 8,
                  let compressed = integer(offset + 20, 4),
                  let expanded = integer(offset + 24, 4), expanded <= UInt64(maximumExpandedBytes) - total,
                  expanded <= max(compressed * 1_000, 1_024 * 1_024),
                  let nameBytes = integer(offset + 28, 2), nameBytes > 0, nameBytes <= 2_048,
                  let extra = integer(offset + 30, 2), let comment = integer(offset + 32, 2),
                  integer(offset + 34, 2) == 0,
                  let localOffset = integer(offset + 42, 4), localOffset < centralOffset,
                  UInt64(offset) + 46 + nameBytes + extra + comment <= UInt64(end) else {
                throw invalid("encrypted, oversized or malformed EPUB entry")
            }
            let local = Int(localOffset)
            guard integer(local, 4) == 0x04034b50,
                  integer(local + 6, 2) == flags,
                  integer(local + 8, 2) == method,
                  integer(local + 26, 2) == nameBytes,
                  let localExtra = integer(local + 28, 2),
                  localOffset + 30 + nameBytes + localExtra + compressed <= centralOffset,
                  Array(bytes[(local + 30)..<(local + 30 + Int(nameBytes))]) == Array(bytes[(offset + 46)..<(offset + 46 + Int(nameBytes))]) else {
                throw invalid("EPUB local and central entries disagree")
            }
            total += expanded
            offset += 46 + Int(nameBytes + extra + comment)
        }
        guard offset == end else { throw invalid("EPUB archive index is malformed") }
        return Int(count)
    }

    private static func invalid(_ reason: String) -> ReaderExtensionError { .resultInvalid(reason) }
}

private final class ReaderExtensionEPUBXML: NSObject, XMLParserDelegate {
    final class Node {
        final class Text {
            var value: String
            init(_ value: String) { self.value = value }
        }
        enum Content {
            case text(Text)
            case child(Node)
        }
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var content: [Content] = []
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
        var textContent: String {
            var result = ""
            for part in content {
                switch part {
                case .text(let text): result.append(text.value)
                case .child(let child): result.append(child.textContent)
                }
            }
            return result
        }
        func descendants(named name: String) -> [Node] {
            (self.name == name ? [self] : []) + children.flatMap { $0.descendants(named: name) }
        }
    }

    private let root = Node(name: "", attributes: [:])
    private var stack: [Node] = []
    private var elements = 0
    private var textBytes = 0
    private var refused = false

    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 2 * 1_024 * 1_024,
              let text = ReaderExtensionEPUBBook.string(data),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw ReaderExtensionError.resultInvalid("unsafe EPUB XML document") }
        let withoutDoctype = text.replacingOccurrences(of: "(?is)<!DOCTYPE\\s+[^>\\[]+>", with: "", options: .regularExpression)
        guard !withoutDoctype.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw ReaderExtensionError.resultInvalid("unsafe EPUB XML document") }
        let delegate = ReaderExtensionEPUBXML()
        delegate.stack = [delegate.root]
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.refused else { throw ReaderExtensionError.resultInvalid("malformed or oversized EPUB XML document") }
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements += 1
        guard elements <= 16_384, stack.count <= 64, attributeDict.count <= 64,
              attributeDict.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8_192 }) else {
            refused = true
            parser.abortParsing()
            return
        }
        let node = Node(name: elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? "", attributes: attributeDict)
        stack.last?.children.append(node)
        stack.last?.content.append(.child(node))
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard string.utf8.count <= 2 * 1_024 * 1_024 - textBytes else {
            refused = true
            parser.abortParsing()
            return
        }
        textBytes += string.utf8.count
        if let last = stack.last?.content.last, case .text(let text) = last { text.value.append(string) }
        else { stack.last?.content.append(.text(Node.Text(string))) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { refused = true; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: string)
    }
}
