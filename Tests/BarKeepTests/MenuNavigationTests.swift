import SwiftUI
import XCTest
import ViewInspector
@testable import BarKeep

final class MenuNavigationTests: XCTestCase {
    @MainActor func testWebButtonUsesCurrentDeviceURLThroughSystemOpenAction() async throws {
        let suite = "dev.barkeep.menu-navigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("fixture.test:8080", forKey: "wifiHost")
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = MenuStateCoverageTests.reply
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        await state.refreshDeviceStatus()
        state.lastError = "Fixture connection warning"
        var opened: [URL] = []
        let view = MenuView().environment(state).environment(\.openURL, OpenURLAction {
            opened.append($0); return .handled
        })
        XCTAssertNotNil(try view.inspect().find(text: "90%"))
        XCTAssertNotNil(try view.inspect().find(text: "Fixture connection warning"))
        try view.inspect().find(ViewType.Button.self, where: {
            (try? $0.accessibilityLabel().string()) == "Open Busy Bar web interface"
        }).tap()
        XCTAssertEqual(opened.map(\.absoluteString), ["http://fixture.test:8080/"])
    }
}
