import AppKit
import SwiftUI

@main
@MainActor
final class EclipseMacApp: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    private var maintenanceTimer: Timer?
    private var lastCloudMaintenance: TimeInterval = 0

    static func main() {
        let application = NSApplication.shared
        let delegate = EclipseMacApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExperimentalFeatureState.configureLaunchState()
        OnboardingState.bootstrapIfNeeded()
        CrashReportManager.shared.start()
        _ = LocalizationManager.shared
        _ = DownloadManager.shared
        _ = ReaderDownloadManager.shared
        KingfisherImageCacheConfigurator.configureIfNeeded()
        LocalNotificationManager.shared.configure()
        MediaStateSyncBootstrap.startIfAvailable()
        WatchTogetherCoordinator.shared.start()
        MacWindowCoordinator.shared.installMenus()
        MacWindowCoordinator.shared.showMainWindow(reason: .launch)
        MacDownloadRecoveryCoordinator.shared.recoverIfNeeded()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintainServices() }
        }
        maintainServices()
        Task.detached(priority: .background) { CacheManager.shared.checkAndAutoClearIfNeeded() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Logger.shared.log("MacLifecycle event=app-reopen hasVisibleWindows=\(flag)", type: "Lifecycle")
        MacWindowCoordinator.shared.showMainWindow(reason: .reopen)
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { MacWindowCoordinator.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        Logger.shared.log("MacLifecycle event=app-active", type: "Lifecycle")
        MacWindowCoordinator.shared.isActive = true
        TrackerManager.shared.checkForExpiredTrackerSessions()
        MediaStateSyncBootstrap.syncOnActivation()
        ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "mac-active")
        Task {
            await LocalNotificationManager.shared.refreshAuthorizationStatus()
            await LocalNotificationManager.shared.syncDeliveredNotificationHistory()
            await LocalNotificationManager.shared.refreshSchedulesIfNeeded()
        }
        maintainServices()
    }

    func applicationDidResignActive(_ notification: Notification) {
        Logger.shared.log("MacLifecycle event=app-inactive", type: "Lifecycle")
        MacWindowCoordinator.shared.isActive = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        let sharingFinished = MacDownloadSharing.shared.prepareForMacTermination()
        MacWindowCoordinator.shared.prepareForTermination()
        DownloadManager.shared.beginMacTermination()
        ReaderDownloadManager.shared.beginMacTermination()
        Task { @MainActor in
            let storageMoveSaved = await MacDownloadMoveCoordinator.shared.prepareForMacTermination()
            let videoSaved = await DownloadManager.shared.prepareForMacTermination()
            let readerSaved = await ReaderDownloadManager.shared.prepareForMacTermination()
            let playbackStopped = await MacPlaybackCoordinator.shared.prepareForMacTermination()
            let readerProgressSaved = MacWindowCoordinator.shared.readerSession.flushForMacTermination()
            let progressSaved = ProgressManager.shared.flushForMacTermination()
            let localResumeSaved = MacLocalPlaybackResumeStore.shared.flushForMacTermination()
            let syncSaved = MediaStateSyncManager.shared.flushForMacTermination()
            if storageMoveSaved && videoSaved && readerSaved && playbackStopped && readerProgressSaved && progressSaved && localResumeSaved && syncSaved && sharingFinished {
                maintenanceTimer?.invalidate()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                MacWindowCoordinator.shared.cancelTermination()
                MacDownloadMoveCoordinator.shared.resumeAfterCancelledMacTermination()
                DownloadManager.shared.resumeAfterCancelledMacTermination()
                ReaderDownloadManager.shared.resumeAfterCancelledMacTermination()
                MacPlaybackCoordinator.shared.cancelMacTermination()
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                MacWindowCoordinator.shared.presentError(sharingFinished ? "Eclipse could not save all pending work. Check available storage and try quitting again." : "A system share is still using a downloaded file. Finish or cancel sharing, then try quitting again.")
            }
        }
        return .terminateLater
    }

    private func maintainServices() {
        guard !terminationPending, MacWindowCoordinator.shared.mainWindow?.isVisible == true else { return }
        MacDownloadRecoveryCoordinator.shared.recoverIfNeeded()
        Task { await MacProviderMaintenance.shared.onActivation() }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastCloudMaintenance >= 900 || lastCloudMaintenance == 0 {
            lastCloudMaintenance = uptime
            ExperimentalCloudSyncManager.shared.syncOnActivationIfNeeded(reason: "mac-maintenance")
        }
    }
}
