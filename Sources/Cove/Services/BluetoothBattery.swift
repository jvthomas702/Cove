import Foundation

/// A connected Bluetooth device that reports its battery (AirPods, Beats, Magic Keyboard/Mouse/Trackpad).
struct BluetoothBattery: Equatable {
    var name: String
    /// Single-battery devices.
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// The lowest level among the parts you're wearing or using (the case doesn't count).
    var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    /// "L 80% · R 78% · Case 60%" or "64%".
    var summary: String {
        var parts: [String] = []
        if let main { parts.append("\(main)%") }
        if let left, let right, abs(left - right) <= 5 {
            parts.append("\(min(left, right))%")
        } else {
            if let left { parts.append("L \(left)%") }
            if let right { parts.append("R \(right)%") }
        }
        if let caseLevel { parts.append("Case \(caseLevel)%") }
        return parts.joined(separator: " · ")
    }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "headphones"
    }

    /// Connected devices with a battery level, from `system_profiler SPBluetoothDataType -json`.
    static func parse(_ data: Data) -> [BluetoothBattery] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        func level(_ value: Any?) -> Int? {
            guard let text = value as? String else { return nil }
            return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        var devices: [BluetoothBattery] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let device = BluetoothBattery(
                        name: name,
                        main: level(info["device_batteryLevelMain"]) ?? level(info["device_batteryLevel"]),
                        left: level(info["device_batteryLevelLeft"]),
                        right: level(info["device_batteryLevelRight"]),
                        caseLevel: level(info["device_batteryLevelCase"])
                    )
                    if device.lowest != nil || device.caseLevel != nil { devices.append(device) }
                }
            }
        }
        return devices.sorted { $0.name < $1.name }
    }
}

/// Polls Bluetooth accessories' battery levels. Uses `system_profiler`, which is slow-ish, so it runs
/// off the main thread every couple of minutes.
@MainActor
final class BluetoothBatteryMonitor {
    var onChange: (([BluetoothBattery]) -> Void)?

    private var timer: Timer?
    private var running = false

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !running else { return }
        running = true
        Task { [weak self] in
            let devices = await Self.read()
            guard let self else { return }
            self.running = false
            if let devices, self.timer != nil { self.onChange?(devices) }
        }
    }

    nonisolated static func read() async -> [BluetoothBattery]? {
        await Task.detached { () -> [BluetoothBattery]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? BluetoothBattery.parse(data) : nil
        }.value
    }
}
