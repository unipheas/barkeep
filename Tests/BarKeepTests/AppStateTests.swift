import AppKit
import XCTest
@testable import BarKeep

final class AppStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        suite = "dev.barkeep.state-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName:suite)!
        HTTPStub.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200,Data(#"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#.utf8))
            case "/api/busy/snapshot" where request.httpMethod == "GET": return (200,Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8))
            default: return (200,Data("{}".utf8))
            }
        }
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName:suite)
        HTTPStub.handler = nil
    }
    @MainActor private func state() -> AppState {
        AppState(defaults:defaults,startServices:false,session:HTTPStub.session(),slackSession:HTTPStub.session(),weatherSession:HTTPStub.session())
    }
    @MainActor private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("State did not settle",file:file,line:line)
    }

    @MainActor func testPreferencesRoundTripWithoutStartingOSServices() {
        let app = state()
        app.theme = "coding"; app.triggerSmartHome = false
        app.offDebounceSeconds = 0.1; app.notificationAppFilter = "teams,slack"
        app.notificationChime = true; app.queueDuringCalls = false
        app.slackSyncEnabled = true; app.slackToken = "fixture"
        app.pingHost = "localhost"
        app.presets = [MessagePreset(text:"Saved",font:"bold",colorHex:"#FFFFFFFF")]
        let restored = state()
        XCTAssertEqual(restored.theme,"coding"); XCTAssertFalse(restored.triggerSmartHome)
        XCTAssertEqual(restored.offDebounceSeconds,0.1)
        XCTAssertEqual(restored.notificationAppFilter,"teams,slack")
        XCTAssertTrue(restored.notificationChime); XCTAssertFalse(restored.queueDuringCalls)
        XCTAssertTrue(restored.slackSyncEnabled); XCTAssertEqual(restored.slackToken,"fixture")
        XCTAssertEqual(restored.pingHost,"localhost"); XCTAssertEqual(restored.presets,app.presets)
        XCTAssertEqual(restored.weatherLocationLabel,"Automatic (IP-based)")
    }

    @MainActor func testDeviceControlsCommitAndRollbackOnFailure() async {
        let app = state()
        app.lastError = "pending"
        app.applyBrightness("50")
        await eventually { app.lastError == nil }
        XCTAssertEqual(app.brightnessValue,"50")
        app.lastError = "pending"; app.applyVolume(40)
        await eventually { app.lastError == nil }
        XCTAssertEqual(app.volumeValue,40)
        app.deviceNameText = "Test"; app.lastError = "pending"; app.applyDeviceName()
        await eventually { app.lastError == nil }
        HTTPStub.handler = { _ in (500,Data("failed".utf8)) }
        app.applyBrightness("75"); await eventually { app.lastError?.contains("500") == true }
        XCTAssertEqual(app.brightnessValue,"50")
        app.lastError = nil; app.applyVolume(80)
        await eventually { app.lastError != nil }
        XCTAssertEqual(app.volumeValue,40)
        app.lastError = nil; app.applyDeviceName(); await eventually { app.lastError != nil }
    }

    @MainActor func testTimersAndBusyOwnership() async {
        let app = state()
        app.startPomodoro(workMinutes:25,restMinutes:5,cycles:4)
        await eventually { app.onCall }
        app.setOnCall(false); await eventually { !app.onCall }
        app.startSimpleTimer(minutes:5); await eventually { app.onCall }
        app.setOnCall(false); await eventually { !app.onCall }
        HTTPStub.handler = { _ in (500,Data()) }
        app.lastError = nil; app.startPomodoro(workMinutes:25,restMinutes:5,cycles:4)
        await eventually { app.lastError != nil }; XCTAssertFalse(app.onCall)
        app.lastError = nil; app.startSimpleTimer(minutes:5)
        await eventually { app.lastError != nil }; XCTAssertFalse(app.onCall)
    }

    @MainActor func testMicrophoneCallDetectionDebouncesAndRespectsExternalBusy() async {
        let app = state()
        app.offDebounceSeconds = 0.02
        app.micStateChanged(.init(isInUse:true,deviceNames:["Test microphone"]))
        await eventually { app.onCall }
        XCTAssertTrue(app.micInUse); XCTAssertEqual(app.activeMicrophoneNames,["Test microphone"])
        app.micStateChanged(.init(isInUse:false,deviceNames:[]))
        app.micStateChanged(.init(isInUse:true,deviceNames:["Test microphone"]))
        try? await Task.sleep(for:.milliseconds(40))
        XCTAssertTrue(app.onCall,"A brief idle interval must not clear a continuing call")
        app.micStateChanged(.init(isInUse:false,deviceNames:[]))
        await eventually { !app.onCall }
        app.autoOnCall = false
        app.micStateChanged(.init(isInUse:true,deviceNames:["Test microphone"]))
        XCTAssertFalse(app.onCall)
        defaults.set(true,forKey:"autoOnCall")
        let external = state()
        var writes = 0
        HTTPStub.handler = { request in
            if request.httpMethod == "PUT" { writes += 1 }
            return (200,Data(#"{"snapshot":{"type":"SIMPLE"}}"#.utf8))
        }
        external.micStateChanged(.init(isInUse:true,deviceNames:[]))
        await eventually { external.onCall }
        external.micStateChanged(.init(isInUse:false,deviceNames:[]))
        XCTAssertEqual(writes,0,"Do not take ownership of another app's busy session")
    }

    @MainActor func testCallEndingDuringBusyRequestDoesNotLeaveBarStuckBusy() async {
        for duringWrite in [false,true] {
            let app = state()
            app.offDebounceSeconds = 0
            let pending = expectation(description:"Busy request pending")
            var writes = 0
            HTTPStub.handler = { request in
                if request.url!.path == "/api/busy/snapshot" {
                    if request.httpMethod == "GET" {
                        if !duringWrite { pending.fulfill(); Thread.sleep(forTimeInterval:0.05) }
                        return (200,Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8))
                    }
                    writes += 1
                    if duringWrite && writes == 1 { pending.fulfill(); Thread.sleep(forTimeInterval:0.05) }
                }
                return (200,Data("{}".utf8))
            }
            app.micStateChanged(.init(isInUse:true,deviceNames:[]))
            await fulfillment(of:[pending],timeout:1)
            app.micStateChanged(.init(isInUse:false,deviceNames:[]))
            try? await Task.sleep(for:.milliseconds(120))
            XCTAssertFalse(app.onCall)
            XCTAssertEqual(writes,duringWrite ? 2 : 0)
        }
    }

    @MainActor func testTeamsNotificationFiltersQueueAndFlush() async throws {
        let app = state()
        app.notificationChime = true
        var delivered: [String] = []
        let draw = expectation(description:"Teams notification drawn")
        let sound = expectation(description:"Notification chime")
        HTTPStub.handler = { request in
            if request.url!.path == "/api/display/draw" {
                delivered.append(String(decoding:HTTPStub.body(request),as:UTF8.self))
                draw.fulfill()
            }
            if request.url!.path == "/api/audio/play" { sound.fulfill() }
            return (200,Data("{}".utf8))
        }
        app.handleNotification(.init(bundleID:"other.app",title:"Ignored",body:"Private"))
        app.handleNotification(.init(bundleID:"com.microsoft.teams2",title:"",body:""))
        app.handleNotification(.init(bundleID:"com.microsoft.teams2",title:"Réunion",body:"Test 👋"))
        await fulfillment(of:[draw,sound],timeout:2)
        await eventually { app.lastError == nil }
        XCTAssertEqual(delivered.count,1)
        XCTAssertTrue(delivered[0].contains("Reunion: Test")); XCTAssertTrue(delivered[0].contains("7B83EB"))
        app.setOnCall(true); await eventually { app.onCall }
        app.handleNotification(.init(bundleID:"com.microsoft.teams2",title:"Queued",body:"One"))
        XCTAssertEqual(app.queuedCount,1)
        app.queueDuringCalls = false
        app.handleNotification(.init(bundleID:"com.microsoft.teams2",title:"Suppressed",body:"Two"))
        XCTAssertEqual(app.queuedCount,1)
        let flush = expectation(description:"Queued notification flushed")
        HTTPStub.handler = { request in
            if request.url!.path == "/api/display/draw" {
                XCTAssertTrue(String(decoding:HTTPStub.body(request),as:UTF8.self).contains("Queued: One"))
                flush.fulfill()
            }
            return (200,Data("{}".utf8))
        }
        app.setOnCall(false)
        await fulfillment(of:[flush],timeout:2)
        XCTAssertEqual(app.queuedCount,0)
    }

    @MainActor func testMessagesImagesDrawingAndErrors() async {
        let app = state()
        for action in [
            { app.sendMessage("ASCII",font:.normal,color:.white,timeoutSeconds:5) },
            { app.sendMessage("Hello 👋",font:.normal,color:.white,timeoutSeconds:5) },
            { app.sendPreset(.init(text:"Preset",font:"unknown",colorHex:"invalid")) },
            { app.sendDrawing([["#FF0000FF",nil]],timeoutSeconds:5) },
            { app.clearDisplay() }
        ] {
            app.lastError = "pending"; action(); await eventually { app.lastError == nil }
        }
        app.lastError = "untouched"
        app.sendMessage("  \n ",font:.normal,color:.white,timeoutSeconds:5)
        XCTAssertEqual(app.lastError,"untouched")
        app.lastError = nil; app.sendDrawing([],timeoutSeconds:5)
        await eventually { app.lastError != nil }
        XCTAssertTrue(app.lastError!.contains("encode"))
        HTTPStub.handler = { _ in (500,Data()) }
        for action in [
            { app.sendMessage("Error",font:.normal,color:.white,timeoutSeconds:5) },
            { app.sendDrawing([[nil]],timeoutSeconds:5) },
            { app.clearDisplay() }
        ] {
            app.lastError = nil; action(); await eventually { app.lastError != nil }
        }
    }

    @MainActor func testFirmwareUpdatePollingOutcomes() async {
        let app=state()
        for (status,version,expected) in [("available","1.4.0","Update available: 1.4.0"),
                                           ("not_available","","Up to date"),("failure","","Check failed"),
                                           ("pending","","Check timed out")] {
            HTTPStub.handler={ request in
                if request.url?.path == "/api/update/status" {
                    return (200,Data("{\"check\":{\"status\":\"\(status)\",\"available_version\":\"\(version)\",\"event\":\"stop\"}}".utf8))
                }
                return (200,Data())
            }
            app.checkForUpdate(pollInterval:.milliseconds(1))
            await eventually { app.updateCheckText != "Checking…" }
            XCTAssertTrue(app.updateCheckText!.contains(expected))
        }
        HTTPStub.handler={ _ in (500,Data()) }
        app.checkForUpdate(pollInterval:.milliseconds(1))
        await eventually { app.updateCheckText != "Checking…" }
        XCTAssertTrue(app.updateCheckText!.contains("HTTP 500"))
    }

    @MainActor func testPreviewLoopPixelsAuthenticationAndCancellation() async {
        let app=state()
        let bytes=Data(Array(repeating:[UInt8(0x33),0x22,0xEE],count:72*16).flatMap { $0 })
        HTTPStub.handler={ _ in (200,Data(bytes.base64EncodedString().utf8)) }
        let preview=Task { await app.previewLoop(interval:.milliseconds(5)) }
        await eventually { app.screenPreview != nil }
        XCTAssertTrue(app.deviceReachable)
        XCTAssertEqual(app.screenPreview?.width,72)
        let rendered = app.screenPreview!.dataProvider!.data! as Data
        XCTAssertEqual(Array(rendered.prefix(4)),[0xEE,0x22,0x33,0xFF], "Device BGR must render as RGBA")
        preview.cancel(); await preview.value
        HTTPStub.handler={ _ in (403,Data()) }
        let failed=Task { await app.previewLoop(interval:.milliseconds(5)) }
        await eventually { app.authenticationRejected }
        XCTAssertNil(app.screenPreview); XCTAssertFalse(app.deviceReachable)
        failed.cancel(); await failed.value
    }

    @MainActor func testWeatherLocationAndWidgetLifecycle() async {
        let app=state()
        let displayed=expectation(description:"Weather displayed")
        displayed.assertForOverFulfill=false
        HTTPStub.handler={ request in
            switch request.url?.host {
            case "geocoding-api.open-meteo.com":
                return (200,Data(#"{"results":[{"latitude":1,"longitude":2,"name":"Fixture City"}]}"#.utf8))
            case "api.open-meteo.com":
                return (200,Data(#"{"current":{"temperature_2m":20,"weather_code":0}}"#.utf8))
            default:
                if request.url?.path == "/api/display/draw",request.httpMethod == "POST",
                   String(decoding:HTTPStub.body(request),as:UTF8.self).contains("20F") { displayed.fulfill() }
                return (200,Data())
            }
        }
        app.applyWeatherLocation("Fixture City")
        await eventually { app.weatherLocationLabel == "Fixture City" }
        XCTAssertEqual(defaults.double(forKey:"weatherLat"),1)
        app.showWeather=true
        await fulfillment(of:[displayed],timeout:2)
        XCTAssertEqual(app.latestWeather?.tempText,"20F")
        app.weatherCelsius=true
        await eventually { app.latestWeather?.unit == "C" }
        app.showWeather=false
        XCTAssertNil(app.latestWeather)
        app.applyWeatherLocation("")
        XCTAssertEqual(app.weatherLocationLabel,"Automatic (IP-based)")
        HTTPStub.handler={ _ in (200,Data("{}".utf8)) }
        app.lastError=nil; app.applyWeatherLocation("Missing City")
        await eventually { app.lastError != nil }
        XCTAssertTrue(app.lastError!.contains("Could not find"))
        // Let the canceled widget task and expiration request finish before the fixture is removed.
        try? await Task.sleep(for:.milliseconds(20))
    }

    @MainActor func testPingWidgetAndPauseResumePreservePreferences() async throws {
        let app=state()
        app.pingHost="127.0.0.1"
        HTTPStub.handler={ _ in (200,Data()) }
        app.showPing=true
        await eventually { app.latestPingMs != nil }
        let fixture=try JSONDecoder().decode(DeviceApp.self,from:Data(appFixture.utf8))
        try await app.launchDeviceApp(fixture,on:app.client)
        XCTAssertTrue(app.widgetsPausedForApp); XCTAssertTrue(app.showPing)
        XCTAssertTrue(defaults.bool(forKey:"showPing"))
        app.resumeWidgets()
        await eventually { app.latestPingMs != nil }
        XCTAssertFalse(app.widgetsPausedForApp)
        app.showPing=false
        XCTAssertNil(app.latestPingMs)
        try? await Task.sleep(for:.milliseconds(20))
    }

    @MainActor func testDeviceAppDisplayHandoffAndFailedLaunchRestoresWidgets() async throws {
        let app = state()
        let fixture = try JSONDecoder().decode(DeviceApp.self,from:Data(appFixture.utf8))
        var requests: [String] = []
        HTTPStub.handler = { request in
            requests.append(request.httpMethod! + " " + request.url!.path)
            return (200,Data())
        }
        let model = DeviceAppsModel(client:app.client,
            launchAction:{ client, deviceApp in try await app.launchDeviceApp(deviceApp,on:client) },
            stopAction:{ app.resumeWidgets() },removeAction:{ app.deviceAppRemoved($0) })
        await model.launch(fixture)
        XCTAssertNil(model.error); XCTAssertTrue(app.widgetsPausedForApp)
        XCTAssertEqual(requests,["DELETE /api/display/draw","POST /api/apps/launch"])
        await model.stop()
        XCTAssertFalse(app.widgetsPausedForApp)
        XCTAssertEqual(requests.last,"POST /api/apps/quit")
        await model.launch(fixture)
        await model.remove(fixture)
        XCTAssertFalse(app.widgetsPausedForApp,"Removing the app should resume widgets")
        HTTPStub.handler = { _ in (500,Data()) }
        await model.launch(fixture)
        XCTAssertFalse(app.widgetsPausedForApp); XCTAssertNotNil(model.error)
    }
}
