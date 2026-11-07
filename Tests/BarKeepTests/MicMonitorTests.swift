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

extension MicMonitorTests {
    @MainActor func testHardwareEventsIncludeUnnamedActiveMicAndRemoveOldListeners() async {
        let hardware = FixtureAudioHardware()
        let monitor = MicMonitor(hardware:hardware.calls)
        var changes:[MicMonitor.Activity]=[]
        monitor.onChange = { changes.append($0) }
        monitor.start(); monitor.start()
        await audioSettle { hardware.listenerCount == 3 }
        XCTAssertEqual(hardware.listenerCount,3,"One device-list listener and two input listeners")
        hardware.lock.withLock { hardware.running = [101] }
        hardware.signal(device:101,selector:kAudioDevicePropertyDeviceIsRunningSomewhere)
        await audioSettle { changes.last?.isInUse == true }
        XCTAssertEqual(changes.last?.deviceNames,["Fixture microphone"])
        hardware.lock.withLock { hardware.running=[102]; hardware.nameMissing=true }
        hardware.signal(device:102,selector:kAudioDevicePropertyDeviceIsRunningSomewhere)
        await audioSettle { changes.last?.deviceNames == ["Microphone"] }
        XCTAssertTrue(changes.last!.isInUse,"A failed name lookup must not hide an active call")
        hardware.lock.withLock { hardware.ids=[101]; hardware.running=[] }
        hardware.signal(device:AudioObjectID(kAudioObjectSystemObject),selector:kAudioHardwarePropertyDevices)
        await audioSettle { changes.last?.isInUse == false }
        XCTAssertEqual(hardware.listenerCount,2)
        monitor.stop(); monitor.stop()
        XCTAssertEqual(hardware.listenerCount,0)
        monitor.start()
        await audioSettle { hardware.listenerCount == 2 }
        monitor.stop()
    }

    @MainActor func testAudioReadFailuresAndHiddenInputsAreHandled() async {
        for (selector,sizing) in [(kAudioHardwarePropertyDevices,true),(kAudioHardwarePropertyDevices,false),
                                  (kAudioDevicePropertyStreams,true),(kAudioDevicePropertyDeviceIsRunningSomewhere,false),
                                  (kAudioDevicePropertyTransportType,false)] {
            let hardware=FixtureAudioHardware()
            hardware.failedSelector=selector; hardware.failSize=sizing
            let monitor=MicMonitor(hardware:hardware.calls)
            monitor.start()
            try? await Task.sleep(for:.milliseconds(15))
            monitor.stop()
            XCTAssertEqual(hardware.listenerCount,0)
        }
        let hidden=FixtureAudioHardware(); hidden.hidden=true
        let monitor=MicMonitor(hardware:hidden.calls)
        monitor.start(); try? await Task.sleep(for:.milliseconds(15)); monitor.stop()
        XCTAssertFalse(monitor.isMicInUse)
    }

    @MainActor func testSystemAudioListenerCanStartAndStopWithoutRecording() async {
        let monitor=MicMonitor()
        monitor.start()
        try? await Task.sleep(for:.milliseconds(20))
        monitor.stop()
    }

    @MainActor private func audioSettle(_ condition:()->Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Audio monitor did not settle")
    }
}

private final class FixtureAudioHardware {
    let lock=NSLock()
    var ids:[AudioObjectID]=[101,102]
    var running:Set<AudioObjectID>=[]
    var nameMissing=false
    var hidden=false
    var failedSelector:AudioObjectPropertySelector?
    var failSize=false
    private let name="Fixture microphone" as CFString
    private var listeners:[String:(DispatchQueue,AudioObjectPropertyListenerBlock)]=[:]
    var listenerCount:Int { lock.withLock { listeners.count } }
    private func key(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector)->String { "\(id)-\(selector)" }
    var calls:AudioHardwareCalls {
        AudioHardwareCalls(size:{ id,address,size in
            self.lock.withLock {
                if self.failedSelector == address.mSelector && self.failSize { return OSStatus(-1) }
                size = address.mSelector == kAudioHardwarePropertyDevices ? UInt32(self.ids.count*4) : 4
                return noErr
            }
        },read:{ id,address,size,pointer in
            self.lock.withLock {
                if self.failedSelector == address.mSelector && !self.failSize { return OSStatus(-1) }
                switch address.mSelector {
                case kAudioHardwarePropertyDevices:
                    for (index,id) in self.ids.enumerated() { pointer.assumingMemoryBound(to:AudioObjectID.self)[index]=id }
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                    pointer.assumingMemoryBound(to:UInt32.self).pointee=self.running.contains(id) ? 1 : 0
                case kAudioDevicePropertyTransportType:
                    pointer.assumingMemoryBound(to:UInt32.self).pointee=kAudioDeviceTransportTypeUSB
                case kAudioDevicePropertyIsHidden:
                    pointer.assumingMemoryBound(to:UInt32.self).pointee=self.hidden ? 1 : 0
                case kAudioObjectPropertyName:
                    pointer.assumingMemoryBound(to:Unmanaged<CFString>?.self).pointee=self.nameMissing ? nil : Unmanaged.passUnretained(self.name)
                default: return OSStatus(-1)
                }
                return noErr
            }
        },add:{ id,address,queue,callback in
            self.lock.withLock { self.listeners[self.key(id,address.mSelector)]=(queue,callback) }
            return noErr
        },remove:{ id,address,_,_ in
            _ = self.lock.withLock { self.listeners.removeValue(forKey:self.key(id,address.mSelector)) }
            return noErr
        })
    }
    func signal(device:AudioObjectID,selector:AudioObjectPropertySelector) {
        guard let (queue,callback)=lock.withLock({ listeners[key(device,selector)] }) else { return }
        queue.async {
            var address=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            withUnsafePointer(to:&address) { callback(1,$0) }
        }
    }
}
