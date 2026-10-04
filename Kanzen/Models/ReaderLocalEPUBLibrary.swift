#if !os(tvOS)
import Combine
import CryptoKit
import Foundation

struct ReaderLocalEPUBItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let author: String?
    let chapterTitles: [String]
    let importedAt: Date

    var mangaID: Int {
        let hash = ("local-epub:" + id).utf8.reduce(into: 5381) { $0 = (($0 &<< 5) &+ $0) &+ Int($1) }
        return hash < 0 ? hash : -hash - 1
    }

    var isValid: Bool {
        id.utf8.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && !title.isEmpty && title.utf8.count <= 8_192 && (author?.utf8.count ?? 0) <= 8_192
            && !chapterTitles.isEmpty && chapterTitles.count <= ReaderExtensionEPUBBook.maximumChapters
            && chapterTitles.allSatisfy { !$0.isEmpty && $0.utf8.count <= 8_192 }
            && Set(chapterTitles).count == chapterTitles.count
            && importedAt.timeIntervalSince1970.isFinite
    }

    func chapters(profileID: UUID) -> [Chapter] {
        chapterTitles.enumerated().map { index, title in
            Chapter(chapterNumber: title, idx: index, chapterData: [ChapterData(params:
                ReaderLocalEPUBChapterPayload(bookID: id, chapterTitle: title, chapterIndex: index, profileID: profileID), title: title)])
        }
    }
}

struct ReaderLocalEPUBChapterPayload: Sendable {
    let bookID: String
    let chapterTitle: String
    let chapterIndex: Int
    let profileID: UUID
}

final class ReaderLocalEPUBLibrary: ObservableObject, ProfileScopedStore {
    static let shared = ReaderLocalEPUBLibrary()
    static let didRemoveBook = Notification.Name("ReaderLocalEPUBLibrary.didRemoveBook")
    @Published private(set) var books: [ReaderLocalEPUBItem] = []
    private var profileID: UUID
    private var generation = UUID()
    private let rootOverride: URL?
    private let fileManager = FileManager.default
    private static let maximumMetadataBytes = 4 * 1_024 * 1_024
    private static let maximumBooks = 200

    init(profileID: UUID = ProfileManager.shared.activeProfileID, root: URL? = nil) {
        self.profileID = profileID
        rootOverride = root
        refresh()
    }

    func switchProfile(to profileID: UUID) {
        self.profileID = profileID
        generation = UUID()
        books = []
        refresh()
    }

    func discardStore(forProfile profileID: UUID) {
        if profileID == self.profileID { generation = UUID(); books = [] }
        if let directory = try? directory(for: profileID) { try? fileManager.removeItem(at: directory) }
    }

