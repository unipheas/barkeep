import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class RemainingControlActionsTests: XCTestCase {
    @MainActor func testAppsSettingsActionAndSystemAlertDismissal() async throws {
        let lock = NSLock()
        var settingsReads = 0
        HTTPStub.handler = { request in
            switch request.url!.path {
            case "/api/apps/list": return (200, Data("{\"apps\":[\(appFixture)]}".utf8))
            case "/api/apps/settings":
                lock.withLock { settingsReads += 1 }
                return (200, Data(#"{"version":1,"values":{"city":"Chicago"}}"#.utf8))
            case "/api/storage/read": return (404, Data())
            default: XCTFail("Unexpected request: \(request)"); return (500, Data())
            }
        }
        defer { HTTPStub.handler = nil }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        await model.refresh()
        var installed: AppsContent?
        var sut = AppsContent(model: model)
        let appeared = expectation(description: "Installed app controls")
        sut.didAppear = { installed = $0; appeared.fulfill() }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel(); model.closeSettings() }
        await fulfillment(of: [appeared], timeout: 5)
        let view = try XCTUnwrap(installed).inspect()
        try view.find(button: "Remove…").tap()
        try view.find(ViewType.Alert.self).dismiss()
        XCTAssertThrowsError(try view.find(text: "Remove Clock?"))
        XCTAssertEqual(model.apps.count, 1)
        try view.find(button: "Settings…").tap()
        for _ in 0..<100 where model.settingsApp == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.settingsApp?.id, "app.test.clock")
        XCTAssertEqual(lock.withLock { settingsReads }, 1)
        XCTAssertTrue(model.settingsJSON.contains("Chicago"))
        try view.find(ViewType.Sheet.self).dismiss()
        XCTAssertNil(model.settingsApp)
    }

    @MainActor func testDeviceChoicesCancelAndCredentialChangesResetDraft() throws {
        let suite = "dev.barkeep.remaining-tools.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let endpoint = try XCTUnwrap(DeviceEndpoint.all.first { !$0.isReadOnly && $0.parameters.contains { !$0.choices.isEmpty } })
        let model = DeviceToolsModel()
        model.reset(for: endpoint)
        let view = try DeviceToolsView(endpoint: endpoint, model: model).environment(state).inspect().find(DeviceToolsView.self)
        for parameter in endpoint.parameters where !parameter.choices.isEmpty {
            let picker = try view.find(ViewType.Picker.self, where: { try $0.labelView().text().string() == parameter.name })
            for choice in parameter.choices { XCTAssertNotNil(try picker.find(text: choice)) }
        }
        // Trigger the same callbacks SwiftUI sends when the destination changes.
        model.values["fixture"] = "stale"
        model.error = "old error"
        try view.hStack().callOnChange(oldValue: "old-host", newValue: "new-host", index: 0)
        XCTAssertNil(model.values["fixture"])
        XCTAssertNil(model.error)
        model.json = "stale"
        model.upload = URL(fileURLWithPath: "/tmp/not-opened.bin")
        try view.hStack().callOnChange(oldValue: "old-token", newValue: "new-token", index: 1)
        XCTAssertEqual(model.json, endpoint.bodyTemplate)
        XCTAssertNil(model.upload)
        model.confirm = true
        try view.find(button: "Cancel").tap()
        try view.find(ViewType.Alert.self).dismiss()
        XCTAssertFalse(model.confirm)
    }

    @MainActor func testDeviceNameSubmitUsesMockedEndpointAndInvalidPresetStillRenders() async throws {
        let suite = "dev.barkeep.remaining-menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("fixture.test", forKey: "wifiHost")
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let submitted = expectation(description: "Device name sent")
        HTTPStub.handler = { request in
            if request.httpMethod == "POST", request.url?.path == "/api/name" { submitted.fulfill() }
            return try MenuStateCoverageTests.reply(request)
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.deviceNameText = "Fixture Name"
        let view = ConnectionSettings().environment(state)
        try view.inspect().find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "BUSY Bar" }).callOnSubmit()
        await fulfillment(of: [submitted], timeout: 5)
        state.presets = [MessagePreset(text: "Invalid legacy color", font: "normal", colorHex: "invalid")]
        XCTAssertNotNil(try MessageTab().environment(state).inspect().find(text: "Invalid legacy color"))
        XCTAssertTrue(try StatusStreamView().environment(state).inspect().find(button: "Save Latest Packet…").isDisabled())
    }
    @MainActor func testQueuedSaveActionsAfterResponseAndPacketResetDoNotExport() async throws {
        let suite = "dev.barkeep.queued-save.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in (200, Data("{}".utf8)) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let endpoint = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/status" })
        let tools = DeviceToolsModel()
        await tools.execute(endpoint, client: state.client)
        var exports = 0
        let toolsView = DeviceToolsView(endpoint: endpoint, model: tools, exportFile: { _, _, _ in exports += 1 }).environment(state)
        let queuedResponseSave = try toolsView.inspect().find(button: "Save Response…")
        XCTAssertFalse(try queuedResponseSave.isDisabled())
        tools.reset(for: endpoint)
        try queuedResponseSave.tap()
        XCTAssertEqual(exports, 0)

        let stream = StatusStreamModel(makeSocket: { _ in RemainingPacketSocket() })
        stream.start(client: state.client)
        defer { stream.stop() }
        for _ in 0..<100 where stream.latestData == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(stream.latestData)
        let streamView = StatusStreamView(model: stream, exportFile: { _, _, _ in exports += 1 }).environment(state)
        let queuedPacketSave = try streamView.inspect().find(button: "Save Latest Packet…")
        XCTAssertFalse(try queuedPacketSave.isDisabled())
        stream.start(client: state.client)
        XCTAssertNil(stream.latestData)
        try queuedPacketSave.tap()
        XCTAssertEqual(exports, 0)
    }

    @MainActor func testQueuedPresetSaveAfterMessageClearedDoesNotCreateEmptyPreset() async throws {
        let suite = "dev.barkeep.queued-preset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.presets = []
        var sut = MessageTab()
        let inspected = sut.on(\.didAppear) { view in
            let input = try view.find(ViewType.TextField.self)
            try input.setInput("Queued message")
            let queuedSave = try view.find(button: "Save current message as preset")
            XCTAssertFalse(try queuedSave.isDisabled())
            try input.setInput("")
            try queuedSave.tap()
            XCTAssertTrue(state.presets.isEmpty)
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
    }

}

private final class RemainingPacketSocket: StatusSocket {
    private var sent = false
    func start() {}
    func enable() async throws {}
    func receive() async throws -> Data {
        if !sent { sent = true; return Data([0x12, 0]) }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func close() {}
}
