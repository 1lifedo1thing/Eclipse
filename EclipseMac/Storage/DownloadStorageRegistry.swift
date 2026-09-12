#if os(macOS)
import Foundation
import Combine
import CryptoKit
import Darwin

enum DownloadStorageDomain: String, Codable, CaseIterable, Sendable {
    case video
    case reader

    var directoryName: String { self == .video ? "Video" : "Reader" }
}

enum DownloadStorageAccess: Sendable {
    case read
    case write
}

struct DownloadStorageLocation: Codable, Hashable, Sendable {
    let rootID: UUID
    let relativePath: String

    func appending(_ component: String) -> DownloadStorageLocation {
        DownloadStorageLocation(rootID: rootID, relativePath: relativePath + "/" + component)
    }
}

struct DownloadStorageRoot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let ownedDirectoryName: String
    var bookmarkData: Data?

    var isInternal: Bool { id == DownloadStorageRegistry.internalRootID }
}

enum DownloadStorageError: LocalizedError {
    case unreadableRegistry
    case unknownRoot
    case invalidPath
    case unavailable
    case ownershipMismatch
    case busy
    case verificationFailed
    case invalidMove

    var errorDescription: String? {
        switch self {
        case .unreadableRegistry: return "The saved download locations could not be read. Existing downloads have been kept."
        case .unknownRoot: return "This download's storage location is no longer registered."
        case .invalidPath: return "The download has an invalid storage path."
        case .unavailable: return "The download folder is unavailable. Reconnect the disk or choose the folder again."
        case .ownershipMismatch: return "The selected folder could not be verified as this app's download folder."
        case .busy: return "Pause downloads and close items using this storage location before moving it."
        case .verificationFailed: return "The copied download could not be verified. The original has been kept."
        case .invalidMove: return "The download move could not be completed. Both locations have been kept."
        }
    }
}

final class DownloadStorageLease: @unchecked Sendable {
    let url: URL
    let location: DownloadStorageLocation
    private let lock = NSLock()
    private var release: (() -> Void)?

    fileprivate init(url: URL, location: DownloadStorageLocation, release: @escaping () -> Void) {
        self.url = url
        self.location = location
        self.release = release
    }

    func close() {
        lock.lock()
        let action = release
        release = nil
        lock.unlock()
        action?()
    }

    deinit { close() }
}

struct DownloadStorageMove: Codable, Identifiable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let source: DownloadStorageLocation
        let destination: DownloadStorageLocation
    }

    enum Phase: String, Codable, Sendable {
        case copying
        case verified
        case committing
        case committed
    }

    let id: UUID
    let entries: [Entry]
    var phase: Phase

    var replacements: [DownloadStorageLocation: DownloadStorageLocation] {
        Dictionary(entries.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
    }
}

final class DownloadStorageRegistry: ObservableObject, @unchecked Sendable {
    static let shared = DownloadStorageRegistry()
    static let internalRootID = UUID(uuid: (0xEC, 0x11, 0x5E, 0xD0, 0, 0, 0x40, 0, 0xA0, 0, 0, 0, 0, 0, 0, 1))
    static let didChangeNotification = Notification.Name("EclipseDownloadStorageDidChange")
    let objectWillChange = ObservableObjectPublisher()

    private struct State: Codable {
        var version = 1
        var defaultRootID: UUID
        var roots: [DownloadStorageRoot]
    }

    private struct Marker: Codable, Equatable {
        let version: Int
        let id: UUID
    }

    private let lock = NSRecursiveLock()
    private let fileManager: FileManager
    private let directory: URL
    private var state: State
    private var registryIsUnreadable = false
    private var leases: [UUID: Int] = [:]
    private var movingRoots = Set<UUID>()
    private var moveReservations: [UUID: Set<UUID>] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

    var roots: [DownloadStorageRoot] {
        lock.lock()
        defer { lock.unlock() }
        return state.roots
    }

    var defaultRootID: UUID {
        lock.lock()
        defer { lock.unlock() }
        return state.defaultRootID
    }

