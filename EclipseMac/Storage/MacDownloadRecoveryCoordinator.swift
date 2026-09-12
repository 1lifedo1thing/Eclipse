import Foundation

@MainActor
final class MacDownloadRecoveryCoordinator {
    static let shared = MacDownloadRecoveryCoordinator()
    private var task: Task<Void, Never>?

    func recoverIfNeeded() {
        guard task == nil, let locations = Self.currentLocations() else { return }
        task = Task {
            defer { task = nil }
            await Task.detached(priority: .utility) {
                do {
                    try DownloadStorageRegistry.shared.recoverMoves(
                        referencedLocations: locations,
                        currentReferencedLocations: {
                            DispatchQueue.main.sync {
                                MainActor.assumeIsolated { Self.currentLocations() }
                            }
                        }
                    )
                } catch {
                    Logger.shared.log("Download move recovery remains pending; saved downloads were retained.", type: "Download")
                }
            }.value
        }
    }

    private static func currentLocations() -> Set<DownloadStorageLocation>? {
        let video = DownloadManager.shared
        let reader = ReaderDownloadManager.shared
        guard !video.metadataLoadFailed, reader.macStorageIndexIsReadable else { return nil }
        return video.storageLocations.union(reader.referencedMacStorageLocations)
    }
}
