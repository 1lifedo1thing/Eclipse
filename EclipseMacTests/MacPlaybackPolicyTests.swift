import Foundation
import XCTest
@testable import EclipseMac

final class MacPlaybackPolicyTests: XCTestCase {
    func testAutomaticQualityAdaptsAndManualQualityStaysSelected() {
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .nominal), .sharp)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .fair), .balanced)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.auto, thermal: .serious), .lowHeat)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.sharp, thermal: .critical), .sharp)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.effectiveProfile(.lowHeat, thermal: .nominal), .lowHeat)
    }

    func testUpscalingTargetsRespectDisplayAndQualityScale() {
        let source = CGSize(width: 1920, height: 1080)
        let bounds = CGSize(width: 2560, height: 1440)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .sharp, mode: .upscaleTo4K,
            source: source, bounds: bounds, backingScale: 2), 1.5, accuracy: 0.001)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .sharp, mode: .oneLevelAlways,
            source: source, bounds: bounds, backingScale: 2), 1, accuracy: 0.001)
        XCTAssertEqual(MacPlaybackVideoQualityPolicy.contentsScale(profile: .lowHeat, mode: .auto,
            source: source, bounds: bounds, backingScale: 2), 1.24, accuracy: 0.001)
    }

    func testBrowserFlowCannotPublishAfterCloseReopenCancelOrOwnerChange() {
        func accepted(window: UInt64 = 1, flow: UInt64 = 1, owner: Bool = true,
                      services: Bool = true, visible: Bool = true, cancelled: Bool = false) -> Bool {
            MacProviderBrowserAuthorityPolicy.accepts(profileIsCurrent: owner, servicesAreCurrent: services,
                capturedWindow: 1, currentWindow: window, capturedFlow: 1, currentFlow: flow,
                allowsPresentation: visible, isCancelled: cancelled)
        }
        XCTAssertTrue(accepted())
        XCTAssertFalse(accepted(window: 3))
        XCTAssertFalse(accepted(flow: 3))
        XCTAssertFalse(accepted(owner: false))
        XCTAssertFalse(accepted(services: false))
        XCTAssertFalse(accepted(visible: false))
        XCTAssertFalse(accepted(cancelled: true))
    }

    func testMacDefaultsAndAutomaticFallback() {
        XCTAssertEqual(PlaybackEngine.defaultSelection(deviceFamily: .mac), .mpv)
        let automatic = PlaybackLaunchPlan.make(selection: .automatic, deviceFamily: .mac)
        XCTAssertEqual(automatic.primary, .avPlayer)
        XCTAssertEqual(automatic.preStartFallback, .mpv)
        XCTAssertNil(PlaybackLaunchPlan.make(selection: .mpv, deviceFamily: .mac).preStartFallback)
        XCTAssertEqual(TypedPluginPlaybackEnginePolicy.effectiveEngine(requested: .automatic, sourceKind: .skyStream), .mpv)
    }

    func testMainWindowAndModeChangesOnlyPreserveExplicitPictureInPicture() {
        for reason in [MacPlaybackLifecyclePolicy.CloseReason.mainWindow, .modeSwitch] {
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: false))
            XCTAssertFalse(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true))
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true,
                isRestoringPictureInPicture: true))
        }
        for reason in [MacPlaybackLifecyclePolicy.CloseReason.player, .pictureInPicture, .accountOrProfile] {
            XCTAssertTrue(MacPlaybackLifecyclePolicy.shouldStop(for: reason, hasExplicitPictureInPicture: true))
        }
    }

    func testClosedWindowOrWatchTogetherRoundTripCannotReadmitPendingPlayback() {
        let initial = WatchTogetherPlaybackHandoffIdentity(sessionID: nil, sessionGeneration: 1, mediaRevision: nil, mediaIdentifier: nil)
        let afterLeave = WatchTogetherPlaybackHandoffIdentity(sessionID: nil, sessionGeneration: 3, mediaRevision: nil, mediaIdentifier: nil)
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 3,
            capturedWatchTogether: initial, currentWatchTogether: initial, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 1,
            capturedWatchTogether: initial, currentWatchTogether: afterLeave, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsAdmission(capturedGeneration: 1, currentGeneration: 1,
            capturedWatchTogether: initial, currentWatchTogether: initial, ownerIsCurrent: false))
    }

    func testRetiredPictureInPictureCannotRestoreOrStopNewPlayback() {
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: false, ownerIsCurrent: true))
        XCTAssertFalse(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: true, ownerIsCurrent: false))
        XCTAssertTrue(MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(controllerIsCurrent: true, ownerIsCurrent: true))
    }

    @MainActor
    func testDelayedPictureInPictureRestoreRejectsCloseReopenAndModeReplacement() async {
        let restoration = MacPlaybackRestorationAuthority(playbackGeneration: 4, windowGeneration: 7)
        XCTAssertTrue(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: false, requiresUnlock: false))
        for replacement in [(playback: UInt64(4), window: UInt64(9)), (playback: UInt64(5), window: UInt64(7))] {
            let delayedCompletion = Task { @MainActor in
                await Task.yield()
                return restoration.isCurrent(playbackGeneration: replacement.playback,
                    windowGeneration: replacement.window, ownerIsCurrent: true,
                    applicationIsTerminating: false, requiresUnlock: false)
            }
            let accepted = await delayedCompletion.value
            XCTAssertFalse(accepted)
        }
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: false,
            applicationIsTerminating: false, requiresUnlock: false))
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: true, requiresUnlock: false))
        XCTAssertFalse(restoration.isCurrent(playbackGeneration: 4, windowGeneration: 7, ownerIsCurrent: true,
            applicationIsTerminating: false, requiresUnlock: true))
    }

    @MainActor
    func testRetirementTimeoutCannotReopenAdmissionBeforeGlobalQuitCancellation() async {
        var gate = MacPlaybackTerminationGate()
        gate.begin()
        let retirement = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        defer { retirement.cancel() }
        let finished = await MacPlaybackShutdownBarrier.wait(for: [retirement], timeout: 0.01)
        XCTAssertFalse(finished)
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: true))
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: false))
        gate.cancel()
        XCTAssertFalse(gate.allowsAdmission(applicationIsTerminating: true))
        XCTAssertTrue(gate.allowsAdmission(applicationIsTerminating: false))
    }

    @MainActor
    func testShutdownWaitsForRetirementAndBoundsUnresponsiveWork() async {
        let finished = Task<Void, Never> {}
        let successful = await MacPlaybackShutdownBarrier.wait(for: [finished], timeout: 1)
        XCTAssertTrue(successful)
        let slow = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let bounded = await MacPlaybackShutdownBarrier.wait(for: [slow], timeout: 0.01)
        XCTAssertFalse(bounded)
        slow.cancel()
        await slow.value
    }

    func testExternalHandoffRejectsPrivateTransportAndPreservesOrdinaryHTTP() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example/video.mp4"))
        XCTAssertTrue(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .stremio, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .nuvio, autoMode: false, watchTogether: false))
        for headers in [false, true] {
            XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: headers, hasProxyOwnership: true,
                sourceKind: .skyStream, autoMode: false, watchTogether: false))
        }
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: true, hasProxyOwnership: false,
            sourceKind: .service, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: try XCTUnwrap(URL(string: "http://127.0.0.1:9000/video")),
            hasHeaders: false, hasProxyOwnership: false, sourceKind: .stremio, autoMode: false, watchTogether: false))
        XCTAssertFalse(MacExternalPlaybackPolicy.allows(url: url, hasHeaders: false, hasProxyOwnership: false,
            sourceKind: .service, autoMode: true, watchTogether: false))
    }
}
