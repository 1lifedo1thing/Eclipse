import Foundation

struct WatchTogetherPlaybackHandoffIdentity: Equatable {
    let sessionID: UUID?
    let sessionGeneration: UInt64
    let mediaRevision: UInt64?
    let mediaIdentifier: String?
}

