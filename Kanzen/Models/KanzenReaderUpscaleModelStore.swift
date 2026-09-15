import Foundation

enum KanzenReaderUpscaleModelStore {
    private static let storedFileName = "reader-upscale.mlmodel"

    static func storedModelURL(forProfile profileID: UUID) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderUpscaling", isDirectory: true)
        guard profileID != ProfileManager.defaultProfileID else {
            return directory.appendingPathComponent(storedFileName)
        }
        return directory.appendingPathComponent("\(profileID.uuidString.lowercased())-\(storedFileName)")
    }

    static var storedModelURL: URL {
        storedModelURL(forProfile: ProfileManager.shared.activeProfileID)
    }

    static func discardModel(forProfile profileID: UUID) {
        guard profileID != ProfileManager.defaultProfileID else { return }
        try? FileManager.default.removeItem(at: storedModelURL(forProfile: profileID))
    }

    static var storedModelName: String {
        guard FileManager.default.fileExists(atPath: storedModelURL.path) else {
            return "None"
        }
        return ProfileSettingsStore.active.string(forKey: "Reader.upscaleModelName") ?? "None"
    }

    static func importModel(from sourceURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        #if os(macOS)
        let owner = ProfileManager.shared.activeProfileID
        let target = storedModelURL(forProfile: owner)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".reader-model-" + UUID().uuidString + ".mlmodel")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        ProfileSettingsStore.shared.store(for: owner).set(sourceURL.lastPathComponent, forKey: "Reader.upscaleModelName")
        #else
        let directory = storedModelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: storedModelURL.path) {
            try FileManager.default.removeItem(at: storedModelURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: storedModelURL)
        ProfileSettingsStore.active.set(sourceURL.lastPathComponent, forKey: "Reader.upscaleModelName")
        #endif
    }

    static func clearModel() {
        try? FileManager.default.removeItem(at: storedModelURL)
        ProfileSettingsStore.active.removeObject(forKey: "Reader.upscaleModelName")
    }
}

