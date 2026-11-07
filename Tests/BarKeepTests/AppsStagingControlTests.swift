import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class AppsStagingControlTests: XCTestCase {
    @MainActor func testStagedReplacementCancelAndInstallControls() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tgz")
        let archive = Data([31, 139, 8, 0, 1, 2, 3])
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url); HTTPStub.handler = nil }
        let replacement = appFixture.replacingOccurrences(of: "1.2.3", with: "2.0.0")
        let lock = NSLock()
        var installs = 0
        var lists = 0
        HTTPStub.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("POST", "/api/apps/stage"):
                XCTAssertEqual(HTTPStub.body(request), archive)
                return (200, Data("{\"install_key\":12345,\"staged\":\(replacement),\"installed\":\(appFixture)}".utf8))
            case ("POST", "/api/apps/install"):
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "install_key", value: "12345")])
                lock.withLock { installs += 1 }
                return (200, Data())
            case ("GET", "/api/apps/list"):
                lock.withLock { lists += 1 }
                return (200, Data("{\"apps\":[\(replacement)]}".utf8))
            default: XCTFail("Unexpected request: \(request)"); return (500, Data())
            }
        }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        await model.stage(url: url)
        XCTAssertNil(model.error)
        let view = AppsContent(model: model)
        XCTAssertNotNil(try view.inspect().find(text: "Clock · 2.0.0"))
        XCTAssertNotNil(try view.inspect().find(text: "app.test.clock"))
        XCTAssertNotNil(try view.inspect().find(text: "By Tester · API 27.12.0"))
        XCTAssertNotNil(try view.inspect().find(text: "Replaces installed version 1.2.3."))
        try view.inspect().find(button: "Cancel").tap()
        XCTAssertNil(model.staged)
        XCTAssertNil(model.message)
        XCTAssertEqual(lock.withLock { installs }, 0)
        XCTAssertEqual(lock.withLock { lists }, 0)
        await model.stage(url: url)
        try view.inspect().find(button: "Install App").tap()
        for _ in 0..<200 where !model.loaded { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.loaded)
        XCTAssertNil(model.staged)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.apps.first?.version, "2.0.0")
        XCTAssertEqual(model.message, "Installed Clock 2.0.0.")
        XCTAssertEqual(lock.withLock { installs }, 1)
        XCTAssertEqual(lock.withLock { lists }, 1)
        XCTAssertNotNil(try view.inspect().find(text: "Installed Clock 2.0.0."))
    }
}
