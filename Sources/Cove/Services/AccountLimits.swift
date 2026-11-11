import Foundation
import Darwin

struct QuotaWindow: Identifiable, Equatable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    func expired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    static func parse(_ object: [String: Any], id: String, title: String, percentKey: String, resetKey: String) -> QuotaWindow? {
        guard let number = object[percentKey] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        let reset = (object[resetKey] as? NSNumber).flatMap { value -> Date? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return QuotaWindow(id: id, title: title, usedPercent: number.doubleValue, resetsAt: reset)
    }
}

enum QuotaParser {
    static func codex(_ result: [String: Any]) -> [QuotaWindow] {
        let buckets: [(String, [String: Any])]
        if let multiple = result["rateLimitsByLimitId"] as? [String: [String: Any]], !multiple.isEmpty {
            buckets = multiple.sorted { $0.key < $1.key }
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [(single["limitId"] as? String ?? "codex", single)]
        } else { return [] }
        return buckets.flatMap { id, bucket in
            ["primary", "secondary"].compactMap { key -> QuotaWindow? in
                guard let window = bucket[key] as? [String: Any] else { return nil }
                let minutes = (window["windowDurationMins"] as? NSNumber).flatMap { value -> Int? in
                    guard CFGetTypeID(value) != CFBooleanGetTypeID(), let minutes = Int(exactly: value.doubleValue), minutes > 0 else { return nil }
                    return minutes
                }
                let period = minutes.map { $0 % 1440 == 0 ? "\($0 / 1440)d" : $0 % 60 == 0 ? "\($0 / 60)h" : "\($0)m" } ?? key.capitalized
                let name = bucket["limitName"] as? String ?? (id == "codex" ? "" : id)
                return QuotaWindow.parse(window, id: "\(id).\(key)", title: [name, period].filter { !$0.isEmpty }.joined(separator: " · "),
                                         percentKey: "usedPercent", resetKey: "resetsAt")
            }
        }
    }

    static func claude(_ payload: [String: Any]) -> [QuotaWindow]? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        return [("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "Spend limit")].compactMap { key, title in
            guard let window = limits[key] as? [String: Any] else { return nil }
            return QuotaWindow.parse(window, id: key, title: title, percentKey: "used_percentage", resetKey: "resets_at")
        }
    }
}

/// A short-lived stdio connection used only for account limits. It never loads a thread or starts a turn.
enum CodexQuotaReader {
    static func read(executable: URL, timeout: TimeInterval = 15) async throws -> [QuotaWindow] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try readSync(executable: executable, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func readSync(executable: URL, timeout: TimeInterval) throws -> [QuotaWindow] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = ClaudeCLI.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "cove_usage", "version": "1.0"]]])
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data(), bytes = [UInt8](repeating: 0, count: 16384)
        let fd = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { break }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 2_000_000 else { break }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                if object["error"] != nil { throw AgentLauncher.LaunchError.message("Codex couldn't report limits. Check its sign-in or update the CLI.") }
                if id == 0 {
                    try send(["method": "initialized"])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1, let result = object["result"] as? [String: Any] {
                    return QuotaParser.codex(result)
                }
            }
        }
        throw AgentLauncher.LaunchError.message("Codex limits are unavailable. Refresh to retry.")
    }
}

@MainActor final class AccountLimits: ObservableObject {
    @Published private(set) var codex: [QuotaWindow] = []
    @Published private(set) var claude: [QuotaWindow] = []
    @Published private(set) var codexUpdatedAt: Date?
    @Published private(set) var claudeUpdatedAt: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var codexStatus = "Refresh to read Codex account limits."
    @Published private(set) var claudeStatus = "Connect Claude limits, then send a message in Claude Code."
    var resolveExecutable: () -> URL? = { AgentLauncher.findExecutable(.codex) }
    var readCodex: (URL) async throws -> [QuotaWindow] = { try await CodexQuotaReader.read(executable: $0) }

    func refresh() async {
        guard !refreshing else { return }
        guard let executable = resolveExecutable() else { codex = []; codexUpdatedAt = nil; codexStatus = "Install Codex CLI and sign in with ChatGPT to see limits."; return }
        refreshing = true
        defer { refreshing = false }
        do {
            codex = try await readCodex(executable)
            codexUpdatedAt = Date()
            codexStatus = codex.isEmpty ? "This account did not report quota windows. Check Codex sign-in and plan." : "Reported by Codex"
        } catch {
            codex = []; codexUpdatedAt = nil
            codexStatus = "Couldn't read limits. Check Codex sign-in, then refresh."
        }
    }

    @discardableResult
    func receiveClaude(_ data: Data, now: Date = Date()) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = QuotaParser.claude(payload) else { return false }
        claude = windows; claudeUpdatedAt = now
        claudeStatus = windows.isEmpty ? "Claude hasn't reported active quota windows for this account." : "Reported by Claude Code"
        return true
    }
}
