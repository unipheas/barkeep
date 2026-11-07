import AppKit

import XCTest
@testable import BarKeep

final class EncodingFailureTests: XCTestCase {
    @MainActor func testFailedMessageEncodingDoesNotSendAnAsset() async {
        let suite = "dev.barkeep.encode-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in XCTFail("Failed encoding must not reach transport"); return (500, Data()) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session(), renderMessage: { _, _ in nil })
        state.sendMessage("🚀", font: .normal, color: .white, timeoutSeconds: 30)
        await settle { state.lastError == "Could not render message image" }
        XCTAssertEqual(state.lastError, "Could not render message image")
    }

    @MainActor func testFailedArcadeEncodingRemainsStoppableAndSendsNoFrame() async {
        let suite = "dev.barkeep.arcade-encode-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE", "Failed encoding must not upload or display a frame")
            return (200, Data())
        }
        let controller = ArcadeController(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()),
            keyboard: EncodingKeyboardFixture(), defaults: defaults, encodeFrame: { _ in nil })
        controller.start(.snake)
        await settle { controller.errorMessage == "Could not encode the arcade frame." }
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.framesSent, 0)
        await controller.stopAndWait()
        XCTAssertFalse(controller.isActive)
    }

    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Encoding error did not settle")
    }
}

@MainActor private final class EncodingKeyboardFixture: ArcadeKeyboardCapturing {
    func start(onEvent: @escaping (NSEvent) -> Void, onCaptured: @escaping () -> Void, onFocusLost: @escaping () -> Void) { onCaptured() }
    func stop(restoreFocus: Bool) {}
}
