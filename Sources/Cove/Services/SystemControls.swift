import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

// MARK: - Volume (CoreAudio)

/// Reads and sets the default output device's volume, and reports changes from any source.
final class VolumeController {
    var onChange: (@MainActor (Float, Bool) -> Void)?

    private var device: AudioDeviceID = 0
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var ready = false

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static let volumeAddress = VolumeController.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    private static let muteAddress = VolumeController.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)

    func start() {
        // Follow the default output device (speakers → AirPods → HDMI…).
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main, block) == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), defaultAddress, block))
        }
        attach()
        // Ignore the burst of callbacks while devices settle at launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.ready = true }
    }

    func stop() {
        for entry in listeners {
            var target = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &target, .main, entry.2)
        }
        listeners.removeAll()
    }

    private func attach() {
        // Drop listeners on the old device, keep the system-object one.
        listeners.removeAll { entry in
            guard entry.0 != AudioObjectID(kAudioObjectSystemObject) else { return false }
            var target = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &target, .main, entry.2)
            return true
        }
        guard let id = Self.defaultOutputDevice() else { return }
        device = id
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
        var candidates = [Self.volumeAddress, Self.muteAddress,
                          Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain),
                          Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1),
                          Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2)]
        for index in candidates.indices {
            if AudioObjectAddPropertyListenerBlock(id, &candidates[index], .main, block) == noErr {
                listeners.append((id, candidates[index], block))
            }
        }
    }

    private func report() {
        guard ready, let volume = volume else { return }
        let muted = isMuted
        let callback = onChange
        Task { @MainActor in callback?(volume, muted) }
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var target = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &target, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    var volume: Float? {
        var target = Self.volumeAddress
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &target),
              AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    var isMuted: Bool {
        var target = Self.muteAddress
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &target),
              AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// False when the device has no software volume (e.g. some HDMI outputs) — let macOS handle the key then.
    var canSetVolume: Bool {
        var target = Self.volumeAddress
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &target)
            && AudioObjectIsPropertySettable(device, &target, &settable) == noErr
            && settable.boolValue
    }

    @discardableResult
    func setVolume(_ newValue: Float) -> Bool {
        var target = Self.volumeAddress
        var value = Float32(min(max(newValue, 0), 1))
        let ok = AudioObjectSetPropertyData(device, &target, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        if ok && value > 0 && isMuted { setMuted(false) }
        return ok
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var target = Self.muteAddress
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &target, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

// MARK: - Brightness (DisplayServices, built-in display)

/// The built-in display's brightness through Apple's private DisplayServices framework
/// (loaded at runtime; if it isn't there, Cove leaves the brightness keys to macOS).
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFunction: GetFunction? = {
        guard let library = DisplayBrightness.handle, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)
    }()
    private static let setFunction: SetFunction? = {
        guard let library = DisplayBrightness.handle, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetFunction.self)
    }()

    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool { getFunction != nil && setFunction != nil && builtInDisplay != nil }

    static var level: Float? {
        guard let getFunction, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setFunction, let display = builtInDisplay else { return false }
        return setFunction(display, min(max(value, 0), 1)) == 0
    }
}

// MARK: - Media keys (event tap)

/// Intercepts the volume and brightness keys so Cove can show its own HUD instead of the system one.
/// Needs Accessibility permission. Keys Cove can't handle are passed through to macOS untouched.
final class MediaKeyTap {
    enum Key: Int {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    /// Return true to swallow the key. Called on the main thread.
    var handler: (@MainActor (Key, _ isDown: Bool, _ isRepeat: Bool, _ fineStep: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: callback,
            userInfo: context
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let data = nsEvent.data1
        guard let key = Key(rawValue: (data & 0xFFFF_0000) >> 16) else { return Unmanaged.passUnretained(event) }
        let flags = data & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) == 1
        let modifiers = nsEvent.modifierFlags
        let fine = modifiers.contains(.option) && modifiers.contains(.shift)
        // The tap's run loop source is on the main run loop, so this is the main thread.
        let handled = MainActor.assumeIsolated { handler?(key, isDown, isRepeat, fine) ?? false }
        if handled { return nil }
        return Unmanaged.passUnretained(event)
    }
}
