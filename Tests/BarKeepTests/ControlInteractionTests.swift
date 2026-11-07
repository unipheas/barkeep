import XCTest
import SwiftUI
import ViewInspector
@testable import BarKeep

final class ControlInteractionTests: XCTestCase {
    @MainActor func testDeviceAndTimerButtonsReflectBusyState() async throws {
        let suite="dev.barkeep.control-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        HTTPStub.handler = { _ in (200,Data("{}".utf8)) }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let device=DeviceTab().environment(state)
        let follow=try device.inspect().find(ViewType.Toggle.self,where: {
            (try? $0.labelView().find(text:"Follow microphone")) != nil
        })
        XCTAssertTrue(try follow.isOn())
        try follow.tap()
        XCTAssertFalse(state.autoOnCall)
        let timers=TimersTab().environment(state)
        XCTAssertFalse(try timers.inspect().find(button:"Start Timer").isDisabled())
        try timers.inspect().find(button:"Start Timer").tap()
        await settle { state.onCall }
        XCTAssertTrue(try timers.inspect().find(button:"Start Timer").isDisabled())
        XCTAssertTrue(try timers.inspect().find(button:"Start Pomodoro").isDisabled())
        try timers.inspect().find(button:"End Current Session").tap()
        await settle { !state.onCall }
        try timers.inspect().find(button:"Start Pomodoro").tap()
        await settle { state.onCall }
        await state.setOnCall(false).value
        let busy=try device.inspect().find(ViewType.Toggle.self,where: {
            (try? $0.labelView().find(text:"On Call / Busy")) != nil
        })
        try busy.tap()
        await settle { state.onCall }
        await state.setOnCall(false).value
    }

    @MainActor func testAppListButtonsRefreshRunAndStop() async throws {
        let client=BusyBarClient(host:"fixture.test",session:HTTPStub.session())
        let model=DeviceAppsModel(client:client)
        let lock=NSLock()
        var calls:[String]=[]
        HTTPStub.handler = { request in
            lock.withLock { calls.append(request.url!.path) }
            if request.url!.path == "/api/apps/list" { return (200,Data("{\"apps\":[\(appFixture)]}".utf8)) }
            return (200,Data("{}".utf8))
        }
        defer { HTTPStub.handler=nil }
        let apps=AppsContent(model:model)
        try apps.inspect().find(button:"Refresh").tap()
        await settle { model.loaded }
        XCTAssertNotNil(try apps.inspect().find(text:"Clock"))
        try apps.inspect().find(button:"Run").tap()
        await settle { model.message?.contains("Launched") == true }
        try apps.inspect().find(button:"Stop Running App").tap()
        await settle { model.message?.contains("stopped") == true }
        XCTAssertTrue(lock.withLock { calls.contains("/api/apps/launch") })
        XCTAssertTrue(lock.withLock { calls.contains("/api/apps/quit") })
    }

    @MainActor func testPresetAndClearButtonsUseDeviceClientAndRespectBusyState() async throws {
        let suite="dev.barkeep.message-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        let drawn=expectation(description:"Preset displayed")
        let cleared=expectation(description:"Display cleared")
        HTTPStub.handler = { request in
            if request.url!.path == "/api/display/draw" && request.httpMethod == "POST" {
                XCTAssertTrue(String(decoding:HTTPStub.body(request),as:UTF8.self).contains("Come in!"))
                drawn.fulfill()
            }
            if request.url!.path == "/api/display/draw" && request.httpMethod == "DELETE" { cleared.fulfill() }
            return (200,Data("{}".utf8))
        }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let message=MessageTab().environment(state)
        let sends=try message.inspect().findAll(ViewType.Button.self,where: {
            (try? $0.labelView().text().string()) == "Send" && !$0.isDisabled()
        })
        XCTAssertEqual(sends.count,3)
        try sends[0].tap()
        await fulfillment(of:[drawn],timeout:3)
        try message.inspect().find(button:"Clear Display").tap()
        await fulfillment(of:[cleared],timeout:3)
        try message.inspect().find(ViewType.Button.self,where: {
            (try? $0.accessibilityLabel().string())?.hasPrefix("Remove preset:") == true
        }).tap()
        XCTAssertEqual(state.presets.count,2)
        XCTAssertFalse(state.presets.contains { $0.text == "Come in!" })
        await state.setOnCall(true).value
        XCTAssertTrue(try message.inspect().find(button:"Send").isDisabled())
        XCTAssertTrue(try message.inspect().find(ViewType.Button.self,where: {
            (try? $0.accessibilityLabel().string())?.hasPrefix("Remove preset:") == true
        }).isDisabled())
        await state.setOnCall(false).value
    }

    @MainActor func testConnectionAndPreferenceControlsPersistTheirValues() async throws {
        let suite="dev.barkeep.preferences-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        HTTPStub.handler={ _ in (200,Data("{}".utf8)) }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let settings=SettingsTab().environment(state)
        try settings.inspect().find(ViewType.Picker.self,where: {
            (try? $0.labelView().text().string()) == "On-call theme"
        }).select(value:"dnd")
        try settings.inspect().find(ViewType.Toggle.self,where: {
            (try? $0.labelView().text().string()) == "Trigger smart home"
        }).tap()
        try settings.inspect().find(ViewType.Picker.self,where: {
            (try? $0.labelView().text().string()) == "Weather unit"
        }).select(value:true)
        try settings.inspect().find(ViewType.TextField.self,where: {
            (try? $0.labelView().text().string()) == "1.1.1.1"
        }).setInput("127.0.0.1")
        try settings.inspect().find(ViewType.Toggle.self,where: {
            (try? $0.labelView().text().string()) == "Sync Slack status when busy"
        }).tap()
        XCTAssertEqual(defaults.string(forKey:"theme"),"dnd")
        XCTAssertFalse(defaults.bool(forKey:"triggerSmartHome"))
        XCTAssertTrue(defaults.bool(forKey:"weatherCelsius"))
        XCTAssertTrue(defaults.bool(forKey:"slackSyncEnabled"))
        XCTAssertEqual(defaults.string(forKey:"pingHost"),"127.0.0.1")
        let connection=ConnectionSettings().environment(state)
        try connection.inspect().find(ViewType.Picker.self).select(value:DeviceConnectionMode.wifi)
        XCTAssertTrue(try connection.inspect().find(button:"Reconnect").isDisabled())
        try connection.inspect().find(ViewType.TextField.self,where: {
            (try? $0.labelView().text().string()) == "busybar.local or IP"
        }).setInput("fixture.test")
        await settle { !state.isConnecting }
        XCTAssertEqual(state.client.host,"fixture.test")
        try connection.inspect().find(button:"Reconnect").tap()
        await settle { !state.isConnecting }
        try connection.inspect().find(ViewType.Picker.self).select(value:DeviceConnectionMode.usb)
        await settle { !state.isConnecting }
        XCTAssertEqual(state.client.host,"10.0.4.20")
        XCTAssertEqual(state.wifiHost,"fixture.test")
        let device=DeviceTab().environment(state)
        try device.inspect().find(ViewType.Picker.self).select(value:"50")
        await settle { state.brightnessValue == "50" }
        // SwiftUI stores the slider binding in normalized 0...1 coordinates.
        try device.inspect().find(ViewType.Slider.self).setValue(0.4)
        await settle { state.volumeValue == 40 }
    }

    @MainActor private func settle(_ predicate: () -> Bool, file:StaticString = #filePath,line:UInt = #line) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("UI state did not settle",file:file,line:line)
    }
}
