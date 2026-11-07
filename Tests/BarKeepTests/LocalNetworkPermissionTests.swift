import Network
import XCTest
@testable import BarKeep

final class LocalNetworkPermissionTests: XCTestCase {
    @MainActor func testPermissionProbeIsIdempotentAndIgnoresOldCallbacks() async {
        let first=FixtureNetworkBrowser(), second=FixtureNetworkBrowser()
        var created=0
        let trigger=LocalNetworkPermissionTrigger(makeBrowser:{
            created += 1
            return created == 1 ? first : second
        })
        let available=expectation(description:"Current browser granted access")
        trigger.onAccessAvailable={ available.fulfill() }
        trigger.requestAccess(); trigger.requestAccess()
        XCTAssertEqual(created,1); XCTAssertEqual(first.starts,1)
        let failed=expectation(description:"Failed probe cancelled")
        first.onCancel={ failed.fulfill() }
        first.stateUpdateHandler?(.waiting(.posix(.ENETDOWN)))
        first.stateUpdateHandler?(.failed(.posix(.ENETDOWN)))
        await fulfillment(of:[failed],timeout:2)
        XCTAssertEqual(first.cancels,1)
        trigger.requestAccess()
        XCTAssertEqual(second.starts,1)
        first.stateUpdateHandler?(.cancelled)
        first.stateUpdateHandler?(.ready)
        await drain()
        XCTAssertEqual(second.cancels,0,"An old callback must not stop the replacement probe")
        second.stateUpdateHandler?(.ready)
        await fulfillment(of:[available],timeout:2)
        XCTAssertEqual(second.cancels,1)
    }

    @MainActor func testCancelledProbeCanBeRequestedAgain() async {
        let browser=FixtureNetworkBrowser()
        let trigger=LocalNetworkPermissionTrigger(makeBrowser:{browser})
        trigger.requestAccess()
        let cancelled=expectation(description:"Cancelled probe stopped")
        browser.onCancel={ cancelled.fulfill() }
        browser.stateUpdateHandler?(.cancelled)
        await fulfillment(of:[cancelled],timeout:2)
        XCTAssertEqual(browser.cancels,1)
        trigger.requestAccess()
        XCTAssertEqual(browser.starts,2)
        let stoppedAgain=expectation(description:"Replacement probe stopped")
        browser.onCancel={ stoppedAgain.fulfill() }
        browser.stateUpdateHandler?(.cancelled)
        await fulfillment(of:[stoppedAgain],timeout:2)
    }

    @MainActor private func drain() async {
        // State callbacks enqueue a main-actor task; wait for that queue to run.
        for _ in 0..<10 { await Task.yield() }
    }
}

private final class FixtureNetworkBrowser: LocalNetworkBrowser {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var starts=0
    var cancels=0
    var onCancel: (() -> Void)?
    func start(queue: DispatchQueue) { starts += 1 }
    func cancel() { cancels += 1; onCancel?() }
}
