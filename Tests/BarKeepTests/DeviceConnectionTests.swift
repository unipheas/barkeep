import XCTest
@testable import BarKeep

final class DeviceConnectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "dev.barkeep.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        ConnectionURLProtocol.handler = nil
    }

    func testLegacyUSBAndWiFiSettingsMigrateWithoutLosingPassword() {
        XCTAssertEqual(DeviceConnection(defaults: defaults).mode, .usb)
        defaults.set("http://busybar.local/login", forKey: "host")
        defaults.set("saved-password", forKey: "token")
        let connection = DeviceConnection(defaults: defaults)
        XCTAssertEqual(connection.mode, .wifi)
        XCTAssertEqual(connection.host, "busybar.local")
        XCTAssertEqual(connection.token, "saved-password")
    }

    func testRoundTripKeepsWiFiAddressAndPasswordWhileUSBHasNoAuthentication() {
        var connection = DeviceConnection(defaults: defaults)
        connection.wifiHost = "http://busybar.local:8080/login"
        connection.password = "saved-password"
        connection.mode = .usb
        connection.save(to: defaults)
        var restored = DeviceConnection(defaults: defaults)
        XCTAssertEqual(restored.host, "10.0.4.20")
        XCTAssertEqual(restored.token, "")
        restored.mode = .wifi
        restored.save(to: defaults)
        let wifi = DeviceConnection(defaults: defaults)
        XCTAssertEqual(wifi.mode, .wifi)
        XCTAssertEqual(wifi.host, "busybar.local:8080")
        XCTAssertEqual(wifi.token, "saved-password")
    }

    func testWiFiCannotSilentlyUseUSBAddress() {
        defaults.set("wifi", forKey: "connectionMode")
        defaults.set("http://10.0.4.20/login", forKey: "wifiHost")
        let connection = DeviceConnection(defaults: defaults)
        XCTAssertTrue(connection.needsWiFiHost)
        XCTAssertTrue(connection.host.isEmpty)
        XCTAssertNotNil(connection.configurationHelp)
    }

    @MainActor
    func testSwitchRoutesActualRequestsAndRecoversFromRejectedPassword() async {
        defaults.set("busybar.local", forKey: "wifiHost")
        defaults.set("wrong-password", forKey: "token")
        let usbRequested = expectation(description: "USB request without Wi-Fi credential")
        let wifiRequested = expectation(description: "Wi-Fi request with saved password")
        ConnectionURLProtocol.handler = { request, complete in
            if request.url?.path == "/api/status" {
                if request.url?.host == "10.0.4.20" {
                    XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Token"))
                    usbRequested.fulfill()
                    complete(.success((200, Self.status)))
                } else {
                    XCTAssertEqual(request.url?.host, "busybar.local")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Token"), "wrong-password")
                    wifiRequested.fulfill()
                    complete(.success((403, "{}")))
                }
            } else { complete(.success((200, "{}"))) }
        }
        let state = AppState(defaults: defaults, startServices: false, session: makeSession())
        state.connectionMode = .wifi
        await fulfillment(of: [wifiRequested], timeout: 3)
        // Wait for the response handler to update observed state.
        for _ in 0..<100 where !state.authenticationRejected { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.authenticationRejected)
        XCTAssertFalse(state.deviceReachable)
        state.connectionMode = .usb
        XCTAssertFalse(state.authenticationRejected)
        XCTAssertFalse(state.deviceReachable)
        await fulfillment(of: [usbRequested], timeout: 3)
        for _ in 0..<100 where !state.deviceReachable { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<100 where state.isConnecting { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.deviceReachable)
        XCTAssertEqual(state.transportType, "usb")
        XCTAssertEqual(DeviceConnection(defaults: defaults).mode, .usb)
        XCTAssertEqual(state.wifiHost, "busybar.local")
    }

    @MainActor
    func testSwitchKeepsOwnershipSoAutomaticBusyCanStillClearOnNewRoute() async {
        defaults.set("busybar.local", forKey: "wifiHost")
        let started = expectation(description: "Started busy on USB")
        let cleared = expectation(description: "Cleared own busy session over Wi-Fi")
        ConnectionURLProtocol.handler = { request, complete in
            if request.httpMethod == "PUT" && request.url?.path == "/api/busy/snapshot" {
                if request.url?.host == "10.0.4.20" { started.fulfill() }
                else { cleared.fulfill() }
                complete(.success((200, "{}")))
            } else if request.url?.path == "/api/status" {
                complete(.success((200, Self.status)))
            } else if request.url?.path == "/api/busy/snapshot" {
                complete(.success((200, "{\"snapshot\":{\"type\":\"INFINITE\"}}")))
            } else { complete(.success((200, "{}"))) }
        }
        let state = AppState(defaults: defaults, startServices: false, session: makeSession())
        state.setOnCall(true)
        await fulfillment(of: [started], timeout: 3)
        for _ in 0..<100 where !state.onCall { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.onCall)
        state.connectionMode = .wifi
        for _ in 0..<100 where !state.onCall || state.isConnecting { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.onCall)
        state.offDebounceSeconds = 0
        state.autoOnCall = false
        await fulfillment(of: [cleared], timeout: 3)
        for _ in 0..<100 where state.onCall { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.onCall)
    }

    @MainActor
    func testLateOldResponseCannotMarkNewConnectionReachable() async {
        defaults.set("busybar.local", forKey: "wifiHost")
        let oldRequest = expectation(description: "Old USB request started")
        let newRequest = expectation(description: "New Wi-Fi request failed")
        let response = HeldConnectionResponse()
        ConnectionURLProtocol.handler = { request, complete in
            if request.url?.host == "10.0.4.20" {
                response.store(complete)
                oldRequest.fulfill()
            } else {
                complete(.failure(URLError(.cannotConnectToHost)))
                newRequest.fulfill()
            }
        }
        let state = AppState(defaults: defaults, startServices: false, session: makeSession())
        let oldRefresh = Task { await state.refreshDeviceStatus() }
        await fulfillment(of: [oldRequest], timeout: 3)
        state.connectionMode = .wifi
        await fulfillment(of: [newRequest], timeout: 3)
        response.finish()
        await oldRefresh.value
        XCTAssertFalse(state.deviceReachable)
        XCTAssertNil(state.firmwareVersion)
        XCTAssertEqual(state.transportType, "wifi")
    }

    @MainActor
    func testMissingWiFiAddressDoesNotFallbackToUSBOrSendRequest() async {
        let unexpected = expectation(description: "No network request")
        unexpected.isInverted = true
        ConnectionURLProtocol.handler = { _, complete in
            unexpected.fulfill()
            complete(.failure(URLError(.badURL)))
        }
        let state = AppState(defaults: defaults, startServices: false, session: makeSession())
        state.connectionMode = .wifi
        await state.refreshDeviceStatus()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertTrue(state.host.isEmpty)
        XCTAssertFalse(state.deviceReachable)
        XCTAssertFalse(state.isConnecting)
        XCTAssertEqual(DeviceConnection(defaults: defaults).mode, .wifi)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static let status = "{\"power\":{\"state\":\"on\",\"battery_charge\":80},\"firmware\":{\"version\":\"test\"}}"
}

private final class HeldConnectionResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var complete: ConnectionURLProtocol.Completion?
    func store(_ completion: @escaping ConnectionURLProtocol.Completion) {
        lock.lock(); defer { lock.unlock() }
        complete = completion
    }
    func finish() {
        lock.lock()
        let completion = complete
        complete = nil
        lock.unlock()
        completion?(.success((200, "{\"power\":{\"state\":\"on\",\"battery_charge\":80},\"firmware\":{\"version\":\"old\"}}")))
    }
}

private final class ConnectionURLProtocol: URLProtocol {
    typealias Completion = (Result<(Int, String), Error>) -> Void
    static var handler: ((URLRequest, @escaping Completion) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(request) { [self] result in
            switch result {
            case let .success((code, body)):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case let .failure(error): client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}
