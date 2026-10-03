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
        let captionTrack = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Synthetic timing cues")).firstMatch
        if selectTrack.waitForExistence(timeout: 2) {
            selectTrack.tap()
            if !captionTrack.waitForExistence(timeout: 3), selectTrack.exists, selectTrack.isHittable {
                selectTrack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
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
            minus.tap()
            try assertDelay(-0.25, value: value, plus: plus, minus: minus)
            plus.tap()
            try assertDelay(0, value: value, plus: plus, minus: minus)
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

final class EclipseRatingsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = [
            "-experimentalICloudSyncEnabled", "NO",
            "-experimentalGoogleDriveSyncEnabled", "NO",
            "-experimentalOneDriveSyncEnabled", "NO",
            "-eclipseSyncSettingsAcrossDevicesV1", "NO"
        ]
        app.launchEnvironment["ECLIPSE_DEBUG_RATINGS_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.segmentedControls["ratings.fixture.season"].waitForExistence(timeout: 30), app.debugDescription)
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testSeasonRatingsAndNotesRemainIndependentAfterReloadAndScopeToggle() throws {
        try expandRating()
        try assertReview(rating: "8/10", note: "Season one fixture note", scope: "Season 1")
        try selectSeason(2)
        try assertReview(rating: "No rating", note: "", scope: "Season 2")

        let star = app.buttons["ratings.star.9"]
        try reveal(star)
        star.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let note = app.textViews["ratings.notes"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription)
        note.tap()
        note.typeText("Season two independent note")
        let done = app.buttons["ratings.fixture.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
        try assertReview(rating: "9/10", note: "Season two independent note", scope: "Season 2")

        try selectSeason(1)
        try assertReview(rating: "8/10", note: "Season one fixture note", scope: "Season 1")
        try selectSeason(2)
        try assertReview(rating: "9/10", note: "Season two independent note", scope: "Season 2")

        let reload = app.buttons["ratings.fixture.reload"]
        try reveal(reload)
        reload.tap()
        try expandRating()
        try assertReview(rating: "9/10", note: "Season two independent note", scope: "Season 2")
        try selectSeason(1)
        try assertReview(rating: "8/10", note: "Season one fixture note", scope: "Season 1")

        try openRatingsSettings()
        let seasonOne = try revealEntry("tv:1396:season:1")
        XCTAssertTrue(seasonOne.staticTexts["Season one fixture note"].exists, app.debugDescription)
        let seasonTwo = try revealEntry("tv:1396:season:2")
        XCTAssertTrue(seasonTwo.staticTexts["Season two independent note"].exists, app.debugDescription)
        let lock = app.switches["settings.ratings.follow-season"]
        try reveal(lock)
        XCTAssertEqual(lock.value as? String, "1", app.debugDescription)
        tapToggle(lock)
        assertToggleValue("0")
        try closeRatingsSettings()
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")
        try selectSeason(2)
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")

        try openRatingsSettings()
        try reveal(lock)
        tapToggle(lock)
        assertToggleValue("1")
        try closeRatingsSettings()
        try assertReview(rating: "9/10", note: "Season two independent note", scope: "Season 2")
    }

    func testRatingsSettingsIncludesSeasonWholeShowNoteOnlyAndLegacyEntries() throws {
        try openRatingsSettings()
        let lock = app.switches["settings.ratings.follow-season"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(lock.value as? String, "1", "Season locking must default to on in a new settings store.")

        let movie = try revealEntry("movie:550")
        XCTAssertTrue(movie.staticTexts["Ratings Fixture Movie"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(movie.staticTexts["Movie note without a rating"].exists, app.debugDescription)
        XCTAssertTrue(movie.staticTexts["Movie"].exists, app.debugDescription)

        let show = try revealEntry("tv:1396")
        XCTAssertTrue(show.staticTexts["Ratings Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole-show fixture note"].exists, app.debugDescription)

        let season = try revealEntry("tv:1396:season:1")
        XCTAssertTrue(season.staticTexts["Season 1"].exists, app.debugDescription)
        XCTAssertTrue(season.staticTexts["Season one fixture note"].exists, app.debugDescription)

        let legacy = try revealEntry("98211")
        XCTAssertTrue(legacy.staticTexts["Legacy ID 98211"].exists, app.debugDescription)
        XCTAssertTrue(legacy.staticTexts["Legacy · Title Type Unknown"].exists, app.debugDescription)
        XCTAssertTrue(legacy.staticTexts["Legacy fixture note"].exists, app.debugDescription)
    }

    private func expandRating() throws {
        let expand = app.buttons["ratings.expand"]
        try reveal(expand)
        expand.tap()
        XCTAssertTrue(app.staticTexts["ratings.value"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func selectSeason(_ season: Int) throws {
        let picker = app.segmentedControls["ratings.fixture.season"]
        try reveal(picker)
        let button = picker.buttons["Season \(season)"]
        XCTAssertTrue(button.exists, app.debugDescription)
        button.tap()
        XCTAssertTrue(button.isSelected, app.debugDescription)
    }

    private func assertReview(rating: String, note: String, scope: String) throws {
        let value = app.staticTexts["ratings.value"]
        try reveal(value)
        let scopeLabel = app.staticTexts["ratings.scope"]
        let notes = app.textViews["ratings.notes"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            value.exists && value.label == rating && scopeLabel.label == scope && (notes.value as? String) == note
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 8), .completed, app.debugDescription)
    }

    private func openRatingsSettings() throws {
        let settings = app.buttons["ratings.fixture.settings"]
        try reveal(settings)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Ratings & Notes"].waitForExistence(timeout: 8), app.debugDescription)
    }

    private func closeRatingsSettings() throws {
        let back = app.navigationBars["Ratings & Notes"].buttons.firstMatch
        XCTAssertTrue(back.exists, app.debugDescription)
        back.tap()
        XCTAssertTrue(app.segmentedControls["ratings.fixture.season"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func assertToggleValue(_ expected: String) {
        let toggle = app.switches["settings.ratings.follow-season"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.exists && (toggle.value as? String) == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, app.debugDescription)
    }

    private func tapToggle(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        if control.exists && control.isHittable {
            control.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        }
    }

    private func revealEntry(_ key: String) throws -> XCUIElement {
        let row = app.descendants(matching: .any).matching(identifier: "settings.ratings.entry.\(key)").firstMatch
        try reveal(row)
        XCTAssertTrue(row.exists, app.debugDescription)
        return row
    }

    private func reveal(_ element: XCUIElement) throws {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let viewport = app.windows.firstMatch.frame
            let frame = element.exists ? element.frame : .zero
            let moveDown = frame.height > 0 && frame.midY < viewport.midY
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.28))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75))
            (moveDown ? upper : lower).press(forDuration: 0.1, thenDragTo: moveDown ? lower : upper)
        }
        XCTFail("The requested ratings control is unavailable: \(element.debugDescription)")
        throw RatingsUIError.unavailable
    }

    private enum RatingsUIError: Error {
        case unavailable
    }
}
