import XCTest

final class SceneAcceptanceTests: XCTestCase {
    func testIsolatedLoginItemRegistrationAndRemoval() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BARKEEP_ACCEPTANCE_LOGIN"] == "1")
        let artifacts = try XCTUnwrap(environment["BARKEEP_ACCEPTANCE_ARTIFACTS"])
        let expectedID = try XCTUnwrap(environment["BARKEEP_ACCEPTANCE_BUNDLE_ID"])
        let prefix = "dev.barkeep.acceptance-login."
        let fresh = URL(fileURLWithPath: artifacts + "/fresh-login-identity")
        // Only a new script-owned UUID app may register from the initial notFound state.
        guard expectedID.hasPrefix(prefix), UUID(uuidString: String(expectedID.dropFirst(prefix.count))) != nil,
              try String(contentsOf: fresh) == expectedID else {
            XCTFail("Login acceptance requires a fresh UUID app with no prior registration attempt")
            return
        }
        let statusURL = URL(fileURLWithPath: artifacts + "/login-status.json")
        let app = XCUIApplication()
        app.launchArguments = ["--show-window"]
        app.launchEnvironment["BARKEEP_ACCEPTANCE_UI"] = "1"
        app.launchEnvironment["BARKEEP_ACCEPTANCE_SUITE"] = environment["BARKEEP_ACCEPTANCE_SUITE"]
        app.launchEnvironment["BARKEEP_ACCEPTANCE_LOGIN_STATUS"] = statusURL.path
        app.launchEnvironment["BARKEEP_ACCEPTANCE_EXPECTED_ID"] = expectedID
        app.launchEnvironment["LLVM_PROFILE_FILE"] = artifacts + "/ui-app-%p.profraw"
        app.launch()
        defer { app.terminate() }
        func report() -> [String: String]? {
            guard let data = try? Data(contentsOf: statusURL),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  value["bundleID"] == expectedID else { return nil }
            return value
        }
        for _ in 0..<50 where report() == nil { Thread.sleep(forTimeInterval: 0.1) }
        let initial = report()?["status"]
        guard (initial == "notRegistered" || initial == "notFound"), report()?["registrationError"] == nil else {
            XCTFail("Never modify a pre-existing or uncertain registration: \(initial ?? "unknown")")
            return
        }
        let controls = app.windows["BarKeep Controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        guard controls.exists else { return }
        controls.descendants(matching: .any).matching(identifier: "Settings").firstMatch.click()
        let toggle = controls.checkBoxes["Launch at login"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        guard toggle.exists else { return }
        XCTContext.runActivity(named: "Attempt one login registration for \(expectedID)") { _ in
            toggle.click() // Exactly one registration attempt, never approve any system prompt.
        }
        for _ in 0..<50 {
            let value = report()
            if value?["status"] == "enabled" || value?["status"] == "requiresApproval" || value?["registrationError"] != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        var evidence = report() ?? [:]
        evidence["preflight"] = initial
        evidence["registered"] = evidence["status"]
        if evidence["status"] == "enabled" {
            toggle.click()
            for _ in 0..<50 where report()?["status"] != "notRegistered" { Thread.sleep(forTimeInterval: 0.1) }
            evidence["afterToggleOff"] = report()?["status"] ?? "unknown"
            XCTAssertEqual(evidence["afterToggleOff"], "notRegistered")
        }
        let evidenceData = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        XCTContext.runActivity(named: "Observed Login Items status") { activity in
            let attachment = XCTAttachment(data: evidenceData, uniformTypeIdentifier: "public.json")
            attachment.name = "login-evidence.json"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        controls.buttons["Quit BarKeep"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        XCTAssertEqual(evidence["registered"], "enabled", "No permission grants or registration retries: \(evidence)")
    }

    func testNormalProductionStartupAndQuit() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_NORMAL"] == "1")
        continueAfterFailure = true
        let app = XCUIApplication()
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_HOST"])
        XCTAssertTrue(host.hasPrefix("127.0.0.1:"))
        let artifacts = try XCTUnwrap(ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_ARTIFACTS"])
        app.launchArguments = ["--show-window", "-connectionMode", "wifi", "-wifiHost", host, "-host", host,
            "-token", "", "-autoOnCall", "NO", "-forwardNotifications", "NO", "-calendarAutoBusy", "NO",
            "-showPing", "NO", "-showWeather", "NO", "-slackSyncEnabled", "NO"]
        app.launchEnvironment["LLVM_PROFILE_FILE"] = artifacts + "/ui-app-%p.profraw"
        // No permission-granting monitor. Unexpected system prompts remain blockers.
        app.launch()
        defer { app.terminate() }
        let controls = app.windows["BarKeep Controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        guard controls.exists else { return }
        let log = URL(fileURLWithPath: artifacts + "/normal-requests.log")
        for _ in 0..<50 {
            if (try? String(contentsOf: log).contains("GET /api/status")) == true { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(try String(contentsOf: log).contains("GET /api/status"))
        controls.buttons["Quit BarKeep"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testScenesNativeUploadAndArcadeLifecycle() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_NORMAL"] == "1" || ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_LOGIN"] == "1")
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--show-window"]
        app.launchEnvironment["BARKEEP_ACCEPTANCE_UI"] = "1"
        app.launchEnvironment["BARKEEP_ACCEPTANCE_SUITE"] = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_SUITE"]
        let artifacts = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_ARTIFACTS"]!
        app.launchEnvironment["LLVM_PROFILE_FILE"] = artifacts + "/ui-app-%p.profraw"
        app.launchEnvironment["BARKEEP_ACCEPTANCE_REQUESTS"] = artifacts + "/requests.json"
        app.launchEnvironment["BARKEEP_ACCEPTANCE_WEATHER_STATE"] = artifacts + "/weather-state.json"
        app.launch()
        defer { app.terminate() }
        let controls = app.windows["BarKeep Controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        let message = controls.descendants(matching: .any).matching(identifier: "Message").firstMatch
        XCTAssertTrue(message.exists)
        guard message.exists else { return }
        message.click()
        let draw = controls.buttons["Drawing Canvas…"]
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.click()
        XCTAssertTrue(app.windows["Busy Bar Canvas"].waitForExistence(timeout: 5))
        let canvasWindow = app.windows["Busy Bar Canvas"]
        let strokeStart = canvasWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.45))
        app.activate()
        strokeStart.click()
        canvasWindow.buttons["Send to Bar"].click()
        func requestRecords() throws -> [[String: String]] {
            let data = try Data(contentsOf: URL(fileURLWithPath: artifacts + "/requests.json"))
            return try JSONSerialization.jsonObject(with: data) as! [[String: String]]
        }
        for _ in 0..<50 {
            if (try? requestRecords().contains { $0["file"] == "canvas.png" }) == true { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let painted = try XCTUnwrap(requestRecords().first { $0["file"] == "canvas.png" }?["paintedPixels"].flatMap(Int.init))
        XCTAssertGreaterThan(painted, 0, "Native click must paint a red pixel before PNG export")
        controls.descendants(matching: .any).matching(identifier: "Apps").firstMatch.click()
        let upload = controls.buttons["Upload…"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        upload.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        guard cancel.exists else { return }
        cancel.click()
        upload.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(artifacts + "/fixture.tgz")
        app.typeKey(.return, modifierFlags: [])
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(controls.staticTexts["Acceptance Clock · 1.0.0"].waitForExistence(timeout: 5))
        controls.buttons["Cancel"].click() // Cancel staging; never install.

        controls.descendants(matching: .any).matching(identifier: "Arcade").firstMatch.click()
        let play = controls.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isEnabled)
        play.click()
        XCTAssertTrue(controls.staticTexts["Keyboard captured · 1–4 switch games · R restarts · Esc stops"].waitForExistence(timeout: 5))
        canvasWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).click()
        XCTAssertTrue(controls.staticTexts["Keyboard controls are paused."].waitForExistence(timeout: 5))
        controls.buttons["Capture Keyboard"].click()
        XCTAssertTrue(controls.staticTexts["Keyboard captured · 1–4 switch games · R restarts · Esc stops"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        let stopped = NSPredicate(format: "exists == false")
        expectation(for: stopped, evaluatedWith: controls.buttons["Stop"])
        waitForExpectations(timeout: 5)
        func arcadeUploadCount() throws -> Int {
            let data = try Data(contentsOf: URL(fileURLWithPath: artifacts + "/requests.json"))
            let requests = try JSONSerialization.jsonObject(with: data) as! [[String: String]]
            return requests.filter { $0["path"] == "/api/assets/upload" && $0["file"]?.hasPrefix("arcade") == true }.count
        }
        Thread.sleep(forTimeInterval: 0.3)
        let before = try! arcadeUploadCount()
        XCTAssertGreaterThan(before, 0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try! arcadeUploadCount(), before)

        app.activate() // Escape restored the pre-game focus; return only to our fixture app.
        controls.descendants(matching: .any).matching(identifier: "Settings").firstMatch.click()
        let weather = controls.textFields["Fixture City"]
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        guard weather.exists else { return }
        weather.click()
        weather.typeText(" ")
        weather.typeText("\n")
        func weatherCity() -> String? {
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: artifacts + "/weather-state.json")),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] else { return nil }
            return value["city"]
        }
        for _ in 0..<50 {
            if weatherCity() == "" { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(weatherCity(), "", "Submit must remove the pinned city from isolated app preferences")
        let tools = controls.buttons["All Device Controls…"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.click()
        XCTAssertTrue(app.windows["BarKeep Device Controls"].waitForExistence(timeout: 5))
        let toolsWindow = app.windows["BarKeep Device Controls"]
        toolsWindow.buttons["Read from Bar"].click()
        let save = toolsWindow.buttons["Save Response…"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: save)
        waitForExpectations(timeout: 5)
        save.click()
        let saveCancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(saveCancel.waitForExistence(timeout: 5))
        saveCancel.click()
        save.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(artifacts)
        app.typeKey(.return, modifierFlags: [])
        let saveConfirm = app.buttons["Save"].firstMatch
        XCTAssertTrue(saveConfirm.waitForExistence(timeout: 5))
        guard saveConfirm.exists else { return }
        saveConfirm.click()
        let exportedURL = URL(fileURLWithPath: artifacts + "/busy-bar-response")
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: exportedURL.path) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let exported = try Data(contentsOf: exportedURL)
        XCTAssertEqual(exported, Data(#"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#.utf8))

        let search = toolsWindow.textFields["Find a device control"]
        XCTAssertTrue(search.exists)
        guard search.exists else { return }
        search.click()
        search.typeText("Upload asset file with app ID")
        let assetEndpoint = toolsWindow.staticTexts["Upload asset file with app ID"].firstMatch
        XCTAssertTrue(assetEndpoint.waitForExistence(timeout: 5))
        guard assetEndpoint.exists else { return }
        assetEndpoint.click()
        let choose = toolsWindow.buttons["Choose File…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        guard choose.exists else { return }
        let uploadsBeforeSelection = try requestRecords().filter { $0["path"] == "/api/assets/upload" }.count
        choose.click()
        let chooseCancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(chooseCancel.waitForExistence(timeout: 5))
        guard chooseCancel.exists else { return }
        chooseCancel.click()
        XCTAssertTrue(toolsWindow.staticTexts["No file selected"].exists)
        choose.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(artifacts + "/fixture.tgz")
        app.typeKey(.return, modifierFlags: [])
        let chooseConfirm = app.buttons["Open"].firstMatch
        XCTAssertTrue(chooseConfirm.waitForExistence(timeout: 5))
        guard chooseConfirm.exists else { return }
        chooseConfirm.click()
        XCTAssertTrue(toolsWindow.staticTexts["fixture.tgz"].waitForExistence(timeout: 5))
        XCTAssertEqual(try requestRecords().filter { $0["path"] == "/api/assets/upload" }.count, uploadsBeforeSelection, "Choosing a file must not submit the API action")
        // Never press Apply to Bar: selecting a fixture is the entire authorized action.
        controls.buttons["Quit BarKeep"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}
