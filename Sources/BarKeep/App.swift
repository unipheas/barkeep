import SwiftUI

@main
@MainActor
struct BarKeepApp: App {
    @State private var state: AppState

    init() {
        let appState = makeApplicationState()
        _state = State(initialValue: appState)
        // Normal launch stays menu-bar-only. A regular window also makes the
        // controls accessible when the menu item is hidden by macOS or the notch.
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--show-window") {
            DispatchQueue.main.async { ControlsWindow.show(state: appState) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
        } label: {
            Image(nsImage: MenuBarIcon.current(onCall: state.onCall, reachable: state.deviceReachable))
        }
        .menuBarExtraStyle(.window)

        Window("BarKeep Device Controls", id: "device-tools") {
            DeviceToolsView().environment(state)
        }
        Window("Busy Bar Canvas", id: "canvas") {
            CanvasView()
                .environment(state)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private enum ControlsWindow {
    static var window: NSWindow?

    static func show(state: AppState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BarKeep Controls"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuView().environment(state))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Preserve normal construction while allowing the standalone acceptance target
/// to supply service adapters. Fixture evidence does not cover the default branch.
@MainActor
private func makeApplicationState() -> AppState {
    #if BARKEEP_APP_ACCEPTANCE
    return AppAcceptance.makeState()
    #else
    return AppState()
    #endif
}
