import AppKit
import SwiftUI
import XCTest
@testable import BarKeep

/// Render the actual native view hierarchy, including AppKit-backed fields.
/// These tests complement (rather than replace) live accessibility/UI testing.
final class ViewRenderingTests: XCTestCase {
    @MainActor func testAllTabsRenderAtMenuWidth() async throws {
        let suite = "dev.barkeep.render-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler = nil }
        HTTPStub.handler = { request in
            if request.url!.path == "/api/apps/list" { return (200,Data("{\"apps\":[\(appFixture)]}".utf8)) }
            return (200,Data("{}".utf8))
        }
        let state = AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let model = DeviceAppsModel(client:state.client)
        await model.refresh()
        let views: [(String,AnyView,CGFloat)] = [
            ("device",AnyView(DeviceTab().environment(state)),372),
            ("message",AnyView(MessageTab().environment(state)),372),
            ("timers",AnyView(TimersTab().environment(state)),372),
            ("arcade",AnyView(ArcadeTab().environment(state)),372),
            ("apps",AnyView(AppsContent(model:model)),372),
            ("settings",AnyView(SettingsTab().environment(state)),372),
            ("device-controls",AnyView(DeviceToolsView().environment(state)),900),
            ("canvas",AnyView(CanvasView().environment(state)),896),
            ("status-stream",AnyView(StatusStreamView().environment(state)),820),
        ]
        for (name,view,width) in views {
            try await render(view,name:name,width:width)
        }
        state.connectionMode = .wifi
        state.wifiHost = "bar.test"
        // Avoid starting OS notification monitoring or making Slack requests while testing fields.
        state.slackSyncEnabled = true
        try await render(AnyView(SettingsTab().environment(state)),name:"settings-wifi-slack",width:372)
        HTTPStub.handler = { _ in (403,Data()) }
        await model.refresh()
        try await render(AnyView(AppsContent(model:model)),name:"apps-error",width:372)
    }

    @MainActor private func render(_ view: AnyView, name: String, width: CGFloat) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(view.padding(14).frame(width:width+28)))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width+28,height:850),
                              styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        try await Task.sleep(for:.milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        XCTAssertTrue(size.width.isFinite && size.height.isFinite,name)
        XCTAssertGreaterThan(size.height,20,name)
        XCTAssertLessThanOrEqual(size.width,width+29,name)
        hosting.setFrameSize(NSSize(width:width+28,height:max(100,size.height)))
        hosting.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["BARKEEP_UI_SNAPSHOTS"] {
            let output = URL(fileURLWithPath:directory,isDirectory:true)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            // SwiftUI's GPU-backed layers do not appear in NSView.cacheDisplay offscreen.
            // ImageRenderer captures SwiftUI content; AppKit-only fields are asserted by native hierarchy tests.
            let renderer = ImageRenderer(content: view.padding(14).frame(width:width+28)
                .environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            let cgImage = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage:cgImage)
            let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:output.appendingPathComponent(name+".png"))
        }
    }
}
