#if !os(tvOS)
import Foundation
import WebKit

struct ReaderExtensionCatalogSearchIndex: Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let source: ReaderExtensionCatalogSource
        let languageDisplayName: String
        fileprivate let searchText: String
        fileprivate let languageRank: Int
        fileprivate let languageCode: String
        fileprivate let nameSortKey: String

        var id: ReaderExtensionSourceID { source.id }
    }

    static func build(
        sources: [ReaderExtensionCatalogSource],
        repositoryID: String,
        showMatureSources: Bool,
        localeIdentifier: String,
        preferredLanguageIdentifiers: [String]
    ) -> [Entry] {
        let locale = Locale(identifier: localeIdentifier)
        let preferredLanguageCodes = canonicalPreferredLanguageCodes(
            preferredLanguageIdentifiers
        )

        return sources.lazy
            .filter { source in
                source.repositoryID == repositoryID
                    && (showMatureSources || source.maturity != .mature)
            }
            .map { source in
                let languageCode = canonicalLanguageCode(source.language)
                let languageDisplayName = displayName(
                    for: source.language,
                    languageCode: languageCode,
                    locale: locale
                )
                return Entry(
                    source: source,
                    languageDisplayName: languageDisplayName,
                    searchText: normalizedSearchText(
                        [source.name, source.language, languageDisplayName].joined(separator: " "),
                        locale: locale
                    ),
                    languageRank: languagePriority(
                        languageCode,
                        preferredLanguageCodes: preferredLanguageCodes
                    ),
                    languageCode: languageCode,
                    nameSortKey: normalizedSearchText(source.name, locale: locale)
                )
            }
            .sorted { lhs, rhs in
                if lhs.languageRank != rhs.languageRank {
                    return lhs.languageRank < rhs.languageRank
                }
                if lhs.languageCode != rhs.languageCode {
                    return lhs.languageCode < rhs.languageCode
                }
                if lhs.nameSortKey != rhs.nameSortKey {
                    return lhs.nameSortKey < rhs.nameSortKey
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    static func filter(
        _ entries: [Entry],
        query: String,
        localeIdentifier: String
    ) -> [Entry] {
        let locale = Locale(identifier: localeIdentifier)
        let terms = normalizedSearchText(query, locale: locale)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            terms.allSatisfy(entry.searchText.contains)
        }
    }

    private static func displayName(
        for rawValue: String,
        languageCode: String,
        locale: Locale
    ) -> String {
        let identifier = normalizedLanguageIdentifier(rawValue)
        if let localized = locale.localizedString(forIdentifier: identifier),
           !localized.isEmpty {
            return localized
        }
        if let localized = locale.localizedString(forLanguageCode: languageCode),
           !localized.isEmpty {
            return localized
        }
        return rawValue.uppercased()
    }

    private static func canonicalPreferredLanguageCodes(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let code = canonicalLanguageCode(identifier)
            return code.isEmpty || !seen.insert(code).inserted ? nil : code
        }
    }

    private static func languagePriority(
        _ languageCode: String,
        preferredLanguageCodes: [String]
    ) -> Int {
        if languageCode == preferredLanguageCodes.first { return 0 }
        if languageCode == "en" {
            return preferredLanguageCodes.first == "en" ? 0 : 1
        }
        if let preferredIndex = preferredLanguageCodes.firstIndex(of: languageCode) {
            return preferredLanguageCodes.first == "en" ? preferredIndex : preferredIndex + 1
        }
        return preferredLanguageCodes.count + 2
    }

    private static func normalizedLanguageIdentifier(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func canonicalLanguageCode(_ rawValue: String) -> String {
        let identifier = normalizedLanguageIdentifier(rawValue)
        let localeCode = Locale(identifier: identifier).languageCode
        let fallback = identifier.split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? identifier
        return (localeCode ?? fallback).lowercased()
    }

    private static func normalizedSearchText(_ rawValue: String, locale: Locale) -> String {
        rawValue
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
    }
}


enum ReaderExtensionSignInURLProxy {
    static let secureScheme = "eclipse-reader-auth-secure"
    static let schemes: Set<String> = [secureScheme]
    static let maximumURLBytes = 16 * 1_024

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "base-uri \(secureScheme):",
        "connect-src \(secureScheme):",
        "form-action \(secureScheme):",
        "navigate-to \(secureScheme): about:",
        "script-src 'unsafe-inline' \(secureScheme):",
        "style-src 'unsafe-inline' \(secureScheme):",
        "img-src data: blob: \(secureScheme):",
        "font-src data: \(secureScheme):",
        "media-src blob: \(secureScheme):",
        "frame-src \(secureScheme):",
        "worker-src 'none'",
        "object-src 'none'",
        "frame-ancestors \(secureScheme):"
    ].joined(separator: "; ")

    static func proxyURL(for originalURL: URL) throws -> URL {
        guard originalURL.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            originalURL,
            requireHTTPS: true
        )
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              originalURL.scheme?.lowercased() == "https" else {
            throw ReaderExtensionError.insecureURL
        }
        components.scheme = secureScheme
        guard let result = components.url else { throw ReaderExtensionError.insecureURL }
        return result
    }

    static func originalURL(
        from proxyURL: URL,
        approvedDomains: Set<String>
    ) throws -> URL {
        guard proxyURL.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              let proxyScheme = proxyURL.scheme?.lowercased(),
              schemes.contains(proxyScheme) else {
            throw ReaderExtensionError.insecureURL
        }
        components.scheme = "https"
        guard let original = components.url else { throw ReaderExtensionError.insecureURL }
        guard original.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            original,
            requireHTTPS: true
        )
        try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            original,
            approvedDomains: approvedDomains
        )
        return original
    }

    static func isProxyURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }
}

