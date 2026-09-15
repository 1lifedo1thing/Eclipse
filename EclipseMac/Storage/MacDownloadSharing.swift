#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class MacDownloadSharing {
    static let shared = MacDownloadSharing()
    private var operations: [UUID: Operation] = [:]
    private var observers: [AnyCancellable] = []

    private init() {
        for name in [Notification.Name.macMainWindowClosed, .activeProfileDidChange,
                     .mediaStateWillChangeCurrentUser, ServiceStoreScope.didChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    if Thread.isMainThread { MainActor.assumeIsolated { self?.cancelUnchosenOperations() } }
                    else { Task { @MainActor in self?.cancelUnchosenOperations() } }
                }.store(in: &observers)
        }
    }

    func share(_ item: DownloadItem, from view: NSView? = nil) {
        let profiles = ProfileManager.shared
        guard operations.count < 16, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              profiles.rosterStoreIsReadable, let profile = profiles.activeProfile,
              let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: profile.id),
              let view = view ?? NSApplication.shared.keyWindow?.contentView ?? MacWindowCoordinator.shared.mainWindow?.contentView,
              view.window?.isVisible == true else { return }
        do {
            let lease = try DownloadManager.shared.acquirePlaybackLease(for: item)
            let operation = Operation(lease: lease, authority: authority, view: view) { [weak self] id in
                self?.operations.removeValue(forKey: id)
            }
            operations[operation.id] = operation
            if profile.isKidsProfile {
                operation.authorizationTask = Task { [weak operation] in
                    let allowed = await TMDBContentFilter.shared.kidsPolicyAllowsPlayback(isMovie: item.isMovie,
                        id: item.tmdbId, title: item.playerTitleBase, persistedDetails: item.kidsPolicyDetails)
                    guard let operation, !Task.isCancelled else { return }
                    guard allowed, operation.isCurrent else { operation.finish(); return }
                    operation.present()
                }
            } else {
                operation.present()
            }
        } catch {
            MacWindowCoordinator.shared.presentError(error.localizedDescription)
        }
    }

    func prepareForMacTermination() -> Bool {
        cancelUnchosenOperations()
        return operations.isEmpty
    }

    private func cancelUnchosenOperations() {
        for operation in Array(operations.values) where !operation.hasChosenService {
            operation.cancel()
        }
    }

    @MainActor
    private final class Operation: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let id = UUID()
        let lease: DownloadStorageLease
        let authority: ProgressManager.ProfileMutationAuthority
        weak var view: NSView?
        var authorizationTask: Task<Void, Never>?
        private var picker: NSSharingServicePicker?
        private var service: NSSharingService?
        private var isFinished = false
        private let completion: (UUID) -> Void
        private(set) var hasChosenService = false

        init(lease: DownloadStorageLease, authority: ProgressManager.ProfileMutationAuthority,
             view: NSView, completion: @escaping (UUID) -> Void) {
            self.lease = lease
            self.authority = authority
            self.view = view
            self.completion = completion
            super.init()
        }

        var isCurrent: Bool {
            !isFinished && !MacLaunchProfileAccess.requiresUnlock && !MacLaunchProfileAccess.isTerminating
                && ProfileManager.shared.rosterStoreIsReadable && view?.window?.isVisible == true
                && ProgressManager.shared.profileMutationAuthorityIsCurrent(authority)
        }

        func present() {
            guard isCurrent, let view else { finish(); return }
            let picker = NSSharingServicePicker(items: [lease.url])
            picker.delegate = self
            self.picker = picker
            picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                of: view, preferredEdge: .minY)
        }

        func cancel() {
            guard !hasChosenService else { return }
            picker?.close()
            finish()
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            authorizationTask?.cancel()
            authorizationTask = nil
            picker?.delegate = nil
            picker = nil
            service?.delegate = nil
            service = nil
            lease.close()
            completion(id)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
            delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
            self.service = sharingService
            return self
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else { finish(); return }
            hasChosenService = true
            self.service = service
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            let shouldReport = isCurrent && (error as NSError).code != NSUserCancelledError
            finish()
            if shouldReport { MacWindowCoordinator.shared.presentError("The downloaded video could not be shared. " + error.localizedDescription) }
        }

        func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
            sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
            sharingContentScope.pointee = .item
            return view?.window
        }
    }
}
#endif
