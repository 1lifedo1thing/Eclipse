import Foundation
import XCTest
@testable import EclipseMac

final class NuvioMacRuntimeTests: XCTestCase {
    func testRuntimeExportsAndSettingsExecuteWithoutManifestSettingsClaim() async throws {
        let provider = fixtureProvider()
        let owner = UUID()
        let code = """
        exports.onSettings = async function() {
            return [{ type: 'text', key: 'label', label: 'Label', defaultValue: SCRAPER_SETTINGS.label }];
        };
        exports.getStreams = async function(id, type, season, episode) {
            var encoded = btoa(String(id) + ':' + type + ':' + season + ':' + episode);
            var label = atob(encoded);
            return [{ url: 'https://media.example/fixture.mp4', title: label,
                headers: { Authorization: 'Fixture stream', Cookie: 'fixture=stream' },
                subtitles: [{ url: 'https://captions.example/fixture.vtt', language: 'en',
                    headers: { Authorization: 'Fixture subtitle' } }] }];
        };
        """
        XCTAssertFalse(provider.declaresSettings)
        let fields = try await NuvioPluginRuntime.executeSettings(code: code, scraper: provider,
            scraperSettings: ["label": "Mac runtime fixture"], servicesProfileID: owner, sharesServices: false)
        XCTAssertEqual(fields.map(\.key), ["label"])
        XCTAssertEqual(fields.first?.defaultValue, .string("Mac runtime fixture"))
        let result = try await NuvioPluginRuntime.execute(code: code, tmdbId: "123", mediaType: "tv",
            season: 2, episode: 3, scraper: provider, repository: fixtureRepository(),
            scraperSettings: ["label": "Mac runtime fixture"], servicesProfileID: owner, sharesServices: false)
        let stream = try XCTUnwrap(result.streams.first)
        XCTAssertEqual(result.streams.count, 1)
        XCTAssertEqual(stream.title, "123:tv:2:3")
        XCTAssertEqual(stream.headers?["Authorization"], "Fixture stream")
        XCTAssertEqual(stream.headers?["Cookie"], "fixture=stream")
        let subtitle = try XCTUnwrap(stream.subtitles?.first)
        XCTAssertEqual(subtitle.headers?["Authorization"], "Fixture subtitle")
        XCTAssertEqual(stream.sanitizedHeaders, ["authorization": "Fixture stream", "cookie": "fixture=stream"])
        XCTAssertEqual(stream.subtitleHeadersByURL?["https://captions.example/fixture.vtt"],
            ["authorization": "Fixture subtitle"])
        XCTAssertEqual(result.requestCount, 0)
    }

    func testMissingRuntimeExportIsAnErrorInsteadOfCodeReadiness() async {
        do {
            _ = try await NuvioPluginRuntime.execute(code: "exports.onSettings = function() { return []; };",
                tmdbId: "123", mediaType: "movie", season: nil, episode: nil,
                scraper: fixtureProvider(), repository: fixtureRepository(), scraperSettings: [:],
                servicesProfileID: UUID(), sharesServices: false)
            XCTFail("An installed metadata row cannot stand in for a getStreams export.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("getStreams"))
        }
    }

    private func fixtureProvider() -> NuvioPluginScraper {
        .init(id: "nuvio:mac-runtime-fixture", providerKey: "fixture", repositoryId: "mac-fixture",
            repositoryUrl: "https://repository.example/manifest.json", name: "Mac runtime fixture",
            description: "", author: nil, version: "1", filename: "fixture.js", codeFileName: "fixture.js",
            supportedTypes: ["movie", "tv"], enabled: true, manifestEnabled: true, declaresSettings: false,
            logo: nil, contentLanguage: ["en"], formats: nil)
    }

    private func fixtureRepository() -> NuvioPluginRepository {
        .init(id: "mac-fixture", manifestUrl: "https://repository.example/manifest.json", name: "Mac fixture",
            description: nil, version: "1", scraperCount: 1, lastUpdated: 0, sortIndex: 0)
    }
}
