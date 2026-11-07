import AppKit
import EventKit
import XCTest
@testable import BarKeep

final class PlatformBoundaryFailureTests: XCTestCase {
    @MainActor func testLoginItemFailureIsVisibleWithoutChangingSystemRegistration() {
        let suite = "dev.barkeep.login-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requested: [Bool] = []
        let service = LoginItemService(isEnabled: { false }, setEnabled: {
            requested.append($0)
            throw BusyBarError(message: "Fixture registration unavailable")
        })
        let state = AppState(defaults: defaults, startServices: false, loginItems: service)
        state.launchAtLogin = true
        XCTAssertEqual(requested, [true])
        XCTAssertFalse(state.launchAtLogin)
        XCTAssertEqual(state.lastError, "Fixture registration unavailable")
    }

    @MainActor func testUnavailableTransliterationRetainsSafeASCIIFallback() {
        XCTAssertEqual(AppState.asciiFold("  Aé\nB🙂  ", transform: { _ in nil }), "AB")
        XCTAssertEqual(AppState.asciiFold("Café"), "Cafe")
    }

    @MainActor func testMissingEventIdentifierStillDetectsContentChanges() {
        let source = BoundaryCalendarSource()
        let now = Date()
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "First"
        event.startDate = now.addingTimeInterval(-60)
        event.endDate = now.addingTimeInterval(60)
        source.items = [event]
        let monitor = CalendarMonitor(source: source, center: NotificationCenter(), now: { now }, identifier: { _ in nil })
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(changes, 1)
        monitor.refresh()
        XCTAssertEqual(changes, 1)
        event.title = "Changed"
        monitor.refresh()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(monitor.currentEvent?.title, "Changed")
    }

    @MainActor func testImmediateNativeKeyboardStopCancelsDelayedCapture() async throws {
        _ = NSApplication.shared
        let keyboard = ArcadeKeyboardCapture()
        var captured = 0
        keyboard.start(onEvent: { _ in XCTFail("Stopped capture must not receive input") }, onCaptured: { captured += 1 }, onFocusLost: {})
        // Stop before yielding: no panel activation or keyboard capture can occur.
        // Restore is idempotent for the application that was already foreground.
        keyboard.stop(restoreFocus: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(captured, 0)
    }

    @MainActor func testURLSessionCancellationDoesNotBecomeArcadeConnectionFailure() async throws {
        let suite = "dev.barkeep.arcade-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let cancelled = expectation(description: "Upload cancelled")
        var notified = false
        let lock = NSLock()
        HTTPStub.handler = { request in
            if request.httpMethod == "POST", request.url?.path == "/api/assets/upload" {
                lock.withLock { if !notified { notified = true; cancelled.fulfill() } }
                throw URLError(.cancelled)
            }
            return (200, Data())
        }
        let controller = ArcadeController(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()), keyboard: BoundaryKeyboard(), defaults: defaults)
        controller.start(.snake)
        await fulfillment(of: [cancelled], timeout: 3)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.framesSent, 0)
        await controller.stopAndWait()
    }
}

@MainActor private final class BoundaryCalendarSource: CalendarSource {
    let authorizationStatus: EKAuthorizationStatus = .fullAccess
    let notificationObject: AnyObject = NSObject()
    var items: [EKEvent] = []
    func requestAccess() async throws -> Bool { true }
    func events(from: Date, to: Date) -> [EKEvent] { items }
}

@MainActor private final class BoundaryKeyboard: ArcadeKeyboardCapturing {
    func start(onEvent: @escaping (NSEvent) -> Void, onCaptured: @escaping () -> Void, onFocusLost: @escaping () -> Void) { onCaptured() }
    func stop(restoreFocus: Bool) {}
}