    func refresh() {
        let owner = profileID
        let currentGeneration = generation
        guard let directory = try? directory(for: owner) else { return }
        Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .utility) { try? Self.items(in: directory) }.value
            guard let self, self.profileID == owner, self.generation == currentGeneration else { return }
            if let items { self.books = items }
        }
    }

    @MainActor
    func importBook(from url: URL) async throws -> ReaderLocalEPUBItem {
        guard !ProfileManager.shared.isKidsModeActive,
              profileID == ProfileManager.shared.activeProfileID else { throw Self.unavailable() }
        let owner = profileID
        let currentGeneration = generation
        let authority = MangaReadingProgressManager.shared.captureMutationAuthority()
        let mediaAuthority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner)
        let directory = try directory(for: owner)
        let prepared = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var readResult: Result<Data, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                readResult = Result { try Self.readArchive(at: coordinatedURL) }
            }
            if let coordinationError { throw coordinationError }
            guard let readResult else { throw Self.unavailable() }
            let data = try readResult.get()
            let book = try ReaderExtensionEPUBBook(data: data)
            let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let item = ReaderLocalEPUBItem(id: id, title: book.title, author: book.author, chapterTitles: book.chapters.map(\.title), importedAt: Date())
            guard item.isValid else { throw Self.unavailable() }
            let metadata = try JSONEncoder().encode(item)
            guard metadata.count <= Self.maximumMetadataBytes else { throw Self.unavailable() }
            let existingCount = try Self.items(in: directory).count
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.validateDirectory(directory.deletingLastPathComponent())
            try Self.validateDirectory(directory)
            let staging = directory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                try data.write(to: staging.appendingPathComponent("book.epub"), options: .atomic)
                try metadata.write(to: staging.appendingPathComponent("book.json"), options: .atomic)
                return (item, staging, existingCount)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }.value
        defer { try? fileManager.removeItem(at: prepared.1) }
        guard !Task.isCancelled, profileID == owner, generation == currentGeneration,
              ProfileManager.shared.isStillActive(owner), !ProfileManager.shared.isKidsModeActive,
              MangaReadingProgressManager.shared.isCurrent(authority),
              let mediaAuthority, ProgressManager.shared.profileMutationAuthorityIsCurrent(mediaAuthority) else {
            throw Self.unavailable()
        }
        let destination = directory.appendingPathComponent(prepared.0.id, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard let existing = Self.item(in: destination), existing.id == prepared.0.id else { throw Self.unavailable() }
            generation = UUID()
            books = (books.filter { $0.id != existing.id } + [existing]).sorted { $0.importedAt > $1.importedAt }
            return existing
        }
        guard prepared.2 < Self.maximumBooks else {
            throw ReaderExtensionError.resultInvalid("The local book library is full. Remove a book before importing another.")
        }
        try fileManager.moveItem(at: prepared.1, to: destination)
        var archiveURL = destination.appendingPathComponent("book.epub")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? archiveURL.setResourceValues(values)
        generation = UUID()
        books = (books.filter { $0.id != prepared.0.id } + [prepared.0]).sorted { $0.importedAt > $1.importedAt }
        return prepared.0
    }

    @MainActor
    func remove(_ item: ReaderLocalEPUBItem) throws {
        guard item.isValid, !ProfileManager.shared.isKidsModeActive,
              profileID == ProfileManager.shared.activeProfileID else { throw Self.unavailable() }
        try fileManager.removeItem(at: directory(for: profileID).appendingPathComponent(item.id, isDirectory: true))
        generation = UUID()
        books.removeAll { $0.id == item.id }
        NotificationCenter.default.post(name: Self.didRemoveBook, object: nil, userInfo: ["bookID": item.id, "profileID": profileID])
    }

    @MainActor
    func document(for payload: ReaderLocalEPUBChapterPayload) async throws -> ReaderNovelDocument {
        guard profileID == payload.profileID, ProfileManager.shared.isStillActive(payload.profileID),
              !ProfileManager.shared.isKidsModeActive,
              payload.bookID.count == 64, payload.bookID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Self.unavailable() }
        let currentGeneration = generation
        let authority = MangaReadingProgressManager.shared.captureMutationAuthority()
        let directory = try directory(for: payload.profileID).appendingPathComponent(payload.bookID, isDirectory: true)
        let document = try await Task.detached(priority: .userInitiated) {
            guard let item = Self.item(in: directory), item.id == payload.bookID,
                  item.chapterTitles.indices.contains(payload.chapterIndex),
                  item.chapterTitles[payload.chapterIndex] == payload.chapterTitle else { throw Self.unavailable() }
            let data = try Self.readArchive(at: directory.appendingPathComponent("book.epub"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == item.id else { throw Self.unavailable() }
            return try ReaderExtensionEPUBBook(data: data).novelDocument(named: payload.chapterTitle)
        }.value
        guard !Task.isCancelled, profileID == payload.profileID, generation == currentGeneration,
              ProfileManager.shared.isStillActive(payload.profileID), !ProfileManager.shared.isKidsModeActive,
              MangaReadingProgressManager.shared.isCurrent(authority), Self.item(in: directory) != nil else { throw Self.unavailable() }
        return document
    }

    private func directory(for profileID: UUID) throws -> URL {
        guard let base = rootOverride ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Self.unavailable() }
        try Self.validateDirectory(base)
        let root = base.appendingPathComponent("ReaderLocalBooks", isDirectory: true)
        let profile = root.appendingPathComponent(profileID.uuidString, isDirectory: true)
        try Self.validateDirectory(root)
        try Self.validateDirectory(profile)
        return profile
    }

    private static func readArchive(at url: URL) throws -> Data {
        try readFile(at: url, maximumBytes: ReaderExtensionEPUBBook.maximumArchiveBytes)
    }

    private static func readFile(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes,
              let stream = InputStream(url: url) else { throw unavailable() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? unavailable() }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw unavailable() }
            data.append(buffer, count: count)
        }
        guard !data.isEmpty else { throw unavailable() }
        return data
    }

    private static func item(in directory: URL) -> ReaderLocalEPUBItem? {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let metadata = directory.appendingPathComponent("book.json")
        guard let metadataValues = try? metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              metadataValues.isRegularFile == true, metadataValues.isSymbolicLink != true,
              let size = metadataValues.fileSize, size <= maximumMetadataBytes,
              let data = try? readFile(at: metadata, maximumBytes: maximumMetadataBytes), let item = try? JSONDecoder().decode(ReaderLocalEPUBItem.self, from: data),
              item.isValid, item.id == directory.lastPathComponent,
              let archive = try? directory.appendingPathComponent("book.epub").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              archive.isRegularFile == true, archive.isSymbolicLink != true,
              let archiveSize = archive.fileSize, archiveSize > 0, archiveSize <= ReaderExtensionEPUBBook.maximumArchiveBytes else { return nil }
        return item
    }

    private static func items(in directory: URL) throws -> [ReaderLocalEPUBItem] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try validateDirectory(directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard urls.count <= 4_096 else { throw unavailable() }
        let items = urls.filter { $0.lastPathComponent.count == 64 && $0.lastPathComponent.allSatisfy(\.isHexDigit) }
            .compactMap { item(in: $0) }
        guard items.count <= maximumBooks else { throw unavailable() }
        return items.sorted { $0.importedAt > $1.importedAt }
    }

    private static func validateDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw unavailable() }
    }

    private static func unavailable() -> ReaderExtensionError {
        .resultInvalid("This local EPUB is unavailable. Reopen Reader Library and import the book again if needed.")
    }
}
#endif
