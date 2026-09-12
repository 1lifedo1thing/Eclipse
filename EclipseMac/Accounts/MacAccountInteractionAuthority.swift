import Foundation

@MainActor
enum MacLaunchProfileAccess {
    static var requiresUnlock = ProfileManager.shared.activeProfile?.isLocked == true
    static var isTerminating = false
    static var windowGeneration: UInt64 = 0
}

@MainActor
struct MacAccountInteractionAuthority {
    let owner: UUID
    let profile: ProgressManager.ProfileMutationAuthority
    let servicesGeneration: Int

    static func capture() -> MacAccountInteractionAuthority? {
        let profiles = ProfileManager.shared
        guard profiles.rosterStoreIsReadable, let active = profiles.activeProfile,
              !active.isKidsProfile, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let profile = ProgressManager.shared.profileMutationAuthority(requiredOwner: active.id) else { return nil }
        return MacAccountInteractionAuthority(owner: active.id, profile: profile, servicesGeneration: ServiceStoreScope.generation)
    }

    var isCurrent: Bool {
        let profiles = ProfileManager.shared
        return profiles.rosterStoreIsReadable && profiles.activeProfile?.id == owner
            && profiles.activeProfile?.isKidsProfile == false
            && !MacLaunchProfileAccess.requiresUnlock
            && !MacLaunchProfileAccess.isTerminating
            && ProgressManager.shared.profileMutationAuthorityIsCurrent(profile)
            && ServiceStoreScope.generation == servicesGeneration
    }
}
