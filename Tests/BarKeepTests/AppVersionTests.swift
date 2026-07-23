import XCTest
@testable import BarKeep

final class AppVersionTests: XCTestCase {
    func testUsesBundleShortVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]

        XCTAssertEqual(AppVersion.displayVersion(from: info), "1.2.3")
    }

    func testFallsBackForDevelopmentBuilds() {
        XCTAssertEqual(AppVersion.displayVersion(from: nil), "development")
    }

    func testConfiguredTransportUsesUSBOnlyForTheUSBInterface() {
        XCTAssertEqual(AppState.configuredTransport(for: "10.0.4.20"), "usb")
        XCTAssertEqual(AppState.configuredTransport(for: " 10.0.4.20 "), "usb")
        XCTAssertEqual(AppState.configuredTransport(for: "172.20.10.9"), "wifi")
        XCTAssertEqual(AppState.configuredTransport(for: "busybar.local"), "wifi")
    }

    func testAuthenticationFailureIsDistinguishedFromReachability() {
        XCTAssertTrue(
            AppState.isAuthenticationError(
                BusyBarError(
                    message: "HTTP 403 /status: Forbidden",
                    statusCode: 403
                )
            )
        )
        XCTAssertFalse(
            AppState.isAuthenticationError(
                URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            AppState.isAuthenticationError(
                BusyBarError(message: "Device response mentioned HTTP 403")
            )
        )
    }
}
