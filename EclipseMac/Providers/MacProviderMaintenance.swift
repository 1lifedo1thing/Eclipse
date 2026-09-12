#if os(macOS)
import AppKit
import CloudKit
import Foundation

@MainActor
final class MacProviderMaintenance {
    static let shared = MacProviderMaintenance()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [.macMainWindowClosed, .activeProfileDidChange,
            ServiceStoreScope.didChangeNotification, .CKAccountChanged, .NSUbiquityIdentityDidChange]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    func onActivation() async {
        guard task == nil, !ProfileManager.shared.isKidsModeActive,
              ProfileManager.shared.rosterStoreIsReadable, !MacLaunchProfileAccess.requiresUnlock else { return }
        generation &+= 1
        let operation = generation
        let owner = ProfileManager.shared.activeProfileID
        let sourceGeneration = ServiceStoreScope.generation
        guard let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner) else { return }
        let work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == operation { self.task = nil } }
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.generation == operation
                    && ProgressManager.shared.profileMutationAuthorityIsCurrent(authority)
                    && ServiceStoreScope.isCurrent(sourceGeneration)
                    && !ProfileManager.shared.isKidsModeActive
                    && ProfileManager.shared.rosterStoreIsReadable && !MacLaunchProfileAccess.requiresUnlock
            }
            guard current() else { return }
            await ServiceManager.shared.autoUpdateServicesIfNeeded()
            guard current() else { return }
            let autoUpdate = ProfileSettingsStore.services.object(forKey: "autoUpdateServicesEnabled") as? Bool ?? true
            if autoUpdate {
                let skyStream = SkyStreamPluginManager.shared
                for _ in 0..<40 where !skyStream.isLoaded {
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    guard current() else { return }
                }
                if current(), skyStream.isLoaded,
                   !skyStream.installedPlugins.isEmpty || !skyStream.repositories.isEmpty,
                   self.updateIsDue(key: "lastSkyStreamAutoUpdateTimestamp") {
                    await skyStream.refreshRepositoriesAndInstalledPlugins(autoUpdate: true)
                    guard current() else { return }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSkyStreamAutoUpdateTimestamp")
                }
                let nuvio = NuvioPluginManager.shared
                for _ in 0..<40 where !nuvio.isLoaded {
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    guard current() else { return }
                }
                if current(), nuvio.isLoaded, !nuvio.repositories.isEmpty,
                   self.updateIsDue(key: "lastMacNuvioAutoUpdateTimestamp") {
                    await nuvio.refreshRepositoriesAndInstalledPlugins(autoUpdate: true)
                    guard current() else { return }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastMacNuvioAutoUpdateTimestamp")
                }
            }
            guard current() else { return }
            await SourceHealthMonitor.shared.runDailyEnabledSourceChecksIfNeeded()
        }
        task = work
        await work.value
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func updateIsDue(key: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: key)
        return last <= 0 || Date().timeIntervalSince1970 - last >= 3_600
    }
}
#endif
