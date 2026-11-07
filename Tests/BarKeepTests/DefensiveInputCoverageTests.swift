import AppKit
import XCTest
@testable import BarKeep

final class DefensiveInputCoverageTests: XCTestCase {
    func testGroupWithoutDeclaredChildrenAcceptsPreservedFutureValues() throws {
        let schema = try JSONDecoder().decode(AppSettingsSchema.self, from: Data(#"{"version":1,"fields":{"future":{"type":"group","label":"Future firmware"}}}"#.utf8))
        XCTAssertNoThrow(try schema.validate(#"{"version":1,"values":{"future":{"newField":42}}}"#))
        XCTAssertThrowsError(try schema.validate(#"{"version":1,"values":{"future":42}}"#))
    }

    func testNestedEditCreatesMissingGroupAndPreservesDocument() throws {
        for existing in [#"{}"#, #"{"group":17}"#] {
            let result = try AppSettingsDocument.replacing(in: "{\"version\":1,\"metadata\":\"preserve\",\"values\":\(existing)}", at: ["group", "child", "name"], value: "new")
            XCTAssertEqual(AppSettingsDocument.value(in: result, at: ["group", "child", "name"]) as? String, "new")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            XCTAssertEqual(root["metadata"] as? String, "preserve")
            XCTAssertEqual(root["version"] as? Int, 1)
        }
    }

    @MainActor func testFailedRemovalRetainsAppStillInRegistry() async throws {
        let app = try JSONDecoder().decode(DeviceApp.self, from: Data(appFixture.utf8))
        HTTPStub.handler = { request in
            if request.url?.path == "/api/apps/list" {
                return (200, Data("{\"apps\":[\(appFixture)]}".utf8))
            }
            return (500, Data("Removal failed".utf8))
        }
        defer { HTTPStub.handler = nil }
        var removals = 0
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()), removeAction: { _ in removals += 1 })
        await model.remove(app)
        XCTAssertEqual(model.apps.map(\.id), [app.id])
        XCTAssertEqual(removals, 0)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.error?.contains("Removal failed") == true)
    }

    @MainActor func testPatternColorFallsBackToWhiteRGBA() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        XCTAssertNil(pattern.usingColorSpace(.deviceRGB))
        XCTAssertEqual(MessageRenderer.rgbaHex(from: pattern), "#FFFFFFFF")
    }
}
