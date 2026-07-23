import XCTest
@testable import BarKeep

final class BusyBarClientTests: XCTestCase {
    func testDisplayPayloadUsesFirmwareAppIDNamespace() {
        let payload = BusyBarClient.displayPayload(
            elements: [["id": "frame", "type": "image", "path": "arcade.png"]],
            priority: 95
        )

        XCTAssertEqual(payload["app_id"] as? String, BusyBarClient.appName)
        XCTAssertNil(payload["application_name"])
        XCTAssertEqual(payload["priority"] as? Int, 95)
    }

    func testAssetUploadUsesSameFirmwareAppIDNamespace() {
        let query = BusyBarClient.assetQuery(filename: "arcade.png")

        XCTAssertEqual(query["app_id"], BusyBarClient.appName)
        XCTAssertEqual(query["file"], "arcade.png")
        XCTAssertNil(query["application_name"])
    }
}
