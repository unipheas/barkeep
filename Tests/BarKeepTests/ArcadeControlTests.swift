import XCTest
import EventKit
import SwiftUI
import ViewInspector
@testable import BarKeep

final class ArcadeControlTests: XCTestCase {
    @MainActor func testUpcomingMeetingCannotOverwriteActiveArcade() async throws {
        let suite = "dev.barkeep.arcade-calendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in (200, Data("{}".utf8)) }
        let source = ArcadeCalendarFixture()
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session(), calendarSource: source, arcadeKeyboard: ControlKeyboardFixture())
        state.calendarAutoBusy = true
        for _ in 0..<200 where state.nextMeetingDate == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(state.nextMeetingDate)
        state.arcade.start(.snake)
        XCTAssertTrue(state.arcade.isActive)
        state.sendMeetingCountdown()
        XCTAssertEqual(state.lastError, "Stop the arcade before drawing another item.")
        await state.arcade.stopAndWait()
        state.calendarAutoBusy = false
    }

    @MainActor func testGameControlsPreviewFocusAndBusySafety() async throws {
        let suite = "dev.barkeep.arcade-controls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { request in
            if request.url?.path == "/api/status" {
                return (200, Data(#"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#.utf8))
            }
            if request.url?.path == "/api/busy/snapshot" { return (200, Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8)) }
            return (200, Data("{}".utf8))
        }
        let keyboard = ControlKeyboardFixture()
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session(), arcadeKeyboard: keyboard)
        await state.refreshDeviceStatus()
        XCTAssertTrue(state.deviceReachable)
        let view = ArcadeTab().environment(state)
        try view.inspect().find(ViewType.Toggle.self).tap()
        XCTAssertNotNil(try view.inspect().find(ViewType.Image.self))
        try view.inspect().find(button: "Play").tap()
        XCTAssertTrue(state.arcade.isActive)
        XCTAssertNotNil(try view.inspect().find(text: "Playing Snake"))
        try view.inspect().find(button: "Restart").tap()
        keyboard.lost?()
        XCTAssertNotNil(try view.inspect().find(text: "Keyboard controls are paused."))
        XCTAssertNotNil(try view.inspect().find(text: "Keyboard focus released. Click Capture Keyboard to resume controls."))
        try view.inspect().find(button: "Capture Keyboard").tap()
        XCTAssertEqual(keyboard.starts, 2)
        XCTAssertNotNil(try view.inspect().find(text: "Keyboard captured · 1–4 switch games · R restarts · Esc stops"))
        state.sendMessage("No interruption", font: .normal, color: .white, timeoutSeconds: 30)
        XCTAssertEqual(state.lastError, "Stop the arcade before sending a message.")
        state.sendDrawing([[nil]], timeoutSeconds: 30)
        XCTAssertEqual(state.lastError, "Stop the arcade before sending a drawing.")
        try view.inspect().find(button: "Stop").tap()
        await state.arcade.stopAndWait()
        XCTAssertFalse(state.arcade.isActive)
        try view.inspect().find(button: "Play").tap()
        await state.setOnCall(true).value
        XCTAssertFalse(state.arcade.isActive)
        XCTAssertNotNil(try view.inspect().find(text: "End the current busy session before starting a game."))
        XCTAssertTrue(try view.inspect().find(button: "Play").isDisabled())
        await state.setOnCall(false).value
        await state.arcade.stopAndWait()
    }
}

@MainActor private final class ControlKeyboardFixture: ArcadeKeyboardCapturing {
    var starts = 0
    var lost: (() -> Void)?
    func start(onEvent: @escaping (NSEvent) -> Void, onCaptured: @escaping () -> Void, onFocusLost: @escaping () -> Void) {
        starts += 1; lost = onFocusLost; onCaptured()
    }
    func stop(restoreFocus: Bool) { lost = nil }
}

@MainActor private final class ArcadeCalendarFixture: CalendarSource {
    let authorizationStatus: EKAuthorizationStatus = .fullAccess
    let notificationObject: AnyObject = NSObject()
    func requestAccess() async throws -> Bool { true }
    func events(from: Date, to: Date) -> [EKEvent] {
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Upcoming fixture"
        event.startDate = Date().addingTimeInterval(120)
        event.endDate = Date().addingTimeInterval(300)
        return [event]
    }
}
