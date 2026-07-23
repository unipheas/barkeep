import CoreAudio
import XCTest
@testable import BarKeep

final class MicMonitorTests: XCTestCase {
    func testPhysicalDeviceIsMonitored() {
        XCTAssertTrue(
            MicMonitor.shouldMonitor(
                transportType: kAudioDeviceTransportTypeBuiltIn,
                isHidden: false
            )
        )
        XCTAssertTrue(
            MicMonitor.shouldMonitor(
                transportType: kAudioDeviceTransportTypeUSB,
                isHidden: false
            )
        )
    }

    func testVirtualAndAggregateDevicesAreIgnored() {
        XCTAssertFalse(
            MicMonitor.shouldMonitor(
                transportType: kAudioDeviceTransportTypeVirtual,
                isHidden: false
            )
        )
        XCTAssertFalse(
            MicMonitor.shouldMonitor(
                transportType: kAudioDeviceTransportTypeAggregate,
                isHidden: false
            )
        )
    }

    func testHiddenDeviceIsIgnored() {
        XCTAssertFalse(
            MicMonitor.shouldMonitor(
                transportType: kAudioDeviceTransportTypeBuiltIn,
                isHidden: true
            )
        )
    }

    func testUnknownTransportFallsBackToMonitoring() {
        XCTAssertTrue(MicMonitor.shouldMonitor(transportType: nil, isHidden: false))
    }
}
