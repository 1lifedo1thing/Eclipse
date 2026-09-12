import Foundation
#if os(macOS)
import Darwin
import Security
#endif

extension FileManager {
    var eclipseCachesDirectories: [URL] {
#if os(macOS)
        let base = urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        let directory = base.appendingPathComponent("Eclipse", isDirectory: true)
        try? createDirectory(at: directory, withIntermediateDirectories: true)
        return [directory]
#else
        urls(for: .cachesDirectory, in: .userDomainMask)
#endif
    }

    var eclipseDocumentsDirectories: [URL] {
#if os(macOS)
        let base = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = EclipseMacDataDirectories.compatibleDocumentsDirectory(fileManager: self)
            ?? base.appendingPathComponent("Eclipse/Data", isDirectory: true)
        try? createDirectory(at: directory, withIntermediateDirectories: true)
        return [directory]
#else
        urls(for: .documentDirectory, in: .userDomainMask)
#endif
    }
}

#if os(macOS)
enum EclipseMacDataDirectories {
    private static let hasAuthenticatedSandbox: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              identifier == Bundle.main.bundleIdentifier,
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true else { return false }
        return true
    }()

    static func compatibleDocumentsDirectory(fileManager: FileManager = .default) -> URL? {
        compatibleDocumentsDirectory(sandboxIsAuthenticated: hasAuthenticatedSandbox,
            home: { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) },
            documents: { fileManager.urls(for: .documentDirectory, in: .userDomainMask).first })
    }

    static func compatibleDocumentsDirectory(sandboxIsAuthenticated: Bool,
        home: () -> URL, documents: () -> URL?) -> URL? {
        guard sandboxIsAuthenticated else { return nil }
        let home = home().standardizedFileURL.resolvingSymlinksInPath()
        guard home.isFileURL, let documents = documents(), documents.isFileURL else { return nil }
        let resolved = documents.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(home.path + "/"), resolved.path != home.path else { return nil }
        return resolved
    }
}
#endif

enum EclipseCacheStorage {
    static func clearContents(at directory: URL, fileManager: FileManager = .default) throws {
#if os(macOS)
        guard directory.lastPathComponent == "Eclipse" else { throw CocoaError(.fileWriteNoPermission) }
        var attributes = stat()
        let isOwnedDirectory = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &attributes) == 0 && (attributes.st_mode & S_IFMT) == S_IFDIR
        }
        guard isOwnedDirectory else { throw CocoaError(.fileWriteNoPermission) }
#endif
        let items = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in items {
#if os(macOS)
            try fileManager.removeItem(at: url)
#else
            try? fileManager.removeItem(at: url)
#endif
        }
    }
}
