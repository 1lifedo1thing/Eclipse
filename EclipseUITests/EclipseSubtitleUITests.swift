import XCTest

final class EclipseSubtitleUITests: XCTestCase {
    private let app = XCUIApplication()
    private var originalDelay: Double?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = [
            "-experimentalICloudSyncEnabled", "NO",
            "-experimentalGoogleDriveSyncEnabled", "NO",
            "-experimentalOneDriveSyncEnabled", "NO",
            "-eclipseSyncSettingsAcrossDevicesV1", "NO"
        ]
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let originalDelay {
            do {
                try restoreDelay(originalDelay)
            } catch {
                XCTFail("Could not restore subtitle timing through the player UI: \(error)")
            }
        }
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let close = app.buttons["player.close"]
        if close.exists && close.isHittable { close.tap() }
        originalDelay = nil
    }

    func testMPVSubtitleQuarterSecondControlsStayOpenAndPreservePlayback() throws {
        guard let fixture = ProcessInfo.processInfo.environment["ECLIPSE_UI_FIXTURE_URL"],
              let url = URL(string: fixture), url.isFileURL else {
            throw XCTSkip("Set ECLIPSE_UI_FIXTURE_URL to the simulator-accessible generated captioned fixture.")
        }
        app.launchEnvironment["ECLIPSE_DEBUG_AUTOPLAY_URL"] = fixture
        app.launchEnvironment["ECLIPSE_DEBUG_HWDEC"] = "no"
        app.launch()
        let subtitles = app.buttons["player.subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 25), app.debugDescription)
        if !subtitles.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(subtitles.isHittable)
        subtitles.tap()
        let selectTrack = app.buttons["Select Track"]
        if selectTrack.waitForExistence(timeout: 2) { selectTrack.tap() }
        let captionTrack = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Synthetic timing cues")).firstMatch
        XCTAssertTrue(captionTrack.waitForExistence(timeout: 8), app.debugDescription)
        captionTrack.tap()
        let timing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Subtitle Delay")).firstMatch
        if !timing.waitForExistence(timeout: 2) {
            if !subtitles.exists || !subtitles.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            }
            XCTAssertTrue(subtitles.waitForExistence(timeout: 5), app.debugDescription)
            subtitles.tap()
        }
        XCTAssertTrue(timing.waitForExistence(timeout: 8), app.debugDescription)
        timing.tap()
        let value = app.staticTexts["player.subtitleDelay.value"]
        let plus = app.buttons["player.subtitleDelay.plus"]
        let minus = app.buttons["player.subtitleDelay.minus"]
        XCTAssertTrue(value.waitForExistence(timeout: 5), app.debugDescription)
        let original = try readDelay(value)
        originalDelay = original
        let first = original <= 59.5 ? plus : minus
        let reverse = original <= 59.5 ? minus : plus
        let delta = original <= 59.5 ? 0.25 : -0.25
        first.tap()
        try assertDelay(original + delta, value: value, plus: plus, minus: minus)
        first.tap()
        try assertDelay(original + 2 * delta, value: value, plus: plus, minus: minus)
        reverse.tap()
        try assertDelay(original + delta, value: value, plus: plus, minus: minus)
        reverse.tap()
        try assertDelay(original, value: value, plus: plus, minus: minus)
        if original == 0 {
            plus.tap()
            app.buttons["Reset"].tap()
            try assertDelay(0, value: value, plus: plus, minus: minus)
        }
        originalDelay = nil
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "MPV persistent subtitle timing controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Done"].tap()
        XCTAssertFalse(value.exists)
        let playback = app.buttons["player.playPause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        XCTAssertEqual(playback.label, "Pause", "Timing adjustments must leave ongoing playback playing.")
        playback.tap()
        XCTAssertEqual(playback.label, "Play")
        playback.tap()
        XCTAssertEqual(playback.label, "Pause")
    }

    private enum RestorationError: Error {
        case unavailableControl
        case unexpectedDelay
    }

    private func restoreDelay(_ original: Double) throws {
        let value = app.staticTexts["player.subtitleDelay.value"]
        if !value.exists {
            if app.state == .notRunning { app.launch() }
            let subtitles = app.buttons["player.subtitles"]
            guard subtitles.waitForExistence(timeout: 25) else { throw RestorationError.unavailableControl }
            if !subtitles.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            }
            guard subtitles.isHittable else { throw RestorationError.unavailableControl }
            subtitles.tap()
            let timing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Subtitle Delay")).firstMatch
            guard timing.waitForExistence(timeout: 5) else { throw RestorationError.unavailableControl }
            timing.tap()
            guard value.waitForExistence(timeout: 5) else { throw RestorationError.unavailableControl }
        }
        let current = try readDelay(value)
        let steps = abs(current - original) / 0.25
        guard steps.isFinite, steps <= 2, abs(steps.rounded() - steps) < 0.001 else {
            throw RestorationError.unexpectedDelay
        }
        let restore = app.buttons[current > original ? "player.subtitleDelay.minus" : "player.subtitleDelay.plus"]
        for _ in 0..<Int(steps.rounded()) {
            guard restore.exists, restore.isEnabled, restore.isHittable else { throw RestorationError.unavailableControl }
            restore.tap()
        }
        guard abs(try readDelay(value) - original) < 0.001 else { throw RestorationError.unexpectedDelay }
    }

    private func readDelay(_ element: XCUIElement) throws -> Double {
        let raw = (element.value as? String) ?? element.label
        return try XCTUnwrap(Double(raw.replacingOccurrences(of: " s", with: "")))
    }

    private func assertDelay(_ expected: Double, value: XCUIElement, plus: XCUIElement, minus: XCUIElement) throws {
        XCTAssertTrue(value.exists)
        XCTAssertTrue(plus.isHittable)
        XCTAssertTrue(minus.isHittable)
        XCTAssertEqual(try readDelay(value), expected, accuracy: 0.001)
        XCTAssertFalse(app.staticTexts["Earlier"].exists)
        XCTAssertFalse(app.staticTexts["Later"].exists)
    }
}
