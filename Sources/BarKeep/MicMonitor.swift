import Foundation
import CoreAudio

/// Watches every audio input device and reports whether any of them is
/// actively capturing (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
/// This flips to true when Teams, Zoom, FaceTime, etc. open the mic —
/// no microphone permission is needed because no audio is captured.
final class MicMonitor {
    var onChange: ((Bool) -> Void)?

    private(set) var isMicInUse = false

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
        let inUse = watchedDevices.contains { isRunningSomewhere($0) }
        guard inUse != isMicInUse else { return }
        isMicInUse = inUse
        let callback = onChange
        DispatchQueue.main.async { callback?(inUse) }
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

        return ids.filter { inputStreamCount($0) > 0 }
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
}
