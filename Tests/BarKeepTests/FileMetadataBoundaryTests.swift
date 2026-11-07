import XCTest
@testable import BarKeep

final class FileMetadataBoundaryTests: XCTestCase {
    @MainActor func testAppPackageMetadataUnavailableThrowsOrExceedsLimit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tgz")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file); HTTPStub.handler = nil }
        var requests = 0
        HTTPStub.handler = { request in
            requests += 1
            XCTAssertEqual(HTTPStub.body(request), bytes)
            return (200, Data("{\"install_key\":123,\"staged\":\(appFixture)}".utf8))
        }
        let client = BusyBarClient(host: "fixture.test", session: HTTPStub.session())
        let unavailable = DeviceAppsModel(client: client, fileSize: { url in XCTAssertEqual(url, file); return nil })
        await unavailable.stage(url: file)
        XCTAssertNotNil(unavailable.staged)
        XCTAssertNil(unavailable.error)
        XCTAssertEqual(requests, 1)
        let failed = DeviceAppsModel(client: client, fileSize: { _ in throw BusyBarError(message: "Fixture metadata unavailable") })
        await failed.stage(url: file)
        XCTAssertEqual(failed.error, "Fixture metadata unavailable")
        XCTAssertNil(failed.staged)
        let oversized = DeviceAppsModel(client: client, fileSize: { _ in 100 * 1024 * 1024 + 1 })
        await oversized.stage(url: file)
        XCTAssertEqual(oversized.error, "App packages must be at most 100 MiB.")
        XCTAssertNil(oversized.staged)
        XCTAssertEqual(requests, 1, "Rejected metadata must not upload")
    }

    @MainActor func testToolUploadMetadataUnavailableThrowsOrExceedsLimit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([4, 5, 6])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file); HTTPStub.handler = nil }
        var requests = 0
        HTTPStub.handler = { request in
            requests += 1
            XCTAssertEqual(HTTPStub.body(request), bytes)
            return (200, Data())
        }
        let client = BusyBarClient(host: "fixture.test", session: HTTPStub.session())
        let endpoint = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/apps/stage" && $0.method == "POST" })
        let unavailable = DeviceToolsModel(fileSize: { url in XCTAssertEqual(url, file); return nil })
        unavailable.upload = file
        unavailable.prepareConfirmation(endpoint, client: client)
        XCTAssertTrue(unavailable.confirm)
        await unavailable.applyConfirmed(client: client)
        XCTAssertNil(unavailable.error)
        XCTAssertEqual(requests, 1)
        let failed = DeviceToolsModel(fileSize: { _ in throw BusyBarError(message: "Fixture metadata unavailable") })
        failed.upload = file
        failed.prepareConfirmation(endpoint, client: client)
        XCTAssertEqual(failed.error, "Fixture metadata unavailable")
        XCTAssertFalse(failed.confirm)
        await failed.applyConfirmed(client: client)
        let oversized = DeviceToolsModel(fileSize: { _ in 256 * 1024 * 1024 + 1 })
        oversized.upload = file
        oversized.prepareConfirmation(endpoint, client: client)
        XCTAssertEqual(oversized.error, "Choose a file smaller than 256 MB.")
        XCTAssertFalse(oversized.confirm)
        await oversized.applyConfirmed(client: client)
        XCTAssertEqual(requests, 1, "Rejected metadata must not upload")
    }
}
