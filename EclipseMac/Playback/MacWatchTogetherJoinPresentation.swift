#if os(macOS)
import AppKit
import SwiftUI

struct MacWatchTogetherJoinPresentation: ViewModifier {
    @ObservedObject private var playback = MacPlaybackCoordinator.shared
    @ObservedObject private var window = MacWindowCoordinator.shared
    @State private var pendingDisabledJoinPrompt = false
    @State private var pendingWaitingForHostNotice = false
    @State private var request: WatchTogetherJoinRequest?
    @State private var suspendedRequest: WatchTogetherJoinRequest?
    @State private var requestAuthority: ProgressManager.ProfileMutationAuthority?
    @State private var suppressLeavePrompt = false
    @State private var showingLeaveConfirmation = false
    @State private var showingDisabledJoinPrompt = false
    @State private var showingWaitingForHostNotice = false

    func body(content: Content) -> some View {
        content
            .onAppear { consumePendingRequest() }
            .onChange(of: window.launchUnlockRequired) { _, locked in
                guard !locked, mayPresent else { return }
                showingDisabledJoinPrompt = pendingDisabledJoinPrompt
                showingWaitingForHostNotice = pendingWaitingForHostNotice
                consumePendingRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherJoinRequested)) { _ in
                DispatchQueue.main.async { consumePendingRequest() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                consumePendingRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherSessionCleared)) { _ in
                closePresentation(clearPending: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
                closePresentation(clearPending: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in
                closePresentation(clearPending: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherDisabledJoinAttempted)) { _ in
                pendingDisabledJoinPrompt = true
                if mayPresent { showingDisabledJoinPrompt = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchTogetherWaitingForHost)) { _ in
                pendingWaitingForHostNotice = true
                guard mayPresent, request == nil, !showingLeaveConfirmation else { return }
                showingWaitingForHostNotice = true
            }
            .onChange(of: playback.session?.id) { _, _ in
                if let session = playback.session, let current = request,
                   session.watchTogetherMediaDescriptor?.isSameLogicalMedia(as: current.media) == true {
                    suspendedRequest = current
                    suppressLeavePrompt = true
                    request = nil
                } else if playback.session == nil {
                    DispatchQueue.main.async { restoreSuspendedRequest() }
                }
            }
            .sheet(item: $request, onDismiss: {
                if suppressLeavePrompt {
                    suppressLeavePrompt = false
                } else if WatchTogetherCoordinator.shared.playbackHandoffIdentity.sessionID != nil {
                    showingLeaveConfirmation = true
                }
            }) { request in
                MediaDetailView(searchResult: request.searchResult, watchTogetherAutoPlay: request.media)
                    .id(request.id)
                    .frame(minWidth: 720, idealWidth: 920, minHeight: 540, idealHeight: 740)
                    .profileScopedAppStorage()
            }
            .alert("Leave Watch Together?", isPresented: $showingLeaveConfirmation) {
                Button("Leave Session", role: .destructive) { WatchTogetherCoordinator.shared.leaveSession() }
                Button("Rejoin", role: .cancel) {
                    showingLeaveConfirmation = false
                    consumePendingRequest()
                }
            } message: {
                Text("You closed the shared title while SharePlay is active. Leaving stops syncing with the group on this Mac.")
            }
            .alert("Watch Together is Off", isPresented: $showingDisabledJoinPrompt) {
                if ProfileManager.shared.isKidsModeActive {
                    Button("OK", role: .cancel) { WatchTogetherCoordinator.shared.declinePendingDisabledSession() }
                } else {
                    Button("Turn On & Join") {
                        guard mayPresent else { return }
                        pendingDisabledJoinPrompt = false
                        WatchTogetherCoordinator.shared.joinPendingDisabledSession()
                    }
                    Button("Not Now", role: .cancel) { WatchTogetherCoordinator.shared.declinePendingDisabledSession() }
                }
            } message: {
                Text(ProfileManager.shared.isKidsModeActive
                    ? "Watch Together is turned off for this profile, so the invitation was not joined."
                    : "You accepted a SharePlay invitation, but Watch Together is turned off in Settings.")
            }
            .alert("Waiting for the Host", isPresented: $showingWaitingForHostNotice) {
                Button("Keep Waiting", role: .cancel) {}
                Button("Leave Session", role: .destructive) { WatchTogetherCoordinator.shared.leaveSession() }
            } message: {
                Text("You joined the session, but the host's Eclipse hasn't responded yet. Ask them to open Eclipse with their video playing.")
            }
    }

    private var mayPresent: Bool {
        !MacLaunchProfileAccess.requiresUnlock && ProfileManager.shared.rosterStoreIsReadable
            && ProfileManager.shared.activeProfile != nil
    }

    private func consumePendingRequest() {
        guard mayPresent, !showingLeaveConfirmation, MacWindowCoordinator.shared.mainWindow?.isVisible == true,
              let pending = WatchTogetherCoordinator.shared.takePendingJoinRequest(
                forSceneSessionIdentifier: MacWindowCoordinator.presentationIdentifier) else { return }
        if playback.session?.watchTogetherMediaDescriptor?.isSameLogicalMedia(as: pending.media) == true {
            suspendedRequest = pending
            return
        }
        guard playback.session == nil || request?.id != pending.id else { return }
        let owner = ProfileManager.shared.activeProfileID
        requestAuthority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner)
        suspendedRequest = pending
        suppressLeavePrompt = false
        request = pending
    }

    private func restoreSuspendedRequest() {
        guard mayPresent, playback.session == nil, MacWindowCoordinator.shared.mainWindow?.isVisible == true,
              let requestAuthority, ProgressManager.shared.profileMutationAuthorityIsCurrent(requestAuthority),
              let suspendedRequest, WatchTogetherCoordinator.shared.isCurrentSharedMedia(suspendedRequest.media) else { return }
        suppressLeavePrompt = false
        request = suspendedRequest
    }

    private func closePresentation(clearPending: Bool) {
        suppressLeavePrompt = request != nil
        showingLeaveConfirmation = false
        showingWaitingForHostNotice = false
        showingDisabledJoinPrompt = false
        request = nil
        if clearPending {
            pendingDisabledJoinPrompt = false
            pendingWaitingForHostNotice = false
            suspendedRequest = nil
            requestAuthority = nil
        }
    }
}
#endif
