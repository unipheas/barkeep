import AppKit
import EventKit
import Network
import ServiceManagement

/// Compiled only into the standalone acceptance app, never the shipping target.
@MainActor enum AppAcceptance {
    private static func descendants(_ root: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 30, let node = root as? any NSAccessibilityProtocol else { return [] }
        var children = node.accessibilityChildren() ?? []
        if let window = root as? NSWindow, let content = window.contentView { children.append(content) }
        if let view = root as? NSView { children.append(contentsOf: view.subviews) }
        return [node] + children.flatMap { descendants($0, depth: depth + 1) }
    }

    private static func press(_ label: String, in window: NSWindow) -> Bool {
        for case let control as NSSegmentedControl in descendants(window) {
            for index in 0..<control.segmentCount where control.label(forSegment: index) == label {
                control.selectedSegment = index
                return control.sendAction(control.action, to: control.target)
            }
        }
        guard let node = descendants(window).first(where: {
            $0.accessibilityLabel() == label || $0.accessibilityTitle() == label
        }) else { return false }
        return node.accessibilityPerformPress()
    }

    private static func inspectScenes(in controls: NSWindow) async -> [String: Any] {
        let labels = descendants(controls).compactMap { $0.accessibilityLabel() ?? $0.accessibilityTitle() }
        let messagePressed = press("Message", in: controls)
        try? await Task.sleep(for: .milliseconds(300))
        let canvasPressed = press("Drawing Canvas…", in: controls)
        try? await Task.sleep(for: .milliseconds(500))
        let canvas = NSApp.windows.first { $0.title == "Busy Bar Canvas" && $0.isVisible }
        canvas?.close()
        let settingsPressed = press("Settings", in: controls)
        try? await Task.sleep(for: .milliseconds(300))
        let toolsPressed = press("All Device Controls…", in: controls)
        try? await Task.sleep(for: .milliseconds(500))
        let tools = NSApp.windows.first { $0.title == "BarKeep Device Controls" && $0.isVisible }
        tools?.close()
        return ["messagePressed": messagePressed, "canvasPressed": canvasPressed,
            "canvasVisible": canvas != nil, "settingsPressed": settingsPressed,
            "deviceToolsPressed": toolsPressed, "deviceToolsVisible": tools != nil,
            "initialAccessibilityLabels": labels]
    }

