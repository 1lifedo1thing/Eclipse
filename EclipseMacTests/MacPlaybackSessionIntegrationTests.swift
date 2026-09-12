import AppKit
import AVFoundation
import Combine
import XCTest
@testable import EclipseMac

@MainActor
final class MacPlaybackSessionIntegrationTests: XCTestCase {
    func testMPVSessionPublishesRealClockAndStopsExactlyOnce() async throws {
        try await exercise(engine: .mpv)
    }

    func testAVPlayerSessionPublishesRealClockAndStopsExactlyOnce() async throws {
        try await exercise(engine: .avPlayer)
    }

    private func exercise(engine: PlaybackEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMacSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.mov")
        try await Task.detached(priority: .utility) { try Self.makeVideo(at: url) }.value
        let asset = AVURLAsset(url: url)
        let fixtureDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(fixtureDuration, 12, accuracy: 0.1)
        let suite = "EclipseMacSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resume = MacLocalPlaybackResumeStore(directory: directory.appendingPathComponent("Resume"))
        let owner = ProfileManager.shared.activeProfileID
        let authority = try XCTUnwrap(ProgressManager.shared.profileMutationAuthority(requiredOwner: owner))
        let request = PlaybackRequest(url: url,
            preset: PlayerPreset(id: .sdrRec709, title: "Fixture", summary: "", stream: nil, commands: []),
            mediaSelectionIntent: .init(preferredAudioLanguage: nil, preferredSubtitleLanguage: nil, subtitlesEnabled: false),
            title: "Native session fixture")
        let session = MacPlaybackSession(request: request, engine: engine, owner: owner, authority: authority,
            defaults: defaults, localResumeStore: resume)
        var publicationCount = 0
        let observation = session.objectWillChange.sink { publicationCount += 1 }
        defer { observation.cancel() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.surface.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        window.contentView = session.surface
        window.orderFront(nil)
        var closeCount = 0
        session.onClose = { closeCount += 1 }
        defer {
            session.stop()
            window.contentView = nil
            window.close()
        }
        session.start()
        do {
            try await wait("\(engine) must publish readiness, duration, and a progressing clock.", session: session) {
                session.isReady && session.isPlaying && session.duration > 11.5 && session.position > 0.5
            }
            XCTAssertNil(session.request.mediaInfo)
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(session.engine, engine)
            XCTAssertEqual(session.duration, fixtureDuration, accuracy: 0.2)
            XCTAssertGreaterThan(session.position, 0.5)
            XCTAssertGreaterThan(publicationCount, 0)
            session.setPlaying(false, broadcast: false)
            try await Task.sleep(nanoseconds: 350_000_000)
            let pausedPosition = session.position
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertFalse(session.isPlaying)
            XCTAssertEqual(session.position, pausedPosition, accuracy: 0.15)
            session.seek(to: 5, broadcast: false)
            try await wait("\(engine) must publish a paused seek through the real renderer.", session: session) {
                abs(session.position - 5) < 0.35 && !session.isPlaying
            }
            let alternate: PlaybackEngine = engine == .mpv ? .avPlayer : .mpv
            for handoffEngine in [alternate, engine] {
                session.retryWithAlternateEngine()
                try await wait("An explicit engine handoff must preserve paused position and intent.", session: session) {
                    session.engine == handoffEngine && session.isReady && !session.isPlaying
                        && abs(session.position - 5) < 0.35
                }
                let handoffPosition = session.position
                try await Task.sleep(nanoseconds: 450_000_000)
                XCTAssertFalse(session.isPlaying)
                XCTAssertEqual(session.position, handoffPosition, accuracy: 0.15)
            }
            session.setPlaying(true, broadcast: false)
            try await wait("\(engine) must resume the same clock after a seek.", session: session) {
                session.isPlaying && session.position > 5.5
            }
            session.stop()
            session.stop()
            var shutdownCompleted = false
            let shutdown = Task { await session.waitUntilStopped(); shutdownCompleted = true }
            defer { shutdown.cancel() }
            try await wait("\(engine) must retire its renderer within the shutdown deadline.", session: session,
                failsOnPlaybackError: false) { shutdownCompleted }
            XCTAssertFalse(session.isCurrentOwner)
            XCTAssertEqual(closeCount, 1)
            let stoppedPosition = session.position
            session.start()
            session.setPlaying(true, broadcast: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(session.position, stoppedPosition, accuracy: 0.01)
            XCTAssertEqual(closeCount, 1)
            XCTAssertGreaterThan(resume.currentTime(for: url, owner: owner), 5)
            XCTAssertTrue(resume.flushForMacTermination())
        } catch {
            session.stop()
            throw error
        }
    }

    private func wait(_ message: String, session: MacPlaybackSession, failsOnPlaybackError: Bool = true,
                      condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            if failsOnPlaybackError, let error = session.errorMessage {
                XCTFail("\(message) Player error: \(error)")
                throw URLError(.cannotDecodeContentData)
            }
            session.surface.window?.contentView?.layoutSubtreeIfNeeded()
            session.surface.window?.displayIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard condition() else {
            XCTFail("\(message) ready=\(session.isReady) playing=\(session.isPlaying) position=\(session.position) duration=\(session.duration)")
            throw URLError(.timedOut)
        }
    }

    nonisolated private static func makeVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
        let width = 640
        let height = 360
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(20)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard Date() < deadline, input.isReadyForMoreMediaData else { throw writer.error ?? URLError(.timedOut) }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                nil, &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer,
                CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw URLError(.cannotCreateFile) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw URLError(.cannotCreateFile)
            }
            let pixels = base.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
            for row in 0..<height {
                for column in 0..<width {
                    pixels[row * stride + column] = 0xFF000000 | UInt32((frame * 2) % 255) << 16
                        | UInt32(column % 255) << 8 | UInt32(row % 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? URLError(.cannotWriteToFile)
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw writer.error ?? URLError(.cannotWriteToFile)
        }
    }
}
