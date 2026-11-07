import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class MenuRootHostedTests: XCTestCase {
    @MainActor func testInstalledTabSelectionAndPreviewLifecycle() async throws {
        let suite = "dev.barkeep.root-tabs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let lock = NSLock()
        var requests = 0
        HTTPStub.handler = { request in
            lock.withLock { requests += 1 }
            XCTAssertEqual(request.httpMethod, "GET", "Tab selection must not change device state")
            if request.url?.path == "/api/apps/list" { return (200, Data(#"{"apps":[]}"#.utf8)) }
            return (503, Data())
        }
        defer { HTTPStub.handler = nil; defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        var sut = MenuView()
        let inspected = sut.on(\.didAppear) { view in
            let tabs = try view.find(ViewType.Picker.self)
            XCTAssertNotNil(try view.find(DeviceTab.self))
            try tabs.select(value: 1)
            XCTAssertNotNil(try view.find(MessageTab.self))
            XCTAssertNotNil(try view.find(button: "Clear Display"))
            try tabs.select(value: 2)
            XCTAssertNotNil(try view.find(TimersTab.self))
            XCTAssertNotNil(try view.find(text: "Simple timer"))
            try tabs.select(value: 3)
            XCTAssertNotNil(try view.find(ArcadeTab.self))
            try tabs.select(value: 5)
            XCTAssertNotNil(try view.find(AppsTab.self))
            try tabs.select(value: 4)
            XCTAssertNotNil(try view.find(SettingsTab.self))
            XCTAssertNotNil(try view.find(text: "Notifications"))
            try tabs.select(value: 0)
            XCTAssertNotNil(try view.find(DeviceTab.self))
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        ViewHosting.expel()
        // Allow in-flight stub completions to drain, then wait longer than the preview interval.
        try await Task.sleep(for: .milliseconds(100))
        let afterDismissal = lock.withLock { requests }
        XCTAssertGreaterThan(afterDismissal, 0, "Hosted menu must have started its mocked status/preview tasks")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(lock.withLock { requests }, afterDismissal, "Dismissed menu must cancel its preview loop")
        XCTAssertFalse(state.arcade.isActive)
    }
}
