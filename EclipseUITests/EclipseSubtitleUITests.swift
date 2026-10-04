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
        try reveal(lock, towardTop: true)
        XCTAssertEqual(lock.value as? String, "1", app.debugDescription)
        tapToggle(lock)
        assertToggleValue("0")
        try closeRatingsSettings()
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")
        try selectSeason(2)
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")

        try openRatingsSettings()
        try reveal(lock, towardTop: true)
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

        let matchedShow = try revealEntry("tv:98211")
        XCTAssertTrue(matchedShow.staticTexts["Legacy Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(matchedShow.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(matchedShow.staticTexts["Legacy fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98211")

        let legacy = try revealEntry("98212")
        XCTAssertTrue(legacy.staticTexts["Collision fixture note"].exists, app.debugDescription)
    }

    func testAutomaticMatchingPreservesKnownLegacyReviewAfterReload() throws {
        try openRatingsSettings()
        let show = try revealEntry("tv:98211")
        XCTAssertTrue(show.staticTexts["Legacy Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["4 / 10"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["Legacy fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98211")

        try reloadRatingsSettings()
        let savedShow = try revealEntry("tv:98211")
        XCTAssertTrue(savedShow.staticTexts["Legacy Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["4 / 10"].exists, app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["Legacy fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98211")
    }

    func testAttachAmbiguousLegacyReviewUsesChosenTitleAfterReload() throws {
        try openRatingsSettings()
        _ = try revealEntry("98212")
        let movieChoice = app.buttons["settings.ratings.attach.98212.movie:98212"]
        let showChoice = app.buttons["settings.ratings.attach.98212.tv:98212"]
        try reveal(movieChoice)
        XCTAssertTrue(movieChoice.exists, app.debugDescription)
        try reveal(showChoice)
        showChoice.tap()

        let show = try revealEntry("tv:98212")
        XCTAssertTrue(show.staticTexts["Collision Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["7 / 10"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["Collision fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98212")
        assertEntryAbsent("movie:98212")

        try reloadRatingsSettings()
        let savedShow = try revealEntry("tv:98212")
        XCTAssertTrue(savedShow.staticTexts["Collision Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["7 / 10"].exists, app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["Collision fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98212")
        assertEntryAbsent("movie:98212")
    }

    func testAutomaticMatchingRemovesEqualLegacyCopyAfterReload() throws {
        try openRatingsSettings()
        let show = try revealEntry("tv:1396")
        XCTAssertTrue(show.staticTexts["Ratings Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(show.staticTexts["6 / 10"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole-show fixture note"].exists, app.debugDescription)
        assertEntryAbsent("1396")

        try reloadRatingsSettings()
        let savedShow = try revealEntry("tv:1396")
        XCTAssertTrue(savedShow.staticTexts["Ratings Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["6 / 10"].exists, app.debugDescription)
        XCTAssertTrue(savedShow.staticTexts["Whole-show fixture note"].exists, app.debugDescription)
        assertEntryAbsent("1396")
    }

    func testAutomaticMatchingPreservesConflictsAndReaderCollisionsAfterReload() throws {
        try openRatingsSettings()
        try assertExcludedLegacyReviews()

        try reloadRatingsSettings()
        try assertExcludedLegacyReviews()
    }

    func testBulkLookupMatchesUniqueRemoteTitlesAndPreservesUncertainReviews() throws {
        try openRatingsSettings()
        let legacy = try revealEntry("98215")
        XCTAssertTrue(legacy.staticTexts["7.5 / 10"].exists, app.debugDescription)
        XCTAssertTrue(legacy.staticTexts["Bulk lookup fixture note"].exists, app.debugDescription)

        let lookup = app.buttons["settings.ratings.lookup-remaining"]
        try reveal(lookup, towardTop: true)
        let lookupLabel = app.staticTexts["Look Up Remaining Reviews"]
        let frame = lookupLabel.exists ? lookupLabel.frame : lookup.frame
        XCTAssertGreaterThan(frame.width, 0, app.debugDescription)
        XCTAssertGreaterThan(frame.height, 0, app.debugDescription)
        XCTAssertGreaterThanOrEqual(frame.minY, app.navigationBars["Ratings & Notes"].frame.maxY, app.debugDescription)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY)), app.debugDescription)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let summary = app.staticTexts["settings.ratings.lookup-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(summary.label.hasPrefix("Matched 1 older reviews"), app.debugDescription)
        try assertBulkLookupReviews()

        try reloadRatingsSettings()
        try assertBulkLookupReviews()
    }

    func testDetailAttachEqualWholeShowLegacyReviewRemovesDuplicateAfterReload() throws {
        try expandRating()
        try assertReview(rating: "8/10", note: "Season one fixture note", scope: "Season 1")
        let attach = app.buttons["ratings.attach-legacy"]
        try reveal(attach)
        XCTAssertTrue(attach.exists, app.debugDescription)

        let changeScope = app.buttons["ratings.change-scope"]
        try reveal(changeScope)
        changeScope.tap()
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")
        try reveal(attach)
        attach.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !attach.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, app.debugDescription)
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")

        let reload = app.buttons["ratings.fixture.reload"]
        try reveal(reload)
        reload.tap()
        try expandRating()
        try reveal(changeScope)
        changeScope.tap()
        try assertReview(rating: "6/10", note: "Whole-show fixture note", scope: "Whole Show")
        XCTAssertFalse(attach.exists, app.debugDescription)

        try openRatingsSettings()
        let show = try revealEntry("tv:1396")
        XCTAssertTrue(show.staticTexts["Ratings Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["6 / 10"].exists, app.debugDescription)
        XCTAssertTrue(show.staticTexts["Whole-show fixture note"].exists, app.debugDescription)
        assertEntryAbsent("1396")
    }

    private func expandRating() throws {
        let expand = app.buttons["ratings.expand"]
        try reveal(expand)
        expand.tap()
        XCTAssertTrue(app.staticTexts["ratings.value"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func assertExcludedLegacyReviews() throws {
        let conflictingLegacy = try revealEntry("98213")
        XCTAssertTrue(conflictingLegacy.staticTexts["4 / 10"].exists, app.debugDescription)
        XCTAssertTrue(conflictingLegacy.staticTexts["Older conflicting note"].exists, app.debugDescription)

        let existingShow = try revealEntry("tv:98213")
        XCTAssertTrue(existingShow.staticTexts["Conflict Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(existingShow.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(existingShow.staticTexts["8 / 10"].exists, app.debugDescription)
        XCTAssertTrue(existingShow.staticTexts["Current conflicting note"].exists, app.debugDescription)

        let readerCollision = try revealEntry("98214")
        XCTAssertTrue(readerCollision.staticTexts["5 / 10"].exists, app.debugDescription)
        XCTAssertTrue(readerCollision.staticTexts["Reader collision note"].exists, app.debugDescription)
        assertEntryAbsent("tv:98214")
    }

    private func assertBulkLookupReviews() throws {
        let ambiguousLegacy = try revealEntry("98212")
        XCTAssertTrue(ambiguousLegacy.staticTexts["7 / 10"].exists, app.debugDescription)
        XCTAssertTrue(ambiguousLegacy.staticTexts["Collision fixture note"].exists, app.debugDescription)
        assertEntryAbsent("movie:98212")
        assertEntryAbsent("tv:98212")

        try assertExcludedLegacyReviews()

        let remoteShow = try revealEntry("tv:98215")
        XCTAssertTrue(remoteShow.staticTexts["Remote Fixture Show"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(remoteShow.staticTexts["Whole Show"].exists, app.debugDescription)
        XCTAssertTrue(remoteShow.staticTexts["7.5 / 10"].exists, app.debugDescription)
        XCTAssertTrue(remoteShow.staticTexts["Bulk lookup fixture note"].exists, app.debugDescription)
        assertEntryAbsent("98215")

        let uncertainLegacy = try revealEntry("98216")
        XCTAssertTrue(uncertainLegacy.staticTexts["6 / 10"].exists, app.debugDescription)
        XCTAssertTrue(uncertainLegacy.staticTexts["Uncertain lookup fixture note"].exists, app.debugDescription)
        assertEntryAbsent("movie:98216")
        assertEntryAbsent("tv:98216")
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

    private func reloadRatingsSettings() throws {
        try closeRatingsSettings()
        let reload = app.buttons["ratings.fixture.reload"]
        try reveal(reload)
        reload.tap()
        try openRatingsSettings()
    }

    private func assertEntryAbsent(_ key: String) {
        let row = app.descendants(matching: .any).matching(identifier: "settings.ratings.entry.\(key)").firstMatch
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !row.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, app.debugDescription)
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

    private func reveal(_ element: XCUIElement, towardTop: Bool = false) throws {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let viewport = app.windows.firstMatch.frame
            let frame = element.exists ? element.frame : .zero
            let moveDown = frame.height > 0 ? frame.midY < viewport.midY : towardTop
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
