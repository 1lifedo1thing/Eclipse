import CryptoKit
import Foundation
import Network
import XCTest
@testable import EclipseMac

final class MacSourceRuntimeTests: XCTestCase {
    func testServiceExecutesSearchDetailsStreamsAndPreservesPrivateHeaders() async throws {
        let suite = "EclipseMacServiceRuntimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: ServiceJavaScriptQuarantineStore(defaults: defaults))
        let script = """
        async function searchResults(query) {
            return JSON.stringify([{title: atob(btoa(query)), image: 'https://fixture.example/poster.jpg', href: 'https://fixture.example/show'}]);
        }
        async function extractDetails(url) {
            return JSON.stringify([{description: 'Native Service runtime', aliases: 'Fixture', airdate: '2026'}]);
        }
        async function extractEpisodes(url) {
            return JSON.stringify([{number: 2, title: 'Second', href: 'https://fixture.example/episode/2'}]);
        }
        async function extractStreamUrl(url) {
            return JSON.stringify({streams: [{url: 'https://fixture.example/video.mp4',
                headers: {Authorization: 'Fixture media', Cookie: 'fixture=service'},
                subtitles: [{url: 'https://fixture.example/captions.vtt', language: 'en',
                    headers: {Authorization: 'Fixture caption'}}]}]});
        }
        """
        let service = Service(id: UUID(), metadata: ServiceMetadata(sourceName: "Native Service fixture",
            author: .init(name: "Eclipse Tests", icon: ""), iconUrl: "", version: "1", language: "en",
            baseUrl: "https://fixture.example", streamType: "mp4", quality: "1080p",
            searchBaseUrl: "https://fixture.example/search", scriptUrl: "https://fixture.example/script.js",
            softsub: true, multiStream: true, multiSubs: true, type: "anime", novel: false, settings: false),
            jsScript: script, url: "https://fixture.example/manifest.json", isActive: true, sortIndex: 0)
        controller.loadScript(script, service: service, timeoutNanoseconds: 5_000_000_000)
        let search: [SearchItem] = await withCheckedContinuation { continuation in
            controller.fetchJsSearchResults(keyword: "Mac fixture", module: service,
                timeoutNanoseconds: 5_000_000_000) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(search.first?.title, "Mac fixture")
        XCTAssertEqual(search.first?.href, "https://fixture.example/show")
        let detail: ([MediaItem], [EpisodeLink]) = await withCheckedContinuation { continuation in
            controller.fetchDetailsJS(url: "https://fixture.example/show", module: service,
                timeoutNanoseconds: 5_000_000_000) { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertEqual(detail.0.first?.description, "Native Service runtime")
        XCTAssertEqual(detail.1.first?.number, 2)
        let result: ServiceStreamExtractionResult = await withCheckedContinuation { continuation in
            controller.fetchStreamUrlJS(episodeUrl: "https://fixture.example/episode/2", module: service,
                timeoutNanoseconds: 5_000_000_000) { continuation.resume(returning: $0) }
        }
        let source = try XCTUnwrap(result.sources?.first)
        XCTAssertEqual(source["url"] as? String, "https://fixture.example/video.mp4")
        let headers = try XCTUnwrap(source["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Fixture media")
        XCTAssertEqual(headers["Cookie"], "fixture=service")
        let subtitle = try XCTUnwrap((source["subtitles"] as? [[String: Any]])?.first)
        XCTAssertEqual(subtitle["url"] as? String, "https://fixture.example/captions.vtt")
        XCTAssertEqual((subtitle["headers"] as? [String: String])?["Authorization"], "Fixture caption")
    }

    func testSkyStreamExecutesNativeDOMPreferencesExportsAndHeaderMapping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMacSkyRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        function search(query) { return [{title: query, url: 'https://fixture.example/show'}]; }
        async function load(url) {
            var document = await parseHtml('<h1>Native DOM</h1>');
            return {title: [document.querySelector('h1').textContent, getPreference('label'), nativeMd5('hello')].join('|'),
                url: url, episodes: [{name: 'Second', episode: 2, season: 1, url: 'https://fixture.example/episode/2'}]};
        }
        function loadStreams(url) {
            return [{url: 'https://fixture.example/video.mp4', headers: {Authorization: 'Fixture media', Cookie: 'fixture=sky', Host: 'invalid.example'},
                subtitles: [{url: 'https://fixture.example/captions.vtt', language: 'en', headers: {Authorization: 'Fixture caption'}}]}];
        }
        function getProviders() { return [{id: 'native', name: 'Native fixture', baseUrl: 'https://fixture.example'}]; }
        """
        let data = Data(script.utf8)
        let scriptURL = directory.appendingPathComponent("plugin.js")
        try data.write(to: scriptURL, options: .atomic)
        let manifest = SkyStreamPluginManifest(packageName: "fixture.mac.\(UUID().uuidString)",
            name: "Native SkyStream fixture", version: 1, authors: ["Eclipse Tests"],
            baseURL: "https://fixture.example", languages: ["en"], categories: ["series"])
        let configuration = SkyStreamRuntimeConfiguration(manifest: manifest, scriptURL: scriptURL,
            expectedScriptSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            dataStore: .init(snapshot: .init(preferences: ["label": .string("Mac preferences")])))
        let pool = SkyStreamRuntimePool()
        let search = try await pool.search(using: configuration, query: "Mac fixture")
        XCTAssertEqual(search.first?.title, "Mac fixture")
        let loaded = try await pool.load(using: configuration, url: "https://fixture.example/show")
        XCTAssertEqual(loaded.title, "Native DOM|Mac preferences|5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(loaded.episodes.first?.episode, 2)
        let providers = try await pool.getProviders(using: configuration)
        XCTAssertEqual(providers.map(\.id), ["native"])
        let streams = try await pool.loadStreams(using: configuration, url: "https://fixture.example/episode/2")
        let stream = try XCTUnwrap(streams.first)
        XCTAssertEqual(stream.headers["authorization"], "Fixture media")
        XCTAssertEqual(stream.headers["cookie"], "fixture=sky")
        XCTAssertNil(stream.headers["host"])
        XCTAssertEqual(stream.subtitles.first?.headers["authorization"], "Fixture caption")
        await pool.invalidatePackage(manifest.packageName, acceptingRevision: nil, resetCookies: true, resetDataStore: true)
    }

    func testStremioHTTPCallbacksKeepCookieIsolationAndPlayableHeaders() async throws {
        let server = try MacSourceHTTPFixture()
        let baseURL = try await server.start()
        defer { server.stop() }
        let client = StremioClient()
        let manifest = try await client.fetchManifest(from: baseURL)
        XCTAssertEqual(manifest.id, "fixture.mac")
        let catalog = try XCTUnwrap(manifest.catalogs?.first)
        let metas = try await client.fetchCatalogMetas(baseURL: baseURL, catalog: catalog)
        XCTAssertEqual(metas.first?.name, "Native HTTP fixture")
        let meta = try await client.fetchMeta(baseURL: baseURL, type: "movie", id: "tt123")
        XCTAssertEqual(meta?.name, "Native HTTP fixture")
        let result = try await client.fetchStreamOutcome(baseURL: baseURL, type: "movie", id: "tt123")
        XCTAssertEqual(result.streams.count, 1)
        XCTAssertEqual(result.torrentOnlyCount, 1)
        XCTAssertEqual(result.externalOnlyCount, 1)
        XCTAssertEqual(result.streams.first?.proxyHeaders?["Authorization"], "Fixture media")
        XCTAssertEqual(result.streams.first?.proxyHeaders?["Cookie"], "fixture=media")
        let subtitles = try await client.fetchSubtitles(baseURL: baseURL, type: "movie", id: "tt123")
        XCTAssertEqual(subtitles.first?.lang, "eng")
        XCTAssertEqual(subtitles.first?.url, "https://fixture.example/captions.vtt")
        XCTAssertEqual(server.requests.count, 5)
        XCTAssertTrue(server.requests.filter { $0.path != "/manifest.json" }.allSatisfy {
            $0.headers["cookie"]?.contains("fixture=stremio") == true
        })
        let separateClient = StremioClient()
        _ = try await separateClient.fetchMeta(baseURL: baseURL, type: "movie", id: "tt456")
        let separateRequest = try XCTUnwrap(server.requests.last { $0.path == "/meta/movie/tt456.json" })
        XCTAssertNil(separateRequest.headers["cookie"])
    }
}

private final class MacSourceHTTPFixture: @unchecked Sendable {
    struct Request {
        let path: String
        let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "EclipseMacSourceHTTPFixture")
    private let lock = NSLock()
    private var capturedRequests: [Request] = []
    private var connections: [UUID: NWConnection] = [:]
    private var startupContinuation: CheckedContinuation<String, Error>?

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    self.finishStarting(.success("http://127.0.0.1:\(port.rawValue)"))
                case .failed(let error):
                    self.finishStarting(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: self.queue)
                self.receive(connection, id: id, buffer: Data())
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.startupContinuation != nil else { return }
                self.listener.cancel()
                self.finishStarting(.failure(URLError(.timedOut)))
            }
        }
    }

    private func finishStarting(_ result: Result<String, Error>) {
        let continuation = startupContinuation
        startupContinuation = nil
        continuation?.resume(with: result)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 65_536, error == nil else { self.finish(connection, id: id); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
                let lines = head.components(separatedBy: "\r\n")
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
                    guard let separator = line.firstIndex(of: ":") else { return }
                    result[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                let request = Request(path: path, headers: headers)
                self.lock.lock()
                self.capturedRequests.append(request)
                self.lock.unlock()
                let body = self.responseBody(for: path)
                let cookie = path == "/manifest.json" ? "Set-Cookie: fixture=stremio; Path=/; HttpOnly\r\n" : ""
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(cookie)Connection: close\r\n\r\n"
                connection.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self] _ in
                    self?.finish(connection, id: id)
                })
            } else if complete {
                self.finish(connection, id: id)
            } else {
                self.receive(connection, id: id, buffer: buffer)
            }
        }
    }

    private func finish(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections.removeValue(forKey: id)
    }

    private func responseBody(for path: String) -> String {
        if path == "/manifest.json" {
            return #"{"id":"fixture.mac","name":"Native fixture","version":"1.0.0","types":["movie"],"resources":["stream","catalog","meta","subtitles"],"catalogs":[{"id":"fixture","type":"movie"}]}"#
        }
        if path.hasPrefix("/catalog/") {
            return #"{"metas":[{"id":"tt123","type":"movie","name":"Native HTTP fixture"}]}"#
        }
        if path.hasPrefix("/meta/") {
            return #"{"meta":{"id":"tt123","type":"movie","name":"Native HTTP fixture"}}"#
        }
        if path.hasPrefix("/stream/") {
            return #"{"streams":[{"url":"https://fixture.example/video.mp4","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Fixture media","Cookie":"fixture=media"}}}},{"infoHash":"0123456789012345678901234567890123456789"},{"externalUrl":"https://fixture.example/watch"}]}"#
        }
        return #"{"subtitles":[{"id":"fixture","url":"https://fixture.example/captions.vtt","lang":"eng"}]}"#
    }
}
