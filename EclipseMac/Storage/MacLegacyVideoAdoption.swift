#if os(macOS)
import CryptoKit
import Darwin
import Foundation

enum MacLegacyVideoAdoption {
    private struct Receipt: Codable {
        let version: Int
        let sourceDigest: String
        let indexDigest: String

        var isValid: Bool {
            version == 1 && [sourceDigest, indexDigest].allSatisfy {
                $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit }
            }
        }
    }

    static func adopt(documents: URL, registry: DownloadStorageRegistry) throws {
        guard registry.isReadable else { throw DownloadStorageError.unreadableRegistry }
        let indexURL = registry.indexURL(for: .video)
        let receiptURL = indexURL.deletingLastPathComponent().appendingPathComponent("legacy-video-adoption.json")
        if let receiptData = try existingData(at: receiptURL, maximumBytes: 4_096) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: receiptData)
            guard receipt.isValid,
                  let current = try existingData(at: indexURL, maximumBytes: DownloadMetadataPersistencePolicy.Bounds.fileBytes),
                  DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(current),
                  try !DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(from: current).hasUnreadableItems else {
                throw DownloadStorageError.verificationFailed
            }
            return
        }
        guard let sourceIndex = try existingFile(relativePath: "Downloads/.downloads_metadata.json", inside: documents),
              let sourceData = try existingData(at: sourceIndex, maximumBytes: DownloadMetadataPersistencePolicy.Bounds.fileBytes) else { return }
        guard DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(sourceData) else {
            throw DownloadStorageError.verificationFailed
        }
        let raw = try JSONDecoder().decode([DownloadItem].self, from: sourceData)
        let normalized = DownloadMetadataPersistencePolicy.normalizedLoadedItems(raw)
        guard !normalized.hasUnreadableItems, raw.count == normalized.items.count,
              Set(raw.map(\.id)).count == raw.count else { throw DownloadStorageError.verificationFailed }
        for item in raw {
            guard item.storageLocation == nil, item.pendingMacFinalization == nil else { throw DownloadStorageError.invalidPath }
            for path in [item.localFileName, item.subtitleFileName, item.reservedVideoFileName, item.reservedSubtitleFileName].compactMap({ $0 }) {
                guard DownloadPathIdentityPolicy.normalizedRelativePath(path) == path,
                      DownloadStorageRegistry.validRelativePath("Video/" + path), path != ".downloads_metadata.json" else {
                    throw DownloadStorageError.invalidPath
                }
            }
        }
        let sourceDigest = digest(sourceData)
        let root = documents.appendingPathComponent("Downloads", isDirectory: true)
        var items = normalized.items
        var leases: [DownloadStorageLease] = []
        defer { leases.forEach { $0.close() } }
        var claimedFiles: [String: String] = [:]
        for index in items.indices {
            try Task.checkCancellation()
            var item = items[index]
            let token = DirectDownloadResumePolicy.digest(item.id)
            let location = registry.legacyDefaultLocation(in: .video,
                relativePath: "Imported/" + sourceDigest + "/" + token)
            item.storageLocation = location
            let lease = try registry.acquire(location, access: .write)
            leases.append(lease)
            try FileManager.default.createDirectory(at: lease.url, withIntermediateDirectories: true)
            var copied = Set<String>()
            func copy(_ path: String, to output: String? = nil, required: Bool = false, minimumBytes: Int64 = 0) throws {
                let destinationPath = output ?? path
                guard !copied.contains(destinationPath) else { return }
                guard let source = try existingFile(relativePath: path, inside: root) else {
                    if required { throw DownloadStorageError.unavailable }
                    return
                }
                let attributes = try fileAttributes(source)
                guard attributes.st_size >= minimumBytes,
                      attributes.st_size <= DownloadMetadataPersistencePolicy.Bounds.byteCount else {
                    throw DownloadStorageError.verificationFailed
                }
                let identity = "\(attributes.st_dev):\(attributes.st_ino)"
                guard claimedFiles[identity] == nil || claimedFiles[identity] == item.id else {
                    throw DownloadStorageError.invalidPath
                }
                claimedFiles[identity] = item.id
                let destination = try registry.acquire(location.appending(destinationPath), access: .write)
                defer { destination.close() }
                try MacDownloadFinalization.copyVerifiedFile(from: source, to: destination.url, expectedBytes: attributes.st_size)
                copied.insert(destinationPath)
            }
            if item.status == .completed, item.localFileName == nil { throw DownloadStorageError.verificationFailed }
            if let path = item.localFileName {
                try copy(path, required: item.status == .completed, minimumBytes: item.status == .completed ? 1 : 0)
            }
            if let path = item.subtitleFileName { try copy(path, required: true) }
            for path in [item.reservedVideoFileName, item.reservedSubtitleFileName].compactMap({ $0 }) {
                try copy(path)
            }
            let checkpointBytes = item.directResumeCheckpoint?.byteCount ?? 0
            try copy(".direct-" + token + ".partial", required: checkpointBytes > 0, minimumBytes: checkpointBytes)
            if item.isHLS, item.status != .completed {
                let candidates = [item.reservedVideoFileName, item.localFileName].compactMap { $0 }
                    .map(partialPath) + ["." + item.id + ".ts.partial"]
                let available = try candidates.filter { try existingFile(relativePath: $0, inside: root) != nil }
                if let source = available.first {
                    let target = item.reservedVideoFileName ?? item.localFileName ?? ("legacy-" + token + ".ts")
                    item.reservedVideoFileName = target
                    let output = partialPath(target)
                    try copy(source, to: output, required: true, minimumBytes: item.hlsResumeByteCount ?? 0)
                    for other in available.dropFirst() {
                        let sourceURL = try existingFile(relativePath: other, inside: root)
                        guard let sourceURL else { throw DownloadStorageError.unavailable }
                        let attributes = try fileAttributes(sourceURL)
                        let destination = try registry.acquire(location.appending(output))
                        defer { destination.close() }
                        try MacDownloadFinalization.copyVerifiedFile(from: sourceURL, to: destination.url, expectedBytes: attributes.st_size)
                    }
                } else if (item.hlsResumeByteCount ?? 0) > 0 {
                    throw DownloadStorageError.unavailable
                }
            }
            items[index] = DownloadManager.persistedDownloadItem(item)
        }
        try Task.checkCancellation()
        guard try existingData(at: sourceIndex, maximumBytes: DownloadMetadataPersistencePolicy.Bounds.fileBytes) == sourceData else {
            throw DownloadStorageError.verificationFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        guard data.count <= DownloadMetadataPersistencePolicy.Bounds.fileBytes,
              DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(data) else {
            throw DownloadStorageError.verificationFailed
        }
        try install(data, at: indexURL, maximumBytes: DownloadMetadataPersistencePolicy.Bounds.fileBytes)
        let receipt = Receipt(version: 1, sourceDigest: sourceDigest, indexDigest: digest(data))
        try install(encoder.encode(receipt), at: receiptURL, maximumBytes: 4_096)
    }

    private static func partialPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { return path }
        return (Array(components.dropLast()) + ["." + last + ".partial"]).joined(separator: "/")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func existingFile(relativePath: String, inside root: URL) throws -> URL? {
        guard DownloadStorageRegistry.validRelativePath("Video/" + relativePath) else { throw DownloadStorageError.invalidPath }
        var current = root.standardizedFileURL
        let components = relativePath.split(separator: "/").map(String.init)
        let rootStatus = try attributesIfPresent(current)
        guard let rootStatus else { return nil }
        guard rootStatus.st_mode & S_IFMT == S_IFDIR else { throw DownloadStorageError.invalidPath }
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            guard let attributes = try attributesIfPresent(current) else { return nil }
            let required = index == components.count - 1 ? S_IFREG : S_IFDIR
            guard attributes.st_mode & S_IFMT == required else { throw DownloadStorageError.invalidPath }
        }
        return current
    }

    private static func fileAttributes(_ url: URL) throws -> stat {
        guard let attributes = try attributesIfPresent(url), attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0 else { throw DownloadStorageError.invalidPath }
        return attributes
    }

    private static func attributesIfPresent(_ url: URL) throws -> stat? {
        var attributes = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &attributes)
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return attributes
    }

    private static func existingData(at url: URL, maximumBytes: Int) throws -> Data? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size >= 0,
              attributes.st_size <= maximumBytes else { throw DownloadStorageError.verificationFailed }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == attributes.st_size, data.count <= maximumBytes else { throw DownloadStorageError.verificationFailed }
        return data
    }

    private static func install(_ data: Data, at destination: URL, maximumBytes: Int) throws {
        if let current = try existingData(at: destination, maximumBytes: maximumBytes) {
            guard current == data else { throw DownloadStorageError.verificationFailed }
            try DownloadStorageRegistry.synchronizeFile(at: destination)
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".legacy-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try DownloadStorageRegistry.durableWrite(data, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try DownloadStorageRegistry.synchronizeFile(at: destination)
    }
}
#endif
