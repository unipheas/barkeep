import AppKit
import SwiftUI
import XCTest
@testable import BarKeep

final class ConnectionSettingsTests: XCTestCase {
    @MainActor
    func testSettingsHideWiFiEditorsInUSBAndRetainValuesWhenRevealedAgain() async {
        let suite = "dev.barkeep.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("busybar.local", forKey: "wifiHost")
        defaults.set("test-password", forKey: "token")
        let state = AppState(defaults: defaults, startServices: false, session: session())
        let (window, hosting) = host(ConnectionSettings().environment(state))
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        await layout(hosting)
        XCTAssertEqual(connectionControls(in: hosting).count, 1)
        XCTAssertTrue(wifiEditors(in: hosting).isEmpty)

        state.connectionMode = .wifi
        await layout(hosting)
        XCTAssertEqual(connectionControls(in: hosting).count, 1)
        XCTAssertEqual(wifiEditors(in: hosting), ["busybar.local or IP", "BUSY Bar", "HTTP API password"])
        XCTAssertTrue(views(in: hosting).contains { ($0 as? NSSecureTextField) != nil })

        state.connectionMode = .usb
        await layout(hosting)
        XCTAssertTrue(wifiEditors(in: hosting).isEmpty)
        XCTAssertFalse(views(in: hosting).contains { ($0 as? NSSecureTextField) != nil })
        XCTAssertEqual(state.wifiHost, "busybar.local")
        XCTAssertEqual(state.token, "test-password")
        XCTAssertEqual(state.client.host, "10.0.4.20")
        XCTAssertEqual(state.client.token, "")

        state.connectionMode = .wifi
        await layout(hosting)
        XCTAssertEqual(wifiEditors(in: hosting), ["busybar.local or IP", "BUSY Bar", "HTTP API password"])
        XCTAssertEqual(state.client.host, "busybar.local")
        XCTAssertEqual(state.client.token, "test-password")
    }

    @MainActor
    func testMainDeviceViewHasNoConnectionSelectorOrWiFiEditors() async {
        let suite = "dev.barkeep.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: session())
        let (window, hosting) = host(MenuView().environment(state))
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        await layout(hosting)
        XCTAssertEqual(connectionControls(in: hosting).count, 0)
        XCTAssertTrue(wifiEditors(in: hosting).isEmpty)
    }

    @MainActor
    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 850),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        return (window, hosting)
    }

    @MainActor
    private func layout(_ view: NSView) async {
        try? await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor
    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    @MainActor
    private func connectionControls(in view: NSView) -> [NSSegmentedControl] {
        views(in: view).compactMap { $0 as? NSSegmentedControl }.filter {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == "USB" && $0.label(forSegment: 1) == "Wi-Fi"
        }
    }

    @MainActor
    private func wifiEditors(in view: NSView) -> Set<String> {
        let placeholders = Set(views(in: view).compactMap { ($0 as? NSTextField)?.placeholderString })
        return placeholders.intersection(["busybar.local or IP", "BUSY Bar", "HTTP API password"])
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsTestURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class SettingsTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}
