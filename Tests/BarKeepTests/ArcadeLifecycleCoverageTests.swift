import AppKit
import XCTest
@testable import BarKeep

final class ArcadeLifecycleCoverageTests: XCTestCase {
    @MainActor func testTransientDrawFailureRecoversAndClearsError() async throws {
        let suite = "dev.barkeep.arcade-recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { HTTPStub.handler = nil; defaults.removePersistentDomain(forName: suite) }
        let lock = NSLock()
        var draws = 0
        var uploads = 0
        HTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            if request.url?.path == "/api/assets/upload" {
                lock.withLock { uploads += 1 }
                return (200, Data())
            }
            XCTAssertEqual(request.url?.path, "/api/display/draw")
            let attempt = lock.withLock { draws += 1; return draws }
            return (attempt == 1 ? 503 : 200, Data())
        }
        let keyboard = LifecycleKeyboard()
        let controller = ArcadeController(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()), keyboard: keyboard, defaults: defaults)
        controller.start(.pong)
        await settle { controller.errorMessage != nil }
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.framesSent, 0)
        await settle { controller.framesSent > 0 }
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.controlsCaptured)
        await controller.stopAndWait()
        XCTAssertEqual(keyboard.restores, [true])
        XCTAssertGreaterThanOrEqual(lock.withLock { uploads }, 2)
        XCTAssertGreaterThanOrEqual(lock.withLock { draws }, 2)
    }

    @MainActor func testStaleUploadFailureCannotPoisonRestartedSession() async throws {
        let suite = "dev.barkeep.arcade-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { HTTPStub.handler = nil; defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Old upload pending")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var first = true
        var drawnHosts: [String] = []
        HTTPStub.handler = { request in
            let isFirst = lock.withLock { let result = first; first = false; return result }
            if isFirst {
                XCTAssertEqual(request.url?.host, "old.test")
                XCTAssertEqual(request.url?.path, "/api/assets/upload")
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (503, Data())
            }
            if request.url?.path == "/api/display/draw" {
                lock.withLock { drawnHosts.append(request.url!.host!) }
            }
            return (200, Data())
        }
        let keyboard = LifecycleKeyboard()
        let client = BusyBarClient(host: "old.test", session: HTTPStub.session())
        let controller = ArcadeController(client: client, keyboard: keyboard, defaults: defaults)
        controller.start(.snake)
        await fulfillment(of: [started], timeout: 3)
        controller.stop()
        client.host = "new.test"
        controller.start(.breakout)
        release.signal()
        await settle { controller.framesSent > 0 }
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.selectedGame, .breakout)
        XCTAssertNil(controller.errorMessage)
        await controller.stopAndWait()
        XCTAssertEqual(keyboard.starts, 2)
        XCTAssertEqual(keyboard.restores, [true, true])
        XCTAssertFalse(lock.withLock { drawnHosts }.isEmpty)
        XCTAssertTrue(lock.withLock { drawnHosts }.allSatisfy { $0 == "new.test" })
    }

    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Arcade recovery did not settle")
    }
}

@MainActor private final class LifecycleKeyboard: ArcadeKeyboardCapturing {
    var starts = 0
    var restores: [Bool] = []
    func start(onEvent: @escaping (NSEvent) -> Void, onCaptured: @escaping () -> Void, onFocusLost: @escaping () -> Void) {
        starts += 1
        onCaptured()
    }
    func stop(restoreFocus: Bool) { restores.append(restoreFocus) }
}
