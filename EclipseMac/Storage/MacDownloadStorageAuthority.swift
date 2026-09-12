#if os(macOS)
import Foundation

@MainActor
struct MacDownloadStorageAuthority {
    let profileID: UUID
    let progress: ProgressManager.ProfileMutationAuthority
    let servicesGeneration: Int

    static func capture() -> MacDownloadStorageAuthority? {
        let profiles = ProfileManager.shared
        guard profiles.rosterStoreIsReadable, !profiles.isKidsModeActive,
              !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let profile = profiles.activeProfile, !profile.isKidsProfile,
              let progress = ProgressManager.shared.profileMutationAuthority(requiredOwner: profile.id) else { return nil }
        return MacDownloadStorageAuthority(profileID: profile.id, progress: progress, servicesGeneration: ServiceStoreScope.generation)
    }

    func isCurrent() -> Bool {
        let profiles = ProfileManager.shared
        return profiles.rosterStoreIsReadable && !profiles.isKidsModeActive
            && !MacLaunchProfileAccess.requiresUnlock && !MacLaunchProfileAccess.isTerminating
            && profiles.activeProfile?.id == profileID && profiles.activeProfile?.isKidsProfile == false
            && ServiceStoreScope.generation == servicesGeneration
            && ProgressManager.shared.profileMutationAuthorityIsCurrent(progress)
    }
}
#endif
