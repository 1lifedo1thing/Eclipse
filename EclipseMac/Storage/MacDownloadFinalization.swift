#if os(macOS)
import Foundation
import CryptoKit
import Darwin

struct MacPendingDownloadFinalization: Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let byteCount: Int64
    let usesDirectCheckpoint: Bool

    var isValid: Bool {
        byteCount > 0 && DownloadStorageRegistry.validRelativePath("Video/" + fileName)
    }
}

enum MacDownloadFinalization {
    static func copyVerifiedFile(from source: URL, to destination: URL, expectedBytes: Int64) throws {
        try Task.checkCancellation()
        let expectedDigest = try digest(source, expectedBytes: expectedBytes)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try digest(destination, expectedBytes: expectedBytes) == expectedDigest else {
                throw DownloadStorageError.verificationFailed
            }
            return
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".incoming-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var copied: Int64 = 0
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            copied += Int64(data.count)
            guard copied <= expectedBytes else { throw DownloadStorageError.verificationFailed }
            try output.write(contentsOf: data)
        }
        guard copied == expectedBytes else { throw DownloadStorageError.verificationFailed }
        try output.synchronize()
        guard try digest(temporary, expectedBytes: expectedBytes) == expectedDigest,
              try digest(source, expectedBytes: expectedBytes) == expectedDigest else {
            throw DownloadStorageError.verificationFailed
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        try FileManager.default.moveItem(at: temporary, to: destination)
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func digest(_ url: URL, expectedBytes: Int64) throws -> SHA256.Digest {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == expectedBytes else { throw DownloadStorageError.verificationFailed }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(data.count)
            guard bytes <= expectedBytes else { throw DownloadStorageError.verificationFailed }
            hasher.update(data: data)
        }
        guard bytes == expectedBytes else { throw DownloadStorageError.verificationFailed }
        return hasher.finalize()
    }
}
#endif
