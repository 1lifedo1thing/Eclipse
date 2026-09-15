#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class MacPlaybackCoordinator: ObservableObject {
    static let shared = MacPlaybackCoordinator()

    @Published private(set) var session: MacPlaybackSession? {
        didSet { observeInlinePlaybackVisibility() }
    }
    @Published private(set) var isInlinePlaybackVisible = false
    private var pictureInPictureObservation: AnyCancellable?
    @Published var errorMessage: String?
    var onRestoreMainWindow: (() -> Void)?
    var onPlaybackPresented: (() -> Void)?
    private var admissionTask: Task<Void, Never>?
    private var admissionGeneration: UInt64 = 0
    private var retirementTasks: [UUID: Task<Void, Never>] = [:]
    private var terminationGate = MacPlaybackTerminationGate()

    private init() {}

    func present(_ request: PlaybackRequest, engine: PlaybackEngine = .selected) {
        guard admissionIsAllowed else { request.launchContext?.ephemeralProxyOwnership?.invalidate(); return }
        session?.cancelPendingAutoplay()
        cancelAdmission()
        let generation = admissionGeneration
        let watchTogetherIdentity = WatchTogetherCoordinator.shared.playbackHandoffIdentity
        let owner = ProfileManager.shared.activeProfileID
        let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner)
        let pendingLease = request.launchContext?.ephemeralProxyOwnership?.acquireLease()
        admissionTask = Task { @MainActor [weak self] in
            defer { pendingLease?.release() }
            guard let self else { return }
            defer { if self.admissionGeneration == generation { self.admissionTask = nil } }
            let allowed: Bool
            switch KidsPlaybackGate.decision(for: request) {
            case .allow: allowed = true
            case .deny: allowed = false
            case .resolve(let identity):
                allowed = await KidsPlaybackGate.awaitFullVerdict(identity, budget: 2) == true
            }
            guard !Task.isCancelled, self.admissionIsAllowed, let authority,
                  MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: generation,
                      currentGeneration: self.admissionGeneration, capturedWatchTogether: watchTogetherIdentity,
                      currentWatchTogether: WatchTogetherCoordinator.shared.playbackHandoffIdentity,
                      ownerIsCurrent: ProgressManager.shared.profileMutationAuthorityIsCurrent(authority)) else { return }
            guard allowed else {
                self.errorMessage = "Not available on this profile"
                return
            }
            if await MacExternalPlayerRegistry.shared.handoffIfSelected(request) {
                if self.admissionGeneration == generation { self.retireCurrentSession() }
                return
            }
            guard !Task.isCancelled, self.admissionIsAllowed, self.admissionGeneration == generation,
                  WatchTogetherCoordinator.shared.playbackHandoffIdentity == watchTogetherIdentity,
                  ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
            self.retireCurrentSession()
            let next = MacPlaybackSession(request: request, engine: engine, owner: owner, authority: authority)
            next.onClose = { [weak self, weak next] in
                guard let self, self.session === next else { return }
                self.session = nil
                if let next { self.trackRetirement(Task { await next.waitUntilStopped() }) }
            }
            next.onRestoreMainWindow = { [weak self] in self?.onRestoreMainWindow?() }
            self.errorMessage = nil
            self.session = next
            self.onPlaybackPresented?()
            next.start()
        }
    }

    func present(
        _ request: PlaybackRequest,
        from presenter: NSViewController?,
        engine: PlaybackEngine = .selected,
        animated: Bool = true
    ) {
        present(request, engine: engine)
    }

    func stopInlinePlayback() {
        cancelAdmission()
        guard MacPlaybackLifecyclePolicy.shouldStop(for: .mainWindow,
            hasExplicitPictureInPicture: session?.isPictureInPicture == true,
            isRestoringPictureInPicture: session?.isRestoringPictureInPicture == true) else { return }
        retireCurrentSession()
    }

    func mainWindowClosed() {
        stopInlinePlayback()
    }

    func stopAll() {
        cancelAdmission()
        retireCurrentSession()
    }

    func beginMacTermination() {
        terminationGate.begin()
        stopAll()
    }

    func prepareForMacTermination() async -> Bool {
        terminationGate.begin()
        let pendingAdmission = admissionTask
        stopAll()
        var tasks = Array(retirementTasks.values)
        if let pendingAdmission { tasks.append(pendingAdmission) }
        let finished = await MacPlaybackShutdownBarrier.wait(for: tasks, timeout: 5)
        if finished {
            retirementTasks.removeAll()
            MacExternalPlayerRegistry.shared.releaseAllForTermination()
        }
        return finished
    }

    func cancelMacTermination() {
        terminationGate.cancel()
    }

    private func retireCurrentSession() {
        guard let current = session else { return }
        current.stop()
        if session === current {
            session = nil
            trackRetirement(Task { await current.waitUntilStopped() })
        }
    }

    private func observeInlinePlaybackVisibility() {
        pictureInPictureObservation = nil
        guard let current = session else { isInlinePlaybackVisible = false; return }
        isInlinePlaybackVisible = !current.isPictureInPicture
        pictureInPictureObservation = current.$isPictureInPicture.removeDuplicates().sink { [weak self, weak current] isPiP in
            guard let self, let current, self.session === current else { return }
            self.isInlinePlaybackVisible = !isPiP
        }
    }

    private var admissionIsAllowed: Bool {
        terminationGate.allowsAdmission(applicationIsTerminating: MacLaunchProfileAccess.isTerminating)
            && !MacLaunchProfileAccess.requiresUnlock
            && ProfileManager.shared.rosterStoreIsReadable
            && ProfileManager.shared.activeProfile != nil
    }

    private func trackRetirement(_ task: Task<Void, Never>) {
        let id = UUID()
        retirementTasks[id] = Task { [weak self] in
            await task.value
            self?.retirementTasks.removeValue(forKey: id)
        }
    }

    private func cancelAdmission() {
        admissionGeneration &+= 1
        if let admissionTask {
            admissionTask.cancel()
            trackRetirement(admissionTask)
        }
        admissionTask = nil
    }
}

typealias PlaybackCoordinator = MacPlaybackCoordinator
#endif
