import XCTest
import SwiftUI
import ViewInspector
import EventKit
import Network
@testable import BarKeep

/// Exercises observable UI branches using isolated defaults and synthetic transports.
/// These are control/label assertions, not claims of physical-device or OS permission verification.
final class MenuStateCoverageTests: XCTestCase {
    @MainActor func testDeviceShowsMicrophoneNotificationsWidgetsAndPreview() async throws {
        let suite = "dev.barkeep.menu-states.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoOnCall")
        defaults.set(true, forKey: "showWeather")
        defaults.set(true, forKey: "showPing")
        defaults.set("127.0.0.1", forKey: "pingHost")
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = Self.reply
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session(), weatherSession: HTTPStub.session())
        defer { state.showWeather = false; state.showPing = false }
        let view = DeviceTab().environment(state)
        XCTAssertNotNil(try view.inspect().find(text: "Microphone idle"))
        XCTAssertEqual(try view.inspect().findAll(where: { (try? $0.text().string()) == "—" }).count, 2)
        _ = state.micStateChanged(.init(isInUse: true, deviceNames: []))
        XCTAssertNotNil(try view.inspect().find(text: "Microphone in use"))
        _ = state.micStateChanged(.init(isInUse: true, deviceNames: ["Fixture Mic"]))
        XCTAssertNotNil(try view.inspect().find(text: "In use: Fixture Mic"))
        await state.setOnCall(true).value
        state.handleNotification(.init(bundleID: "com.microsoft.teams2", title: "one", body: ""))
        XCTAssertNotNil(try view.inspect().find(text: "1 notification queued"))
        state.handleNotification(.init(bundleID: "com.microsoft.teams2", title: "two", body: ""))
        XCTAssertNotNil(try view.inspect().find(text: "2 notifications queued"))
        await state.setOnCall(false).value
        let app = try JSONDecoder().decode(DeviceApp.self, from: Data(appFixture.utf8))
        try await state.launchDeviceApp(app, on: state.client)
        XCTAssertTrue(state.widgetsPausedForApp)
        try view.inspect().find(button: "Resume").tap()
        XCTAssertFalse(state.widgetsPausedForApp)
        state.showWeather = false; state.showWeather = true
        await settle { state.latestWeather != nil }
        XCTAssertNotNil(try view.inspect().find(text: "☀️ 72F · Fixture City"))
        let preview = Task { await state.previewLoop(interval: .milliseconds(10)) }
        await settle { state.screenPreview != nil }
        preview.cancel(); await preview.value
        XCTAssertNotNil(try view.inspect().find(ViewType.Image.self))
    }

    @MainActor func testCalendarStatesAndMeetingCountdownControl() async throws {
        let suite = "dev.barkeep.menu-calendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let calendar = MenuCalendarFixture()
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = Self.reply
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session(), calendarSource: calendar)
        defer { state.calendarAutoBusy = false }
        let view = TimersTab().environment(state)
        calendar.allow = false
        state.calendarAutoBusy = true
        await Task.yield()
        XCTAssertNotNil(try view.inspect().find(text: "Waiting for calendar access — approve the system prompt."))
        state.calendarAutoBusy = false
        calendar.allow = true
        state.calendarAutoBusy = true
        await settle { state.calendarAccessGranted }
        XCTAssertNotNil(try view.inspect().find(text: "No upcoming events in the next 24 h."))
        state.calendarAutoBusy = false
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Fixture appointment"
        event.startDate = Date().addingTimeInterval(3600)
        event.endDate = Date().addingTimeInterval(7200)
        calendar.items = [event]
        state.calendarAutoBusy = true
        await settle { state.nextMeetingTitle != nil }
        XCTAssertNotNil(try view.inspect().find(text: "Next: Fixture appointment"))
        try view.inspect().find(button: "Countdown on Bar").tap()
        await Task.yield()
    }

    @MainActor func testConnectionFailureAndFirmwareLabels() async throws {
        let suite = "dev.barkeep.menu-connection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("fixture.test", forKey: "wifiHost")
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in (403, Data()) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        await state.refreshDeviceStatus()
        let connection = ConnectionSettings().environment(state)
        XCTAssertNotNil(try connection.inspect().find(ViewType.Text.self, where: { try $0.string().contains("rejected the local HTTP API password") }))
        HTTPStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        await state.refreshDeviceStatus()
        XCTAssertNotNil(try connection.inspect().find(ViewType.Text.self, where: { try $0.string().hasPrefix("Wi-Fi device unreachable") }))
        HTTPStub.handler = Self.reply
        await state.refreshDeviceStatus()
        let settings = SettingsTab().environment(state)
        XCTAssertNotNil(try settings.inspect().find(text: "Firmware 1.3.1 · Wi-Fi connected"))
        try settings.inspect().find(button: "Check for Update").tap()
        await settle { state.updateCheckText != nil }
        XCTAssertNotNil(try settings.inspect().find(text: state.updateCheckText!))
    }

    @MainActor func testSecureFieldCoordinatorEditsOnlyTextNotifications() throws {
        var text = "before"
        let field = CompactSecureField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "Fixture")
        let coordinator = field.makeCoordinator()
        coordinator.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: NSObject()))
        XCTAssertEqual(text, "before")
        let native = NSSecureTextField()
        native.stringValue = "after"
        coordinator.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: native))
        XCTAssertEqual(text, "after")
    }

    static func reply(_ request: URLRequest) throws -> (Int, Data) {
        let body: String
        switch request.url!.path {
        case "/api/status": body = #"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#
        case "/api/busy/snapshot": body = #"{"snapshot":{"type":"NOT_STARTED"}}"#
        case "/api/wifi/status": body = #"{"state":"connected"}"#
        case "/api/update/status": body = #"{"check":{"available_version":"1.3.1","event":"stop","status":"available"}}"#
        case "/api/screen": body = Data(repeating: 0, count: 72*16*3).base64EncodedString()
        case "/json": body = #"{"loc":"29.7,-98.0","city":"Fixture City"}"#
        case "/v1/forecast": body = #"{"current":{"temperature_2m":72,"weather_code":0}}"#
        default: body = "{}"
        }
        return (200, Data(body.utf8))
    }
    @MainActor private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("UI state did not settle", file: file, line: line)
    }
}

@MainActor private final class MenuCalendarFixture: CalendarSource {
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    let notificationObject: AnyObject = NSObject()
    var allow = true
    var items: [EKEvent] = []
    func requestAccess() async throws -> Bool { allow }
    func events(from: Date, to: Date) -> [EKEvent] { items }
}
