import Foundation

enum MacPlaybackLifecyclePolicy {
    enum CloseReason {
        case mainWindow
        case modeSwitch
        case player
        case pictureInPicture
        case accountOrProfile
    }

    static func shouldStop(for reason: CloseReason, hasExplicitPictureInPicture: Bool,
                           isRestoringPictureInPicture: Bool = false) -> Bool {
        switch reason {
        case .mainWindow, .modeSwitch: return !hasExplicitPictureInPicture || isRestoringPictureInPicture
        case .player, .pictureInPicture, .accountOrProfile: return true
        }
    }

    static func acceptsAdmission(capturedGeneration: UInt64, currentGeneration: UInt64,
        capturedWatchTogether: WatchTogetherPlaybackHandoffIdentity,
        currentWatchTogether: WatchTogetherPlaybackHandoffIdentity, ownerIsCurrent: Bool) -> Bool {
        ownerIsCurrent && capturedGeneration == currentGeneration && capturedWatchTogether == currentWatchTogether
    }

    static func acceptsPictureInPictureCallback(controllerIsCurrent: Bool, ownerIsCurrent: Bool) -> Bool {
        controllerIsCurrent && ownerIsCurrent
    }
}

struct MacPlaybackRestorationAuthority {
    let playbackGeneration: UInt64
    let windowGeneration: UInt64

    func isCurrent(playbackGeneration: UInt64, windowGeneration: UInt64, ownerIsCurrent: Bool,
                   applicationIsTerminating: Bool, requiresUnlock: Bool) -> Bool {
        self.playbackGeneration == playbackGeneration && self.windowGeneration == windowGeneration
            && ownerIsCurrent && !applicationIsTerminating && !requiresUnlock
    }
}

struct MacPlaybackTerminationGate {
    private(set) var isTerminating = false

    mutating func begin() { isTerminating = true }
    mutating func cancel() { isTerminating = false }

    func allowsAdmission(applicationIsTerminating: Bool) -> Bool {
        !isTerminating && !applicationIsTerminating
    }
}

struct MacAutoplayCompletionGate {
    private var handledGeneration: UInt64?

    mutating func claim(completedGeneration: UInt64, currentGeneration: UInt64,
                        position: Double, duration: Double, isEligible: Bool) -> Bool {
        guard completedGeneration == currentGeneration, handledGeneration != currentGeneration,
              isEligible, AutoplayNextEpisodeSettings.isComplete(position: position, duration: duration) else {
            return false
        }
        handledGeneration = currentGeneration
        return true
    }
}
