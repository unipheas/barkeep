import XCTest
@testable import BarKeep

final class BusyBarClientTests: XCTestCase {
    func testBrowserURLIsNormalizedToAnAPIHost() {
        XCTAssertEqual(
            BusyBarClient.normalizedHost("http://10.69.1.15/login"),
            "10.69.1.15"
        )
        XCTAssertEqual(
            BusyBarClient.normalizedHost("https://busybar.local:8080/settings"),
            "busybar.local:8080"
        )
        XCTAssertEqual(
            BusyBarClient.normalizedHost(" 10.0.4.20/ "),
            "10.0.4.20"
        )
        XCTAssertEqual(
            BusyBarClient.webInterfaceURL(for: "http://10.69.1.15/login")?.absoluteString,
            "http://10.69.1.15/"
        )
    }

    func testMultilineTokenIsRejectedBeforeSendingARequest() async {
        let client = BusyBarClient(
            host: "192.0.2.1",
            token: "token\nterminal output"
        )

        do {
            _ = try await client.status()
            XCTFail("Expected a malformed-token error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Wi-Fi password contains pasted line breaks. Clear it and enter only the Busy Bar's local HTTP API password."
            )
        }
    }

    func testAuthenticationUsesDocumentedAPITokenHeader() throws {
        var request = URLRequest(url: URL(string: "http://busybar.local/api/status")!)

        try BusyBarClient.applyAuthentication(to: &request, token: "valid-token")

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-API-Token"),
            "valid-token"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDisplayPayloadUsesFirmwareApplicationNamespace() {
        let payload = BusyBarClient.displayPayload(
            elements: [["id": "frame", "type": "image", "path": "arcade.png"]],
            priority: 95
        )

        XCTAssertEqual(payload["application_name"] as? String, BusyBarClient.appName)
        XCTAssertNil(payload["app_id"])
        XCTAssertEqual(payload["priority"] as? Int, 95)
    }

    func testAssetUploadUsesSameFirmwareApplicationNamespace() {
        let query = BusyBarClient.assetQuery(filename: "arcade.png")

        XCTAssertEqual(query["application_name"], BusyBarClient.appName)
        XCTAssertEqual(query["file"], "arcade.png")
        XCTAssertNil(query["app_id"])
    }
}
