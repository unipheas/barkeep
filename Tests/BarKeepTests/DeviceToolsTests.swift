import XCTest
@testable import BarKeep

final class DeviceToolsTests: XCTestCase {
    override func tearDown() { HTTPStub.handler = nil }

    private func endpoint(_ path: String, _ method: String = "GET") -> DeviceEndpoint {
        DeviceEndpoint.all.first { $0.path == path && $0.method == method }!
    }

    @MainActor func testValidationBeforeConfirmationAndImmutableDestination() async throws {
        let client = BusyBarClient(host:"bar.test", session:HTTPStub.session())
        let model = DeviceToolsModel()
        let brightness = endpoint("/display/brightness", "POST")
        model.reset(for: brightness)
        model.prepareConfirmation(brightness, client:client)
        XCTAssertFalse(model.confirm)
        XCTAssertEqual(model.error,"Enter value.")
        model.values["value"] = "50"
        model.prepareConfirmation(brightness, client:client)
        XCTAssertTrue(model.confirm)
        XCTAssertEqual(model.confirmationHost,"bar.test")
        model.values["value"] = "80"
        var calls = 0
        HTTPStub.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.host,"bar.test")
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"50")
            return (200, Data())
        }
        await model.applyConfirmed(client:client)
        XCTAssertEqual(calls,1)
        XCTAssertEqual(model.response,"Completed successfully.")
        await model.applyConfirmed(client:client)
        XCTAssertEqual(calls,1,"A confirmation must be single-use")
        model.prepareConfirmation(brightness,client:client)
        client.host = "other.test"
        await model.applyConfirmed(client:client)
        XCTAssertEqual(calls,1)
        XCTAssertTrue(model.error!.contains("Device changed"))
        model.reset(for:nil)
        XCTAssertNil(model.error); XCTAssertNil(model.responseData); XCTAssertNil(model.confirmationHost)
        XCTAssertEqual(model.values,[:]); XCTAssertEqual(model.json,"")
    }

    @MainActor func testResponseFormattingAndErrors() async throws {
        let client = BusyBarClient(host:"bar.test", session:HTTPStub.session())
        let model = DeviceToolsModel()
        for bytes in [Data(#"{"ok":true}"#.utf8),Data("plain text".utf8),Data([0xFF,0xFE]),Data(repeating:65,count:65537)] {
            HTTPStub.handler = { _ in (200,bytes) }
            await model.execute(endpoint("/status"),client:client)
            XCTAssertEqual(model.responseData,bytes)
            XCTAssertFalse(model.response.isEmpty)
            if bytes.count > 65536 { XCTAssertTrue(model.response.contains("65537 bytes")) }
            if bytes == Data([0xFF,0xFE]) { XCTAssertTrue(model.response.contains("binary bytes")) }
        }
        HTTPStub.handler = { _ in (403,Data()) }
        await model.execute(endpoint("/status"),client:client)
        XCTAssertNotNil(model.error); XCTAssertNil(model.responseData); XCTAssertFalse(model.working)
        await model.execute(endpoint("/display/brightness","POST"),client:client)
        XCTAssertEqual(model.error,"Enter value.")
    }

    @MainActor func testUploadBoundsAndJSONValidation() async throws {
        let client = BusyBarClient(host:"bar.test", session:HTTPStub.session())
        let model = DeviceToolsModel()
        let stage = endpoint("/apps/stage","POST")
        model.prepareConfirmation(stage,client:client)
        XCTAssertEqual(model.error,"Choose a file to upload.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        try Data([1,2,3]).write(to:url)
        model.upload = url
        model.prepareConfirmation(stage,client:client)
        HTTPStub.handler = { request in
            XCTAssertEqual(HTTPStub.body(request),Data([1,2,3]))
            return (200,Data())
        }
        await model.applyConfirmed(client:client)
        XCTAssertNil(model.error)
        let handle = try FileHandle(forWritingTo:url)
        try handle.truncate(atOffset:256 * 1024 * 1024 + 1); try handle.close()
        model.prepareConfirmation(stage,client:client)
        XCTAssertFalse(model.confirm); XCTAssertTrue(model.error!.contains("256 MB"))
        model.reset(for:endpoint("/busy/snapshot","PUT"))
        model.json = "{invalid"
        model.prepareConfirmation(endpoint("/busy/snapshot","PUT"),client:client)
        XCTAssertFalse(model.confirm); XCTAssertNotNil(model.error)
    }

    @MainActor func testResetAndEndpointChangesDiscardLateResultsAndErrors() async throws {
        let client = BusyBarClient(host:"bar.test", session:HTTPStub.session())
        let model = DeviceToolsModel()
        for fail in [false,true] {
            let started = expectation(description:"Request started")
            HTTPStub.handler = { _ in
                started.fulfill()
                Thread.sleep(forTimeInterval:0.1)
                return (fail ? 500 : 200,Data("{}".utf8))
            }
            let task = Task { await model.execute(endpoint("/status"),client:client) }
            await fulfillment(of:[started],timeout:1)
            XCTAssertTrue(model.working)
            model.prepareConfirmation(endpoint("/status"),client:client)
            XCTAssertFalse(model.confirm)
            await model.execute(endpoint("/status"),client:client)
            await model.applyConfirmed(client:client)
            model.reset(for:endpoint("/name"))
            await task.value
            XCTAssertNil(model.error); XCTAssertNil(model.responseData)
            XCTAssertFalse(model.working)
        }
        let started = expectation(description:"Destination change")
        HTTPStub.handler = { _ in
            started.fulfill(); Thread.sleep(forTimeInterval:0.1)
            return (200,Data("{}".utf8))
        }
        let task = Task { await model.execute(endpoint("/status"),client:client) }
        await fulfillment(of:[started],timeout:1)
        client.token = "changed"
        await task.value
        XCTAssertNil(model.responseData)
    }
}
