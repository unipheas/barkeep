import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class StatusStreamInteractionTests: XCTestCase {
    @MainActor func testStreamButtonsDisplayPacketsAndStopTheSocket() async throws {
        let suite="dev.barkeep.stream-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let socket=StreamControlSocket()
        let model=StatusStreamModel(makeSocket:{ _ in socket })
        defer { model.stop() }
        let view=StatusStreamView(model:model).environment(state)
        XCTAssertTrue(try view.inspect().find(button:"Save Latest Packet…").isDisabled())
        try view.inspect().find(button:"Start Stream").tap()
        for _ in 0..<200 where model.packetCount == 0 { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(model.packetCount,1)
        XCTAssertFalse(try view.inspect().find(button:"Save Latest Packet…").isDisabled())
        XCTAssertNotNil(try view.inspect().find(text:model.latestJSON))
        try view.inspect().find(button:"Stop Stream").tap()
        XCTAssertFalse(model.running)
        XCTAssertTrue(socket.closed)
        XCTAssertNotNil(try view.inspect().find(button:"Start Stream"))
        try view.inspect().find(ViewType.VStack.self).callOnDisappear()
        XCTAssertFalse(model.running)
    }

    @MainActor func testStreamConnectionFailureRemainsVisible() throws {
        let suite="dev.barkeep.stream-error-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let model=StatusStreamModel(makeSocket:{ _ in throw BusyBarError(message:"Fixture connection failed") })
        let view=StatusStreamView(model:model).environment(state)
        try view.inspect().find(button:"Start Stream").tap()
        XCTAssertNotNil(try view.inspect().find(text:"Fixture connection failed"))
        XCTAssertFalse(model.running)
    }
}

private final class StreamControlSocket: StatusSocket {
    var closed=false
    var sent=false
    func start() {}
    func enable() async throws {}
    func receive() async throws -> Data {
        if !sent { sent=true; return Data([0x12,0]) }
        try await Task.sleep(for:.seconds(30))
        throw CancellationError()
    }
    func close() { closed=true }
}