enum ReaderExtensionSignInContentRewriter {
    static let maximumMarkupInputBytes = 2 * 1_024 * 1_024
    static let maximumSVGInputBytes = 1 * 1_024 * 1_024
    static let maximumTransformedBytes = 4 * 1_024 * 1_024
    static let maximumRewriteCandidates = 20_000

    static func rewrittenBody(
        _ body: Data,
        contentType: String,
        finalURL: URL,
        visibleCookies: [String: String] = [:]
    ) throws -> Data {
        let lowerType = contentType.lowercased()
        let prefix = String(data: body.prefix(512), encoding: .utf8)?.lowercased() ?? ""
        if lowerType.contains("text/html") || lowerType.contains("application/xhtml")
            || prefix.contains("<html") || prefix.contains("<!doctype html") {
            guard body.count <= maximumMarkupInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let html = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            let transformed = Data(try rewriteHTML(
                html,
                baseURL: finalURL,
                visibleCookies: visibleCookies
            ).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        if lowerType.contains("text/css") {
            guard body.count <= maximumMarkupInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let css = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            let transformed = Data(try rewriteCSS(css, baseURL: finalURL).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        if lowerType.contains("image/svg+xml") {
            guard body.count <= maximumSVGInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let markup = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            try validateRewriteComplexity(markup)
            let transformed = Data(try rewriteMarkupAttributes(markup, baseURL: finalURL).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        return body
    }

    static func rewriteHTML(
        _ rawHTML: String,
        baseURL: URL,
        visibleCookies: [String: String] = [:]
    ) throws -> String {
        guard rawHTML.utf8.count <= maximumMarkupInputBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try validateRewriteComplexity(rawHTML)
        var html = rawHTML
        html = try replacingMatches(
            in: html,
            pattern: #"(?is)<meta\b[^>]*http-equiv\s*=\s*([\"'])?content-security-policy(?:-report-only)?\1?[^>]*>"#
        ) { _ in "" }
        html = try replacingMatches(in: html, pattern: #"(?is)<base\b[^>]*>"#) { _ in "" }
        html = try rewriteMarkupAttributes(html, baseURL: baseURL)
        html = try rewriteMetaRefresh(html, baseURL: baseURL)
        html = try replacingMatches(
            in: html,
            pattern: #"(?is)(\bstyle\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4] else { return match.full }
            return try boundedConcatenation([
                match.groups[1],
                match.groups[2],
                try rewriteCSSUnchecked(match.groups[3], baseURL: baseURL),
                match.groups[4]
            ])
        }

        let proxiedBase = (try? ReaderExtensionSignInURLProxy.proxyURL(for: baseURL))?.absoluteString ?? ""
        let bootstrap = bootstrapScript(visibleCookies: visibleCookies)
        let injection = try boundedConcatenation([
            "<meta http-equiv=\"Content-Security-Policy\" content=\"",
            htmlEscaped(ReaderExtensionSignInURLProxy.contentSecurityPolicy),
            "\"><base href=\"",
            htmlEscaped(proxiedBase),
            "\"><script>",
            bootstrap,
            "</script>"
        ])
        // Prefix the policy and host shims before every byte supplied by the
        // remote document. A crafted script placed before its own <head> can
        // therefore never execute before the CSP and URL wrappers.
        return try boundedConcatenation(["<!doctype html><head>", injection, "</head>", html])
    }

    static func rewriteCSS(_ css: String, baseURL: URL) throws -> String {
        guard css.utf8.count <= maximumMarkupInputBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try validateRewriteComplexity(css)
        return try rewriteCSSUnchecked(css, baseURL: baseURL)
    }

    private static func rewriteCSSUnchecked(_ css: String, baseURL: URL) throws -> String {
        var output = try replacingMatches(
            in: css,
            pattern: #"(?is)url\(\s*([\"']?)(.*?)\1\s*\)"#
        ) { match in
            guard match.groups.count >= 3,
                  let translated = translatedReference(match.groups[2], baseURL: baseURL) else {
                return match.full
            }
            let quote = match.groups[1].isEmpty ? "\"" : match.groups[1]
            return "url(\(quote)\(translated)\(quote))"
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(@import\s+)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4],
                  let translated = translatedReference(match.groups[3], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + match.groups[2] + translated + match.groups[4]
        }
        return output
    }

    private static func rewriteMarkupAttributes(_ markup: String, baseURL: URL) throws -> String {
        var output = try replacingMatches(
            in: markup,
            pattern: #"(?is)(\b(?:src|href|action|formaction|poster|data|xlink:href)\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4],
                  let translated = translatedReference(match.groups[3], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + match.groups[2] + translated + match.groups[4]
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(\b(?:src|href|action|formaction|poster|data|xlink:href)\s*=\s*)([^\s\"'=<>`]+)"#
        ) { match in
            guard match.groups.count == 3,
                  let translated = translatedReference(match.groups[2], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + translated
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(\bsrcset\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4] else { return match.full }
            return try boundedConcatenation([
                match.groups[1],
                match.groups[2],
                try rewriteSrcsetValue(match.groups[3], baseURL: baseURL),
                match.groups[4]
            ])
        }
        return output
    }

    private static func rewriteSrcsetValue(_ value: String, baseURL: URL) throws -> String {
        let entries = value.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count <= maximumRewriteCandidates else {
            throw ReaderExtensionError.contentTooLarge
        }
        var output = ""
        var outputByteCount = 0
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                try appendBounded(", ", to: &output, byteCount: &outputByteCount)
            }
            let components = entry.split(whereSeparator: \Character.isWhitespace)
            let transformed: String
            if let first = components.first,
               let translated = translatedReference(String(first), baseURL: baseURL) {
                transformed = ([translated] + components.dropFirst().map(String.init))
                    .joined(separator: " ")
            } else {
                transformed = String(entry)
            }
            try appendBounded(transformed, to: &output, byteCount: &outputByteCount)
        }
        return output
    }

    private static func rewriteMetaRefresh(_ html: String, baseURL: URL) throws -> String {
        try replacingMatches(
            in: html,
            pattern: #"(?is)(<meta\b[^>]*http-equiv\s*=\s*([\"'])?refresh\2?[^>]*content\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 6, match.groups[3] == match.groups[5] else { return match.full }
            let content = try replacingMatches(
                in: match.groups[4],
                pattern: #"(?is)(\burl\s*=\s*)(.*)$"#
            ) { nested in
                guard nested.groups.count == 3,
                      let translated = translatedReference(
                        nested.groups[2].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'")),
                        baseURL: baseURL
                      ) else { return nested.full }
                return nested.groups[1] + translated
            }
            return try boundedConcatenation([
                match.groups[1], match.groups[3], content, match.groups[5]
            ])
        }
    }

    private static func translatedReference(_ raw: String, baseURL: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            if scheme == "http" { return "about:blank#blocked-insecure-reader-auth-load" }
            if scheme != "https" {
                if scheme == ReaderExtensionSignInURLProxy.secureScheme
                    || scheme == "data" || scheme == "blob" || scheme == "about" {
                    return nil
                }
                return "about:blank#blocked-reader-auth-scheme"
            }
        }
        guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return "about:blank#blocked-reader-auth-url"
        }
        guard let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: resolved) else {
            return "about:blank#blocked-reader-auth-target"
        }
        return proxied.absoluteString
    }

    private static func bootstrapScript(visibleCookies: [String: String]) -> String {
        let cookieData = (try? JSONSerialization.data(
            withJSONObject: visibleCookies,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        let cookieJSON = (String(data: cookieData, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return #"""
        (() => {
          'use strict';
          const secureScheme = '\#(ReaderExtensionSignInURLProxy.secureScheme):';
          const cookieJar = Object.assign(Object.create(null), \#(cookieJSON));
          const cookieWriteBudget = { count: 0, characters: 0 };
          const proxy = value => {
            try {
              const url = new URL(String(value), document.baseURI);
              if (url.protocol === 'https:') url.protocol = secureScheme;
              else if (url.protocol === 'http:') return 'about:blank#blocked-insecure-reader-auth-load';
              return url.href;
            } catch (_) { return String(value); }
          };
          Object.defineProperty(window, '__eclipseReaderAuthProxy', { value: proxy });
          Object.defineProperty(window, '__eclipseReplaceReaderCookies', {
            value: next => {
              for (const key of Object.keys(cookieJar)) delete cookieJar[key];
              if (next && typeof next === 'object') {
                for (const [key, value] of Object.entries(next)) cookieJar[String(key)] = String(value);
              }
            }
          });
          const cookieDescriptor = {
            configurable: false,
            get: () => Object.entries(cookieJar).map(([key, value]) => `${key}=${value}`).join('; '),
            set: value => {
              const raw = String(value).slice(0, 4096);
              cookieWriteBudget.count += 1;
              cookieWriteBudget.characters += raw.length;
              if (cookieWriteBudget.count > 128 || cookieWriteBudget.characters > 256 * 1024) return;
              const pair = raw.split(';', 1)[0];
              const split = pair.indexOf('=');
              if (split > 0) cookieJar[pair.slice(0, split).trim()] = pair.slice(split + 1).trim();
              try { window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({ cookie: raw }); } catch (_) {}
            }
          };
          let installedCookieShim = false;
          try {
            Object.defineProperty(Document.prototype, 'cookie', cookieDescriptor);
            installedCookieShim = true;
          } catch (_) {}
          if (!installedCookieShim) {
            try { Object.defineProperty(document, 'cookie', cookieDescriptor); } catch (_) {}
          }
          const nativeFetch = window.fetch && window.fetch.bind(window);
          if (nativeFetch) window.fetch = (input, init) => {
            if (input instanceof Request) return nativeFetch(new Request(proxy(input.url), input), init);
            return nativeFetch(proxy(input), init);
          };
          const nativeOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            return nativeOpen.call(this, method, proxy(url), ...rest);
          };
          if (navigator.sendBeacon) {
            const nativeBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = (url, data) => nativeBeacon(proxy(url), data);
          }
          const nativeSetAttribute = Element.prototype.setAttribute;
          const urlAttributes = new Set(['src', 'href', 'action', 'formaction', 'poster', 'data', 'xlink:href']);
          Element.prototype.setAttribute = function(name, value) {
            return nativeSetAttribute.call(this, name, urlAttributes.has(String(name).toLowerCase()) ? proxy(value) : value);
          };
          const rewriteNode = node => {
            if (!node || node.nodeType !== 1) return;
            for (const attribute of urlAttributes) if (node.hasAttribute(attribute)) nativeSetAttribute.call(node, attribute, proxy(node.getAttribute(attribute)));
            for (const child of node.querySelectorAll('[src],[href],[action],[formaction],[poster],[data]')) rewriteNode(child);
          };
          new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(rewriteNode)))
            .observe(document.documentElement, { childList: true, subtree: true });
          const rewriteFormTarget = (form, submitter) => {
            if (form && form.action) form.action = proxy(form.action);
            if (submitter && submitter.formAction) submitter.formAction = proxy(submitter.formAction);
          };
          const nativeSubmit = HTMLFormElement.prototype.submit;
          HTMLFormElement.prototype.submit = function() { rewriteFormTarget(this, null); return nativeSubmit.call(this); };
          const nativeRequestSubmit = HTMLFormElement.prototype.requestSubmit;
          if (nativeRequestSubmit) HTMLFormElement.prototype.requestSubmit = function(submitter) {
            rewriteFormTarget(this, submitter);
            return nativeRequestSubmit.call(this, submitter);
          };
          document.addEventListener('submit', event => rewriteFormTarget(event.target, event.submitter), true);
          const nativeOpenWindow = window.open;
          window.open = (url, ...rest) => nativeOpenWindow.call(window, proxy(url), ...rest);
        })();
        """#
    }

    private struct Match {
        let full: String
        let groups: [String]
    }

    private static func replacingMatches(
        in input: String,
        pattern: String,
        transform: (Match) throws -> String
    ) throws -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let nsInput = input as NSString
        let matches = expression.matches(
            in: input,
            range: NSRange(location: 0, length: nsInput.length)
        )
        var output = ""
        output.reserveCapacity(min(input.utf8.count, maximumTransformedBytes))
        var outputByteCount = 0
        var cursor = 0
        for result in matches {
            guard result.range.location >= cursor,
                  result.range.location <= nsInput.length,
                  result.range.length <= nsInput.length - result.range.location else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            try appendBounded(
                nsInput.substring(with: NSRange(
                    location: cursor,
                    length: result.range.location - cursor
                )),
                to: &output,
                byteCount: &outputByteCount
            )
            var groups: [String] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                if range.location == NSNotFound { groups.append("") }
                else { groups.append(nsInput.substring(with: range)) }
            }
            try appendBounded(
                try transform(Match(full: groups.first ?? "", groups: groups)),
                to: &output,
                byteCount: &outputByteCount
            )
            cursor = result.range.location + result.range.length
        }
        try appendBounded(
            nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor)),
            to: &output,
            byteCount: &outputByteCount
        )
        return output
    }

    private static func boundedConcatenation(_ parts: [String]) throws -> String {
        var output = ""
        var outputByteCount = 0
        for part in parts {
            try appendBounded(part, to: &output, byteCount: &outputByteCount)
        }
        return output
    }

    private static func appendBounded(
        _ value: String,
        to output: inout String,
        byteCount: inout Int
    ) throws {
        let additionalBytes = value.utf8.count
        guard additionalBytes <= maximumTransformedBytes - byteCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        output.append(value)
        byteCount += additionalBytes
    }

    private static func validateRewriteComplexity(_ input: String) throws {
        let pattern = #"(?is)(?:\b(?:src|href|action|formaction|poster|data|xlink:href|srcset|style)\s*=|url\s*\(|@import\b|<meta\b|<base\b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let length = (input as NSString).length
        var count = 0
        expression.enumerateMatches(
            in: input,
            range: NSRange(location: 0, length: length)
        ) { _, _, stop in
            count += 1
            if count > maximumRewriteCandidates { stop.pointee = true }
        }
        guard count <= maximumRewriteCandidates else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    private static func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum ReaderExtensionCloudflareBrowserPolicy {
    static func allowsNavigation(
        to url: URL,
        session: ReaderExtensionSignInSession
    ) -> Bool {
        guard url.absoluteString.utf8.count <= ReaderExtensionSignInURLProxy.maximumURLBytes,
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "about" || scheme == "blob" { return true }
        guard scheme == "https",
              url.user == nil,
              url.password == nil,
              (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                url,
                requireHTTPS: true
              )) != nil,
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else {
            return false
        }
        return session.networkDomains.contains(host)
    }

    static func isSourcePage(
        _ url: URL,
        session: ReaderExtensionSignInSession
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else {
            return false
        }
        return session.approvedDomains.contains(host)
    }

    static func sourceCookies(
        from cookies: [HTTPCookie],
        approvedDomains: Set<String>
    ) -> [HTTPCookie] {
        let approved = ReaderExtensionSecurityPolicy.canonicalHosts(approvedDomains)
        return cookies.filter { cookie in
            guard let domain = ReaderExtensionSecurityPolicy.canonicalHost(cookie.domain),
                  ReaderExtensionKeychainStore.validatedCookieIdentity(cookie) != nil else {
                return false
            }
            return approved.contains {
                ReaderExtensionSecurityPolicy.host(domain, isEqualToOrSubdomainOf: $0)
            }
        }
    }

    static func mergingSourceCookies(
        _ incoming: [HTTPCookie],
        existing: [HTTPCookie],
        approvedDomains: Set<String>
    ) -> [HTTPCookie]? {
        let accepted = sourceCookies(
            from: incoming,
            approvedDomains: approvedDomains
        )
        guard !accepted.isEmpty else { return nil }
        let identities = Set(accepted.compactMap(
            ReaderExtensionKeychainStore.validatedCookieIdentity
        ))
        return existing.filter {
            guard let identity = ReaderExtensionKeychainStore.validatedCookieIdentity($0) else {
                return false
            }
            return !identities.contains(identity)
        } + accepted
    }

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
#if os(iOS)
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
#endif
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
#if os(iOS)
        configuration.allowsInlineMediaPlayback = true
#endif
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    @MainActor
    static func install(
        _ cookies: [HTTPCookie],
        in store: WKHTTPCookieStore
    ) async {
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    static func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}


enum ReaderExtensionSignInCookieBridge {
    static let maximumCookieStringBytes = 4 * 1_024

    static func visibleCookies(
        for url: URL,
        session: ReaderExtensionSignInSession
    ) -> [String: String] {
        session.authenticationStore.cookies().filter {
            !$0.isHTTPOnly && ReaderExtensionSecurityPolicy.cookie(
                $0,
                mayBeSentTo: url,
                approvedDomains: session.approvedDomains
            )
        }.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    @MainActor
    static func persist(
        cookieString: String,
        proxyURL: URL,
        session: ReaderExtensionSignInSession
    ) throws {
        try ReaderExtensionManager.shared.validateSignInSession(session)
        let originalURL = try ReaderExtensionSignInURLProxy.originalURL(
            from: proxyURL,
            approvedDomains: session.approvedDomains
        )
        try session.authenticationStore.updateCookies { existing in
            try cookiesByMergingScriptWrite(
                cookieString,
                originalURL: originalURL,
                approvedDomains: session.approvedDomains,
                existing: existing
            )
        }
    }

    static func cookiesByMergingScriptWrite(
        _ cookieString: String,
        originalURL: URL,
        approvedDomains: Set<String>,
        existing: [HTTPCookie]
    ) throws -> [HTTPCookie] {
        guard cookieString.utf8.count <= maximumCookieStringBytes,
              !cookieString.contains("\r"), !cookieString.contains("\n") else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(originalURL)
        try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            originalURL,
            approvedDomains: approvedDomains
        )
        let incoming = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": cookieString],
            for: originalURL
        ).filter { cookie in
            !cookie.isHTTPOnly
                && ReaderExtensionSecurityPolicy.cookie(
                    cookie,
                    mayBeSentTo: originalURL,
                    approvedDomains: approvedDomains,
                    now: .distantPast
                )
                && ReaderExtensionKeychainStore.validatedCookieIdentity(cookie) != nil
        }
        guard !incoming.isEmpty else { throw ReaderExtensionError.insecureURL }
        let identities = Set(incoming.compactMap(
            ReaderExtensionKeychainStore.validatedCookieIdentity
        ))
        return existing.filter {
            guard let identity = ReaderExtensionKeychainStore.validatedCookieIdentity($0) else {
                return false
            }
            return !identities.contains(identity)
        } + incoming
    }
}

enum ReaderExtensionSignInRequestTranslator {
    static func networkRequest(
        from request: URLRequest,
        sourceID: ReaderExtensionSourceID,
        approvedDomains: Set<String>,
        baseDomain: String?,
        isExplicitInitialTopLevelNavigation: Bool = false
    ) throws -> ReaderExtensionNetworkRequest {
        guard let proxyURL = request.url else { throw ReaderExtensionError.insecureURL }
        let originalURL = try ReaderExtensionSignInURLProxy.originalURL(
            from: proxyURL,
            approvedDomains: approvedDomains
        )
        guard let method = ReaderExtensionNetworkRequest.Method(
            rawValue: (request.httpMethod ?? "GET").uppercased()
        ) else { throw ReaderExtensionError.insecureURL }
        let translatedHeaders = translatedBrowserHeaders(
            request.allHTTPHeaderFields ?? [:],
            approvedDomains: approvedDomains
        )
        let targetHost = ReaderExtensionSecurityPolicy.canonicalHost(of: originalURL)
        let initialHost = ReaderExtensionSecurityPolicy.canonicalHost(baseDomain)
        // Origin/Referer can legitimately be absent, but that absence is not
        // proof of same-origin initiation. Only the one exact top-level load
        // created by Eclipse may use the session host as its initiator. Every
        // other request fails closed instead of gaining ambient cookies.
        let explicitInitialHost = isExplicitInitialTopLevelNavigation
            && initialHost == targetHost ? targetHost : nil
        let initiatorHost = translatedHeaders.initiatorHost ?? explicitInitialHost
        let admitsSameOriginCookies = initiatorHost != nil && initiatorHost == targetHost
        return ReaderExtensionNetworkRequest(
            method: method,
            url: originalURL,
            headers: translatedHeaders.headers,
            body: try boundedBody(from: request),
            sourceID: sourceID,
            approvedDomains: approvedDomains,
            baseDomain: initiatorHost,
            allowsCookies: admitsSameOriginCookies,
            cookieAccessPolicy: .sameOriginHostOnly,
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumResponseBytes
        )
    }

    private static func translatedBrowserHeaders(
        _ input: [String: String],
        approvedDomains: Set<String>
    ) -> (headers: [String: String], initiatorHost: String?) {
        var output = input
        var initiatorHost: String?
        for (name, value) in input {
            switch name.lowercased() {
            case "accept-encoding":
                // The pinned HTTP/1.1 transport intentionally does not expose
                // a general decompressor to untrusted sign-in pages.
                output.removeValue(forKey: name)
            case "origin":
                output.removeValue(forKey: name)
                guard value.lowercased() != "null",
                      let proxyURL = URL(string: value),
                      let original = try? ReaderExtensionSignInURLProxy.originalURL(
                        from: proxyURL,
                        approvedDomains: approvedDomains
                      ),
                      let host = ReaderExtensionSecurityPolicy.canonicalHost(of: original) else { continue }
                initiatorHost = host
                var components = URLComponents()
                components.scheme = "https"
                components.host = host
                components.port = original.port
                output[name] = components.string ?? "https://\(host)"
            case "referer":
                output.removeValue(forKey: name)
                guard let proxyURL = URL(string: value),
                      let original = try? ReaderExtensionSignInURLProxy.originalURL(
                        from: proxyURL,
                        approvedDomains: approvedDomains
                      ),
                      let host = ReaderExtensionSecurityPolicy.canonicalHost(of: original) else { continue }
                if initiatorHost == nil { initiatorHost = host }
                output[name] = original.absoluteString
            default:
                break
            }
        }
        output["Accept-Encoding"] = "identity"
        return (output, initiatorHost)
    }

    private static func boundedBody(from request: URLRequest) throws -> Data? {
        if let body = request.httpBody {
            guard body.count <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? ReaderExtensionError.insecureURL }
            if count == 0 { break }
            guard result.count <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes - count else {
                throw ReaderExtensionError.contentTooLarge
            }
            result.append(buffer, count: count)
        }
        return result
    }
}

enum ReaderExtensionSignInResponseHeaderPolicy {
    static func sanitizedHeaders(
        _ headers: [String: String],
        bodyCount: Int,
        approvedDomains: Set<String>
    ) -> [String: String] {
        let removed: Set<String> = [
            "content-encoding", "content-length", "content-security-policy",
            "content-security-policy-report-only", "location", "set-cookie",
            "transfer-encoding", "x-frame-options", "refresh", "link",
            "report-to", "nel"
        ]
        var output = headers.filter { !removed.contains($0.key.lowercased()) }
        for (name, value) in headers where name.caseInsensitiveCompare("Content-Type") == .orderedSame {
            let mime = value.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if mime == "text/html" || mime == "application/xhtml+xml"
                || mime == "text/css" || mime == "image/svg+xml" {
                let deliveredMIME = mime == "application/xhtml+xml" ? "text/html" : mime
                output[name] = "\(deliveredMIME); charset=utf-8"
            }
        }
        for (name, value) in headers where name.caseInsensitiveCompare("Access-Control-Allow-Origin") == .orderedSame {
            output.removeValue(forKey: name)
            if value == "*" {
                output[name] = value
                continue
            }
            guard let originURL = URL(string: value),
                  originURL.scheme?.lowercased() == "https",
                  originURL.user == nil,
                  originURL.password == nil,
                  originURL.query == nil,
                  originURL.fragment == nil,
                  originURL.path.isEmpty || originURL.path == "/",
                  (try? ReaderExtensionSecurityPolicy.validateApprovedDomain(
                    originURL,
                    approvedDomains: approvedDomains
                  )) != nil,
                  let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: originURL),
                  let host = proxied.host else { continue }
            var components = URLComponents()
            components.scheme = ReaderExtensionSignInURLProxy.secureScheme
            components.host = host
            components.port = originURL.port
            output[name] = components.string
        }
        output["Content-Length"] = String(bodyCount)
        output["Content-Security-Policy"] = ReaderExtensionSignInURLProxy.contentSecurityPolicy
        output["Referrer-Policy"] = "no-referrer"
        output["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        output["X-Content-Type-Options"] = "nosniff"
        return output
    }
}

enum ReaderExtensionSignInResourceLimitError: LocalizedError, Equatable {
    case stopped
    case totalRequests
    case queuedRequests
    case requestBytes
    case responseBytes

    var errorDescription: String? {
        switch self {
        case .stopped: return "The isolated sign-in session has ended."
        case .totalRequests: return "The sign-in page exceeded its request limit."
        case .queuedRequests: return "The sign-in page opened too many simultaneous requests."
        case .requestBytes: return "The sign-in page exceeded its request-data limit."
        case .responseBytes: return "The sign-in page exceeded its response-data limit."
        }
    }
}

final class ReaderExtensionSignInResourceBudget: @unchecked Sendable {
    let maximumTotalRequests: Int
    let maximumRequestBytes: Int
    let maximumResponseBytes: Int

    private let lock = NSLock()
    private var totalRequests = 0
    private var requestBytes = 0
    private var responseBytes = 0
    private(set) var isStopped = false

    init(
        maximumTotalRequests: Int = 512,
        maximumRequestBytes: Int = 8 * 1_024 * 1_024,
        maximumResponseBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumTotalRequests = max(1, maximumTotalRequests)
        self.maximumRequestBytes = max(0, maximumRequestBytes)
        self.maximumResponseBytes = max(0, maximumResponseBytes)
    }

    func reserveRequest() throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard totalRequests < maximumTotalRequests else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.totalRequests
            }
            totalRequests += 1
        }
    }

    func recordRequestBytes(_ count: Int) throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard count >= 0, count <= maximumRequestBytes - requestBytes else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.requestBytes
            }
            requestBytes += count
        }
    }

    func recordResponseBytes(_ count: Int) throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard count >= 0, count <= maximumResponseBytes - responseBytes else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.responseBytes
            }
            responseBytes += count
        }
    }

    func stop() {
        lock.withReaderExtensionSignInLock { isStopped = true }
    }

}

private actor ReaderExtensionSignInConcurrencyGate {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var didRelease = false
        private let releaseAction: @Sendable () -> Void

        init(releaseAction: @escaping @Sendable () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            let shouldRelease = lock.withReaderExtensionSignInLock { () -> Bool in
                guard !didRelease else { return false }
                didRelease = true
                return true
            }
            if shouldRelease { releaseAction() }
        }

        deinit { release() }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    private let maximumConcurrentRequests: Int
    private var activeRequests = 0
    private var waiters: [Waiter] = []
    private var isStopped = false

    init(maximumConcurrentRequests: Int = 6) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
        if activeRequests < maximumConcurrentRequests {
            activeRequests += 1
            return makeLease()
        }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func stop() {
        isStopped = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: ReaderExtensionSignInResourceLimitError.stopped) }
    }

    private func makeLease() -> Lease {
        Lease { [weak self] in
            guard let self else { return }
            Task { await self.releasePermit() }
        }
    }

    private func releasePermit() {
        if !waiters.isEmpty, !isStopped {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: makeLease())
        } else {
            activeRequests = max(0, activeRequests - 1)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private extension NSLock {
    func withReaderExtensionSignInLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

final class ReaderExtensionSignInSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var onError: ((String) -> Void)?

    private let session: ReaderExtensionSignInSession
    private let initialProxyURL: URL?
    private let resourceBudget: ReaderExtensionSignInResourceBudget
    private let concurrencyGate = ReaderExtensionSignInConcurrencyGate()
    private let lock = NSLock()
    private static let maximumRetainedTasks = 32
    private final class ActiveRequest {
        let isExplicitInitialTopLevelNavigation: Bool
        var task: Task<Void, Never>?
        var wasStopped = false

        init(isExplicitInitialTopLevelNavigation: Bool) {
            self.isExplicitInitialTopLevelNavigation = isExplicitInitialTopLevelNavigation
        }
    }
    private var tasks: [ObjectIdentifier: ActiveRequest] = [:]
    private var didClaimInitialTopLevelNavigation = false

    init(
        session: ReaderExtensionSignInSession,
        resourceBudget: ReaderExtensionSignInResourceBudget = ReaderExtensionSignInResourceBudget()
    ) {
        self.session = session
        initialProxyURL = try? ReaderExtensionSignInURLProxy.proxyURL(for: session.startURL)
        self.resourceBudget = resourceBudget
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        do {
            try resourceBudget.reserveRequest()
        } catch {
            urlSchemeTask.didFailWithError(error)
            stopSession(after: error)
            return
        }
        lock.lock()
        let isExplicitInitialTopLevelNavigation = !didClaimInitialTopLevelNavigation
            && Self.matchesInitialTopLevelRequest(urlSchemeTask.request, expectedURL: initialProxyURL)
        if isExplicitInitialTopLevelNavigation {
            didClaimInitialTopLevelNavigation = true
        }
        let activeRequest = ActiveRequest(
            isExplicitInitialTopLevelNavigation: isExplicitInitialTopLevelNavigation
        )
        guard tasks.count < Self.maximumRetainedTasks else {
            lock.unlock()
            let error = ReaderExtensionSignInResourceLimitError.queuedRequests
            urlSchemeTask.didFailWithError(error)
            stopSession(after: error)
            return
        }
        tasks[identifier] = activeRequest
        lock.unlock()
        let task = Task { [weak self, weak urlSchemeTask] in
            guard let self, let urlSchemeTask else { return }
            do {
                let permit = try await concurrencyGate.acquire()
                defer { permit.release() }
                let request = try await makeNetworkRequest(
                    from: urlSchemeTask.request,
                    isExplicitInitialTopLevelNavigation: activeRequest.isExplicitInitialTopLevelNavigation
                )
                try resourceBudget.recordRequestBytes(request.body?.count ?? 0)
                let response = try await session.network.request(request)
                try resourceBudget.recordResponseBytes(response.body.count)
                try await MainActor.run {
                    try ReaderExtensionManager.shared.validateSignInSession(self.session)
                }
                let contentType = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
                }?.value ?? "application/octet-stream"
                let disposition = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Disposition") == .orderedSame
                }?.value.lowercased() ?? ""
                guard !disposition.contains("attachment") else {
                    throw ReaderExtensionError.unsupportedArchive
                }
                let visibleCookies = ReaderExtensionCookieAdmissionPolicy.allowsCookies(
                    for: response.finalURL,
                    request: request
                ) ? ReaderExtensionSignInCookieBridge.visibleCookies(
                    for: response.finalURL,
                    session: session
                ) : [:]
                let body = try ReaderExtensionSignInContentRewriter.rewrittenBody(
                    response.body,
                    contentType: contentType,
                    finalURL: response.finalURL,
                    visibleCookies: visibleCookies
                )
                // Count both received and post-rewrite bytes so a sequence of
                // expansion-heavy documents cannot hide behind the wire-size
                // budget.
                try resourceBudget.recordResponseBytes(body.count)
                let responseURL = try ReaderExtensionSignInURLProxy.proxyURL(for: response.finalURL)
                let headers = ReaderExtensionSignInResponseHeaderPolicy.sanitizedHeaders(
                    response.headers,
                    bodyCount: body.count,
                    approvedDomains: session.approvedDomains
                )
                guard let http = HTTPURLResponse(
                    url: responseURL,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else { throw ReaderExtensionError.insecureURL }
                guard finishIfActive(identifier, action: {
                    urlSchemeTask.didReceive(http)
                    urlSchemeTask.didReceive(body)
                    urlSchemeTask.didFinish()
                }) else { return }
            } catch is CancellationError {
                _ = finishIfActive(identifier) {}
            } catch {
                guard finishIfActive(identifier, action: {
                    urlSchemeTask.didFailWithError(error)
                }) else { return }
                onError?(error.localizedDescription)
                if isSessionStoppingSafetyLimit(error) {
                    stopSession(after: error)
                }
            }
        }
        lock.lock()
        activeRequest.task = task
        if activeRequest.wasStopped { task.cancel() }
        lock.unlock()
    }

    func webView(_: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        let activeRequest = tasks.removeValue(forKey: identifier)
        activeRequest?.wasStopped = true
        let task = activeRequest?.task
        lock.unlock()
        task?.cancel()
    }

    private func isSessionStoppingSafetyLimit(_ error: Error) -> Bool {
        if error is ReaderExtensionSignInResourceLimitError {
            return true
        }
        guard let readerError = error as? ReaderExtensionError else {
            return false
        }
        if case .contentTooLarge = readerError {
            return true
        }
        return false
    }

    func cancelAll() {
        resourceBudget.stop()
        Task { await concurrencyGate.stop() }
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        active.forEach { $0.wasStopped = true }
        lock.unlock()
        active.forEach { $0.task?.cancel() }
    }

    private func stopSession(after error: Error) {
        resourceBudget.stop()
        Task { await concurrencyGate.stop() }
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        active.forEach { $0.wasStopped = true }
        lock.unlock()
        active.forEach { $0.task?.cancel() }
        onError?(error.localizedDescription)
    }

    func makeNetworkRequest(
        from request: URLRequest,
        isExplicitInitialTopLevelNavigation: Bool = false
    ) async throws -> ReaderExtensionNetworkRequest {
        try await MainActor.run {
            try ReaderExtensionManager.shared.validateSignInSession(session)
        }
        return try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: request,
            sourceID: session.sourceID,
            approvedDomains: session.approvedDomains,
            baseDomain: session.baseDomain,
            isExplicitInitialTopLevelNavigation: isExplicitInitialTopLevelNavigation
        )
    }

    private static func matchesInitialTopLevelRequest(
        _ request: URLRequest,
        expectedURL: URL?
    ) -> Bool {
        guard let expectedURL,
              request.url?.absoluteString == expectedURL.absoluteString,
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil,
              request.httpBodyStream == nil else {
            return false
        }
        return true
    }

    @discardableResult
    private func finishIfActive(
        _ identifier: ObjectIdentifier,
        action: () -> Void
    ) -> Bool {
        lock.lock()
        let wasActive = tasks.removeValue(forKey: identifier) != nil
        lock.unlock()
        guard wasActive else { return false }
        action()
        return true
    }
}

enum ReaderExtensionExternalBrowserBoundary {
    static let disclosure = "Opens in your default browser. Browser cookies stay there and are not imported into Eclipse; use Sign In above when the source needs an Eclipse authentication session."

    static func validatedURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              ReaderExtensionSecurityPolicy.canonicalHost(of: url) != nil else {
            return nil
        }
        return url
    }
}


#endif
