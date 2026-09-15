import Foundation
import CryptoKit

struct ExperimentalCloudNuvioRestorePlan: Equatable {
    let state: NuvioStoredPluginsState
    let deviceLocalSourceIDs: Set<String>
}

enum PluginCloudConfiguration {
    static func nuvioStateForExperimentalCloudSync(
        _ state: NuvioStoredPluginsState
    ) -> NuvioStoredPluginsState? {
        let bounded = NuvioPluginStore.bounded(state)
        guard !bounded.wasBounded,
              bounded.state.repositories.allSatisfy({
                  PrivateCloudSourceURLPolicy.validatedHTTPURLString($0.manifestUrl) != nil
              }),
              bounded.state.scrapers.allSatisfy({
                  PrivateCloudSourceURLPolicy.validatedHTTPURLString($0.repositoryUrl) != nil
              }) else {
            return nil
        }
        return bounded.state
    }

    static func nuvioMetadataForMediaState(
        persistedValue: Any?
    ) -> Data? {
        let state: NuvioStoredPluginsState
        if let persistedValue {
            guard let persistedData = persistedValue as? Data else { return nil }
            guard NuvioPluginStore.persistedStateDataIsWithinLimit(persistedData),
                  let decoded = try? JSONDecoder().decode(
                    NuvioStoredPluginsState.self,
                    from: persistedData
                  ) else {
                return nil
            }
            state = decoded
        } else {
            state = NuvioStoredPluginsState()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let safeState = nuvioStateForExperimentalCloudSync(state),
              let encoded = try? encoder.encode(safeState), !encoded.isEmpty,
           encoded.count <= MediaStateServiceSourcesPayload.maximumNuvioMetadataBytes else {
            return nil
        }
        return encoded
    }

    static func nuvioRestorePlanForExperimentalCloudSync(
        incoming: NuvioStoredPluginsState,
        current: NuvioStoredPluginsState
    ) -> ExperimentalCloudNuvioRestorePlan {
        guard let safeIncoming = nuvioStateForExperimentalCloudSync(incoming),
              let safeCurrent = nuvioStateForExperimentalCloudSync(current) else {
            return ExperimentalCloudNuvioRestorePlan(
                state: current,
                deviceLocalSourceIDs: Set(
                    current.repositories.map(\.id) + current.scrapers.map(\.id)
                )
            )
        }
        let boundedCurrent = safeCurrent
        let safeCurrentRepositoryIDs = Set(safeCurrent.repositories.map(\.id))

        let deviceLocalRepositories = boundedCurrent.repositories.filter {
            !safeCurrentRepositoryIDs.contains($0.id)
        }
        let deviceLocalRepositoryIDs = Set(deviceLocalRepositories.map(\.id))
        let deviceLocalScrapers = boundedCurrent.scrapers.filter {
            deviceLocalRepositoryIDs.contains($0.repositoryId)
        }

        var merged = safeIncoming
        merged.repositories.append(contentsOf: deviceLocalRepositories.filter { repository in
            !merged.repositories.contains(where: { $0.id == repository.id })
        })
        merged.scrapers.append(contentsOf: deviceLocalScrapers.filter { scraper in
            !merged.scrapers.contains(where: { $0.id == scraper.id })
        })

        let survivingScraperIDs = Set(merged.scrapers.map(\.id))
        let incomingScraperIDs = Set(safeIncoming.scrapers.map(\.id))
        let deviceLocalScraperIDs = Set(deviceLocalScrapers.map(\.id))
        merged.scraperSettings = safeIncoming.scraperSettings.filter {
            incomingScraperIDs.contains($0.key)
        }
        for (scraperID, settings) in boundedCurrent.scraperSettings
        where deviceLocalScraperIDs.contains(scraperID)
            && survivingScraperIDs.contains(scraperID) {
            merged.scraperSettings[scraperID] = settings
        }
        merged = NuvioPluginStore.bounded(merged).state

        let mergedRepositoryIDs = Set(merged.repositories.map(\.id))
        let mergedScraperIDs = Set(merged.scrapers.map(\.id))
        let survivingDeviceLocalRepositoryIDs = deviceLocalRepositoryIDs.intersection(
            mergedRepositoryIDs
        )
        let survivingDeviceLocalScraperIDs = Set(deviceLocalScrapers.map(\.id)).intersection(
            mergedScraperIDs
        )
        return ExperimentalCloudNuvioRestorePlan(
            state: merged,
            deviceLocalSourceIDs: survivingDeviceLocalRepositoryIDs.union(
                survivingDeviceLocalScraperIDs
            )
        )
    }

    static func skyStreamSnapshotForExperimentalCloudSync(
        _ incoming: SkyStreamBackupSnapshot,
        stripArchives: Bool = false
    ) -> SkyStreamBackupSnapshot? {
        let configurationIsComplete = SkyStreamPrivateCloudConfigurationPolicy
            .snapshotHasCompleteConfiguration(incoming)
        guard incoming.privateCloudConfigurationIsComplete != true
                || configurationIsComplete else {
            return nil
        }
        let validatedURL: (String) -> String? = configurationIsComplete
            ? skyStreamPrivateCloudURLString
            : skyStreamCloudSafeURLString

        func resolvedURL(_ rawValue: String, relativeTo baseURL: URL) -> String? {
            guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return validatedURL(resolved.absoluteString)
        }

        func sanitizedPluginManifest(
            _ incomingManifest: SkyStreamPluginManifest,
            relativeTo baseURL: URL? = nil
        ) -> SkyStreamPluginManifest? {
            func configuredURL(_ rawValue: String) -> String? {
                if let baseURL {
                    return resolvedURL(rawValue, relativeTo: baseURL)
                }
                return validatedURL(rawValue)
            }

            var manifest = incomingManifest
            manifest.additionalFields = [:]
            if !manifest.baseURL.isEmpty {
                guard let baseURL = configuredURL(manifest.baseURL) else { return nil }
                manifest.baseURL = baseURL
            }
            if let iconURL = manifest.iconURL {
                guard let validatedIconURL = configuredURL(iconURL) else { return nil }
                manifest.iconURL = validatedIconURL
            }
            if let domains = manifest.domains {
                var sanitizedDomains: [SkyStreamPluginDomain] = []
                sanitizedDomains.reserveCapacity(domains.count)
                for incomingDomain in domains {
                    guard let domainURL = configuredURL(incomingDomain.url) else { return nil }
                    var domain = incomingDomain
                    domain.url = domainURL
                    domain.additionalFields = [:]
                    sanitizedDomains.append(domain)
                }
                manifest.domains = sanitizedDomains
            }
            if let providers = manifest.providers {
                var sanitizedProviders: [SkyStreamPluginProvider] = []
                sanitizedProviders.reserveCapacity(providers.count)
                for incomingProvider in providers {
                    var provider = incomingProvider
                    if let baseURL = provider.baseURL {
                        guard let validatedBaseURL = configuredURL(baseURL) else { return nil }
                        provider.baseURL = validatedBaseURL
                    }
                    if let iconURL = provider.iconURL {
                        guard let validatedIconURL = configuredURL(iconURL) else { return nil }
                        provider.iconURL = validatedIconURL
                    }
                    provider.additionalFields = [:]
                    sanitizedProviders.append(provider)
                }
                manifest.providers = sanitizedProviders
            }
            return manifest
        }

        var repositories: [SkyStreamRepositoryBackupSnapshot] = []
        repositories.reserveCapacity(incoming.repositories.count)
        for repository in incoming.repositories {
            guard let sourceURL = validatedURL(repository.sourceURL),
                  let baseURL = URL(string: sourceURL) else { return nil }
            var sanitized = repository
            sanitized.sourceURL = sourceURL
            sanitized.additionalFields = [:]
            let rawPluginListURLs = sanitized.pluginListURLs.isEmpty
                ? (sanitized.manifest?.pluginLists ?? [])
                : sanitized.pluginListURLs
            var pluginListURLs: [String] = []
            pluginListURLs.reserveCapacity(rawPluginListURLs.count)
            for rawValue in rawPluginListURLs {
                guard let resolved = resolvedURL(rawValue, relativeTo: baseURL) else { return nil }
                pluginListURLs.append(resolved)
            }
            sanitized.pluginListURLs = pluginListURLs
            sanitized.lastRefreshedAt = nil
            sanitized.frozenAt = nil
            guard !sanitized.pluginListURLs.isEmpty else { return nil }
            if var manifest = sanitized.manifest {
                guard sanitized.kind == .repository,
                      SkyStreamRepositoryManifest.isSupportedManifestVersion(
                          manifest.manifestVersion
                      ) else { return nil }
                for rawValue in manifest.pluginLists {
                    guard resolvedURL(rawValue, relativeTo: baseURL) != nil else { return nil }
                }
                manifest.additionalFields = [:]
                manifest.pluginLists = sanitized.pluginListURLs
                var includedRepositories: [String] = []
                includedRepositories.reserveCapacity(manifest.includedRepositories.count)
                for rawValue in manifest.includedRepositories {
                    guard let resolved = resolvedURL(rawValue, relativeTo: baseURL) else { return nil }
                    includedRepositories.append(resolved)
                }
                manifest.includedRepositories = includedRepositories
                var embeddedPlugins: [SkyStreamPluginListEntry] = []
                embeddedPlugins.reserveCapacity(manifest.plugins.count)
                for incomingEntry in manifest.plugins {
                    guard let archiveURL = resolvedURL(incomingEntry.url, relativeTo: baseURL),
                          let embeddedManifest = sanitizedPluginManifest(
                            incomingEntry.manifest,
                            relativeTo: baseURL
                          ) else { return nil }
                    var entry = incomingEntry
                    entry.url = archiveURL
                    entry.manifest = embeddedManifest
                    entry.additionalFields = [:]
                    embeddedPlugins.append(entry)
                }
                manifest.plugins = embeddedPlugins
                if let iconURL = manifest.iconURL {
                    guard let validatedIconURL = resolvedURL(iconURL, relativeTo: baseURL) else {
                        return nil
                    }
                    manifest.iconURL = validatedIconURL
                }
                if let websiteURL = manifest.websiteURL {
                    guard let validatedWebsiteURL = resolvedURL(
                        websiteURL,
                        relativeTo: baseURL
                    ) else { return nil }
                    manifest.websiteURL = validatedWebsiteURL
                }
                sanitized.manifest = manifest
            } else {
                guard sanitized.kind == .pluginList else { return nil }
            }
            guard SkyStreamBackupMetadataPolicy.isBounded(repository: sanitized) else {
                return nil
            }
            repositories.append(sanitized)
        }
        repositories.sort { $0.sourceURL < $1.sourceURL }

        var aggregateArchiveBytes = 0
        var plugins: [SkyStreamPluginBackupSnapshot] = []
        plugins.reserveCapacity(incoming.plugins.count)
        for plugin in incoming.plugins {
            guard let sourceURL = validatedURL(plugin.state.provenance.sourceURL) else {
                return nil
            }
            var sanitized = plugin
            if stripArchives {
                sanitized.archivePayload = nil
                sanitized.payloadWasRedacted = true
            } else if let archive = plugin.archivePayload {
                let digest = SHA256.hash(data: archive)
                    .map { String(format: "%02x", $0) }
                    .joined()
                let (nextAggregateBytes, overflow) = aggregateArchiveBytes.addingReportingOverflow(
                    archive.count
                )
                if archive.count <= 20 * 1_024 * 1_024,
                   digest.caseInsensitiveCompare(plugin.state.archiveSHA256) == .orderedSame,
                   !overflow,
                   nextAggregateBytes <= 64 * 1_024 * 1_024 {
                    aggregateArchiveBytes = nextAggregateBytes
                    sanitized.archivePayload = archive
                    sanitized.payloadWasRedacted = false
                } else {
                    sanitized.archivePayload = nil
                    sanitized.payloadWasRedacted = true
                }
            } else {
                sanitized.archivePayload = nil
                sanitized.payloadWasRedacted = true
            }
            sanitized.additionalFields = [:]
            sanitized.state.additionalFields = [:]
            sanitized.state.payloadRelativePath = ""
            sanitized.state.runtimeStorage = nil
            if configurationIsComplete {
                guard SkyStreamPrivateCloudConfigurationPolicy
                    .preferencesAreCompleteAndBounded(sanitized.state.preferences) else {
                    return nil
                }
            } else {
                sanitized.state.preferences = sanitized.state.preferences.filter { key, value in
                    !value.isSecret &&
                        !value.isRedacted &&
                        !containsCloudUnsafeSecret(key)
                }
            }
            sanitized.state.preferences = sanitized.state.preferences.mapValues { value in
                var canonical = value
                canonical.updatedAt = nil
                return canonical
            }
            sanitized.preferencesWereRedacted = !configurationIsComplete

            sanitized.state.provenance.sourceURL = sourceURL
            if let repositoryURL = sanitized.state.provenance.repositoryURL {
                guard let validatedRepositoryURL = validatedURL(repositoryURL) else { return nil }
                sanitized.state.provenance.repositoryURL = validatedRepositoryURL
            }
            if let pluginListURL = sanitized.state.provenance.pluginListURL {
                guard let validatedPluginListURL = validatedURL(pluginListURL) else { return nil }
                sanitized.state.provenance.pluginListURL = validatedPluginListURL
            }
            sanitized.state.provenance.additionalFields = [:]
            sanitized.state.provenance.pinnedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.provenance.frozenAt = nil
            sanitized.state.provenance.expectedArchiveSHA256 = sanitized.state.archiveSHA256
            if let selectedDomainURL = sanitized.state.selectedDomainURL {
                guard let validatedSelectedDomainURL = validatedURL(selectedDomainURL) else {
                    return nil
                }
                sanitized.state.selectedDomainURL = validatedSelectedDomainURL
            }
            sanitized.state.providers = sanitized.state.providers.filter {
                $0.removedAt == nil
            }.map { provider in
                var provider = provider
                provider.removedAt = nil
                provider.additionalFields = [:]
                return provider
            }.sorted { $0.id < $1.id }

            guard let manifest = sanitizedPluginManifest(sanitized.state.manifest) else {
                return nil
            }
            sanitized.state.manifest = manifest
            sanitized.state.compatibility.reasons = sanitized.state.compatibility.reasons.map { reason in
                var reason = reason
                reason.additionalFields = [:]
                return reason
            }
            sanitized.state.installedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.updatedAt = Date(timeIntervalSince1970: 0)
            sanitized.state.compatibility = .untested
            let usesDynamicProviders = sanitized.state.usesDynamicProviders == true
                || sanitized.state.manifest.providers?.isEmpty == true
            sanitized.state.usesDynamicProviders = usesDynamicProviders
            if usesDynamicProviders {
                sanitized.state.manifest.providers = []
            }
            if let selectedDomainURL = sanitized.state.selectedDomainURL,
               sanitized.state.manifest.domains?.contains(where: {
                    $0.url == selectedDomainURL
               }) != true {
                return nil
            }
            guard SkyStreamBackupMetadataPolicy.isBounded(pluginState: sanitized.state) else {
                return nil
            }
            plugins.append(sanitized)
        }
        plugins.sort { $0.id < $1.id }
        return SkyStreamBackupSnapshot(
            schemaVersion: incoming.schemaVersion,
            repositories: repositories,
            plugins: plugins,
            createdAt: Date(timeIntervalSince1970: 0),
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: configurationIsComplete ? true : nil,
            additionalFields: [:]
        )
    }

    private static func skyStreamPrivateCloudURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value == trimmed,
              value.utf8.count <= 8 * 1_024,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false,
              components.url?.absoluteString == value else {
            return nil
        }
        return value
    }

