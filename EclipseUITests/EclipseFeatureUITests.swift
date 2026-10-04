import XCTest

final class EclipseFeatureUITests: XCTestCase {
    private let app = XCUIApplication()
    private var restorations: [() throws -> Void] = []
    private var activeSettingsPage: String?
    private var suppressScreenshots = false

    private enum UIInteractionError: Error {
        case unavailable(String)
        case unexpectedValue(String)
        case timedOut(String)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        suppressScreenshots = false
        app.launchArguments = [
            "-experimentalICloudSyncEnabled", "NO",
            "-experimentalGoogleDriveSyncEnabled", "NO",
            "-experimentalOneDriveSyncEnabled", "NO",
            "-eclipseSyncSettingsAcrossDevicesV1", "NO"
        ]
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        capture(name)
        var failures: [String] = []
        for restore in restorations.reversed() {
            do {
                try restore()
            } catch {
                failures.append(String(describing: error))
            }
        }
        restorations = []
        XCTAssertTrue(failures.isEmpty, "Could not restore the original settings through the UI: \(failures.joined(separator: "; "))")
    }

    func testQuickActionsOpensSettingsAndFindsAutoplay() throws {
        try openSettingFromLaunch("Autoplay Next Episode")
        try verifyToggleRoundTrip(label: "Autoplay Next Episode", search: "Autoplay Next Episode")
    }

