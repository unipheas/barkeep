import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class AppsLifecycleHostedTests: XCTestCase {
    @MainActor func testInstalledAppsLoadLaunchAndResumeWidgets() async throws {
        let suite = "dev.barkeep.apps-lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let lock = NSLock()
        var removed = false
        HTTPStub.handler = { request in
            if request.url?.path == "/api/apps" && request.httpMethod == "DELETE" { lock.withLock { removed = true } }
            if request.url?.path == "/api/apps/list" { return (200, Data(lock.withLock { removed ? "{\"apps\":[]}" : "{\"apps\":[\(appFixture)]}" }.utf8)) }
            return (200, Data("{}".utf8))
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let appeared = expectation(description: "Apps view installed")
        var installed: AppsTab?
        var sut = AppsTab()
        sut.didAppear = { installed = $0; appeared.fulfill() }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [appeared], timeout: 5)
        var model: DeviceAppsModel?
        for _ in 0..<200 {
            model = try? installed?.inspect().find(AppsContent.self).actualView().model
            if model?.loaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loaded = try XCTUnwrap(model)
        XCTAssertTrue(loaded.loaded)
        XCTAssertEqual(loaded.apps.count, 1)
        let content = try XCTUnwrap(installed).inspect().find(AppsContent.self)
        try content.find(button: "Run").tap()
        for _ in 0..<200 where !state.widgetsPausedForApp { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.widgetsPausedForApp)
        for _ in 0..<200 where loaded.working { try await Task.sleep(for: .milliseconds(10)) }
        try content.find(button: "Stop Running App").tap()
        for _ in 0..<200 where state.widgetsPausedForApp { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.widgetsPausedForApp)
        XCTAssertNil(loaded.error)
        let app = try XCTUnwrap(loaded.apps.first)
        await loaded.remove(app)
        XCTAssertTrue(loaded.apps.isEmpty)
        XCTAssertTrue(lock.withLock { removed })
        XCTAssertNil(loaded.error)
    }
}