    private static func skyStreamCloudSafeURLString(_ value: String) -> String? {
        guard let sanitized = cloudSafeURLString(value),
              var components = URLComponents(string: sanitized),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.queryItems?.isEmpty != false else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func cloudSafeURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsCloudUnsafeSecretInURL(trimmed),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",

              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,

              (components.percentEncodedQuery ?? "").isEmpty,
              !containsCredentialShapedPathSegment(components.percentEncodedPath) else {
            return nil
        }

        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func containsCredentialShapedPathSegment(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        if lowercased.contains("x-amz-") || lowercased.contains("x-goog-") { return true }
        return path.split(separator: "/").contains { $0.hasPrefix("eyJ") }
    }

    private static func containsCloudUnsafeSecretInURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else {
            return containsCloudUnsafeSecret(value)
        }
        if let user = components.user, containsCloudUnsafeSecret(user) { return true }
        if let password = components.password, !password.isEmpty { return true }
        if let query = components.percentEncodedQuery, containsCloudUnsafeSecret(query) { return true }
        if let fragment = components.percentEncodedFragment,
           containsCloudUnsafeSecret(fragment) { return true }
        return components.percentEncodedPath
            .split(separator: "/")
            .contains { $0.contains("=") && containsCloudUnsafeSecret(String($0)) }
    }

    private static func containsCloudUnsafeSecret(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let secretMarkers = [
            "access_token",
            "refresh_token",
            "authorization",
            "bearer ",
            "api_key",
            "apikey",
            "password",
            "passwd",
            "session",
            "secret",
            "token="
        ]
        return secretMarkers.contains { lowercased.contains($0) }
    }
}
