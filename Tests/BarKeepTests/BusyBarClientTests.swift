import XCTest
@testable import BarKeep

final class BusyBarClientTests: XCTestCase {
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
