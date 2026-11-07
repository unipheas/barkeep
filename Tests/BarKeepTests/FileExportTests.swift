import XCTest
import SwiftUI
import ViewInspector
@testable import BarKeep

final class FileExportTests: XCTestCase {
    @MainActor func testConnectionChangesStopHostedStream() async throws {
        let suite = "dev.barkeep.stream-connection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let model = StatusStreamModel(makeSocket: { _ in ExportPacketSocket() })
        var sut = StatusStreamView(model: model)
        let inspected = sut.on(\.didAppear) { view in
            model.start(client: state.client)
            XCTAssertTrue(model.running)
            try view.vStack().callOnChange(oldValue: "old-host", newValue: "new-host", index: 0)
            XCTAssertFalse(model.running)
            model.start(client: state.client)
            XCTAssertTrue(model.running)
            try view.vStack().callOnChange(oldValue: "old-token", newValue: "new-token", index: 1)
            XCTAssertFalse(model.running)
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel(); model.stop() }
        await fulfillment(of: [inspected], timeout: 5)
    }

    @MainActor func testAtomicExportAndFilesystemFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("response.json")
        let data = Data("fixture".utf8)
        XCTAssertNoThrow(try FileExport.write(data, to: file).get())
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertThrowsError(try FileExport.write(data, to: directory).get())
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    @MainActor func testDeviceResponseExportSurfacesWriteFailure() async throws {
        let suite = "dev.barkeep.export-response.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let data = Data(#"{"fixture":true}"#.utf8)
        HTTPStub.handler = { _ in (200, data) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let model = DeviceToolsModel()
        let endpoint = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/status" })
        await model.execute(endpoint, client: state.client)
        var exports = 0
        let view = DeviceToolsView(endpoint: endpoint, model: model, exportFile: { bytes, name, complete in
            XCTAssertEqual(bytes, data)
            XCTAssertEqual(name, "busy-bar-response")
            exports += 1
            complete(.failure(BusyBarError(message: "Fixture export failed")))
        }).environment(state)
        try view.inspect().find(button: "Save Response…").tap()
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(model.error, "Fixture export failed")
    }

    @MainActor func testPacketSaveFailureAndSuccessUpdateInstalledErrorState() async throws {
        let suite = "dev.barkeep.export-packet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        let model = StatusStreamModel(makeSocket: { _ in ExportPacketSocket() })
        model.start(client: state.client)
        defer { model.stop() }
        for _ in 0..<200 where model.latestData == nil { try await Task.sleep(for: .milliseconds(5)) }
        let packet = try XCTUnwrap(model.latestData)
        var fail = true
        var exports = 0
        var sut = StatusStreamView(model: model, exportFile: { bytes, name, complete in
            XCTAssertEqual(bytes, packet)
            XCTAssertEqual(name, "busy-bar-status.json")
            exports += 1
            complete(fail ? .failure(BusyBarError(message: "Fixture packet save failed")) : .success(()))
        })
        let inspected = sut.on(\.didAppear) { view in
            try view.find(button: "Save Latest Packet…").tap()
            XCTAssertNotNil(try view.find(text: "Fixture packet save failed"))
            fail = false
            try view.find(button: "Save Latest Packet…").tap()
            XCTAssertThrowsError(try view.find(text: "Fixture packet save failed"))
            XCTAssertEqual(exports, 2)
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
    }
}

private final class ExportPacketSocket: StatusSocket {
    private var sent = false
    func start() {}
    func enable() async throws {}
    func receive() async throws -> Data {
        if !sent { sent = true; return Data([0x12, 0]) }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func close() {}
}