    private static func loginStatusName() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    private static func observeOrCleanLoginItem(state: AppState) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BARKEEP_ACCEPTANCE_LOGIN_STATUS"] else { return }
        let identity = Bundle.main.bundleIdentifier ?? ""
        // Never act on any real app service or a non-login-test acceptance build.
        guard identity == environment["BARKEEP_ACCEPTANCE_EXPECTED_ID"],
              identity.hasPrefix("dev.barkeep.acceptance-login."),
              UUID(uuidString: String(identity.dropFirst("dev.barkeep.acceptance-login.".count))) != nil else {
            fatalError("Login-item acceptance requires its unique test bundle identity")
        }
        var cleanupAction = "none"
        let initialStatus = loginStatusName()
        func report(_ error: String? = nil) {
            var result = ["bundleID": identity, "status": loginStatusName(),
                "initialStatus": initialStatus, "cleanupAction": cleanupAction]
            if let error { result["error"] = error }
            if let error = state.lastError { result["registrationError"] = error }
            if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        Task { @MainActor in
            if environment["BARKEEP_ACCEPTANCE_LOGIN_CLEANUP"] == "1" {
                do {
                    if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                        cleanupAction = "unregister"
                        try await SMAppService.mainApp.unregister()
                    }
                    report()
                } catch { report(error.localizedDescription) }
                NSApp.terminate(nil)
                return
            }
            for _ in 0..<600 {
                report()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func makeState() -> AppState {
        let suite = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_SUITE"] ?? "dev.barkeep.acceptance.\(UUID().uuidString)"
        let prefix = "dev.barkeep.acceptance."
        guard suite.hasPrefix(prefix), UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil else {
            fatalError("Acceptance preferences require an isolated UUID suite")
        }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoOnCall")
        defaults.set(false, forKey: "forwardNotifications")
        defaults.set(false, forKey: "calendarAutoBusy")
        defaults.set(false, forKey: "showPing")
        defaults.set(false, forKey: "showWeather")
        defaults.set("Fixture City", forKey: "weatherCity")
        defaults.set(false, forKey: "slackSyncEnabled")
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("acceptance.invalid", forKey: "wifiHost")
        defaults.set("", forKey: "token")
        if let path = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_WEATHER_STATE"] {
            Task { @MainActor in
                for _ in 0..<1200 {
                    let value = ["city": defaults.string(forKey: "weatherCity") ?? ""]
                    if let bytes = try? JSONSerialization.data(withJSONObject: value) {
                        try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AcceptanceTransport.self]
        let session = URLSession(configuration: configuration)
        let hardware = AudioHardwareCalls(
            size: { _, _, size in size = 0; return 0 },
            read: { _, _, _, _ in 0 },
            add: { _, _, _, _ in 0 },
            remove: { _, _, _, _ in 0 })
        let browser = AcceptanceBrowser()
        let state = AppState(defaults: defaults, startServices: true,
            session: session, slackSession: session, weatherSession: session,
            calendarSource: AcceptanceCalendar(),
            localNetworkPermissionTrigger: LocalNetworkPermissionTrigger(makeBrowser: { browser }),
            micMonitor: MicMonitor(hardware: hardware), notificationWatcher: NotificationWatcher(paths: []))
        observeOrCleanLoginItem(state: state)
        Task { @MainActor in
            var passed = false
            for _ in 0..<100 {
                let controls = NSApp.windows.first { $0.title == "BarKeep Controls" }
                if controls?.isVisible == true, controls?.contentView != nil,
                   AcceptanceTransport.requestCount > 0, browser.started {
                    passed = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            var sceneResults: [String: Any] = [:]
            if ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_SCENES"] == "1",
               let controls = NSApp.windows.first(where: { $0.title == "BarKeep Controls" }) {
                sceneResults = await inspectScenes(in: controls)
                passed = passed && sceneResults["canvasVisible"] as? Bool == true
                    && sceneResults["deviceToolsVisible"] as? Bool == true
            }
            let result: [String: Any] = ["passed": passed, "scenes": sceneResults,
                "controlsVisible": NSApp.windows.contains { $0.title == "BarKeep Controls" && $0.isVisible },
                "mockRequests": AcceptanceTransport.requestCount,
                "fixtureBrowserStarted": browser.started]
            if let path = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_RESULT"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            if ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_UI"] == "1" { return }
            defaults.removePersistentDomain(forName: suite)
            session.invalidateAndCancel()
            NSApp.terminate(nil)
        }
        return state
    }
}

private final class AcceptanceBrowser: LocalNetworkBrowser {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var started = false
    func start(queue: DispatchQueue) { started = true; stateUpdateHandler?(.ready) }
    func cancel() {}
}

@MainActor private final class AcceptanceCalendar: CalendarSource {
    var authorizationStatus: EKAuthorizationStatus { .denied }
    let notificationObject: AnyObject = NSObject()
    func requestAccess() async throws -> Bool { false }
    func events(from: Date, to: Date) -> [EKEvent] { [] }
}

private final class AcceptanceTransport: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var requests: [[String: String]] = []
    static var requestCount: Int { lock.withLock { count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            Self.count += 1
            let filename = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "file" })?.value ?? ""
            var entry = ["path": request.url?.path ?? "", "method": request.httpMethod ?? "", "file": filename]
            if filename == "canvas.png" {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                if let image = NSBitmapImageRep(data: body) {
                    var painted = 0
                    for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
                        if (image.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.1 { painted += 1 }
                    }}
                    entry["paintedPixels"] = String(painted)
                }
            }
            Self.requests.append(entry)
            if let path = ProcessInfo.processInfo.environment["BARKEEP_ACCEPTANCE_REQUESTS"],
               let bytes = try? JSONSerialization.data(withJSONObject: Self.requests) {
                try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        let fixtureApp = #"{"id":"app.acceptance.clock","name":"Acceptance Clock","version":"1.0.0","api_version":"27.12.0","author":"Fixture","description":"Fixture only","is_debug":false,"icon_path":""}"#
        let status: Int
        let data: Data
        switch (request.httpMethod ?? "", request.url?.path ?? "") {
        case ("GET", "/api/status"):
            status = 200; data = Data(#"{"power":{"state":"charging","battery_charge":90},"firmware":{"version":"1.3.1"}}"#.utf8)
        case ("GET", "/api/busy/snapshot"):
            status = 200; data = Data(#"{"snapshot":{"type":"NOT_STARTED"}}"#.utf8)
        case ("GET", "/api/screen"):
            status = 200; data = Data(Data(repeating: 0, count: 72 * 16 * 3).base64EncodedString().utf8)
        case ("GET", "/api/apps/list"):
            status = 200; data = Data(#"{"apps":[]}"#.utf8)
        case ("POST", "/api/apps/stage"):
            status = 200; data = Data("{\"install_key\":12345,\"staged\":\(fixtureApp)}".utf8)
        case ("POST", "/api/assets/upload"), ("POST", "/api/display/draw"), ("DELETE", "/api/display/draw"):
            status = 200; data = Data()
        default: status = 503; data = Data() // Unknown requests never reach a network.
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
