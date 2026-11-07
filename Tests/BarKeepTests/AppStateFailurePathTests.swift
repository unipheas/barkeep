import XCTest
@testable import BarKeep

final class AppStateFailurePathTests: XCTestCase {
    @MainActor func testRejectedPingHostShowsFailureBadgeWithoutStartingPing() async throws {
        let suite = "dev.barkeep.ping-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let shown = expectation(description: "Red failure badge")
        let expired = expectation(description: "Badge expired on disable")
        HTTPStub.handler = { request in
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: HTTPStub.body(request)) as? [String: Any])
            let elements = try XCTUnwrap(root["elements"] as? [[String: Any]])
            let ping = try XCTUnwrap(elements.first { $0["id"] as? String == "ping" })
            if ping["text"] as? String == "x" {
                XCTAssertEqual(ping["color"] as? String, "#FF3B30FF")
                shown.fulfill()
            } else {
                XCTAssertEqual(ping["timeout"] as? Int, 1)
                expired.fulfill()
            }
            return (200, Data())
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.pingHost = "-invalid-option"
        state.showPing = true
        await fulfillment(of: [shown], timeout: 3)
        XCTAssertNil(state.latestPingMs)
        state.showPing = false
        await fulfillment(of: [expired], timeout: 3)
    }

    @MainActor func testNotificationTransportFailureIsReported() async {
        let suite = "dev.barkeep.notification-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in (503, Data()) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.handleNotification(.init(bundleID: "com.microsoft.teams2", title: "Fixture", body: ""))
        for _ in 0..<200 where state.lastError == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.lastError?.contains("503") == true)
    }

    @MainActor func testNewCallRequeuesNotificationsNotYetReplayed() async throws {
        let suite = "dev.barkeep.notification-requeue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let first = expectation(description: "First queued notification replayed")
        HTTPStub.handler = { request in
            if request.url?.path == "/api/display/draw" {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: HTTPStub.body(request)) as? [String: Any])
                let elements = try XCTUnwrap(root["elements"] as? [[String: Any]])
                XCTAssertTrue(elements.contains { ($0["text"] as? String)?.contains("[1/3]") == true }, "No later notification should replay during the new call")
                first.fulfill()
            }
            return (200, Data("{}".utf8))
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        await state.setOnCall(true).value
        for title in ["one", "two", "three"] {
            state.handleNotification(.init(bundleID: "com.microsoft.teams2", title: title, body: ""))
        }
        XCTAssertEqual(state.queuedCount, 3)
        await state.setOnCall(false).value
        await fulfillment(of: [first], timeout: 3)
        await state.setOnCall(true).value
        // Exercise the real 13-second spacing rather than changing production timing.
        for _ in 0..<1500 where state.queuedCount != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.queuedCount, 2)
        XCTAssertTrue(state.onCall)
    }
}
