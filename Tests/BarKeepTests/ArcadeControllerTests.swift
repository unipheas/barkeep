import AppKit
import XCTest
@testable import BarKeep

final class ArcadeControllerTests: XCTestCase {
    override func tearDown() { HTTPStub.handler = nil }
    @MainActor func testKeyboardLifecycleGameSelectionAndPreview() async throws {
        let suite="dev.barkeep.arcade-tests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let keyboard=FixtureKeyboard()
        let controller=ArcadeController(client:BusyBarClient(host:"bar.test",session:HTTPStub.session()),keyboard:keyboard,defaults:defaults)
        HTTPStub.handler = { _ in (200,Data()) }
        controller.captureKeyboard(); XCTAssertEqual(keyboard.starts,0)
        controller.stop()
        controller.showPreview=true
        XCTAssertNotNil(controller.previewImage); XCTAssertTrue(defaults.bool(forKey:"arcadeShowPreview"))
        controller.start(.snake)
        XCTAssertTrue(controller.isActive); XCTAssertTrue(controller.controlsCaptured)
        await settle { controller.framesSent > 0 }
        controller.start(.tetris)
        XCTAssertEqual(controller.selectedGame,.tetris); XCTAssertEqual(keyboard.starts,1)
        for (code,game) in [(UInt16(18),ArcadeGame.snake),(19,.tetris),(20,.pong),(21,.breakout)] {
            keyboard.event?(try key(code)); XCTAssertEqual(controller.selectedGame,game)
        }
        for code in [UInt16(126),125,123,124,49,13,1,0] {
            keyboard.event?(try key(code)); keyboard.event?(try key(code,down:false))
        }
        keyboard.event?(try key(18,repeatKey:true))
        XCTAssertEqual(controller.selectedGame,.breakout)
        keyboard.event?(try key(15))
        keyboard.lost?()
        XCTAssertFalse(controller.controlsCaptured); XCTAssertTrue(controller.errorMessage!.contains("focus"))
        controller.captureKeyboard()
        XCTAssertTrue(controller.controlsCaptured); XCTAssertNil(controller.errorMessage)
        keyboard.event?(try key(53,down:false)); XCTAssertTrue(controller.isActive)
        keyboard.event?(try key(53)); XCTAssertFalse(controller.isActive)
        await controller.stopAndWait()
        XCTAssertEqual(keyboard.stops,1)
        controller.showPreview=false; XCTAssertNil(controller.previewImage)
    }

    @MainActor func testSlowUploadDropsFramesAndStopPreventsLateDrawing() async {
        let keyboard=FixtureKeyboard()
        let client=BusyBarClient(host:"first.test",session:HTTPStub.session())
        let controller=ArcadeController(client:client,keyboard:keyboard)
        let started=expectation(description:"Frame upload started")
        let release=DispatchSemaphore(value:0)
        defer { release.signal() }
        var requests: [URLRequest]=[]
        HTTPStub.handler = { request in
            requests.append(request)
            started.fulfill()
            _ = release.wait(timeout:.now()+10)
            return (200,Data())
        }
        controller.start(.snake)
        await fulfillment(of:[started],timeout:3)
        await settle(seconds:3) { controller.framesDropped > 0 }
        XCTAssertGreaterThan(controller.framesDropped,0)
        client.host="second.test"
        controller.stop()
        release.signal()
        await controller.stopAndWait()
        XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests[0].url?.host,"first.test")
        XCTAssertEqual(controller.framesSent,0)
    }

    @MainActor func testRepeatedNetworkFailuresStopArcade() async {
        HTTPStub.handler = { _ in (503,Data()) }
        let controller=ArcadeController(client:BusyBarClient(host:"bar.test",session:HTTPStub.session()),keyboard:FixtureKeyboard())
        controller.start(.pong)
        await settle(seconds:7) { !controller.isActive }
        XCTAssertEqual(controller.errorMessage,"Arcade stopped after repeated connection failures.")
        XCTAssertFalse(controller.controlsCaptured)
        await controller.stopAndWait()
    }

    @MainActor private func key(_ code:UInt16,down:Bool=true,repeatKey:Bool=false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:down ? .keyDown:.keyUp,location:.zero,modifierFlags:[],timestamp:0,
                                     windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:repeatKey,keyCode:code))
    }
    @MainActor private func settle(seconds:Double=2,_ predicate:()->Bool) async {
        for _ in 0..<Int(seconds*100) {
            if predicate() { return }
            try? await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Arcade state did not settle")
    }
}

@MainActor private final class FixtureKeyboard: ArcadeKeyboardCapturing {
    var event: ((NSEvent)->Void)?
    var lost: (()->Void)?
    var starts=0
    var stops=0
    func start(onEvent:@escaping(NSEvent)->Void,onCaptured:@escaping()->Void,onFocusLost:@escaping()->Void) {
        starts += 1; event=onEvent; lost=onFocusLost; onCaptured()
    }
    func stop(restoreFocus:Bool) { stops += 1; event=nil; lost=nil }
}
