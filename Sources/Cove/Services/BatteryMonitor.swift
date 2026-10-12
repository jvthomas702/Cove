import Foundation
import IOKit.ps

/// Event-driven battery state (no polling): IOKit calls back whenever the power source changes.
final class BatteryMonitor {
    var onChange: (@MainActor (BatteryState?) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.publish()
        }
        if let unmanaged = IOPSNotificationCreateRunLoopSource(callback, context) {
            let runLoopSource = unmanaged.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            source = runLoopSource
        }
        publish()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func publish() {
        let state = Self.read()
        Task { @MainActor [weak self] in self?.onChange?(state) }
    }

    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let listRef = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        for source in listRef as Array {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let powerState = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            return BatteryState(percent: percent, pluggedIn: powerState == kIOPSACPowerValue, charging: charging)
        }
        return nil
    }
}
