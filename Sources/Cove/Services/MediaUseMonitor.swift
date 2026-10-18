import CoreAudio
import CoreMediaIO
import Foundation

// MARK: - State (pure)

/// The iPhone-style privacy dot: green while a camera is on, orange while only a microphone is.
enum PrivacyDot: Equatable {
    case camera, microphone

    var label: String { self == .camera ? "Camera in use" : "Microphone in use" }
}

/// One capture source as the system reports it: a camera, an input device or an audio process.
struct CaptureReading: Equatable {
    var running: Bool
    /// The process doing the capturing, when known (audio processes on macOS 14.2+).
    var pid: pid_t? = nil
}

/// Whether any camera or microphone is in use right now.
struct MediaUse: Equatable {
    var camera = false
    var microphone = false

    /// The camera wins when both are on, as on the iPhone.
    var dot: PrivacyDot? {
        if camera { return .camera }
        if microphone { return .microphone }
        return nil
    }

    /// Folds the raw readings into what's in use. Cove's own process never counts.
    static func reduce(cameras: [CaptureReading], microphones: [CaptureReading], ownPID: pid_t) -> MediaUse {
        func inUse(_ readings: [CaptureReading]) -> Bool { readings.contains { $0.running && $0.pid != ownPID } }
        return MediaUse(camera: inUse(cameras), microphone: inUse(microphones))
    }
}

// MARK: - Monitor

/// Watches whether any app is using a camera (CoreMediaIO) or a microphone (CoreAudio).
/// Only reads "is it running" flags, so no camera or microphone permission is needed.
/// Property listeners give instant updates; a slow poll catches anything a listener misses.
final class MediaUseMonitor {
    var onChange: (@MainActor (MediaUse) -> Void)?

    private struct AudioWatch: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    private var audioWatches: [AudioWatch: AudioObjectPropertyListenerBlock] = [:]
    private var cameraWatches: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var systemCameraBlock: CMIOObjectPropertyListenerBlock?
    private var timer: Timer?
    private var last: MediaUse?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let cameraSystem = CMIOObjectID(kCMIOObjectSystemObject)

    func start() {
        guard timer == nil else { return }
        // Devices (and, on macOS 14.2+, audio clients) coming and going.
        watchAudio([Self.system], kAudioHardwarePropertyDevices)
        if #available(macOS 14.2, *) { watchAudio([Self.system], kAudioHardwarePropertyProcessObjectList) }
        var devices = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        if CMIOObjectAddPropertyListenerBlock(Self.cameraSystem, &devices, .main, block) == noErr { systemCameraBlock = block }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (watch, block) in audioWatches {
            var address = Self.audioAddress(watch.selector)
            AudioObjectRemovePropertyListenerBlock(watch.object, &address, .main, block)
        }
        audioWatches.removeAll()
        for (device, block) in cameraWatches {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        cameraWatches.removeAll()
        if let block = systemCameraBlock {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(Self.cameraSystem, &address, .main, block)
        }
        systemCameraBlock = nil
        last = nil
    }

    /// Runs on the main thread (listeners use the main queue, the timer the main run loop).
    private func refresh() {
        guard timer != nil else { return }
        let use = MediaUse.reduce(cameras: cameraReadings(), microphones: microphoneReadings(), ownPID: ownPID)
        guard use != last else { return }
        last = use
        let callback = onChange
        Task { @MainActor in callback?(use) }
    }

    // MARK: Camera (CoreMediaIO)

    private func cameraReadings() -> [CaptureReading] {
        let devices = cameraDevices()
        syncCameraWatches(devices)
        return devices.map { device in
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var running = UInt32(0)
            var used = UInt32(0)
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return CaptureReading(running: status == noErr && running != 0)
        }
    }

    private func cameraDevices() -> [CMIOObjectID] {
        var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(Self.cameraSystem, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(Self.cameraSystem, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func syncCameraWatches(_ devices: [CMIOObjectID]) {
        let current = Set(devices)
        for (device, block) in cameraWatches where !current.contains(device) {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(device, &address, .main, block)
            cameraWatches[device] = nil
        }
        for device in current where cameraWatches[device] == nil {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if CMIOObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { cameraWatches[device] = block }
        }
    }

    // MARK: Microphone (CoreAudio)

    private func microphoneReadings() -> [CaptureReading] {
        // macOS 14.2+ says which process is recording, so Cove can leave itself out and a headset that's
        // only playing audio doesn't count.
        if #available(macOS 14.2, *) {
            let processes = audioObjects(kAudioHardwarePropertyProcessObjectList)
            if !processes.isEmpty {
                watchAudio(processes, kAudioProcessPropertyIsRunningInput)
                return processes.map { process in
                    CaptureReading(running: audioUInt32(process, kAudioProcessPropertyIsRunningInput) != 0,
                                   pid: audioPID(process))
                }
            }
        }
        let inputs = audioObjects(kAudioHardwarePropertyDevices).filter(hasInput)
        watchAudio(inputs, kAudioDevicePropertyDeviceIsRunningSomewhere)
        return inputs.map { CaptureReading(running: audioUInt32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0) }
    }

    private func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = Self.audioAddress(selector)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func hasInput(_ device: AudioObjectID) -> Bool {
        var address = Self.audioAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = Self.audioAddress(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    @available(macOS 14.2, *)
    private func audioPID(_ process: AudioObjectID) -> pid_t? {
        var address = Self.audioAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    /// Listens for `selector` on exactly `objects`, dropping listeners on objects that went away.
    private func watchAudio(_ objects: [AudioObjectID], _ selector: AudioObjectPropertySelector) {
        let wanted = Set(objects.map { AudioWatch(object: $0, selector: selector) })
        for (watch, block) in audioWatches where watch.selector == selector && !wanted.contains(watch) {
            var address = Self.audioAddress(selector)
            AudioObjectRemovePropertyListenerBlock(watch.object, &address, .main, block)
            audioWatches[watch] = nil
        }
        for watch in wanted where audioWatches[watch] == nil {
            var address = Self.audioAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(watch.object, &address, .main, block) == noErr { audioWatches[watch] = block }
        }
    }

    // MARK: Addresses

    private static func audioAddress(_ selector: AudioObjectPropertySelector,
                                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func cameraAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        // Element 0 is the main element.
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(0))
    }
}
