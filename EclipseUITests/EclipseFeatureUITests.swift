import XCTest

final class EclipseFeatureUITests: XCTestCase {
    private let app = XCUIApplication()
    private var restorations: [() throws -> Void] = []
    private var activeSettingsPage: String?

    private enum UIInteractionError: Error {
        case unavailable(String)
        case unexpectedValue(String)
        case timedOut(String)
    }

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
                            || app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles · .+")).firstMatch.exists
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

    private func verifyAvailableEditorCanCancel(source: String, kind: String) throws {
        let summary = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ titles · .+")).firstMatch
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
        for (source, title) in [("AniList", "AniList"), ("MAL", "MyAnimeList")] {
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

    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
