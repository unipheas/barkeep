import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class AppsHostedTests: XCTestCase {
    @MainActor func testSettingsSheetShowsSelectedAppAndDoneClosesIt() async throws {
        HTTPStub.handler = { request in
            switch request.url!.path {
            case "/api/apps/settings": return (200, Data(#"{"version":1,"values":{"city":"Chicago"}}"#.utf8))
            case "/api/storage/read": return (404, Data())
            default: XCTFail("Unexpected request: \(request)"); return (500, Data())
            }
        }
        defer { HTTPStub.handler = nil }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        let app = try JSONDecoder().decode(DeviceApp.self, from: Data(appFixture.utf8))
        await model.loadSettings(app)
        XCTAssertEqual(model.settingsApp?.id, app.id)
        var sut = AppsContent(model: model)
        let inspected = sut.on(\.didAppear) { view in
            XCTAssertNotNil(try view.find(text: "Clock Settings"))
            let editor = try view.find(ViewType.TextEditor.self)
            XCTAssertTrue(try editor.input().contains("Chicago"))
            try view.find(button: "Done").tap()
            XCTAssertNil(model.settingsApp)
            XCTAssertEqual(model.settingsJSON, "")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel(); model.closeSettings() }
        await fulfillment(of: [inspected], timeout: 5)
    }

    @MainActor func testRemoveRequiresConfirmationAndRefreshesList() async throws {
        let lock = NSLock()
        var removed = false
        var deleteCount = 0
        HTTPStub.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/api/apps/list"):
                return (200, Data(lock.withLock { removed ? #"{"apps":[]}"# : "{\"apps\":[\(appFixture)]}" }.utf8))
            case ("DELETE", "/api/apps"):
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "app_id" })?.value, "app.test.clock")
                lock.withLock { removed = true; deleteCount += 1 }
                return (200, Data())
            default:
                XCTFail("Unexpected request: \(request)")
                return (500, Data())
            }
        }
        defer { HTTPStub.handler = nil }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        await model.refresh()
        XCTAssertEqual(model.apps.count, 1)
        var sut = AppsContent(model: model)
        let inspected = sut.on(\.didAppear) { view in
            try view.find(button: "Remove…").tap()
            XCTAssertNotNil(try view.find(text: "Remove Clock?"))
            try view.find(button: "Cancel").tap()
            XCTAssertEqual(lock.withLock { deleteCount }, 0)
            XCTAssertEqual(model.apps.count, 1)
            try view.find(button: "Remove…").tap()
            try view.find(button: "Remove").tap()
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
        for _ in 0..<100 where !model.apps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertEqual(lock.withLock { deleteCount }, 1)
    }
}
