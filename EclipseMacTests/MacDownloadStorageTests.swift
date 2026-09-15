#if os(macOS)
import Foundation
import XCTest
@testable import EclipseMac

final class MacDownloadStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseStorageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testMoveShutdownKeepsAdmissionStoppedUntilQuitIsCancelled() async {
        var terminating = false
        let coordinator = MacDownloadMoveCoordinator(isAppTerminating: { terminating })
        var release: CheckedContinuation<Void, Never>?
        var finished = false
        XCTAssertTrue(coordinator.beginMove {
            await withCheckedContinuation { release = $0 }
            finished = true
        })
        while release == nil { await Task.yield() }
        terminating = true
        let initiallyStopped = await coordinator.prepareForMacTermination(timeout: .milliseconds(50))
        XCTAssertFalse(initiallyStopped)
        XCTAssertTrue(coordinator.isMoving)
        coordinator.resumeAfterCancelledMacTermination()
        XCTAssertFalse(coordinator.beginMove {})
        release?.resume()
        release = nil
        while coordinator.isMoving { await Task.yield() }
        XCTAssertTrue(finished)
        XCTAssertFalse(coordinator.beginMove {})
        terminating = false
        XCTAssertFalse(coordinator.beginMove {})
        coordinator.resumeAfterCancelledMacTermination()
        XCTAssertTrue(coordinator.beginMove {})
        let finallyStopped = await coordinator.prepareForMacTermination()
        XCTAssertTrue(finallyStopped)
    }

    @MainActor
    func testMoveShutdownCancelsCooperativePreparationAndAwaitsCleanup() async {
        let coordinator = MacDownloadMoveCoordinator(isAppTerminating: { false })
        var cancellationObserved = false
        var cleanupFinished = false
        XCTAssertTrue(coordinator.beginMove {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancellationObserved = true }
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(30))
            }.value
            cleanupFinished = true
        })
        await Task.yield()
        let stopped = await coordinator.prepareForMacTermination()
        XCTAssertTrue(stopped)
        XCTAssertTrue(cancellationObserved)
        XCTAssertTrue(cleanupFinished)
        XCTAssertFalse(coordinator.isMoving)
        XCTAssertFalse(coordinator.beginMove {})
    }

    func testCompatibilityDirectoryNeverExaminesUnsignedDocuments() throws {
        let directory = try directory()
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let original = Data("existing authoritative store".utf8)
        let store = documents.appendingPathComponent("ProgressData.json")
        try original.write(to: store)
        var homeWasRequested = false
        var documentsWereRequested = false
        let selected = EclipseMacDataDirectories.compatibleDocumentsDirectory(sandboxIsAuthenticated: false,
            home: { homeWasRequested = true; return directory },
            documents: { documentsWereRequested = true; return documents })
        XCTAssertNil(selected)
        XCTAssertFalse(homeWasRequested)
        XCTAssertFalse(documentsWereRequested)
        XCTAssertEqual(try Data(contentsOf: store), original)
    }

    func testCompatibilityDirectoryKeepsOwnedStoresAndRejectsEscapingLinks() throws {
        let directory = try directory()
        let home = directory.appendingPathComponent("Sandbox", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let unrelated = directory.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let original = Data("retained store and recovery authority".utf8)
        let store = documents.appendingPathComponent("UserRatings.json")
        let marker = documents.appendingPathComponent("UserRatings.unreadable.marker")
        try original.write(to: store)
        try original.write(to: marker)
        let selected = EclipseMacDataDirectories.compatibleDocumentsDirectory(sandboxIsAuthenticated: true,
            home: { home }, documents: { documents })
        XCTAssertEqual(selected, documents.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: store), original)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        let link = home.appendingPathComponent("Redirected", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        XCTAssertNil(EclipseMacDataDirectories.compatibleDocumentsDirectory(sandboxIsAuthenticated: true,
            home: { home }, documents: { link }))
        XCTAssertNil(EclipseMacDataDirectories.compatibleDocumentsDirectory(sandboxIsAuthenticated: true,
            home: { home }, documents: { unrelated }))
    }

    private func legacyVideo(id: String = "legacy-movie", status: DownloadStatus = .completed) -> DownloadItem {
        DownloadItem(id: id, tmdbId: 42, isMovie: true, title: "Fixture", displayTitle: "Fixture",
            posterURL: nil, episodeName: nil, streamURL: "https://example.invalid/movie.mp4", headers: [:],
            serviceBaseURL: "https://example.invalid", status: status, progress: status == .completed ? 1 : 0,
            totalBytes: 10, downloadedBytes: status == .completed ? 10 : 0,
            localFileName: status == .completed ? "Fixture/video.mp4" : nil, subtitleFileName: nil,
            error: nil, dateAdded: Date(timeIntervalSince1970: 1), dateCompleted: nil, isAnime: false)
    }

    func testLegacyVideoAdoptionPreservesOriginalsAndDoesNotResurrectDeletedRows() throws {
        let directory = try directory()
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        let source = downloads.appendingPathComponent("Fixture/video.mp4")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x41, count: 10)
        try bytes.write(to: source)
        try Data("unrelated".utf8).write(to: downloads.appendingPathComponent("unrelated.txt"))
        let index = downloads.appendingPathComponent(".downloads_metadata.json")
        let original = try JSONEncoder().encode([legacyVideo()])
        try original.write(to: index)
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        try MacLegacyVideoAdoption.adopt(documents: documents, registry: registry)
        let destinationIndex = registry.indexURL(for: .video)
        let rows = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: destinationIndex))
        let row = try XCTUnwrap(rows.first)
        let location = try XCTUnwrap(row.storageLocation)
        XCTAssertEqual(location.rootID, DownloadStorageRegistry.internalRootID)
        let lease = try registry.acquire(location.appending("Fixture/video.mp4"))
        defer { lease.close() }
        XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: index), original)
        let root = try registry.acquire(location)
        defer { root.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("unrelated.txt").path))
        try Data("[]".utf8).write(to: destinationIndex)
        try MacLegacyVideoAdoption.adopt(documents: documents, registry: registry)
        XCTAssertEqual(try Data(contentsOf: destinationIndex), Data("[]".utf8))
    }

    func testLegacyVideoAdoptionRejectsConflictingIndexesAndEscapingFiles() throws {
        let directory = try directory()
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        let source = downloads.appendingPathComponent("Fixture/video.mp4")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(repeating: 0x41, count: 10)
        try original.write(to: source)
        try JSONEncoder().encode([legacyVideo()]).write(to: downloads.appendingPathComponent(".downloads_metadata.json"))
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        let existing = Data("[]".utf8)
        try existing.write(to: registry.indexURL(for: .video))
        XCTAssertThrowsError(try MacLegacyVideoAdoption.adopt(documents: documents, registry: registry))
        XCTAssertEqual(try Data(contentsOf: registry.indexURL(for: .video)), existing)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let otherRegistry = DownloadStorageRegistry(directory: directory.appendingPathComponent("OtherRegistry"))
        let external = directory.appendingPathComponent("external.mp4")
        try original.write(to: external)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
        XCTAssertThrowsError(try MacLegacyVideoAdoption.adopt(documents: documents, registry: otherRegistry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherRegistry.indexURL(for: .video).path))
        XCTAssertEqual(try Data(contentsOf: external), original)
    }

    func testLegacyVideoAdoptionKeepsIncompleteIndexAndDirectCheckpointAuthority() throws {
        let directory = try directory()
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let index = downloads.appendingPathComponent(".downloads_metadata.json")
        let invalid = Data("[{}]".utf8)
        try invalid.write(to: index)
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        XCTAssertThrowsError(try MacLegacyVideoAdoption.adopt(documents: documents, registry: registry))
        XCTAssertEqual(try Data(contentsOf: index), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.indexURL(for: .video).path))
        var row = legacyVideo(status: .paused)
        row.directResumeCheckpoint = DirectDownloadCheckpoint(byteCount: 3, totalBytes: 10,
            representationSHA256: String(repeating: "a", count: 64))
        let partialName = ".direct-" + DirectDownloadResumePolicy.digest(row.id) + ".partial"
        try Data([1, 2, 3]).write(to: downloads.appendingPathComponent(partialName))
        try JSONEncoder().encode([row]).write(to: index)
        try MacLegacyVideoAdoption.adopt(documents: documents, registry: registry)
        let rows = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: registry.indexURL(for: .video)))
        let migrated = try XCTUnwrap(rows.first)
        XCTAssertEqual(migrated.directResumeCheckpoint, row.directResumeCheckpoint)
        let location = try XCTUnwrap(migrated.storageLocation)
        let lease = try registry.acquire(location.appending(partialName))
        defer { lease.close() }
        XCTAssertEqual(try Data(contentsOf: lease.url), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent(partialName)), Data([1, 2, 3]))
    }

    func testCacheClearOnlyRemovesOwnedContentsAndRejectsRedirectedRoots() throws {
        let directory = try directory()
        let owned = directory.appendingPathComponent("Eclipse", isDirectory: true)
        let unrelated = directory.appendingPathComponent("OtherApp", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let bytes = Data("unrelated cache".utf8)
        let preserved = unrelated.appendingPathComponent("data")
        try bytes.write(to: preserved)
        try Data("owned cache".utf8).write(to: owned.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("link"), withDestinationURL: unrelated)
        try EclipseCacheStorage.clearContents(at: owned)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owned.path), [])
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        XCTAssertThrowsError(try EclipseCacheStorage.clearContents(at: directory))
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: unrelated)
        XCTAssertThrowsError(try EclipseCacheStorage.clearContents(at: owned))
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
    }

    func testRegistryPreservesUnreadableAuthorityAndStableInternalIdentity() throws {
        let directory = try directory()
        let registry = DownloadStorageRegistry(directory: directory)
        XCTAssertTrue(registry.isReadable)
        let location = try registry.locationForNewItem(in: .video, relativePath: "Items/movie")
        let reopened = DownloadStorageRegistry(directory: directory)
        XCTAssertEqual(reopened.defaultRootID, location.rootID)
        XCTAssertEqual(reopened.legacyDefaultLocation(in: .reader, relativePath: "series/chapter").rootID, DownloadStorageRegistry.internalRootID)
        let malformed = Data("unreadable registry".utf8)
        let stateURL = directory.appendingPathComponent("roots.json")
        try malformed.write(to: stateURL)
        let unreadable = DownloadStorageRegistry(directory: directory)
        XCTAssertFalse(unreadable.isReadable)
        XCTAssertThrowsError(try unreadable.locationForNewItem(in: .video, relativePath: "Items/next"))
        XCTAssertEqual(try Data(contentsOf: stateURL), malformed)
    }

    func testTraversalAndSymlinkPathsAreRejected() throws {
        for path in ["Video/../private", "Video//file", "/Video/file", "Reader/a/../../b", "Video/\\file", "Video/a\u{0000}b"] {
            XCTAssertFalse(DownloadStorageRegistry.validRelativePath(path), path)
        }
        let directory = try directory()
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        let location = try registry.locationForNewItem(in: .video, relativePath: "Items/movie")
        let link = try registry.acquire(location.appending("escape"), access: .write)
        defer { link.close() }
        let outside = directory.appendingPathComponent("Unowned", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: outside)
        XCTAssertThrowsError(try registry.acquire(location.appending("escape/payload"), access: .write)) { error in
            guard case DownloadStorageError.invalidPath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload").path))
    }

    func testStorageStatisticsIncludeRegisteredDisksAndKeepUnavailableTotalsUnknown() throws {
        let directory = try directory()
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        let video = try registry.locationForNewItem(in: .video, relativePath: "Items/video")
        let videoLease = try registry.acquire(video.appending("video.mp4"), access: .write)
        try Data(repeating: 1, count: 17).write(to: videoLease.url)
        videoLease.close()
        let reader = try registry.locationForNewItem(in: .reader, relativePath: "series/chapter")
        let readerLease = try registry.acquire(reader.appending("page.jpg"), access: .write)
        try Data(repeating: 2, count: 23).write(to: readerLease.url)
        readerLease.close()
        let selected = directory.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let external = try registry.selectDefaultFolder(selected)
        let second = try registry.locationForNewItem(in: .video, relativePath: "Items/second")
        let secondLease = try registry.acquire(second.appending("video.mp4"), access: .write)
        try Data(repeating: 3, count: 31).write(to: secondLease.url)
        secondLease.close()
        let roots = Set(registry.roots.map(\.id))
        XCTAssertEqual(registry.storedBytes(in: .video, rootIDs: roots), 48)
        XCTAssertEqual(registry.storedBytes(in: .reader, rootIDs: roots), 23)
        XCTAssertNil(registry.storedBytes(in: .video, rootIDs: [UUID()]))
        let link = try registry.acquire(DownloadStorageLocation(rootID: external.id, relativePath: "Video/link"), access: .write)
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: directory)
        link.close()
        XCTAssertNil(registry.storedBytes(in: .video, rootIDs: roots))
    }

    func testMoveRefusesOpenLeaseAndCommitsVerifiedCopyBeforeRemovingOriginal() async throws {
        let directory = try directory()
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        let location = try registry.locationForNewItem(in: .video, relativePath: "Items/movie")
        let original = try registry.acquire(location, access: .write)
        try FileManager.default.createDirectory(at: original.url, withIntermediateDirectories: true)
        let bytes = Data("movie fixture".utf8)
        try bytes.write(to: original.url.appendingPathComponent("video.mp4"))
        let selected = directory.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let root = try registry.selectDefaultFolder(selected)
        do {
            _ = try await registry.prepareMove([location], toRootID: root.id)
            XCTFail("Move accepted a live storage lease")
        } catch DownloadStorageError.busy { }
        original.close()
        let move = try await registry.prepareMove([location], toRootID: root.id)
        var destination: DownloadStorageLocation?
        try registry.commitMove(move) { replacements in
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.appendingPathComponent("video.mp4").path))
            destination = replacements[location]
        }
        await registry.waitForMoveCleanup(move.id)
        let committed = try XCTUnwrap(destination)
        let lease = try registry.acquire(committed)
        defer { lease.close() }
        XCTAssertEqual(try Data(contentsOf: lease.url.appendingPathComponent("video.mp4")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.url.path))
        XCTAssertEqual(location.rootID, DownloadStorageRegistry.internalRootID)
        XCTAssertEqual(registry.defaultRootID, root.id)
    }

    func testFailedIndexCommitKeepsBothCopiesAndRecoveryRequiresDestinationAuthority() async throws {
        let directory = try directory()
        let registry = DownloadStorageRegistry(directory: directory.appendingPathComponent("Registry"))
        let location = try registry.locationForNewItem(in: .reader, relativePath: "series/chapter")
        let original = try registry.acquire(location, access: .write)
        try FileManager.default.createDirectory(at: original.url, withIntermediateDirectories: true)
        let bytes = Data("reader fixture".utf8)
        try bytes.write(to: original.url.appendingPathComponent("page.jpg"))
        original.close()
        let selected = directory.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let root = try registry.selectDefaultFolder(selected)
        let move = try await registry.prepareMove([location], toRootID: root.id)
        XCTAssertThrowsError(try registry.commitMove(move) { _ in throw CocoaError(.fileWriteOutOfSpace) })
        try registry.recoverMoves(referencedLocations: [location])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
        let destination = try XCTUnwrap(move.replacements[location])
        try registry.recoverMoves(referencedLocations: [destination], currentReferencedLocations: { [location] })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
        XCTAssertThrowsError(try registry.recoverMoves(referencedLocations: [destination], currentReferencedLocations: { nil }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.url.path))
        try registry.recoverMoves(referencedLocations: [destination])
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.url.path))
        let copied = try registry.acquire(destination)
        defer { copied.close() }
        XCTAssertEqual(try Data(contentsOf: copied.url.appendingPathComponent("page.jpg")), bytes)
    }

    func testFinalizationPreservesSourceAndRefusesDifferentOccupiedDestination() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("Output/video.mp4")
        let bytes = Data(repeating: 0x47, count: 2_000_123)
        try bytes.write(to: source)
        try MacDownloadFinalization.copyVerifiedFile(from: source, to: destination, expectedBytes: Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try MacDownloadFinalization.copyVerifiedFile(from: source, to: destination, expectedBytes: Int64(bytes.count))
        let occupied = Data(repeating: 0x11, count: bytes.count)
        try occupied.write(to: destination)
        XCTAssertThrowsError(try MacDownloadFinalization.copyVerifiedFile(from: source, to: destination, expectedBytes: Int64(bytes.count)))
        XCTAssertEqual(try Data(contentsOf: destination), occupied)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLocalResumeSurvivesRenameAndIsolatesProfilesAndUnreadableFiles() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.mp4")
        try Data("local video".utf8).write(to: source)
        let storeDirectory = directory.appendingPathComponent("Resume")
        let store = MacLocalPlaybackResumeStore(directory: storeDirectory)
        let owner = UUID()
        store.update(url: source, owner: owner, position: 123, duration: 1000)
        XCTAssertEqual(store.currentTime(for: source, owner: owner), 123)
        XCTAssertEqual(store.currentTime(for: source, owner: UUID()), 0)
        let reopened = MacLocalPlaybackResumeStore(directory: storeDirectory)
        let renamed = directory.appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: source, to: renamed)
        XCTAssertEqual(reopened.currentTime(for: renamed, owner: owner), 123)
        reopened.update(url: renamed, owner: owner, position: 951, duration: 1000)
        XCTAssertEqual(reopened.currentTime(for: renamed, owner: owner), 0)
        let profileURL = storeDirectory.appendingPathComponent(owner.uuidString.lowercased() + ".json")
        let malformed = Data("unreadable resume".utf8)
        try malformed.write(to: profileURL)
        let unreadable = MacLocalPlaybackResumeStore(directory: storeDirectory)
        unreadable.update(url: renamed, owner: owner, position: 333, duration: 1000)
        XCTAssertEqual(try Data(contentsOf: profileURL), malformed)
        XCTAssertFalse(unreadable.flushForMacTermination())
    }

    func testLocalResumeRetainsNewestFailedOwnerWriteUntilDurableRetry() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.mp4")
        try Data("local video".utf8).write(to: source)
        let storeDirectory = directory.appendingPathComponent("Resume")
        var failWrites = false
        let store = MacLocalPlaybackResumeStore(directory: storeDirectory) { data, url in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try DownloadStorageRegistry.durableWrite(data, to: url)
        }
        let owner = UUID()
        let other = UUID()
        store.update(url: source, owner: owner, position: 123, duration: 1000)
        store.update(url: source, owner: other, position: 222, duration: 1000)
        failWrites = true
        store.update(url: source, owner: owner, position: 345, duration: 1000)
        store.update(url: source, owner: owner, position: 456, duration: 1000)
        XCTAssertEqual(store.currentTime(for: source, owner: owner), 456)
        XCTAssertFalse(store.flushForMacTermination())
        XCTAssertEqual(MacLocalPlaybackResumeStore(directory: storeDirectory).currentTime(for: source, owner: owner), 123)
        failWrites = false
        XCTAssertTrue(store.flushForMacTermination())
        let reopened = MacLocalPlaybackResumeStore(directory: storeDirectory)
        XCTAssertEqual(reopened.currentTime(for: source, owner: owner), 456)
        XCTAssertEqual(reopened.currentTime(for: source, owner: other), 222)
    }

    func testLocalResumeRetryPreservesNewerExternalResetAndChangedFiles() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.mp4")
        try Data("local video".utf8).write(to: source)
        let storeDirectory = directory.appendingPathComponent("Resume")
        var failWrites = false
        let store = MacLocalPlaybackResumeStore(directory: storeDirectory) { data, url in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try DownloadStorageRegistry.durableWrite(data, to: url)
        }
        let owner = UUID()
        store.update(url: source, owner: owner, position: 123, duration: 1000)
        failWrites = true
        store.update(url: source, owner: owner, position: 456, duration: 1000)
        let external = MacLocalPlaybackResumeStore(directory: storeDirectory)
        external.update(url: source, owner: owner, position: 951, duration: 1000)
        let profileURL = storeDirectory.appendingPathComponent(owner.uuidString.lowercased() + ".json")
        let resetBytes = try Data(contentsOf: profileURL)
        failWrites = false
        XCTAssertFalse(store.flushForMacTermination())
        store.update(url: source, owner: owner, position: 567, duration: 1000)
        XCTAssertFalse(store.flushForMacTermination())
        XCTAssertEqual(try Data(contentsOf: profileURL), resetBytes)
        XCTAssertEqual(MacLocalPlaybackResumeStore(directory: storeDirectory).currentTime(for: source, owner: owner), 0)
    }

    func testLocalResumeRetriesOwnBytesAfterPostWriteFailure() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.mp4")
        try Data("local video".utf8).write(to: source)
        let storeDirectory = directory.appendingPathComponent("Resume")
        var failAfterWrite = true
        let store = MacLocalPlaybackResumeStore(directory: storeDirectory) { data, url in
            try DownloadStorageRegistry.durableWrite(data, to: url)
            if failAfterWrite { throw CocoaError(.fileWriteUnknown) }
        }
        let owner = UUID()
        store.update(url: source, owner: owner, position: 123, duration: 1000)
        store.update(url: source, owner: owner, position: 456, duration: 1000)
        XCTAssertFalse(store.flushForMacTermination())
        failAfterWrite = false
        XCTAssertTrue(store.flushForMacTermination())
        XCTAssertEqual(MacLocalPlaybackResumeStore(directory: storeDirectory).currentTime(for: source, owner: owner), 456)
    }
}
#endif
