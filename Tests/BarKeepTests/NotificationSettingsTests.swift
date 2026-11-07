import XCTest
import SwiftUI
import ViewInspector
@testable import BarKeep

final class NotificationSettingsTests: XCTestCase {
    @MainActor func testNotificationStatusAndFilterControlsUseFixtureWatcher() async throws {
        let suite = "dev.barkeep.notification-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "forwardNotifications")
        defaults.set(false, forKey: "autoOnCall")
        let watcher = NotificationWatcher(paths: [])
        let browser = FixtureNetworkBrowser()
        let microphone = MicMonitor(hardware: AudioHardwareCalls(
            size: { _, _, size in size = 0; return 0 }, read: { _, _, _, _ in 0 },
            add: { _, _, _, _ in 0 }, remove: { _, _, _, _ in 0 }))
        defer { microphone.stop(); watcher.stop(); defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = MenuStateCoverageTests.reply
        let state = AppState(defaults: defaults, session: HTTPStub.session(),
            localNetworkPermissionTrigger: LocalNetworkPermissionTrigger(makeBrowser: { browser }),
            micMonitor: microphone, notificationWatcher: watcher)
        browser.stateUpdateHandler?(.cancelled)
        await settle { state.deviceReachable && !state.isConnecting && state.notificationStatus == .noAccess }
        var opened: [URL] = []
        let view = SettingsTab().environment(state).environment(\.openURL, OpenURLAction {
            opened.append($0); return .handled
        })
        XCTAssertNotNil(try view.inspect().find(text: "Needs Full Disk Access to read notifications"))
        try view.inspect().find(button: "Open Full Disk Access Settings…").tap()
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        watcher.stop()
        await settle { state.notificationStatus == .stopped }
        XCTAssertNotNil(try view.inspect().find(ViewType.EmptyView.self))
        watcher.onStatusChange?(.watching)
        await settle { state.notificationStatus == .watching }
        XCTAssertNotNil(try view.inspect().find(text: "Watching for notifications"))
        watcher.onStatusChange?(.error("Fixture database unavailable"))
        await settle { state.notificationStatus == .error("Fixture database unavailable") }
        XCTAssertNotNil(try view.inspect().find(text: "Fixture database unavailable"))
        try view.inspect().find(ViewType.TextField.self, where: {
            try $0.labelView().text().string() == "bundle IDs, comma-separated"
        }).setInput("app.fixture")
        try view.inspect().find(ViewType.Toggle.self, where: {
            (try? $0.labelView().find(text: "Chime on the bar")) != nil
        }).tap()
        try view.inspect().find(ViewType.Toggle.self, where: {
            (try? $0.labelView().find(text: "Queue during calls, replay after")) != nil
        }).tap()
        XCTAssertEqual(state.notificationAppFilter, "app.fixture")
        XCTAssertTrue(state.notificationChime)
        XCTAssertFalse(state.queueDuringCalls)
        XCTAssertEqual(defaults.string(forKey: "notificationAppFilter"), "app.fixture")
        watcher.onStatusChange?(.stopped)
        await settle { state.notificationStatus == .stopped }
        state.forwardNotifications = false
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Notification UI did not settle")
    }
}
