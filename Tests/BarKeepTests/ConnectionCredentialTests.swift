import XCTest
@testable import BarKeep

final class ConnectionCredentialTests: XCTestCase {
    @MainActor func testEditingFixturePasswordRefreshesWiFiButNeverLeaksIntoUSB() async throws {
        let suite = "dev.barkeep.connection-credential.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("fixture.test", forKey: "wifiHost")
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = MenuStateCoverageTests.reply
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let before = state.connectionRevision
        state.token = "fixture-one"
        await settle { state.deviceReachable && !state.isConnecting }
        XCTAssertGreaterThan(state.connectionRevision, before)
        XCTAssertEqual(state.client.token, "fixture-one")
        XCTAssertEqual(defaults.string(forKey: "token"), "fixture-one")
        state.connectionMode = .usb
        await settle { state.deviceReachable && !state.isConnecting }
        let usbRevision = state.connectionRevision
        state.token = "fixture-two"
        XCTAssertEqual(state.connectionRevision, usbRevision)
        XCTAssertEqual(state.client.token, "")
        XCTAssertEqual(defaults.string(forKey: "token"), "fixture-two")
        state.connectionMode = .wifi
        await settle { state.deviceReachable && !state.isConnecting }
        XCTAssertEqual(state.client.token, "fixture-two")
        XCTAssertEqual(state.client.host, "fixture.test")
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Connection did not settle")
    }
}
