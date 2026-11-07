import AppKit
import EventKit
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

    @MainActor func testStartupWiresPermissionsMicrophoneNotificationsAndCalendar() async throws {
        defaults.set(true,forKey:"forwardNotifications")
        defaults.set(true,forKey:"calendarAutoBusy")
        defaults.set(0.0,forKey:"offDebounceSeconds")
        let browser=FixtureNetworkBrowser()
        let permission=LocalNetworkPermissionTrigger(makeBrowser:{browser})
        let microphone=MicMonitor(hardware:AudioHardwareCalls(
            size:{ _,_,size in size=0; return 0 },
            read:{ _,_,_,_ in 0 },add:{ _,_,_,_ in 0 },remove:{ _,_,_,_ in 0 }))
        let watcher=NotificationWatcher(paths:[])
        let calendar=AppCalendarFixture()
        let app=AppState(defaults:defaults,session:HTTPStub.session(),calendarSource:calendar,
                         localNetworkPermissionTrigger:permission,micMonitor:microphone,notificationWatcher:watcher)
        defer { microphone.stop(); app.forwardNotifications=false; app.calendarAutoBusy=false }
        await eventually { app.deviceReachable && app.notificationStatus == .noAccess }
        XCTAssertEqual(browser.starts,1)
        XCTAssertTrue(app.calendarAccessGranted)
        browser.stateUpdateHandler?(.ready)
        await eventually { browser.cancels == 1 && !app.isConnecting }
        microphone.onChange?(.init(isInUse:true,deviceNames:["Fixture Teams microphone"]))
        await eventually { app.onCall && app.micInUse }
        XCTAssertEqual(app.activeMicrophoneNames,["Fixture Teams microphone"])
        microphone.onChange?(.init(isInUse:false,deviceNames:[]))
        await eventually { !app.onCall && !app.micInUse }
        let delivered=expectation(description:"Watcher callback reaches device")
        HTTPStub.handler={ request in
            if request.url!.path == "/api/display/draw" {
                XCTAssertTrue(String(decoding:HTTPStub.body(request),as:UTF8.self).contains("Fixture notification"))
                delivered.fulfill()
            }
            return (200,Data("{}".utf8))
        }
        watcher.onNotification?(.init(bundleID:"com.microsoft.teams2",title:"Fixture notification",body:""))
        await fulfillment(of:[delivered],timeout:2)
        await eventually { app.lastError == nil }
    }

    @MainActor func testCalendarBusyCountdownAndDisableLifecycle() async throws {
        let source = AppCalendarFixture()
        let now = Date()
        let current = EKEvent(eventStore: EKEventStore())
        current.title = "Fixture meeting"; current.startDate = now.addingTimeInterval(-60); current.endDate = now.addingTimeInterval(60)
        let next = EKEvent(eventStore: EKEventStore())
        next.title = "Fixture next"; next.startDate = now.addingTimeInterval(120); next.endDate = now.addingTimeInterval(300)
        source.items = [current, next]
        let app = AppState(defaults:defaults,startServices:false,session:HTTPStub.session(),calendarSource:source)
        app.offDebounceSeconds = 0
        app.sendMeetingCountdown() // No meeting is loaded yet.
        app.calendarAutoBusy = true
        await eventually { app.onCall && app.inMeeting }
        XCTAssertEqual(app.nextMeetingTitle,"Fixture next")
        XCTAssertTrue(app.calendarAccessGranted)
        let sent = expectation(description:"Meeting countdown sent")
        HTTPStub.handler = { request in
            if request.url!.path == "/api/display/draw" { sent.fulfill() }
            return (200,Data("{}".utf8))
        }
        app.lastError = "pending"
        app.sendMeetingCountdown()
        await fulfillment(of:[sent],timeout:2)
        await eventually { app.lastError == nil }
        HTTPStub.handler = { _ in (500,Data()) }
        app.sendMeetingCountdown()
        await eventually { app.lastError?.contains("500") == true }
        HTTPStub.handler = { _ in (200,Data("{}".utf8)) }
        app.calendarAutoBusy = false
        await eventually { !app.onCall && !app.inMeeting }
        XCTAssertNil(app.nextMeetingTitle); XCTAssertNil(app.nextMeetingDate)
    }

    @MainActor func testSlackSyncErrorsRemainVisibleAfterBusyChanges() async {
        let app = state()
        let original = HTTPStub.handler!
        HTTPStub.handler = { request in
            if request.url?.host == "slack.com" { return (200,Data(#"{"ok":false,"error":"missing_scope"}"#.utf8)) }
            return try original(request)
        }
        app.slackToken = "fixture"; app.slackSyncEnabled = true
        app.setOnCall(true)
        await eventually { app.lastError?.contains("missing_scope") == true }
        XCTAssertTrue(app.onCall)
        app.lastError = nil
        app.setOnCall(false)
        await eventually { app.lastError?.contains("missing_scope") == true }
        XCTAssertFalse(app.onCall)
    }

    @MainActor func testCallEndWaitsForPendingCallStart() async throws {
        for session in ["call","simple","pomodoro"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PendingBusyRequest.self]
            let app = AppState(defaults:defaults,startServices:false,session:URLSession(configuration:config))
            let lock = NSLock()
            var pending: [PendingBusyRequest] = []
            PendingBusyRequest.arrived = { request in lock.withLock { pending.append(request) } }
            defer { PendingBusyRequest.arrived = nil }
            let start: Task<Void,Never>
            switch session {
            case "simple": start = app.startSimpleTimer(minutes:5)
            case "pomodoro": start = app.startPomodoro(workMinutes:25,restMinutes:5,cycles:4)
            default: start = app.setOnCall(true)
            }
            await eventually { lock.withLock { pending.count == 1 } }
            let stop = app.setOnCall(false)
            try await Task.sleep(for:.milliseconds(80))
            XCTAssertEqual(lock.withLock { pending.count },1,"A call end must wait for the pending device write")
            lock.withLock { pending[0] }.finish()
            await eventually { lock.withLock { pending.count == 2 } }
            let second = lock.withLock { pending[1] }
            let json = try JSONSerialization.jsonObject(with:HTTPStub.body(second.request)) as! [String:Any]
            XCTAssertEqual((json["snapshot"] as? [String:Any])?["type"] as? String,"NOT_STARTED")
            second.finish()
            await start.value; await stop.value
            XCTAssertFalse(app.onCall)
            XCTAssertNil(app.lastError)
        }
    }

    @MainActor func testBusyFailureRemainsVisibleAfterSuccessfulStatusRefresh() async {
        let original = HTTPStub.handler!
        HTTPStub.handler = { request in
            if request.httpMethod == "PUT" { return (503,Data()) }
            return try original(request)
        }
        let app = state()
        await app.setOnCall(true).value
        XCTAssertFalse(app.onCall)
        XCTAssertTrue(app.deviceReachable)
        XCTAssertTrue(app.lastError?.contains("503") == true)
    }

    @MainActor func testConnectionChangeDiscardsQueuedBusyWrites() async {
        defaults.set("next.test",forKey:"wifiHost")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingBusyRequest.self]
        let app = AppState(defaults:defaults,startServices:false,session:URLSession(configuration:config))
        let lock = NSLock()
        var pending: [PendingBusyRequest] = []
        PendingBusyRequest.arrived = { request in
            if request.request.httpMethod == "PUT" { lock.withLock { pending.append(request) } }
            else { request.finish() }
        }
        defer { PendingBusyRequest.arrived = nil }
        let start = app.setOnCall(true)
        await eventually { lock.withLock { pending.count == 1 } }
        let stop = app.setOnCall(false)
        app.connectionMode = .wifi
        lock.withLock { pending[0] }.finish()
        await start.value; await stop.value
        await eventually { !app.isConnecting }
        XCTAssertEqual(lock.withLock { pending.count },1)
        XCTAssertFalse(app.onCall)
        let newStart = app.setOnCall(true)
        await eventually { lock.withLock { pending.count == 2 } }
        let request = lock.withLock { pending[1] }
        XCTAssertEqual(request.request.url?.host,"next.test")
        request.finish()
        await newStart.value
        XCTAssertTrue(app.onCall)
    }

    @MainActor func testCancelledControlWritesDoNotBlockRefreshOrRetainState() async {
        var app: AppState? = state()
        weak var released = app
        let brightness = app!.applyBrightness("75")
        let volume = app!.applyVolume(50)
        let busy = app!.setOnCall(true)
        brightness.cancel(); volume.cancel(); busy.cancel()
        await brightness.value; await volume.value; await busy.value
        let original = HTTPStub.handler!
        HTTPStub.handler = { request in
            if request.url!.path == "/api/display/brightness" { return (200,Data(#"{"value":"25"}"#.utf8)) }
            if request.url!.path == "/api/audio/volume" { return (200,Data(#"{"volume":30}"#.utf8)) }
            return try original(request)
        }
        await app!.refreshDeviceStatus()
        XCTAssertEqual(app!.volumeValue,30)
        XCTAssertEqual(app!.brightnessValue,"25")
        app = nil
        XCTAssertNil(released,"A cancelled operation must release its stored task")
    }

    @MainActor func testOldStatusRefreshCannotUndoNewBusyWrite() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingBusyRequest.self]
        let app = AppState(defaults:defaults,startServices:false,session:URLSession(configuration:config))
        let lock = NSLock()
        var snapshot: PendingBusyRequest?
        PendingBusyRequest.arrived = { request in
            switch (request.request.httpMethod,request.request.url!.path) {
            case ("GET","/api/busy/snapshot"):
                lock.withLock { snapshot = request }
            case (_,"/api/status"):
                request.finish(json:#"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#)
            default: request.finish()
            }
        }
        defer { PendingBusyRequest.arrived = nil }
        let refresh = Task { await app.refreshDeviceStatus() }
        await eventually { lock.withLock { snapshot != nil } }
        await app.setOnCall(true).value
        XCTAssertTrue(app.onCall)
        lock.withLock { snapshot }?.finish(json:#"{"snapshot":{"type":"NOT_STARTED"}}"#)
        await refresh.value
        XCTAssertTrue(app.onCall,"An older snapshot must not overwrite the completed call-start write")
    }

    @MainActor func testReadsDuringWritesCannotRollBackCommittedControls() async throws {
        for path in ["/api/busy/snapshot","/api/display/brightness","/api/audio/volume"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PendingBusyRequest.self]
            let app = AppState(defaults:defaults,startServices:false,session:URLSession(configuration:config))
            let lock = NSLock()
            var pendingWrite: PendingBusyRequest?, pendingRead: PendingBusyRequest?
            let replies = [
                "/api/status": #"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#,
                "/api/busy/snapshot": #"{"snapshot":{"type":"NOT_STARTED"}}"#,
                "/api/display/brightness": #"{"value":"25"}"#,
                "/api/audio/volume": #"{"volume":30}"#,
            ]
            PendingBusyRequest.arrived = { request in
                if request.request.url!.path == path {
                    lock.withLock {
                        if request.request.httpMethod == "GET" { pendingRead = request }
                        else { pendingWrite = request }
                    }
                } else { request.finish(json:replies[request.request.url!.path] ?? "{}") }
            }
            defer { PendingBusyRequest.arrived = nil }
            let write: Task<Void,Never>
            switch path {
            case "/api/display/brightness": write = app.applyBrightness("75")
            case "/api/audio/volume": write = app.applyVolume(80)
            default: write = app.setOnCall(true)
            }
            await eventually { lock.withLock { pendingWrite != nil } }
            let refresh = Task { await app.refreshDeviceStatus() }
            await eventually { lock.withLock { pendingRead != nil } }
            try XCTUnwrap(lock.withLock { pendingWrite }).finish()
            await write.value
            try XCTUnwrap(lock.withLock { pendingRead }).finish(json:replies[path]!)
            await refresh.value
            switch path {
            case "/api/display/brightness": XCTAssertEqual(app.brightnessValue,"75")
            case "/api/audio/volume": XCTAssertEqual(app.volumeValue,80)
            default: XCTAssertTrue(app.onCall)
            }
        }
    }

    @MainActor func testNotificationDoesNotChimeOrReplayOnNewDevice() async {
        for queued in [false,true] {
            defaults.set("usb",forKey:"connectionMode")
            let app = state()
            app.notificationAppFilter = ""
            app.notificationChime = true
            app.wifiHost = "second.test"
            if queued { app.setOnCall(true); await eventually { app.onCall } }
            let pending = expectation(description:"Notification drawing pending")
            let finished = expectation(description:"Old response finished")
            let release = DispatchSemaphore(value:0)
            let lock = NSLock()
            var drawnHosts: [String] = [], chimes = 0
            HTTPStub.handler = { request in
                if request.url!.path == "/api/display/draw" {
                    lock.withLock { drawnHosts.append(request.url!.host!) }
                    pending.fulfill()
                    _ = release.wait(timeout:.now()+5)
                    finished.fulfill()
                }
                if request.url!.path == "/api/audio/play" { lock.withLock { chimes += 1 } }
                return (200,Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8))
            }
            defer { release.signal() }
            app.handleNotification(.init(bundleID:"fixture",title:"One",body:"Test"))
            if queued {
                app.handleNotification(.init(bundleID:"fixture",title:"Two",body:"Test"))
                XCTAssertEqual(app.queuedCount,2)
                app.setOnCall(false)
            }
            await fulfillment(of:[pending],timeout:2)
            app.connectionMode = .wifi
            release.signal()
            await fulfillment(of:[finished],timeout:2)
            await eventually { !app.isConnecting }
            XCTAssertEqual(lock.withLock { drawnHosts },["10.0.4.20"])
            XCTAssertEqual(lock.withLock { chimes },0)
            XCTAssertEqual(app.queuedCount,0)
        }
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

    @MainActor func testOlderControlFailureCannotUndoNewSelection() async {
        for brightness in [false,true] {
            let app=state()
            let pending=expectation(description:"First control request pending")
            let release=DispatchSemaphore(value:0)
            let lock=NSLock()
            var writes=0
            HTTPStub.handler={ _ in
                let count=lock.withLock { writes += 1; return writes }
                if count == 1 { pending.fulfill(); _ = release.wait(timeout:.now()+5); return (500,Data()) }
                return (200,Data())
            }
            defer { release.signal() }
            let first=brightness ? app.applyBrightness("25") : app.applyVolume(20)
            await fulfillment(of:[pending],timeout:2)
            let latest=brightness ? app.applyBrightness("75") : app.applyVolume(80)
            release.signal()
            await first.value; await latest.value
            XCTAssertEqual(brightness ? app.brightnessValue : String(app.volumeValue),brightness ? "75" : "80")
            XCTAssertNil(app.lastError)
        }
    }

    @MainActor func testRapidControlWritesCoalesceAndRollbackToLastConfirmedValue() async {
        for brightness in [false,true] {
            let app=state()
            let pending=expectation(description:"First write held")
            let release=DispatchSemaphore(value:0)
            let lock=NSLock()
            var values:[String]=[]
            HTTPStub.handler={ request in
                let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
                let value=query.first { $0.name == (brightness ? "value" : "volume") }!.value!
                let count=lock.withLock { values.append(value); return values.count }
                if count == 1 { pending.fulfill(); _ = release.wait(timeout:.now()+5); return (200,Data()) }
                return (500,Data())
            }
            defer { release.signal() }
            let first=brightness ? app.applyBrightness("25") : app.applyVolume(20)
            await fulfillment(of:[pending],timeout:2)
            let middle=brightness ? app.applyBrightness("50") : app.applyVolume(50)
            let latest=brightness ? app.applyBrightness("75") : app.applyVolume(80)
            release.signal()
            await first.value; await middle.value; await latest.value
            XCTAssertEqual(lock.withLock { values },brightness ? ["25","75"] : ["20","80"])
            XCTAssertEqual(brightness ? app.brightnessValue : String(app.volumeValue),brightness ? "25" : "20")
            XCTAssertTrue(app.lastError?.contains("500") == true)
        }
    }

    @MainActor func testStatusRefreshCannotOverwriteNewControlSelections() async {
        let app=state()
        let pending=expectation(description:"Status refresh has read old control values")
        let release=DispatchSemaphore(value:0)
        let original=HTTPStub.handler!
        HTTPStub.handler={ request in
            if request.httpMethod == "GET" {
                switch request.url!.path {
                case "/api/display/brightness": return (200,Data(#"{"value":"10"}"#.utf8))
                case "/api/audio/volume": return (200,Data(#"{"volume":20}"#.utf8))
                case "/api/name":
                    pending.fulfill(); _ = release.wait(timeout:.now()+5)
                    return (200,Data(#"{"name":"Fixture"}"#.utf8))
                default: break
                }
            }
            return try original(request)
        }
        defer { release.signal() }
        let refresh=Task { await app.refreshDeviceStatus() }
        await fulfillment(of:[pending],timeout:2)
        let brightness=app.applyBrightness("75"), volume=app.applyVolume(80)
        release.signal()
        await refresh.value; await brightness.value; await volume.value
        XCTAssertEqual(app.brightnessValue,"75")
        XCTAssertEqual(app.volumeValue,80)
        XCTAssertTrue(app.deviceReachable)
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
            let release = DispatchSemaphore(value:0)
            let lock = NSLock()
            defer { release.signal() }
            var writes = 0
            HTTPStub.handler = { request in
                if request.url!.path == "/api/busy/snapshot" {
                    if request.httpMethod == "GET" {
                        if !duringWrite { pending.fulfill(); _ = release.wait(timeout:.now()+5) }
                        return (200,Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8))
                    }
                    let count = lock.withLock { writes += 1; return writes }
                    if duringWrite && count == 1 { pending.fulfill(); _ = release.wait(timeout:.now()+5) }
                }
                return (200,Data("{}".utf8))
            }
            let transition = app.micStateChanged(.init(isInUse:true,deviceNames:[]))
            await fulfillment(of:[pending],timeout:3)
            app.micStateChanged(.init(isInUse:false,deviceNames:[]))
            release.signal()
            await transition?.value
            if duringWrite { await eventually { !app.onCall && lock.withLock { writes == 2 } } }
            XCTAssertFalse(app.onCall)
            XCTAssertEqual(lock.withLock { writes },duringWrite ? 2 : 0)
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

@MainActor private final class AppCalendarFixture: CalendarSource {
    let authorizationStatus: EKAuthorizationStatus = .fullAccess
    let notificationObject: AnyObject = NSObject()
    var items: [EKEvent] = []
    func requestAccess() async throws -> Bool { true }
    func events(from: Date, to: Date) -> [EKEvent] { items }
}

/// Keeps each response pending without blocking URLSession's protocol queue.
private final class PendingBusyRequest: URLProtocol {
    static var arrived: ((PendingBusyRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.arrived?(self) }
    override func stopLoading() {}
    func finish(json: String = "{}") {
        let data = Data(json.utf8)
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