    var isReadable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !registryIsUnreadable
    }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = (directory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("Eclipse/DownloadStorage", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        let internalRoot = DownloadStorageRoot(
            id: Self.internalRootID,
            displayName: "On This Mac",
            ownedDirectoryName: "Content",
            bookmarkData: nil
        )
        state = State(defaultRootID: internalRoot.id, roots: [internalRoot])
        do {
            try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let stateURL = self.directory.appendingPathComponent("roots.json")
            if fileManager.fileExists(atPath: stateURL.path) {
                let data = try boundedData(at: stateURL, maximumBytes: 4 * 1_024 * 1_024)
                let saved = try JSONDecoder().decode(State.self, from: data)
                guard saved.version == 1, saved.roots.count <= 128,
                      Set(saved.roots.map(\.id)).count == saved.roots.count,
                      saved.roots.contains(where: { $0.id == saved.defaultRootID }),
                      saved.roots.filter({ $0.id == Self.internalRootID }) == [internalRoot],
                      saved.roots.allSatisfy({ Self.validRoot($0) }) else {
                    throw DownloadStorageError.unreadableRegistry
                }
                state = saved
            } else {
                try persist(state)
            }
            let internalURL = self.directory.appendingPathComponent(internalRoot.ownedDirectoryName, isDirectory: true)
            if !fileManager.fileExists(atPath: internalURL.path) {
                try fileManager.createDirectory(at: internalURL, withIntermediateDirectories: true)
                try writeMarker(id: internalRoot.id, to: internalURL)
            }
            try validateMarker(id: internalRoot.id, at: internalURL)
        } catch {
            registryIsUnreadable = true
        }
    }

    func completionStagingURL(id: UUID) throws -> URL {
        let staging = directory.appendingPathComponent("PendingVideo", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging.appendingPathComponent(id.uuidString.lowercased())
    }

    func internalContentURL(for domain: DownloadStorageDomain) -> URL {
        directory.appendingPathComponent("Content", isDirectory: true).appendingPathComponent(domain.directoryName, isDirectory: true)
    }

    func indexURL(for domain: DownloadStorageDomain) -> URL {
        directory.appendingPathComponent(domain.rawValue + "-index.json")
    }

    func legacyDefaultLocation(in domain: DownloadStorageDomain, relativePath: String) -> DownloadStorageLocation {
        DownloadStorageLocation(rootID: Self.internalRootID, relativePath: domain.directoryName + "/" + relativePath)
    }

    func locationForNewItem(in domain: DownloadStorageDomain, relativePath: String) throws -> DownloadStorageLocation {
        lock.lock()
        defer { lock.unlock() }
        guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
        let location = DownloadStorageLocation(rootID: state.defaultRootID, relativePath: domain.directoryName + "/" + relativePath)
        guard Self.validRelativePath(location.relativePath) else { throw DownloadStorageError.invalidPath }
        let lease = try acquire(location, access: .write)
        lease.close()
        return location
    }

    func acquire(_ location: DownloadStorageLocation, access: DownloadStorageAccess = .read) throws -> DownloadStorageLease {
        lock.lock()
        defer { lock.unlock() }
        guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
        guard !movingRoots.contains(location.rootID) else { throw DownloadStorageError.busy }
        return try acquireLocked(location, access: access)
    }

    private func acquireLocked(_ location: DownloadStorageLocation, access: DownloadStorageAccess) throws -> DownloadStorageLease {
        guard Self.validRelativePath(location.relativePath) else { throw DownloadStorageError.invalidPath }
        guard let index = state.roots.firstIndex(where: { $0.id == location.rootID }) else {
            throw DownloadStorageError.unknownRoot
        }
        var root = state.roots[index]
        var scopedURL: URL?
        let rootURL: URL
        if root.isInternal {
            rootURL = directory.appendingPathComponent(root.ownedDirectoryName, isDirectory: true)
        } else {
            guard let bookmark = root.bookmarkData else { throw DownloadStorageError.unavailable }
            var stale = false
            let selectedURL: URL
            do {
                selectedURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw DownloadStorageError.unavailable
            }
            guard selectedURL.startAccessingSecurityScopedResource() else { throw DownloadStorageError.unavailable }
            scopedURL = selectedURL
            rootURL = selectedURL.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(root.ownedDirectoryName, isDirectory: true)
            if stale {
                do {
                    root.bookmarkData = try selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    var replacement = state
                    replacement.roots[index] = root
                    try persist(replacement)
                    state = replacement
                } catch {
                    selectedURL.stopAccessingSecurityScopedResource()
                    throw DownloadStorageError.unavailable
                }
            }
        }
        do {
            try validateMarker(id: root.id, at: rootURL)
            let result = rootURL.appendingPathComponent(location.relativePath).standardizedFileURL
            try validatePath(result, inside: rootURL)
            if access == .write {
                let parent = result.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try validatePath(result, inside: rootURL)
            }
            leases[root.id, default: 0] += 1
            return DownloadStorageLease(url: result, location: location) { [weak self] in
                scopedURL?.stopAccessingSecurityScopedResource()
                guard let self else { return }
                self.lock.lock()
                let count = self.leases[root.id, default: 0]
                if count <= 1 { self.leases.removeValue(forKey: root.id) }
                else { self.leases[root.id] = count - 1 }
                self.lock.unlock()
            }
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    @discardableResult
    func selectDefaultFolder(_ selectedURL: URL) throws -> DownloadStorageRoot {
        lock.lock()
        defer { lock.unlock() }
        guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
        guard selectedURL.isFileURL, state.roots.count < 128 else { throw DownloadStorageError.invalidPath }
        let accessed = selectedURL.startAccessingSecurityScopedResource()
        defer { if accessed { selectedURL.stopAccessingSecurityScopedResource() } }
        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DownloadStorageError.invalidPath }
        let id = UUID()
        let name = "Eclipse Downloads " + id.uuidString.lowercased()
        let ownedURL = selectedURL.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: ownedURL.path) else { throw DownloadStorageError.ownershipMismatch }
        let bookmark = try selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = DownloadStorageRoot(id: id, displayName: String(selectedURL.lastPathComponent.prefix(256)),
            ownedDirectoryName: name, bookmarkData: bookmark)
        try fileManager.createDirectory(at: ownedURL, withIntermediateDirectories: false)
        try writeMarker(id: id, to: ownedURL)
        var replacement = state
        replacement.roots.append(root)
        replacement.defaultRootID = id
        try persist(replacement)
        state = replacement
        announceChange()
        return root
    }

    func reconnect(_ rootID: UUID, selectedFolder: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
        guard let index = state.roots.firstIndex(where: { $0.id == rootID }), !state.roots[index].isInternal else {
            throw DownloadStorageError.unknownRoot
        }
        let accessed = selectedFolder.startAccessingSecurityScopedResource()
        defer { if accessed { selectedFolder.stopAccessingSecurityScopedResource() } }
        let root = state.roots[index]
        try validateMarker(id: rootID, at: selectedFolder.appendingPathComponent(root.ownedDirectoryName, isDirectory: true))
        var replacement = state
        replacement.roots[index].bookmarkData = try selectedFolder.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        try persist(replacement)
        state = replacement
        announceChange()
    }

    func setDefaultRoot(_ rootID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
        let lease = try acquire(DownloadStorageLocation(rootID: rootID, relativePath: "Video"), access: .write)
        defer { lease.close() }
        var replacement = state
        replacement.defaultRootID = rootID
        try persist(replacement)
        state = replacement
        announceChange()
    }

    func useDefaultFolder() throws {
        try setDefaultRoot(Self.internalRootID)
    }

    func prepareMove(_ locations: [DownloadStorageLocation], toRootID: UUID) async throws -> DownloadStorageMove {
        let preparation = Task.detached(priority: .utility) { [self] in
            try prepareMoveSynchronously(locations, toRootID: toRootID)
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    private func prepareMoveSynchronously(_ locations: [DownloadStorageLocation], toRootID: UUID) throws -> DownloadStorageMove {
        try Task.checkCancellation()
        var move = try withLock {
            guard !registryIsUnreadable else { throw DownloadStorageError.unreadableRegistry }
            let sources = Array(Set(locations)).filter { $0.rootID != toRootID }
            guard !sources.isEmpty, sources.count <= 100_000,
                  state.roots.contains(where: { $0.id == toRootID }) else { throw DownloadStorageError.invalidMove }
            let involved = Set(sources.map(\.rootID)).union([toRootID])
            guard involved.allSatisfy({ leases[$0, default: 0] == 0 && !movingRoots.contains($0) }) else {
                throw DownloadStorageError.busy
            }
            let id = UUID()
            let prepared = DownloadStorageMove(id: id, entries: sources.map { source in
                DownloadStorageMove.Entry(source: source, destination: Self.moveDestination(source, id: id, rootID: toRootID))
            }, phase: .copying)
            guard Self.validMove(prepared) else { throw DownloadStorageError.invalidMove }
            try persistMove(prepared)
            movingRoots.formUnion(involved)
            moveReservations[id] = involved
            return prepared
        }
        do {
            for entry in move.entries {
                try Task.checkCancellation()
                let source = try withLock { try acquireLocked(entry.source, access: .read) }
                defer { source.close() }
                let destination = try withLock { try acquireLocked(entry.destination, access: .write) }
                defer { destination.close() }
                let sourceManifest = try contentManifest(at: source.url)
                guard !fileManager.fileExists(atPath: destination.url.path) else { throw DownloadStorageError.invalidMove }
                try fileManager.copyItem(at: source.url, to: destination.url)
                try Task.checkCancellation()
                guard try contentManifest(at: destination.url) == sourceManifest,
                      try contentManifest(at: source.url) == sourceManifest else { throw DownloadStorageError.verificationFailed }
                try synchronizeTree(at: destination.url)
            }
            try Task.checkCancellation()
            move.phase = .verified
            try persistMove(move)
            return move
        } catch {
            releaseMove(move)
            throw error
        }
    }

    func commitMove(_ move: DownloadStorageMove, persistLocations: ([DownloadStorageLocation: DownloadStorageLocation]) throws -> Void) throws {
        var saved = try withLock {
            let saved = try loadMove(id: move.id)
            guard saved.phase == .verified, saved.entries == move.entries, Self.validMove(saved) else {
                throw DownloadStorageError.invalidMove
            }
            let involved = Self.involvedRoots(saved)
            if moveReservations[saved.id] == nil {
                guard involved.allSatisfy({ leases[$0, default: 0] == 0 && !movingRoots.contains($0) }) else {
                    throw DownloadStorageError.busy
                }
                moveReservations[saved.id] = involved
                movingRoots.formUnion(involved)
            }
            return saved
        }
        var cleanupOwnsReservation = false
        defer { if !cleanupOwnsReservation { releaseMove(saved) } }
        saved.phase = .committing
        try persistMove(saved)
        try persistLocations(saved.replacements)
        saved.phase = .committed
        do {
            try persistMove(saved)
            let committed = saved
            cleanupOwnsReservation = true
            let cleanup = Task.detached(priority: .utility) { [self] in
                defer { releaseMove(committed) }
                do { try finishCommittedMove(committed) }
                catch { announceChange() }
            }
            withLock { cleanupTasks[committed.id] = cleanup }
        } catch {
            announceChange()
        }
    }

    func waitForMoveCleanup(_ id: UUID) async {
        let task = withLock { cleanupTasks[id] }
        await task?.value
        _ = withLock { cleanupTasks.removeValue(forKey: id) }
    }

    func cancelMove(_ move: DownloadStorageMove) {
        releaseMove(move)
    }

    func recoverMoves(referencedLocations: Set<DownloadStorageLocation>,
        currentReferencedLocations: (() -> Set<DownloadStorageLocation>?)? = nil) throws {
        guard isReadable else { throw DownloadStorageError.unreadableRegistry }
        let journalDirectory = directory.appendingPathComponent("Moves", isDirectory: true)
        guard fileManager.fileExists(atPath: journalDirectory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            let data = try boundedData(at: url, maximumBytes: 32 * 1_024 * 1_024)
            var move = try JSONDecoder().decode(DownloadStorageMove.self, from: data)
            guard Self.validMove(move), url.lastPathComponent == moveURL(id: move.id).lastPathComponent else {
                throw DownloadStorageError.invalidMove
            }
            let allCommitted = move.entries.allSatisfy { referencedLocations.contains($0.destination)
                && !referencedLocations.contains($0.source) }
            if allCommitted {
                try withLock {
                    let involved = Self.involvedRoots(move)
                    guard involved.allSatisfy({ leases[$0, default: 0] == 0 && !movingRoots.contains($0) }) else {
                        throw DownloadStorageError.busy
                    }
                    movingRoots.formUnion(involved)
                    moveReservations[move.id] = involved
                }
                defer { releaseMove(move) }
                let current: Set<DownloadStorageLocation>
                if let currentReferencedLocations {
                    guard let captured = currentReferencedLocations() else { throw DownloadStorageError.unreadableRegistry }
                    current = captured
                } else { current = referencedLocations }
                guard move.entries.allSatisfy({ current.contains($0.destination) && !current.contains($0.source) }) else { continue }
                move.phase = .committed
                try persistMove(move)
                try finishCommittedMove(move)
            }
        }
    }

    private static func moveDestination(_ source: DownloadStorageLocation, id: UUID, rootID: UUID) -> DownloadStorageLocation {
        let domain = source.relativePath.split(separator: "/").first.map(String.init) ?? ""
        let identity = Data((source.rootID.uuidString.lowercased() + "\u{0000}" + source.relativePath).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return DownloadStorageLocation(rootID: rootID, relativePath: domain + "/Moved/" + id.uuidString.lowercased() + "/" + digest)
    }

    private static func validMove(_ move: DownloadStorageMove) -> Bool {
        guard !move.entries.isEmpty, move.entries.count <= 100_000,
              Set(move.entries.map(\.source)).count == move.entries.count,
              Set(move.entries.map(\.destination)).count == move.entries.count else { return false }
        let sources = Set(move.entries.map(\.source))
        return move.entries.allSatisfy { entry in
            guard entry.source.rootID != entry.destination.rootID,
                  validRelativePath(entry.source.relativePath), validRelativePath(entry.destination.relativePath) else { return false }
            let domain = entry.source.relativePath.split(separator: "/").first.map(String.init) ?? ""
            let legacyPath = domain + "/Moved/" + move.id.uuidString.lowercased() + "/"
                + entry.source.rootID.uuidString.lowercased() + "/" + entry.source.relativePath
            guard entry.destination == moveDestination(entry.source, id: move.id, rootID: entry.destination.rootID)
                || entry.destination.relativePath == legacyPath else { return false }
            var ancestor = ""
            for component in entry.source.relativePath.split(separator: "/").dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + String(component)
                if sources.contains(DownloadStorageLocation(rootID: entry.source.rootID, relativePath: ancestor)) { return false }
            }
            return true
        }
    }

    private static func involvedRoots(_ move: DownloadStorageMove) -> Set<UUID> {
        Set(move.entries.flatMap { [$0.source.rootID, $0.destination.rootID] })
    }

    private func releaseMove(_ move: DownloadStorageMove) {
        withLock {
            if let involved = moveReservations.removeValue(forKey: move.id) { movingRoots.subtract(involved) }
        }
        announceChange()
    }

    private func withLock<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }

    private func finishCommittedMove(_ move: DownloadStorageMove) throws {
        for entry in move.entries {
            let source = try withLock { try acquireLocked(entry.source, access: .read) }
            defer { source.close() }
            let destination = try withLock { try acquireLocked(entry.destination, access: .read) }
            defer { destination.close() }
            if fileManager.fileExists(atPath: source.url.path) {
                guard try contentManifest(at: source.url) == contentManifest(at: destination.url) else {
                    throw DownloadStorageError.verificationFailed
                }
                try fileManager.removeItem(at: source.url)
                try synchronizeDirectory(source.url.deletingLastPathComponent())
            }
        }
        try fileManager.removeItem(at: moveURL(id: move.id))
        try synchronizeDirectory(moveURL(id: move.id).deletingLastPathComponent())
    }

    private func contentManifest(at root: URL) throws -> [String: String] {
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw DownloadStorageError.invalidPath }
        if values.isRegularFile == true { return ["": try digest(at: root)] }
        var enumerationError: Error?
        guard values.isDirectory == true, let enumerator = fileManager.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw DownloadStorageError.unavailable }
        var manifest: [String: String] = ["": "directory"]
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard manifest.count < 1_000_000 else { throw DownloadStorageError.verificationFailed }
            let entry = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard entry.isSymbolicLink != true else { throw DownloadStorageError.invalidPath }
            let entryPath = url.standardizedFileURL.path
            guard entryPath.hasPrefix(rootPath) else { throw DownloadStorageError.invalidPath }
            let path = String(entryPath.dropFirst(rootPath.count))
            if entry.isDirectory == true { manifest[path] = "directory" }
            else if entry.isRegularFile == true { manifest[path] = try digest(at: url) }
            else { throw DownloadStorageError.invalidPath }
        }
        if let enumerationError { throw enumerationError }
        return manifest
    }

    private func digest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func synchronizeTree(at root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            for child in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try synchronizeTree(at: child)
            }
            try synchronizeDirectory(root)
        } else {
            let handle = try FileHandle(forWritingTo: root)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    private static func validRoot(_ root: DownloadStorageRoot) -> Bool {
        !root.displayName.isEmpty && root.displayName.utf8.count <= 1_024
            && !root.ownedDirectoryName.isEmpty && root.ownedDirectoryName.utf8.count <= 256
            && !root.ownedDirectoryName.contains("/") && root.ownedDirectoryName != "." && root.ownedDirectoryName != ".."
            && (root.isInternal ? root.bookmarkData == nil : (root.bookmarkData?.count ?? 0) > 0
                && root.ownedDirectoryName == "Eclipse Downloads " + root.id.uuidString.lowercased())
            && (root.bookmarkData?.count ?? 0) <= 64 * 1_024
    }

    static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count <= 64 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && ["Video", "Reader"].contains(components.first.map(String.init) ?? "")
    }

    private func validatePath(_ url: URL, inside root: URL) throws {
        let expected = root.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(expected), root.resolvingSymlinksInPath().path == root.standardizedFileURL.path,
              url.resolvingSymlinksInPath().path.hasPrefix(expected) else { throw DownloadStorageError.invalidPath }
        var cursor = url
        while cursor.path != root.path {
            if fileManager.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw DownloadStorageError.invalidPath }
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { throw DownloadStorageError.invalidPath }
            cursor = parent
        }
    }

    private func writeMarker(id: UUID, to url: URL) throws {
        try durableWrite(try JSONEncoder().encode(Marker(version: 1, id: id)),
            to: url.appendingPathComponent(".eclipse-download-root.json"))
    }

    private func validateMarker(id: UUID, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DownloadStorageError.unavailable }
        let data = try boundedData(at: url.appendingPathComponent(".eclipse-download-root.json"), maximumBytes: 1_024)
        guard try JSONDecoder().decode(Marker.self, from: data) == Marker(version: 1, id: id) else {
            throw DownloadStorageError.ownershipMismatch
        }
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { throw DownloadStorageError.unavailable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw DownloadStorageError.unavailable
        }
        return data
    }

    private func persist(_ state: State) throws {
        try durableWrite(try JSONEncoder().encode(state), to: directory.appendingPathComponent("roots.json"))
    }

    private func moveURL(id: UUID) -> URL {
        directory.appendingPathComponent("Moves", isDirectory: true).appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func persistMove(_ move: DownloadStorageMove) throws {
        let url = moveURL(id: move.id)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try durableWrite(try JSONEncoder().encode(move), to: url)
    }

    private func loadMove(id: UUID) throws -> DownloadStorageMove {
        try JSONDecoder().decode(DownloadStorageMove.self, from: boundedData(at: moveURL(id: id), maximumBytes: 32 * 1_024 * 1_024))
    }

    static func durableWrite(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try synchronizeFile(at: destination)
        guard try Data(contentsOf: destination) == data else { throw DownloadStorageError.verificationFailed }
    }

    static func synchronizeFile(at destination: URL) throws {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func durableWrite(_ data: Data, to destination: URL) throws {
        try Self.durableWrite(data, to: destination)
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func announceChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
#endif

#if os(macOS)
import Foundation

extension DownloadStorageRegistry {
    func storedBytes(in domain: DownloadStorageDomain, rootIDs: Set<UUID>) -> Int64? {
        guard isReadable else { return nil }
        var total: Int64 = 0
        for rootID in rootIDs {
            if Task.isCancelled { return nil }
            do {
                let lease = try acquire(DownloadStorageLocation(rootID: rootID, relativePath: domain.directoryName))
                defer { lease.close() }
                let values: URLResourceValues
                do {
                    values = try URL(fileURLWithPath: lease.url.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    continue
                }
                guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                var failed = false
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                guard let enumerator = FileManager.default.enumerator(at: lease.url,
                    includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in failed = true; return false }) else { return nil }
                var count = 0
                for case let url as URL in enumerator {
                    if Task.isCancelled { return nil }
                    count += 1
                    guard count <= 1_000_000 else { return nil }
                    let attributes = try url.resourceValues(forKeys: keys)
                    guard attributes.isSymbolicLink != true else { return nil }
                    if attributes.isRegularFile == true {
                        guard let bytes = attributes.fileSize, bytes >= 0 else { return nil }
                        let addition = total.addingReportingOverflow(Int64(bytes))
                        guard !addition.overflow else { return nil }
                        total = addition.partialValue
                    }
                }
                guard !failed else { return nil }
            } catch { return nil }
        }
        return total
    }
}
#endif
