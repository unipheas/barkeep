import Foundation
import CoreAudio

/// Watches every audio input device and reports whether any of them is
/// actively capturing (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
/// This flips to true when Teams, Zoom, FaceTime, etc. open the mic —
/// no microphone permission is needed because no audio is captured.
final class MicMonitor {
    struct Activity: Equatable {
        let isInUse: Bool
        let deviceNames: [String]
    }

    var onChange: ((Activity) -> Void)?

    private(set) var isMicInUse = false
    private(set) var activeDeviceNames: [String] = []

    private let queue = DispatchQueue(label: "busybar.micmonitor")
    private var watchedDevices: Set<AudioObjectID> = []
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        let running: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.evaluate() }
        }
        let devices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.rebuildWatchList() }
        }
        runningListener = running
        devicesListener = devices
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, devices
        )
        queue.async { self.rebuildWatchList() }
    }

    func stop() {
        queue.sync {
            if let devices = devicesListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, devices
                )
            }
            if let running = runningListener {
                for device in watchedDevices {
                    AudioObjectRemovePropertyListenerBlock(device, &runningAddress, queue, running)
                }
            }
            watchedDevices.removeAll()
        }
    }

    private func rebuildWatchList() {
        guard let running = runningListener else { return }
        let inputs = Set(allInputDevices())
        for device in watchedDevices.subtracting(inputs) {
            AudioObjectRemovePropertyListenerBlock(device, &runningAddress, queue, running)
        }
        for device in inputs.subtracting(watchedDevices) {
            AudioObjectAddPropertyListenerBlock(device, &runningAddress, queue, running)
        }
        watchedDevices = inputs
        evaluate()
    }

    private func evaluate() {
        let names = watchedDevices
            .filter { isRunningSomewhere($0) }
            .compactMap { deviceName($0) }
            .sorted()
        let activity = Activity(isInUse: !names.isEmpty, deviceNames: names)
        guard activity != Activity(isInUse: isMicInUse, deviceNames: activeDeviceNames) else { return }
        isMicInUse = activity.isInUse
        activeDeviceNames = activity.deviceNames
        let callback = onChange
        DispatchQueue.main.async { callback?(activity) }
    }

    private func allInputDevices() -> [AudioObjectID] {
        var size: UInt32 = 0
        var address = devicesAddress
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.filter {
            inputStreamCount($0) > 0
                && Self.shouldMonitor(
                    transportType: transportType($0),
                    isHidden: isHidden($0)
                )
        }
    }

    static func shouldMonitor(transportType: UInt32?, isHidden: Bool) -> Bool {
        guard !isHidden else { return false }
        guard let transportType else { return true }
        return transportType != kAudioDeviceTransportTypeVirtual
            && transportType != kAudioDeviceTransportTypeAggregate
    }

    private func inputStreamCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = runningAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func transportType(_ device: AudioObjectID) -> UInt32? {
        readUInt32(device, selector: kAudioDevicePropertyTransportType)
    }

    private func isHidden(_ device: AudioObjectID) -> Bool {
        readUInt32(device, selector: kAudioDevicePropertyIsHidden) == 1
    }

    private func readUInt32(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else {
            return nil
        }
        return name.takeUnretainedValue() as String
    }
}