    func testMPVReturnsFromBackgroundWithoutPictureInPicture() throws {
        guard let fixture = ProcessInfo.processInfo.environment["ECLIPSE_UI_FIXTURE_URL"],
              let url = URL(string: fixture), url.isFileURL else {
            throw XCTSkip("Set ECLIPSE_UI_FIXTURE_URL to a simulator-accessible audio/video fixture.")
        }
        app.launchArguments += [
            "-mpvAppExitPictureInPictureEnabled", "NO",
            "-defaultPlaybackSpeed", "1"
        ]
        app.launchEnvironment["ECLIPSE_DEBUG_AUTOPLAY_URL"] = fixture
        app.launchEnvironment["ECLIPSE_DEBUG_HWDEC"] = "no"
        if let logPath = ProcessInfo.processInfo.environment["ECLIPSE_UI_MPV_LOG_PATH"] {
            app.launchEnvironment["ECLIPSE_DEBUG_MPV_LOG_FILE"] = logPath
        }
        app.launch()
        let playback = app.buttons["player.playPause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { playback.label == "Pause" })

        for cycle in 1...2 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            Thread.sleep(forTimeInterval: 2)
            app.activate()
            if !playback.waitForExistence(timeout: 2) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            }
            XCTAssertTrue(playback.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(waitUntil(timeout: 10) { playback.label == "Pause" }, app.debugDescription)
            capture("MPV inline after background cycle \(cycle)")
        }

        if !playback.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.isHittable)
        playback.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playback.label == "Play" })
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        if !playback.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(playback.label, "Play", "Foreground recovery must preserve the user's pause intent.")
        Thread.sleep(forTimeInterval: 2)
        if !playback.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        XCTAssertTrue(playback.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(playback.label, "Play", "Foreground recovery must preserve the user's pause intent.")
        capture("MPV paused after background cycle")
        let close = app.buttons["player.close"]
        if close.exists, close.isHittable { close.tap() }
    }

    func testImageDataSaverChangesAndPersists() throws {
        try openSettingFromLaunch("Image Data Saver")
        try verifyToggleRoundTrip(label: "Image Data Saver", search: "Image Data Saver", checkPersistence: true)
    }

    func testRememberedPlaybackChoiceChangesAndPersists() throws {
        try openSettingFromLaunch("Remember Last Choice per Show")
        try verifyToggleRoundTrip(label: "Remember Last Choice per Show", search: "Remember Last Choice per Show", checkPersistence: true)
        XCTAssertTrue(app.buttons["Clear Remembered Choices"].exists)
    }

    func testAnimationOffers60And120FramesPerSecond() throws {
        try openSettingFromLaunch("Animation Frame Rate")
        let identifier = "settings.appearance.animationFrameRate"
        let original = try menuValue(identifier, options: ["20 FPS", "30 FPS", "60 FPS", "120 FPS"])
        restorations.append { [self] in
            try openSettingFromLaunch("Animation Frame Rate")
            try selectMenu(identifier, value: original)
        }
        try selectMenu(identifier, value: "60 FPS")
        capture("Background animation at 60 FPS")
        try selectMenu(identifier, value: "120 FPS")
        capture("Background animation at 120 FPS")
        try openSettingFromLaunch("Animation Frame Rate")
        XCTAssertEqual(try menuValue(identifier, options: ["20 FPS", "30 FPS", "60 FPS", "120 FPS"]), "120 FPS")
        try selectMenu(identifier, value: original)
        restorations.removeLast()
    }

    func testDownloadConcurrencyAndFillerControls() throws {
        try openSettingFromLaunch("Concurrent Downloads")
        let overallID = "settings.storage.concurrentDownloads"
        let hlsID = "settings.storage.concurrentHLSDownloads"
        let options = ["1", "2", "3", "4"]
        let originalOverall = try menuValue(overallID, options: options)
        let originalHLS = try menuValue(hlsID, options: options)
        restorations.append { [self] in
            try openSettingFromLaunch("Concurrent Downloads")
            try selectMenu(overallID, value: originalOverall)
            try selectMenu(hlsID, value: originalHLS)
        }
        let expectedOverall = originalOverall == "4" ? "1" : "4"
        let expectedHLS = originalHLS == "4" ? "1" : "4"
        try selectMenu(overallID, value: expectedOverall == "4" ? "1" : "4")
        try selectMenu(hlsID, value: expectedHLS == "4" ? "1" : "4")
        try selectMenu(overallID, value: expectedOverall)
        try selectMenu(hlsID, value: expectedHLS)
        capture("Overall and HLS download limits")
        try openSettingFromLaunch("Concurrent Downloads")
        XCTAssertEqual(try menuValue(overallID, options: options), expectedOverall)
        XCTAssertEqual(try menuValue(hlsID, options: options), expectedHLS)
        try verifyToggleRoundTrip(label: "Skip Filler in Download All", search: "Concurrent Downloads")
        try selectMenu(overallID, value: originalOverall)
        try selectMenu(hlsID, value: originalHLS)
        restorations.removeLast()
    }

    func testDeepLibraryFilterRowsDoNotOverlap() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10), app.debugDescription)
        for source in ["AniList", "MAL", "Trakt"] {
            sources.buttons[source].tap()
            let search = app.textFields["Search library"]
            let primary = app.buttons[source == "Trakt" ? "trackerLibrary.traktSection" : "trackerLibrary.status"].firstMatch
            let genre = app.buttons["trackerLibrary.genre"].firstMatch
            let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
            XCTAssertTrue(primary.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(genre.exists, app.debugDescription)
            XCTAssertTrue(refresh.exists, app.debugDescription)
            XCTAssertGreaterThan(primary.frame.width, 150)
            XCTAssertGreaterThanOrEqual(primary.frame.height, 44)
            XCTAssertLessThanOrEqual(search.frame.maxY, primary.frame.minY)
            XCTAssertLessThanOrEqual(primary.frame.maxY, genre.frame.minY)
            XCTAssertFalse(primary.frame.intersects(refresh.frame))
            XCTAssertLessThanOrEqual(genre.frame.maxX, app.frame.maxX)
            if source == "AniList" {
                let lists = app.buttons["trackerLibrary.anilistSection"].firstMatch
                XCTAssertTrue(lists.exists, app.debugDescription)
                XCTAssertLessThanOrEqual(genre.frame.maxY, lists.frame.minY)
            }
            capture("\(source) filter layout")
        }
    }

    func testDeepLibraryMALGridGeometryRemainsStable() throws {
        suppressScreenshots = true
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["MAL"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.exists { throw XCTSkip("MAL is not connected on this simulator.") }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open."))
        let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        let loadingCount = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles loaded")).firstMatch
        guard cards.firstMatch.waitForExistence(timeout: 60) else {
            if unavailable.exists { throw XCTSkip("MAL is not connected on this simulator.") }
            if app.buttons["Retry"].exists { throw UIInteractionError.unavailable("MAL returned a library error.") }
            throw XCTSkip("The connected MAL library has no cards to validate.")
        }

        struct Cell {
            let id: String
            let frame: CGRect
            let titleLength: Int
            let readiness: String
        }

        func snapshot() throws -> [Cell] {
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("MAL returned a library error during geometry validation.") }
            return cards.allElementsBoundByIndex.prefix(18).compactMap { card in
                let frame = card.frame
                guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
                      frame.width > 0, frame.height > 0 else { return nil }
                return Cell(id: card.identifier, frame: frame,
                            titleLength: max(0, card.label.count - "Open ".count), readiness: card.value as? String ?? "Unknown")
            }
        }

        let initial = try snapshot()
        var columns: [CGFloat] = []
        for cell in initial where !columns.contains(where: { abs($0 - cell.frame.minX) <= 1 }) { columns.append(cell.frame.minX) }
        guard columns.count >= 2, initial.count >= columns.count * 2 else {
            throw XCTSkip("At least two complete MAL grid rows are needed for geometry validation.")
        }
        let baseline = Array(initial.prefix(min(initial.count / columns.count, 3) * columns.count))
        let baselineIDs = Set(baseline.map(\.id))
        let rowCount = baseline.count / columns.count
        let tolerance: CGFloat = 1
        var readinessChanges = Set<String>()
        var sampleCount = 0

        func checkGeometry(_ cells: [Cell]) throws {
            let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let anchor = baseline.first, let currentAnchor = byID[anchor.id] else {
                throw UIInteractionError.unavailable("The first sampled MAL card disappeared during loading.")
            }
            let translation = CGPoint(x: currentAnchor.frame.minX - anchor.frame.minX, y: currentAnchor.frame.minY - anchor.frame.minY)
            for row in 0..<rowCount {
                let reference = baseline[row * columns.count]
                guard let currentReference = byID[reference.id] else {
                    throw UIInteractionError.unavailable("MAL row \(row + 1) lost its sampled first card.")
                }
                for column in 0..<columns.count {
                    let old = baseline[row * columns.count + column]
                    guard let current = byID[old.id] else {
                        throw UIInteractionError.unavailable("MAL row \(row + 1) column \(column + 1) disappeared during loading.")
                    }
                    XCTAssertEqual(current.frame.minY, currentReference.frame.minY, accuracy: tolerance, "MAL row \(row + 1) has misaligned card tops.")
                    XCTAssertEqual(current.frame.width, currentReference.frame.width, accuracy: tolerance, "MAL row \(row + 1) has unequal card widths.")
                    XCTAssertEqual(current.frame.height, currentReference.frame.height, accuracy: tolerance, "MAL row \(row + 1) has unequal card heights.")
                    XCTAssertGreaterThanOrEqual(current.frame.minX, app.frame.minX - tolerance, "MAL card \(row * columns.count + column + 1) overflowed the leading viewport edge.")
                    XCTAssertLessThanOrEqual(current.frame.maxX, app.frame.maxX + tolerance, "MAL card \(row * columns.count + column + 1) overflowed the trailing viewport edge.")
                    XCTAssertEqual(current.frame.minX - old.frame.minX, translation.x, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) moved horizontally.")
                    XCTAssertEqual(current.frame.minY - old.frame.minY, translation.y, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed row spacing.")
                    XCTAssertEqual(current.frame.width, old.frame.width, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed width.")
                    XCTAssertEqual(current.frame.height, old.frame.height, accuracy: tolerance, "MAL card \(row * columns.count + column + 1) changed height.")
                    if old.readiness == "Matching", current.readiness == "Ready" { readinessChanges.insert(old.id) }
                }
            }
            sampleCount += 1
        }

        try checkGeometry(initial)
        let matchingDeadline = Date().addingTimeInterval(12)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            let current = try snapshot()
            try checkGeometry(current)
            if refresh.isEnabled && loaded.exists && !readinessChanges.isEmpty { break }
        } while Date() < matchingDeadline
        guard waitUntil(timeout: 60, { refresh.isEnabled && (loaded.exists || self.app.buttons["Retry"].exists) }) else {
            throw UIInteractionError.timedOut("MAL did not settle before the refresh geometry check.")
        }
        try checkGeometry(snapshot())

        let scoredCells = baseline.filter { cell in
            let entryID = String(cell.id.dropFirst("trackerLibrary.open.".count))
            return app.descendants(matching: .any).matching(identifier: "trackerLibrary.score.\(entryID)").firstMatch.exists
        }.count
        guard refresh.isHittable else { throw UIInteractionError.unavailable("MAL refresh is outside the visible library controls.") }
        Thread.sleep(forTimeInterval: 1.1)
        refresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        var observedLoading = false
        let refreshDeadline = Date().addingTimeInterval(60)
        repeat {
            if !refresh.isEnabled || loadingCount.exists { observedLoading = true }
            let current = try snapshot()
            try checkGeometry(current)
            if observedLoading && refresh.isEnabled && loaded.exists { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < refreshDeadline
        guard refresh.isEnabled, loaded.exists else { throw UIInteractionError.timedOut("MAL refresh did not settle during geometry validation.") }
        try checkGeometry(snapshot())
        let lengths = baseline.map(\.titleLength)
        let receipt = XCTAttachment(string: "MAL grid rows=\(rowCount) columns=\(columns.count) cells=\(baselineIDs.count) samples=\(sampleCount) title-length-min=\(lengths.min() ?? 0) title-length-max=\(lengths.max() ?? 0) scored-cells=\(scoredCells) unscored-cells=\(baseline.count - scoredCells) readiness-changes=\(readinessChanges.count) refresh-loading-observed=\(observedLoading)")
        receipt.name = "MAL grid geometry coverage"
        receipt.lifetime = .keepAlways
        add(receipt)
        guard observedLoading else { throw XCTSkip("MAL refresh completed too quickly to observe loading geometry.") }
        guard let minimum = lengths.min(), let maximum = lengths.max(), maximum - minimum >= 10 else {
            throw XCTSkip("The sampled MAL rows need more varied title lengths for wrapping coverage.")
        }
        guard scoredCells > 0, scoredCells < baseline.count else {
            throw XCTSkip("The sampled MAL rows need both scored and unscored entries for optional-footer coverage.")
        }
        guard !readinessChanges.isEmpty else {
            throw XCTSkip("No sampled MAL matching state changed during geometry validation.")
        }
    }

    func testDeepLibraryMALGridFitsAccessibilityText() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["MAL"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.waitForExistence(timeout: 2) { throw XCTSkip("MAL is not connected on this simulator.") }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open."))
        guard app.buttons["trackerLibrary.refresh"].waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("MAL library controls are unavailable.")
        }
        let readyDeadline = Date().addingTimeInterval(60)
        while (!cards.firstMatch.exists || !cards.firstMatch.isHittable) && Date() < readyDeadline {
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("MAL returned a library error at accessibility text size.") }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard cards.firstMatch.exists, cards.firstMatch.isHittable else { throw XCTSkip("The connected MAL library has no visible accessibility-size cards to validate.") }
        let first = cards.firstMatch
        let firstFrame = first.frame
        let entryID = String(first.identifier.dropFirst("trackerLibrary.open.".count))
        let viewport = app.frame
        let tolerance: CGFloat = 1
        XCTAssertGreaterThanOrEqual(firstFrame.minX, viewport.minX - tolerance, "The MAL accessibility card overflowed the leading viewport edge.")
        XCTAssertLessThanOrEqual(firstFrame.maxX, viewport.maxX + tolerance, "The MAL accessibility card overflowed the trailing viewport edge.")
        XCTAssertGreaterThanOrEqual(firstFrame.width, viewport.width * 0.8, "MAL accessibility text did not use a full-width column.")
        XCTAssertGreaterThan(firstFrame.height, 0)
        let sampledFrames = cards.allElementsBoundByIndex.prefix(6).map(\.frame).filter { $0.width > 0 && $0.height > 0 }
        for (index, frame) in sampledFrames.enumerated() {
            XCTAssertEqual(frame.minX, firstFrame.minX, accuracy: tolerance, "MAL accessibility card \(index + 1) used another column.")
            XCTAssertEqual(frame.width, firstFrame.width, accuracy: tolerance, "MAL accessibility card \(index + 1) changed column width.")
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - tolerance, "MAL accessibility card \(index + 1) overflowed the leading viewport edge.")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + tolerance, "MAL accessibility card \(index + 1) overflowed the trailing viewport edge.")
        }
        let progress = app.staticTexts["trackerLibrary.progress.\(entryID)"].firstMatch
        for _ in 0..<8 where !progress.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        guard progress.exists, progress.isHittable else { throw UIInteractionError.unavailable("MAL progress is inaccessible at accessibility text size.") }
        XCTAssertGreaterThan(progress.frame.width, 0)
        XCTAssertGreaterThanOrEqual(progress.frame.minX, viewport.minX - tolerance)
        XCTAssertLessThanOrEqual(progress.frame.maxX, viewport.maxX + tolerance)
        let edit = app.buttons["trackerLibrary.edit.\(entryID)"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        guard edit.exists, edit.isHittable else { throw UIInteractionError.unavailable("MAL editing is inaccessible at accessibility text size.") }
        XCTAssertLessThanOrEqual(progress.frame.maxY, edit.frame.minY + tolerance, "MAL progress overlapped the accessibility edit button.")
        XCTAssertGreaterThanOrEqual(edit.frame.minX, viewport.minX - tolerance)
        XCTAssertLessThanOrEqual(edit.frame.maxX, viewport.maxX + tolerance)
        let scores = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.score."))
            .allElementsBoundByIndex.prefix(6)
        for score in scores {
            XCTAssertGreaterThan(score.frame.width, 0, "A present MAL score became inaccessible at accessibility text size.")
            XCTAssertGreaterThanOrEqual(score.frame.minX, viewport.minX - tolerance)
            XCTAssertLessThanOrEqual(score.frame.maxX, viewport.maxX + tolerance)
        }
        XCTAssertFalse(app.buttons["Retry"].exists, "MAL returned a library error at accessibility text size.")
        capture("MAL accessibility text layout")
    }

    func testDeepLibraryConnectedTrackerReads() throws {
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10), app.debugDescription)
        var checked = 0
        sourceLoop: for source in ["AniList", "MAL", "Trakt"] {
            sources.buttons[source].tap()
            let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
            if unavailable.waitForExistence(timeout: 2) { continue }
            let sections = source == "Trakt" ? ["Watched History", "Collection", "Watchlist"] : ["Library"]
            let mediaTypes = source == "Trakt" ? ["Movies", "Shows"] : ["Anime"]
            for mediaType in mediaTypes {
                if source == "Trakt" { app.segmentedControls["trackerLibrary.mediaType"].buttons[mediaType].tap() }
                for section in sections {
                    if source == "Trakt" { try selectMenu("trackerLibrary.traktSection", value: section) }
                    let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
                    XCTAssertTrue(refresh.waitForExistence(timeout: 10))
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        refresh.isEnabled
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, "\(source) \(section) did not become ready")
                    let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                        refresh.isEnabled && (loaded.exists || app.buttons["Retry"].exists)
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, "\(source) \(section) did not settle")
                    if source == "Trakt", app.staticTexts["Trakt session expired. Reconnect Trakt in Settings."].exists {
                        capture("Trakt reconnect required")
                        continue sourceLoop
                    }
                    XCTAssertTrue(loaded.exists, "\(source) \(section) did not load")
                    XCTAssertFalse(app.buttons["Retry"].exists, "\(source) \(section) returned a library error")
                    capture("\(source) \(mediaType) \(section) connected read")
                    checked += 1
                }
            }
        }
        if checked == 0 { throw XCTSkip("No tracker is connected on this simulator.") }
    }

    func testDeepLibraryTraktPersonalListReads() throws {
        suppressScreenshots = true
        app.launchArguments += ["-trackerDeepLibraryEnabled", "YES"]
        restartApp()
        try openLibraryTab()
        let sources = app.segmentedControls["trackerLibrarySourcePicker"]
        guard sources.waitForExistence(timeout: 10) else { throw UIInteractionError.unavailable("Library sources are unavailable.") }
        sources.buttons["Trakt"].tap()
        let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
        if unavailable.waitForExistence(timeout: 2) { throw XCTSkip("Trakt is not connected on this simulator.") }
        let sections = app.buttons["trackerLibrary.traktSection"].firstMatch
        let refresh = app.buttons["trackerLibrary.refresh"].firstMatch
        let kinds = app.segmentedControls["trackerLibrary.mediaType"]
        guard sections.waitForExistence(timeout: 10), refresh.exists, kinds.exists else {
            throw UIInteractionError.unavailable("Trakt library controls are unavailable.")
        }
        let standards = Set(["Watchlist", "Watched History", "Collection"])
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        let loadingCount = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles loaded")).firstMatch
        let metadataError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Custom lists:")).firstMatch
        let reconnect = app.staticTexts["Trakt session expired. Reconnect Trakt in Settings."]

        func checkErrors(_ index: Int) throws {
            if reconnect.exists { throw XCTSkip("Trakt requires reconnection on this simulator.") }
            guard !metadataError.exists else { throw UIInteractionError.unavailable("Trakt personal-list metadata failed for read \(index).") }
            guard !app.buttons["Retry"].exists else { throw UIInteractionError.unavailable("Trakt personal-list read \(index) returned a library error.") }
        }

        func menuOptions() -> [XCUIElement] {
            let buttons = app.buttons.allElementsBoundByIndex
            let standardRows = buttons.filter { standards.contains($0.label) && $0.isHittable }
            guard standardRows.count == standards.count, let reference = standardRows.first,
                  let lastStandard = standardRows.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return [] }
            let frame = reference.frame
            return buttons.filter {
                !standards.contains($0.label) && $0.isHittable && $0.frame.height > 0
                    && abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.maxX - frame.maxX) < 2
                    && $0.frame.minY >= lastStandard.frame.maxY - 2
            }.sorted { $0.frame.minY < $1.frame.minY }
        }

        func dismissMenu() {
            sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        func waitForRead(_ index: Int, previousCount: String?) throws -> Bool {
            var admitted = false
            let admissionDeadline = Date().addingTimeInterval(2)
            while Date() < admissionDeadline {
                try checkErrors(index)
                if !refresh.isEnabled || loadingCount.exists { admitted = true; break }
                if refresh.isEnabled, loaded.exists, loaded.label != previousCount { admitted = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !admitted {
                guard waitUntil(timeout: 60, { refresh.isEnabled }) else {
                    throw UIInteractionError.timedOut("Trakt personal-list read \(index) did not become ready.")
                }
                try checkErrors(index)
                Thread.sleep(forTimeInterval: 1.1)
                refresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let refreshDeadline = Date().addingTimeInterval(5)
                while Date() < refreshDeadline {
                    try checkErrors(index)
                    if !refresh.isEnabled || loadingCount.exists { admitted = true; break }
                    if refresh.isEnabled, loaded.exists, loaded.label != previousCount { admitted = true; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            guard waitUntil(timeout: 60, { refresh.isEnabled && (loaded.exists || self.app.buttons["Retry"].exists) }) else {
                throw UIInteractionError.timedOut("Trakt personal-list read \(index) did not settle.")
            }
            try checkErrors(index)
            guard loaded.exists else { throw UIInteractionError.unavailable("Trakt personal-list read \(index) has no settled title count.") }
            return admitted
        }

        var personalNames: [String] = []
        let metadataDeadline = Date().addingTimeInterval(60)
        while Date() < metadataDeadline {
            try checkErrors(0)
            sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            guard app.buttons["Collection"].waitForExistence(timeout: 5) else {
                throw UIInteractionError.unavailable("Trakt list options are unavailable.")
            }
            personalNames = menuOptions().map(\.label)
            dismissMenu()
            if !personalNames.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard !personalNames.isEmpty else {
            throw XCTSkip("No personal-list options were observed; the UI cannot distinguish pending metadata from a valid empty response.")
        }
        let duplicateNameCount = personalNames.count - Set(personalNames).count

        var readIndex = 0
        var unprovenReads: [Int] = []
        for mediaType in ["Movies", "Shows"] {
            kinds.buttons[mediaType].tap()
            guard waitUntil(timeout: 10, { kinds.buttons[mediaType].isSelected }) else {
                throw UIInteractionError.timedOut("Trakt media type did not change.")
            }
            for (optionIndex, name) in personalNames.enumerated() {
                readIndex += 1
                let previousCount = loaded.exists ? loaded.label : nil
                sections.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                guard app.buttons["Collection"].waitForExistence(timeout: 5) else {
                    throw UIInteractionError.unavailable("Trakt list options are unavailable for read \(readIndex).")
                }
                let options = menuOptions()
                guard options.indices.contains(optionIndex), options[optionIndex].label == name else {
                    throw UIInteractionError.unavailable("Personal-list option is unavailable for read \(readIndex).")
                }
                let option = options[optionIndex]
                option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                guard waitUntil(timeout: 5, { sections.value as? String == name }) else {
                    throw UIInteractionError.timedOut("Personal-list selection did not change for read \(readIndex).")
                }
                if try !waitForRead(readIndex, previousCount: previousCount) { unprovenReads.append(readIndex) }
            }
        }
        if !unprovenReads.isEmpty {
            throw XCTSkip("Work admission was not observable for \(unprovenReads.count) personal-list reads: \(unprovenReads.map(String.init).joined(separator: ", ")).")
        }
        if duplicateNameCount > 0 {
            throw XCTSkip("\(duplicateNameCount) personal-list options share names; the UI cannot verify their distinct identities.")
        }
    }

    func testDeepLibrarySwitchesTrackerAndMediaType() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnectedSources = try disconnectedTrackerSources()
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let sourcePicker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10), app.debugDescription)
        for source in ["AniList", "MAL"] {
            let sourceButton = sourcePicker.buttons[source]
            XCTAssertTrue(sourceButton.exists, app.debugDescription)
            sourceButton.tap()
            let kindPicker = app.segmentedControls["trackerLibrary.mediaType"]
            XCTAssertTrue(kindPicker.waitForExistence(timeout: 10), app.debugDescription)
            for kind in ["Anime", "Manga"] {
                let kindButton = kindPicker.buttons[kind]
                XCTAssertTrue(kindButton.exists, app.debugDescription)
                kindButton.tap()
                XCTAssertTrue(kindButton.isSelected, app.debugDescription)
                XCTAssertTrue(app.textFields["Search library"].exists, app.debugDescription)
                let unavailable = app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."]
                if disconnectedSources.contains(source) {
                    XCTAssertTrue(unavailable.waitForExistence(timeout: 10), app.debugDescription)
                } else {
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                        app.buttons["Retry"].exists
                            || app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch.exists
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 35), .completed, app.debugDescription)
                }
                if unavailable.exists {
                    XCTAssertTrue(app.buttons["Tracker Settings"].exists, app.debugDescription)
                    XCTAssertFalse(app.buttons["Retry"].isEnabled)
                }
                capture("\(source) \(kind) library")
                try verifyAvailableEditorCanCancel(source: source, kind: kind)
            }
        }
        let trakt = sourcePicker.buttons["Trakt"]
        XCTAssertTrue(trakt.exists, app.debugDescription)
        trakt.tap()
        let traktKind = app.segmentedControls["trackerLibrary.mediaType"]
        XCTAssertTrue(traktKind.waitForExistence(timeout: 10), app.debugDescription)
        for kind in ["Movies", "Shows"] {
            traktKind.buttons[kind].tap()
            XCTAssertTrue(traktKind.buttons[kind].isSelected, app.debugDescription)
            let sections = app.buttons["trackerLibrary.traktSection"]
            XCTAssertTrue(sections.waitForExistence(timeout: 10), app.debugDescription)
            for title in ["Watched History", "Collection", "Watchlist"] {
                sections.tap()
                let option = app.buttons[title].firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
                option.tap()
                XCTAssertEqual(currentMenuValue(sections, options: [title]), title, app.debugDescription)
                if disconnectedSources.contains("Trakt") {
                    XCTAssertTrue(app.staticTexts["Enable Deep Library Integration and connect this tracker in Settings to view its library."].waitForExistence(timeout: 10))
                } else {
                    let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in loaded.exists || app.buttons["Retry"].exists }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, app.debugDescription)
                    XCTAssertTrue(loaded.exists, "Connected Trakt \(kind) \(title) did not load: \(app.debugDescription)")
                    let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
                    if edit.exists {
                        try reveal(edit)
                        edit.tap()
                        let editor = app.navigationBars["Edit Trakt Entry"]
                        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
                        XCTAssertTrue(app.staticTexts["Each action updates Trakt immediately."].exists)
                        XCTAssertFalse(app.staticTexts["Updating Trakt…"].exists)
                        capture("Trakt \(kind) \(title) read-only editor")
                        editor.buttons["Close"].tap()
                    }
                }
                capture("Trakt \(kind) \(title) library")
            }
            capture("Trakt \(kind) library sections")
        }
        sourcePicker.buttons["My Library"].tap()
        XCTAssertFalse(app.segmentedControls["trackerLibrary.mediaType"].exists)
        try openSettingFromLaunch("Deep Library Integration")
        try setSwitch("Deep Library Integration", to: original)
        restorations.removeLast()
        if !original {
            restartApp()
            try openLibraryTab()
            XCTAssertFalse(app.segmentedControls["trackerLibrarySourcePicker"].exists)
        }
    }

    func testLinkClickCollectionContainsEverySeasonInStoryOrder() throws {
        guard ProcessInfo.processInfo.environment["ECLIPSE_UI_LINK_CLICK"] == "1" else {
            throw XCTSkip("Set ECLIPSE_UI_LINK_CLICK=1 to verify current Link Click metadata without tracker writes.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        let sources = [("AniList", "anilist"), ("MAL", "myAnimeList")].filter { !disconnected.contains($0.0) }
        guard !sources.isEmpty else { throw XCTSkip("No anime tracker is connected on this simulator.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        let standard = app.tabBars.buttons["Search"].firstMatch
        let modern = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Search", "magnifyingglass")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in standard.exists || modern.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, app.debugDescription)
        (standard.exists ? standard : modern).tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText("Link Click\n")
        let result = app.buttons["media.search.result.tv-123542"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), app.debugDescription)
        result.tap()
        let collection = app.buttons["Add to Collection"].firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 60), app.debugDescription)
        collection.tap()
        for (name, service) in sources {
            let count = app.staticTexts["trackerCollection.\(service).seasonCount"]
            if service != sources.first?.1 { try reveal(count) }
            let built = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in count.exists && count.label == "All 4 seasons" }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [built], timeout: 120), .completed, app.debugDescription)
            var titles: [String] = []
            for index in 0..<4 {
                let title = app.staticTexts["trackerCollection.\(service).season.\(index)"]
                try reveal(title)
                XCTAssertTrue(title.waitForExistence(timeout: 60), app.debugDescription)
                titles.append(title.label)
            }
            XCTAssertTrue(titles[2].localizedCaseInsensitiveContains("Bridon"), "\(name): \(titles)")
            XCTAssertTrue(titles[3].contains("III") || titles[3].contains("3"), "\(name): \(titles)")
            let receipt = XCTAttachment(string: "\(name): \(titles.joined(separator: " → "))")
            receipt.name = "Link Click all-season tracker identities"
            receipt.lifetime = .keepAlways
            add(receipt)
            capture("\(name) Link Click all-season collection")
        }
    }

    func testDeepLibraryIncludesPlanningAndAllStatuses() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        let sources = ["AniList", "MAL"].filter { !disconnected.contains($0) }
        guard !sources.isEmpty else { throw XCTSkip("No anime tracker is connected on this simulator.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        for source in sources {
            picker.buttons[source].tap()
            XCTAssertEqual(try menuValue("trackerLibrary.status", options: ["All Statuses"]), "All Statuses")
            for status in ["Planning to Watch", "Completed", "All Statuses"] {
                try selectMenu("trackerLibrary.status", value: status)
                let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                    loaded.exists || app.buttons["Retry"].exists
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 60), .completed, app.debugDescription)
                XCTAssertTrue(loaded.exists, app.debugDescription)
                capture("\(source) \(status) deep library")
            }
            if source == "AniList" {
                XCTAssertTrue(app.buttons["trackerLibrary.anilistSection"].exists, app.debugDescription)
            }
        }
    }

    func testMatchedTrackerCardOpensNormalMediaDetails() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL", "Trakt"].first(where: { !disconnected.contains($0) }) else {
            throw XCTSkip("No tracker account is connected on this simulator.")
        }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let loaded = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 60), app.debugDescription)
        if loaded.label.hasPrefix("0 ") { throw XCTSkip("The selected tracker list is empty on this simulator.") }
        let ready = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "trackerLibrary.open.", "Ready")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "The visible tracker cards did not resolve: \(app.debugDescription)")
        try reveal(ready)
        capture("Resolved tracker cards before opening")
        let entryID = String(ready.identifier.dropFirst("trackerLibrary.open.".count))
        let trackerProgress = app.staticTexts["trackerLibrary.progress.\(entryID)"]
        let progressLabel = trackerProgress.exists ? trackerProgress.label : nil
        ready.tap()
        let detailAction = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(Play.*|Resume.*|Continue.*|No Sources|Choose Episode)")).firstMatch
        XCTAssertTrue(detailAction.waitForExistence(timeout: 60), "A tracker card must open normal media details with the playback action: \(app.debugDescription)")
        if detailAction.label == "Choose Episode" {
            XCTAssertTrue(app.staticTexts["trackerLibrary.playbackNotice"].exists, "An unresolved next episode needs an explanation.")
        } else if source != "Trakt", let progressLabel, let raw = progressLabel.split(separator: " ").first, let watched = Int(raw), detailAction.label.hasPrefix("Play E") {
            XCTAssertEqual(detailAction.label, "Play E\(watched + 1)", "Play from a tracker library must follow its last watched episode.")
        }
        let receipt = XCTAttachment(string: "\(source): tracker progress \(progressLabel ?? "n/a"); detail action \(detailAction.label)")
        receipt.name = "Tracker-first playback selection"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("Tracker card opens normal media details")
        if detailAction.label == "Choose Episode" {
            detailAction.tap()
            let chooser = app.descendants(matching: .any).matching(identifier: "mediaDetail.episodeChooser").firstMatch
            XCTAssertTrue(chooser.waitForExistence(timeout: 15), app.debugDescription)
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                hasVisibleFrame(chooser)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Choose Episode must reveal the episode list.")
            XCTAssertFalse(app.alerts["Tracker Playback"].exists)
            capture("Choose Episode opens the existing episode list")
        }
    }

    func testTrackerProgressSelectsNextAvailableEpisode() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_TRACKER_RESUME_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_TRACKER_RESUME_TITLE to an existing tracker title with an aired next episode.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No anime tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let search = app.textFields["Search library"]
        search.tap()
        search.typeText(title)
        let card = app.buttons["Open \(title)"]
        guard card.waitForExistence(timeout: 10) else { throw XCTSkip("The configured tracker fixture title is absent.") }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, app.debugDescription)
        let entryID = String(card.identifier.dropFirst("trackerLibrary.open.".count))
        let progress = app.staticTexts["trackerLibrary.progress.\(entryID)"]
        let raw = try XCTUnwrap(progress.label.split(separator: " ").first)
        let watched = try XCTUnwrap(Int(raw))
        try reveal(card)
        card.tap()
        let expected = app.buttons["Play E\(watched + 1)"]
        XCTAssertTrue(expected.waitForExistence(timeout: 60), "Expected tracker continuation after \(watched) watched episodes: \(app.debugDescription)")
        let receipt = XCTAttachment(string: "\(source) / \(title): \(watched) watched -> \(expected.label). No playback or tracker write was performed.")
        receipt.name = "Aired tracker episode selection"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("Tracker progress selects aired next episode")
    }

    func testTrackerLibraryAllStatusesLoadsAndFilters() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No anime tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let start = Date()
        try selectMenu("trackerLibrary.status", value: "All Statuses")
        XCTAssertTrue(summary.waitForExistence(timeout: 90), app.debugDescription)
        let total = summary.label
        let receipt = XCTAttachment(string: "\(source) All Statuses: \(total), \(Date().timeIntervalSince(start)) seconds from selecting the list through completion.")
        receipt.name = "Live paginated library loading"
        receipt.lifetime = .keepAlways
        add(receipt)
        capture("All statuses library loaded")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open.")).firstMatch
        guard card.exists else { throw XCTSkip("The connected library is empty.") }
        let originalCardID = card.identifier
        let originalCardTitle = card.label
        let term = String(originalCardTitle.dropFirst(5).prefix(12))
        let search = app.textFields["Search library"]
        search.tap()
        search.typeText(term)
        XCTAssertTrue(app.buttons["Clear Search"].waitForExistence(timeout: 5))
        let filteredCard = app.buttons[originalCardID]
        XCTAssertTrue(filteredCard.waitForExistence(timeout: 5), "Local filtering must preserve the selected title.")
        XCTAssertEqual(filteredCard.label, originalCardTitle)
        capture("Local library filter")
        app.buttons["Clear Search"].tap()
        XCTAssertTrue(app.staticTexts[total].waitForExistence(timeout: 5))
    }

    func testReaderCollectionSheetShowsLocalAndConnectedTrackers() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_IMPORTED_MANGA_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_IMPORTED_MANGA_TITLE to an imported Reader history title.")
        }
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        if app.buttons["Quick Actions"].waitForExistence(timeout: 5) {
            app.buttons["Quick Actions"].tap()
            let reader = app.buttons["Switch to Reader Mode"]
            if reader.waitForExistence(timeout: 5) { reader.tap() }
        }
        let history = app.tabBars.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        history.tap()
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try reveal(imported)
        imported.tap()
        let details = app.buttons["Open Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        details.tap()
        let collections = app.buttons["reader.addToCollection"]
        try reveal(collections)
        collections.tap()
        XCTAssertTrue(app.navigationBars["Add to Collection"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Local")).firstMatch.exists)
        for (source, header) in [("AniList", "AniList"), ("MAL", "MyAnimeList")] where !disconnected.contains(source) {
            let label = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", header)).firstMatch
            try reveal(label)
            XCTAssertTrue(label.exists, app.debugDescription)
        }
        capture("Local and connected Reader trackers")
        app.buttons["Done"].tap()
        try openSettingFromLaunch("Deep Library Integration")
        try setSwitch("Deep Library Integration", to: original)
        restorations.removeLast()
    }

    func testImportedMangaCanChooseReaderSource() throws {
        guard let title = ProcessInfo.processInfo.environment["ECLIPSE_UI_IMPORTED_MANGA_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set ECLIPSE_UI_IMPORTED_MANGA_TITLE to an imported Reader history title without a source.")
        }
        restartApp()
        if app.buttons["Quick Actions"].waitForExistence(timeout: 5) {
            app.buttons["Quick Actions"].tap()
            let reader = app.buttons["Switch to Reader Mode"]
            XCTAssertTrue(reader.waitForExistence(timeout: 5))
            reader.tap()
        }
        let history = app.tabBars.buttons["History"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        history.tap()
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try reveal(imported)
        imported.tap()
        let details = app.buttons["Open Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        details.tap()
        let choose = app.buttons["reader.chooseSource"]
        try reveal(choose)
        XCTAssertTrue(choose.isEnabled)
        choose.tap()
        XCTAssertTrue(app.navigationBars["Choose Reader Source"].waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields["Search title"]
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, title)
        XCTAssertTrue(app.buttons.matching(identifier: "Search").allElementsBoundByIndex.contains { $0.isHittable && $0.isEnabled })
        capture("Imported manga source picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
    }

    func testTrackerMangaOpensReaderOrActionableSourceFallback() throws {
        try openSettingFromLaunch("Deep Library Integration")
        let original = try switchValue("Deep Library Integration")
        restorations.append { [self] in
            try openSettingFromLaunch("Deep Library Integration")
            try setSwitch("Deep Library Integration", to: original)
        }
        let disconnected = try disconnectedTrackerSources()
        guard let source = ["AniList", "MAL"].first(where: { !disconnected.contains($0) }) else { throw XCTSkip("No manga tracker connected.") }
        try setSwitch("Deep Library Integration", to: true)
        restartApp()
        try openLibraryTab()
        let picker = app.segmentedControls["trackerLibrarySourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[source].tap()
        let kinds = app.segmentedControls["trackerLibrary.mediaType"]
        XCTAssertTrue(kinds.waitForExistence(timeout: 10))
        kinds.buttons["Manga"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 60), app.debugDescription)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trackerLibrary.open.")).firstMatch
        guard card.exists else { throw XCTSkip("The connected manga list is empty.") }
        try reveal(card)
        card.tap()
        let chooser = app.navigationBars["Choose Match"]
        if chooser.waitForExistence(timeout: 8) {
            let searchSources = app.buttons["Search Reader Sources"]
            XCTAssertTrue(searchSources.waitForExistence(timeout: 10), app.debugDescription)
            searchSources.tap()
            XCTAssertTrue(app.buttons["Manage Sources"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.searchFields.firstMatch.exists || app.textFields.firstMatch.exists, "Fallback must open normal Reader search.")
            capture("Manga source search fallback")
        } else {
            let chapters = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "chapter")).firstMatch
            XCTAssertTrue(chapters.waitForExistence(timeout: 30), "Matched manga must open its normal Reader details: \(app.debugDescription)")
            capture("Matched manga reader details")
        }
    }

    private func verifyAvailableEditorCanCancel(source: String, kind: String) throws {
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles")).firstMatch
        guard summary.exists,
              let countText = summary.label.split(separator: " ").first,
              let count = Int(countText), count > 0 else { return }
        let originalSummary = summary.label
        let editButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
        try reveal(editButton)
        let entryTitle = String(editButton.label.dropFirst("Edit ".count))
        editButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let editor = app.navigationBars["Edit Tracker Entry"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let cancel = editor.buttons["Cancel"]
        defer {
            if editor.exists && cancel.exists { cancel.tap() }
        }
        XCTAssertTrue(app.staticTexts[entryTitle].exists, app.debugDescription)
        let trackerName = source == "MAL" ? "MyAnimeList" : "AniList"
        XCTAssertTrue(app.staticTexts["Save changes to \(trackerName)."].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Status"].exists
            || app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Status")).firstMatch.exists, app.debugDescription)
        let progressLabel = kind == "Anime" ? "Episodes Watched" : "Chapters Read"
        let progress = app.textFields[progressLabel]
        XCTAssertTrue(app.staticTexts[progressLabel].exists, "Progress needs a visible label even when it already has a value.")
        XCTAssertTrue(progress.exists, app.debugDescription)
        XCTAssertNotNil((progress.value as? String).flatMap(Int.init), "The editor must show existing \(progressLabel.lowercased()).")
        XCTAssertTrue(app.steppers.firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Rating:")).firstMatch.exists
            || app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", "Rating:")).firstMatch.exists, app.debugDescription)
        let save = editor.buttons["Save"]
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertFalse(save.isEnabled, "Opening an unchanged tracker entry must not enable Save.")
        XCTAssertFalse(app.buttons["Saving…"].exists)
        let rating = app.steppers.firstMatch
        let increment = rating.buttons["Increment"]
        let decrement = rating.buttons["Decrement"]
        let adjustment = increment.exists && increment.isEnabled ? increment : decrement
        XCTAssertTrue(adjustment.exists && adjustment.isEnabled, "One bounded rating adjustment must be available.")
        adjustment.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Changing the local rating must enable Save.")
        XCTAssertFalse(app.buttons["Saving…"].exists)
        capture("\(source) \(kind) unsaved rating change before Cancel")
        XCTAssertTrue(cancel.exists && cancel.isEnabled, app.debugDescription)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !editor.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(app.staticTexts[originalSummary].exists, "Cancelling the editor must preserve the loaded tracker list.")
    }

    private func disconnectedTrackerSources() throws -> Set<String> {
        var result = Set<String>()
        for (source, title) in [("AniList", "AniList"), ("MAL", "MyAnimeList"), ("Trakt", "Trakt")] {
            let service = app.staticTexts[title].firstMatch
            try reveal(service)
            let titleFrame = service.frame
            let rowButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Connect", "Disconnect"]))
                .allElementsBoundByIndex.filter {
                    $0.frame.minX > titleFrame.minX && abs($0.frame.midY - titleFrame.midY) < 36
                }
            guard rowButtons.count == 1, let action = rowButtons.first else {
                throw UIInteractionError.unavailable("Could not identify the \(title) account row.")
            }
            if action.label == "Connect" {
                let notConnected = app.staticTexts.matching(identifier: "Not connected").allElementsBoundByIndex.contains {
                    $0.frame.minY > titleFrame.minY && $0.frame.minY < titleFrame.maxY + 24
                }
                guard notConnected else {
                    throw UIInteractionError.unexpectedValue("The \(title) account row did not confirm its connection state.")
                }
                result.insert(source)
            }
        }
        return result
    }

    private func verifyToggleRoundTrip(label: String, search: String, checkPersistence: Bool = false) throws {
        let original = try switchValue(label)
        restorations.append { [self] in
            try openSettingFromLaunch(search)
            try setSwitch(label, to: original)
        }
        try setSwitch(label, to: !original)
        capture("\(label) changed")
        if checkPersistence {
            try openSettingFromLaunch(search)
            XCTAssertEqual(try switchValue(label), !original)
        }
        try setSwitch(label, to: original)
        restorations.removeLast()
    }

    private func switchValue(_ label: String) throws -> Bool {
        let control = app.switches[label].firstMatch
        try reveal(control)
        guard let value = control.value as? String, ["0", "1"].contains(value) else {
            throw UIInteractionError.unexpectedValue("Could not read the \(label) toggle.")
        }
        return value == "1"
    }

    private func setSwitch(_ label: String, to enabled: Bool) throws {
        let control = app.switches[label].firstMatch
        try reveal(control)
        if try switchValue(label) != enabled {
            let target = try switchTapTarget(control)
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let expected = enabled ? "1" : "0"
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            throw UIInteractionError.timedOut("The control did not reach its requested value.")
        }
    }

    private func switchTapTarget(_ control: XCUIElement) throws -> XCUIElement {
        let rowFrame = control.frame
        guard rowFrame.width > 100 else { return control }
        let nativeSwitches = app.switches.allElementsBoundByIndex.filter { candidate in
            let frame = candidate.frame
            return frame.width > 0 && frame.width <= 100 && frame.height > 0
                && rowFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        guard nativeSwitches.count == 1, let target = nativeSwitches.first else {
            throw UIInteractionError.unavailable("Could not identify the native switch inside \(control.label).")
        }
        return target
    }

    private func menuValue(_ identifier: String, options: [String]) throws -> String {
        let control = app.buttons[identifier].firstMatch
        try reveal(control)
        guard let value = currentMenuValue(control, options: options) else {
            throw UIInteractionError.unexpectedValue("Could not read menu \(identifier): \(control.debugDescription)")
        }
        return value
    }

    private func currentMenuValue(_ control: XCUIElement, options: [String]) -> String? {
        if let value = control.value as? String, options.contains(value) { return value }
        if let label = options.first(where: { control.label == $0 || control.label.hasSuffix(", \($0)") }) { return label }
        let texts = control.staticTexts.allElementsBoundByIndex.map(\.label)
        return options.first(where: texts.contains)
    }

    private func selectMenu(_ identifier: String, value: String) throws {
        let control = app.buttons[identifier].firstMatch
        try reveal(control)
        control.tap()
        let option = app.buttons[value].firstMatch
        guard option.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("Menu option \(value) is unavailable.")
        }
        option.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            currentMenuValue(app.buttons[identifier].firstMatch, options: [value]) == value
        }, object: nil)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            throw UIInteractionError.timedOut("The control did not reach its requested value.")
        }
    }

    private func openSettingFromLaunch(_ title: String) throws {
        restartApp()
        try openSettings()
        try searchSettings(title)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        guard result.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search did not find \(title).")
        }
        result.tap()
        switch title {
        case "Animation Frame Rate":
            try waitForSettingsPage(["Appearance"])
            try openSettingsCategory("Motion & Startup")
        case "Image Data Saver":
            try waitForSettingsPage(["Appearance"])
            try openSettingsCategory("Detail Pages")
        case "Remember Last Choice per Show":
            try waitForSettingsPage(["Auto Mode"])
        case "Autoplay Next Episode":
            try waitForSettingsPage(["MPV Player", "Media Player"])
        case "Deep Library Integration":
            try waitForSettingsPage(["Trackers"])
        case "Concurrent Downloads":
            try waitForSettingsPage(["Storage"])
        default:
            throw UIInteractionError.unavailable("No test navigation route exists for \(title).")
        }
    }

    private func waitForSettingsPage(_ titles: [String]) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            titles.contains { app.navigationBars[$0].exists }
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed,
              let title = titles.first(where: { app.navigationBars[$0].exists }) else {
            throw UIInteractionError.unavailable("Settings did not open \(titles.joined(separator: " or ")).")
        }
        activeSettingsPage = title
    }

    private func openSettingsCategory(_ title: String) throws {
        let category = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        try reveal(category)
        category.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try waitForSettingsPage([title])
    }

    private func openLibraryTab() throws {
        let standardTab = app.tabBars.buttons["Library"].firstMatch
        let modernTab = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Library", "books.vertical.fill")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            standardTab.exists || modernTab.exists
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 30) == .completed else {
            throw UIInteractionError.unavailable("The Library tab is unavailable.")
        }
        let tab = standardTab.exists ? standardTab : modernTab
        guard tab.frame.width > 0, tab.frame.height > 0 else {
            throw UIInteractionError.unavailable("The Library tab has no visible frame.")
        }
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func restartApp() {
        activeSettingsPage = nil
        if app.state != .notRunning { app.terminate() }
        app.launch()
    }

    private func openSettings() throws {
        let mediaMode = app.buttons["Switch to Media Mode"]
        if mediaMode.waitForExistence(timeout: 2) { mediaMode.tap() }
        let quickActions = app.buttons["Quick Actions"]
        guard quickActions.waitForExistence(timeout: 30) else {
            throw UIInteractionError.unavailable("Quick Actions is unavailable.")
        }
        quickActions.tap()
        let settings = app.buttons["Settings"].firstMatch
        guard settings.waitForExistence(timeout: 5) else {
            throw UIInteractionError.unavailable("Settings is unavailable in Quick Actions.")
        }
        settings.tap()
        guard app.searchFields.firstMatch.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search is unavailable.")
        }
    }

    private func searchSettings(_ text: String) throws {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 10) else {
            throw UIInteractionError.unavailable("Settings search is unavailable.")
        }
        field.tap()
        if let value = field.value as? String, value != field.placeholderValue, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func reveal(_ element: XCUIElement) throws {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            hasVisibleFrame(element)
        }, object: nil)
        if XCTWaiter.wait(for: [settled], timeout: 2) == .completed { return }
        for _ in 0..<8 {
            let viewport = visibleViewport()
            guard !viewport.isEmpty, !viewport.isNull else {
                throw UIInteractionError.unavailable("The current Settings page has no visible viewport.")
            }
            let frame = element.exists ? element.frame : .zero
            let needsEarlierContent = frame.height > 0 && frame.midY < viewport.minY
            let upper = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.25)
            let lower = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.75)
            let from = needsEarlierContent ? upper : lower
            let to = needsEarlierContent ? lower : upper
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: from.x, dy: from.y))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
            if hasVisibleFrame(element) { return }
        }
        guard hasVisibleFrame(element) else {
            throw UIInteractionError.unavailable("The requested control is not visible: \(element.debugDescription)")
        }
    }

    private func visibleViewport() -> CGRect {
        var viewport = app.windows.firstMatch.frame
        if let activeSettingsPage {
            let bar = app.navigationBars[activeSettingsPage]
            guard bar.exists else { return .zero }
            let frame = bar.frame
            guard frame.width > 0, frame.height > 0 else { return .zero }
            let top = max(viewport.minY, frame.maxY)
            viewport = CGRect(x: max(viewport.minX, frame.minX), y: top,
                              width: min(viewport.width, frame.width), height: max(0, viewport.maxY - top))
        }
        if app.keyboards.firstMatch.exists {
            let keyboard = app.keyboards.firstMatch.frame
            if keyboard.intersects(viewport) {
                viewport.size.height = max(0, keyboard.minY - viewport.minY)
            }
        }
        return viewport.insetBy(dx: 4, dy: 8)
    }

    private func hasVisibleFrame(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        let viewport = visibleViewport()
        guard !viewport.isNull, !viewport.isEmpty else { return false }
        return viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            && viewport.intersection(frame).height >= min(frame.height, 24)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            condition()
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ title: String) {
        guard !suppressScreenshots else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
