import XCTest
@testable import Cove

final class AccountLimitsTests: XCTestCase {
    func testCodexParsesAllReportedBucketsWithoutCountingLegacyBucketTwice() {
        let main: [String: Any] = ["primary": ["usedPercent": 23.5, "windowDurationMins": 300, "resetsAt": 2_000_000_000],
                                   "secondary": ["usedPercent": 60, "windowDurationMins": 10080]]
        let windows = QuotaParser.codex(["rateLimits": main, "rateLimitsByLimitId": ["codex": main,
            "review": ["limitName": "Code review", "primary": ["usedPercent": 10, "windowDurationMins": 10080]]]])
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.title, "5h")
        XCTAssertEqual(windows.first?.remainingPercent, 76.5)
        XCTAssertEqual(windows[1].title, "7d")
        XCTAssertEqual(windows.last?.title, "Code review · 7d")
        XCTAssertEqual(QuotaParser.codex(["rateLimits": main]).count, 2)
        XCTAssertTrue(QuotaParser.codex([:]).isEmpty)
    }

    func testClaudeDoesNotTreatAbsentNullOrInvalidWindowsAsUnusedQuota() throws {
        XCTAssertNil(QuotaParser.claude([:]))
        XCTAssertEqual(QuotaParser.claude(["rate_limits": [:]]), [])
        let windows = try XCTUnwrap(QuotaParser.claude(["rate_limits": [
            "five_hour": ["used_percentage": 100, "resets_at": 1000],
            "seven_day": NSNull(), "spend_limit": ["used_percentage": true]]]))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].remainingPercent, 0)
        XCTAssertTrue(windows[0].expired(at: Date(timeIntervalSince1970: 1001)))
        XCTAssertFalse(windows[0].expired(at: Date(timeIntervalSince1970: 999)))
        XCTAssertNil(QuotaWindow.parse(["used": -1], id: "x", title: "x", percentKey: "used", resetKey: "reset"))
    }

    func testQuotaReaderUsesOnlyInitializeAndAccountReadAndKeepsStdinOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-quota-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        try Data("""
        #!/usr/bin/env python3
        import json, sys
        assert sys.argv[1:] == ['app-server']
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize'
        print(json.dumps({'id': 0, 'result': {}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'
        print(json.dumps({'id': 1, 'result': {'rateLimits': {'primary': {'usedPercent': 35, 'windowDurationMins': 300}}}}), flush=True)
        sys.stdin.read()
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let windows = try await CodexQuotaReader.read(executable: script, timeout: 5)
        XCTAssertEqual(windows.first?.remainingPercent, 65)
        XCTAssertEqual(windows.first?.title, "5h")
    }

    func testQuotaReaderTimesOutWhenCLIStopsAnswering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-quota-timeout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        try Data("#!/usr/bin/env python3\nimport time\ntime.sleep(5)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = Date()
        do { _ = try await CodexQuotaReader.read(executable: script, timeout: 0.2); XCTFail("Expected unavailable limits") }
        catch { XCTAssertLessThan(Date().timeIntervalSince(start), 3) }
    }

    func testClaudeSetupWrapsAndRestoresExistingStatusLineAndPreservesOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-quota-setup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json"), executable = root.appendingPathComponent("tools/cove-claude-usage")
        let bundled = root.appendingPathComponent("bundled")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "cat | jq '.model.display_name'", "padding": 2],
                                       "env": ["EXAMPLE": "kept"]]
        let originalData = try JSONSerialization.data(withJSONObject: original, options: .sortedKeys)
        try originalData.write(to: settingsURL)
        try ClaudeUsageSetup.set(installed: true, settingsURL: settingsURL, executable: executable, bundled: bundled, port: 8888)
        XCTAssertTrue(ClaudeUsageSetup.isInstalled(settingsURL: settingsURL, executable: executable))
        let first = try Data(contentsOf: settingsURL)
        try ClaudeUsageSetup.set(installed: true, settingsURL: settingsURL, executable: executable, bundled: bundled, port: 8888)
        XCTAssertEqual(try Data(contentsOf: settingsURL), first, "Connecting twice must not wrap itself")
        try ClaudeUsageSetup.set(installed: false, settingsURL: settingsURL, executable: executable)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: restored, options: .sortedKeys), originalData)
        XCTAssertFalse(ClaudeUsageSetup.isInstalled(settingsURL: settingsURL, executable: executable))
    }
}

@MainActor final class AccountLimitsModelTests: XCTestCase {
    func testRefreshClearsOldValuesOnFailureAndClaudeOmissionClearsUnavailableWindows() async throws {
        let limits = AccountLimits()
        limits.resolveExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
        limits.readCodex = { _ in [QuotaWindow(id: "test", title: "5h", usedPercent: 30, resetsAt: nil)] }
        await limits.refresh()
        XCTAssertEqual(limits.codex.first?.remainingPercent, 70)
        limits.readCodex = { _ in throw URLError(.notConnectedToInternet) }
        await limits.refresh()
        XCTAssertTrue(limits.codex.isEmpty)
        XCTAssertNil(limits.codexUpdatedAt)
        XCTAssertFalse(limits.refreshing)
        XCTAssertTrue(limits.receiveClaude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8)))
        XCTAssertEqual(limits.claude.first?.remainingPercent, 100)
        XCTAssertFalse(limits.receiveClaude(Data("{}".utf8)))
        XCTAssertTrue(limits.receiveClaude(Data(#"{"rate_limits":{}}"#.utf8)))
        XCTAssertTrue(limits.claude.isEmpty)
    }
}
