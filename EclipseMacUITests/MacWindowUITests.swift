import AppKit
import AVFoundation
import XCTest

final class MacWindowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        if app.state == .notRunning { app.launch() } else { app.activate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Mac shell failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testLaunchHasOneResizableMainWindowAndNativeMenus() throws {
        let window = try accessibleMainWindow()
        XCTAssertEqual(app.windows.matching(identifier: "eclipse-mac-main").count, 1)
        for title in ["Eclipse", "File", "Edit", "View", "Window"] {
            XCTAssertTrue(app.menuBars.menuBarItems[title].exists, "Missing native \(title) menu")
        }
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["Open Video…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Close Window"].exists)
        app.typeKey(.escape, modifierFlags: [])
        let original = window.frame
        XCTAssertGreaterThanOrEqual(original.width, 720)
        XCTAssertGreaterThanOrEqual(original.height, 520)
        let screens = NSScreen.screens
        let primaryTop = try XCTUnwrap(screens.first?.frame.maxY)
        let visibleFrames = screens.map { screen in CGRect(x: screen.visibleFrame.minX, y: primaryTop - screen.visibleFrame.maxY, width: screen.visibleFrame.width, height: screen.visibleFrame.height) }
        let visible = try XCTUnwrap(visibleFrames.max { lhs, rhs in
            let left = lhs.intersection(original)
            let right = rhs.intersection(original)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        })
        let right = visible.maxX - original.maxX - 8
        let left = original.minX - visible.minX - 8
        let bottom = visible.maxY - original.maxY - 8
        let top = original.minY - visible.minY - 8
        let towardRight = right >= left
        let towardBottom = bottom >= top
        let width = min(120, max(0, max(right, left)))
        let height = min(80, max(0, max(bottom, top)))
        guard width >= 30 || height >= 30 else {
            let evidence = XCTAttachment(string: "The saved window already fills the available display area. Minimum size was verified; no room exists for a reversible growth test.")
            evidence.lifetime = .keepAlways
            add(evidence)
            return
        }
        let horizontal: CGFloat = towardRight ? 1 : -1
        let vertical: CGFloat = towardBottom ? 1 : -1
        let offset = CGVector(dx: towardRight ? 1 : 0, dy: towardBottom ? 1 : 0)
        let corner = window.coordinate(withNormalizedOffset: offset).withOffset(CGVector(dx: -2 * horizontal, dy: -2 * vertical))
        defer {
            let current = window.frame
            let restore = window.coordinate(withNormalizedOffset: offset).withOffset(CGVector(dx: -2 * horizontal, dy: -2 * vertical))
            restore.press(forDuration: 0.2, thenDragTo: restore.withOffset(CGVector(dx: (original.width - current.width) * horizontal, dy: (original.height - current.height) * vertical)))
            XCTAssertEqual(window.frame.width, original.width, accuracy: 2)
            XCTAssertEqual(window.frame.height, original.height, accuracy: 2)
            XCTAssertEqual(window.frame.minX, original.minX, accuracy: 2)
            XCTAssertEqual(window.frame.minY, original.minY, accuracy: 2)
        }
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: width * horizontal, dy: height * vertical)))
        if width >= 30 { XCTAssertGreaterThan(window.frame.width, original.width + 20) }
        if height >= 30 { XCTAssertGreaterThan(window.frame.height, original.height + 20) }
        XCTAssertGreaterThanOrEqual(window.frame.width, 720)
        XCTAssertGreaterThanOrEqual(window.frame.height, 520)
    }

    func testSettingsShortcutUsesExistingMainWindow() throws {
        _ = try accessibleMainWindow()
        app.typeKey(",", modifierFlags: .command)
        let back = app.buttons["mac.settings.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        XCTAssertEqual(app.windows.matching(identifier: "eclipse-mac-main").count, 1)
        back.click()
        XCTAssertFalse(back.exists)
    }

    func testReaderFindShortcutUsesSameWindowWithoutSubmittingSearch() throws {
        let window = try accessibleMainWindow()
        let mode = app.segmentedControls["mac.mode"]
        guard mode.waitForExistence(timeout: 5) else {
            throw XCTSkip("The existing sidebar is hidden or onboarding is active; mode selection was preserved.")
        }
        let reader = mode.descendants(matching: .any).matching(identifier: "Reader").firstMatch
        let media = mode.descendants(matching: .any).matching(identifier: "Media").firstMatch
        guard reader.exists, media.exists, reader.isSelected || media.isSelected else {
            throw XCTSkip("The mode control did not expose its current selection; the existing mode was preserved.")
        }
        let startedInReader = reader.isSelected
        if !startedInReader { reader.click() }
        defer { if !startedInReader, media.exists, media.isHittable { media.click() } }
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["mac.reader.search"]
        guard search.waitForExistence(timeout: 8) else {
            if app.staticTexts["Switch to a grown-up profile to discover Reader sources. Saved titles and completed downloads remain available."].exists {
                throw XCTSkip("The existing kids profile correctly blocks Reader discovery; no profile was changed.")
            }
            XCTFail("Command-F did not open Reader search")
            return
        }
        XCTAssertTrue(search.isEnabled)
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(app.windows.matching(identifier: "eclipse-mac-main").count, 1)
        XCTAssertTrue(window.exists)
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertTrue(search.exists)
    }

    func testNativePlayerControlsPublishLiveClockPauseAndPausedSeek() throws {
        let window = try accessibleMainWindow()
        guard !app.buttons["Close player"].exists else {
            throw XCTSkip("Existing playback was preserved; the UI fixture requires an idle main window.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMacPlaybackUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Eclipse-UI-fixture-\(UUID().uuidString).mov")
        try Self.makePlaybackVideo(at: url)
        let duration = 60.0
        let title = url.deletingPathExtension().lastPathComponent
        defer {
            if app.staticTexts[title].exists, app.buttons["Close player"].exists {
                let slider = app.sliders["Playback position"]
                if slider.exists, slider.isEnabled { slider.adjust(toNormalizedSliderPosition: 1) }
                app.buttons["Close player"].click()
            }
        }
        app.menuBars.menuBarItems["File"].click()
        let openVideo = app.menuItems["Open Video…"]
        XCTAssertTrue(openVideo.waitForExistence(timeout: 3))
        guard openVideo.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            throw XCTSkip("The current profile blocks local-file admission; no profile was changed.")
        }
        openVideo.click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let open = window.sheets.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        open.click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Close player"].exists)
        waitForPlayerUI("The visible player must expose Pause and a progressing real clock.") {
            guard self.app.buttons["Pause"].exists, let clock = self.playerClock() else { return false }
            return clock.elapsed >= 1 && clock.elapsed < duration && abs(clock.duration - duration) < 1.1
        }
        app.buttons["Pause"].click()
        waitForPlayerUI("Pausing must expose Play and preserve the elapsed/duration display.") {
            guard self.app.buttons["Play"].exists, let clock = self.playerClock() else { return false }
            return clock.elapsed >= 1 && abs(clock.duration - duration) < 1.1
        }
        let paused = try XCTUnwrap(playerClock())
        Thread.sleep(forTimeInterval: 0.75)
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertEqual(try XCTUnwrap(playerClock()).elapsed, paused.elapsed, accuracy: 0.1)
        let position = app.sliders["Playback position"]
        XCTAssertTrue(position.exists)
        XCTAssertTrue(position.isEnabled)
        position.adjust(toNormalizedSliderPosition: 0.4)
        waitForPlayerUI("A paused seek must redraw the real clock while Play remains available.") {
            guard self.app.buttons["Play"].exists, let clock = self.playerClock() else { return false }
            return abs(clock.elapsed - duration * 0.4) < 1.1 && abs(clock.duration - duration) < 1.1
        }
        let sought = try XCTUnwrap(playerClock())
        Thread.sleep(forTimeInterval: 0.75)
        XCTAssertEqual(try XCTUnwrap(playerClock()).elapsed, sought.elapsed, accuracy: 0.1)
        app.buttons["Play"].click()
        waitForPlayerUI("Resuming must expose Pause and advance the clock from the sought position.") {
            self.app.buttons["Pause"].exists && (self.playerClock()?.elapsed ?? 0) > sought.elapsed + 0.5
        }
        XCTAssertEqual(app.windows.matching(identifier: "eclipse-mac-main").count, 1)
    }

    private func playerClock() -> (elapsed: Double, duration: Double)? {
        for element in app.staticTexts.allElementsBoundByIndex {
            let text = element.label
            let halves = text.components(separatedBy: " / ")
            guard halves.count == 2, let elapsed = clockSeconds(halves[0]),
                  let trailing = clockSeconds(halves[1].replacingOccurrences(of: "−", with: "")) else { continue }
            return (elapsed, halves[1].contains("−") ? elapsed + trailing : trailing)
        }
        return nil
    }

    private func clockSeconds(_ value: String) -> Double? {
        let components = value.split(separator: ":")
        guard (2...3).contains(components.count) else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == components.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    private func waitForPlayerUI(_ message: String, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 15)
        if result != .completed {
            let values = app.staticTexts.allElementsBoundByIndex.map(\.label)
            XCTFail("\(message) Visible text: \(values)")
        }
    }

    private func accessibleMainWindow() throws -> XCUIElement {
        let window = app.windows["eclipse-mac-main"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        if app.otherElements["mac.profile.locked"].exists || app.staticTexts["Unlock your profile to continue."].exists || app.secureTextFields.count > 0 {
            throw XCTSkip("The existing profile requires its owner's PIN; the test does not unlock or alter it.")
        }
        if window.sheets.count > 0 {
            throw XCTSkip("An existing onboarding, profile, or account sheet requires user choices; the test leaves it intact.")
        }
        return window
    }

    private static func makePlaybackVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
        let width = 320
        let height = 180
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
        for frame in 0..<600 {
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
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
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
