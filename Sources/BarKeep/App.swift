import SwiftUI

@main
struct BarKeepApp: App {
    @State private var state = AppState()

    init() {
        // Menu-bar-only app: no Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
        } label: {
            Image(nsImage: MenuBarIcon.current(onCall: state.onCall, reachable: state.deviceReachable))
        }
        .menuBarExtraStyle(.window)

        Window("Busy Bar Canvas", id: "canvas") {
            CanvasView()
                .environment(state)
        }
        .windowResizability(.contentSize)
    }
}
