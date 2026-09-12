#if os(macOS)
import Foundation
import CryptoKit

final class MacLocalPlaybackResumeStore: @unchecked Sendable {
    static let shared = MacLocalPlaybackResumeStore()

    private struct Entry: Codable {
        let identity: String
        let bookmark: Data?
        let position: Double
        let duration: Double
        let updatedAt: Date
    }

    private struct Store: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private enum DiskAuthority: Equatable {
        case missing
        case contents(Int, Data)
    }

    private struct PendingWrite {
        let revision: UInt64
        let data: Data
    }

    private let lock = NSLock()
    private let directory: URL
    private let writer: (Data, URL) throws -> Void
    private var loaded: [UUID: Store] = [:]
    private var unreadable = Set<UUID>()
    private var authorities: [UUID: DiskAuthority] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private var pending: [UUID: PendingWrite] = [:]
    private var unpreparedOwners = Set<UUID>()

    init(directory: URL? = nil, writer: @escaping (Data, URL) throws -> Void = DownloadStorageRegistry.durableWrite) {
        self.directory = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Eclipse/LocalPlayback", isDirectory: true)
        self.writer = writer
    }

    func currentTime(for url: URL, owner: UUID) -> Double {
        guard let identity = identity(for: url) else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let store = load(owner: owner), let entry = store.entries[identity],
              entry.position.isFinite, entry.position >= 0,
              entry.duration.isFinite, entry.duration > entry.position,
              entry.position < entry.duration * 0.95 else { return 0 }
        return entry.position
    }

    func update(url: URL, owner: UUID, position: Double, duration: Double) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0,
              position <= duration + 60, let identity = identity(for: url) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var store = load(owner: owner) else {
            unpreparedOwners.insert(owner)
            return
        }
        if position >= duration * 0.95 {
            store.entries.removeValue(forKey: identity)
        } else {
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            guard bookmark == nil || (bookmark?.count ?? 0) <= 64 * 1_024 else { return }
            store.entries[identity] = Entry(identity: identity, bookmark: bookmark,
                position: position, duration: duration, updatedAt: Date())
            if store.entries.count > 500 {
                for key in store.entries.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
                    .prefix(store.entries.count - 500).map(\.key) {
                    store.entries.removeValue(forKey: key)
                }
            }
        }
        do {
            let data = try JSONEncoder().encode(store)
            guard data.count <= 36 * 1_024 * 1_024 else { throw DownloadStorageError.unavailable }
            let revision = revisions[owner, default: 0] &+ 1
            revisions[owner] = revision
            pending[owner] = PendingWrite(revision: revision, data: data)
            loaded[owner] = store
            unpreparedOwners.remove(owner)
            _ = persistPending(owner: owner)
        } catch {
            unpreparedOwners.insert(owner)
        }
    }

    func flushForMacTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var saved = unpreparedOwners.isEmpty
        for owner in pending.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if !persistPending(owner: owner) { saved = false }
        }
        return saved && pending.isEmpty
    }

    private func persistPending(owner: UUID) -> Bool {
        guard let candidate = pending[owner], let expected = authorities[owner] else { return false }
        let url = fileURL(owner: owner)
        let candidateAuthority = Self.authority(for: candidate.data)
        do {
            guard Self.authority(for: try readData(at: url)) == expected else { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writer(candidate.data, url)
            guard Self.authority(for: try readData(at: url)) == candidateAuthority,
                  pending[owner]?.revision == candidate.revision else { return false }
            authorities[owner] = candidateAuthority
            pending.removeValue(forKey: owner)
            return true
        } catch {
            if let observed = try? readData(at: url), Self.authority(for: observed) == candidateAuthority {
                authorities[owner] = candidateAuthority
            }
            return false
        }
    }

    private static func authority(for data: Data?) -> DiskAuthority {
        guard let data else { return .missing }
        return .contents(data.count, Data(SHA256.hash(data: data)))
    }

    private func readData(at url: URL) throws -> Data? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 36 * 1_024 * 1_024 else {
            throw DownloadStorageError.unavailable
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 36 * 1_024 * 1_024 else { throw DownloadStorageError.unavailable }
        return data
    }

    private func load(owner: UUID) -> Store? {
        guard !unreadable.contains(owner) else { return nil }
        if let store = loaded[owner] { return store }
        do {
            guard let data = try readData(at: fileURL(owner: owner)) else {
                loaded[owner] = Store()
                authorities[owner] = .missing
                return loaded[owner]
            }
            let store = try JSONDecoder().decode(Store.self, from: data)
            guard store.version == 1, store.entries.count <= 500,
                  store.entries.allSatisfy({ key, value in
                      key == value.identity && key.count == 64 && key.allSatisfy(\.isHexDigit)
                          && value.position.isFinite && value.position >= 0
                          && value.duration.isFinite && value.duration > 0
                          && (value.bookmark?.count ?? 0) <= 64 * 1_024
                  }) else { throw DownloadStorageError.unavailable }
            if loaded.count >= 8 {
                for cached in loaded.keys where pending[cached] == nil && !unpreparedOwners.contains(cached) {
                    loaded.removeValue(forKey: cached)
                    authorities.removeValue(forKey: cached)
                    revisions.removeValue(forKey: cached)
                }
            }
            loaded[owner] = store
            authorities[owner] = Self.authority(for: data)
            return store
        } catch {
            unreadable.insert(owner)
            return nil
        }
    }

    private func fileURL(owner: UUID) -> URL {
        directory.appendingPathComponent(owner.uuidString.lowercased() + ".json")
    }

    private func identity(for url: URL) -> String? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileResourceIdentifierKey, .volumeUUIDStringKey]),
              values.isRegularFile == true else { return nil }
        let data: Data
        if let volume = values.volumeUUIDString,
           let resource = values.fileResourceIdentifier as? NSObject,
           let encoded = try? NSKeyedArchiver.archivedData(withRootObject: resource, requiringSecureCoding: false) {
            var value = Data(volume.utf8)
            value.append(0)
            value.append(encoded)
            data = value
        } else {
            data = Data(url.standardizedFileURL.path.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
