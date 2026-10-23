import SwiftUI
import XCTest
@testable import Cove

// MARK: - HTTP server

final class HTTPTests: XCTestCase {
    func testParsesCompleteRequest() {
        let raw = "POST /event?x=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nOrigin: chrome-extension://abc\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/event")
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertEqual(request.origin, "chrome-extension://abc")
    }

    func testWaitsForBody() {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\""
        guard case .incomplete = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("should wait for the rest of the body") }
    }

    func testAsksToContinue() {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n"
        guard case .needsContinue = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("should send 100 Continue") }
    }

    func testRejectsGarbage() {
        guard case .invalid = HTTPRequest.parse(Data("NOPE\r\n\r\n".utf8)) else { return XCTFail("should be invalid") }
    }

    func testOriginPolicy() {
        XCTAssertTrue(EventServer.isAllowed(origin: nil))            // curl, hooks
        XCTAssertTrue(EventServer.isAllowed(origin: "chrome-extension://abcdef"))
        XCTAssertFalse(EventServer.isAllowed(origin: "https://evil.example"))
        XCTAssertFalse(EventServer.isAllowed(origin: "http://localhost:3000"))
    }
}

// MARK: - Config

final class ConfigTests: XCTestCase {
    func testMissingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(CoveConfig.self, from: Data(#"{"port": 8000, "sounds": false}"#.utf8))
        XCTAssertEqual(config.port, 8000)
        XCTAssertFalse(config.sounds)
        XCTAssertEqual(config.approvals, "smart")
        XCTAssertTrue(config.buddy)
        XCTAssertTrue(config.screenshotsToShelf)
        XCTAssertTrue(config.shortcuts)
    }

    func testWrongTypesFallBackInsteadOfFailing() throws {
        let config = try JSONDecoder().decode(CoveConfig.self, from: Data(#"{"port": "nope", "countdownMinutes": 45}"#.utf8))
        XCTAssertEqual(config.port, 7777)
        XCTAssertEqual(config.countdownMinutes, 45)
    }

    func testRoundTrip() throws {
        var config = CoveConfig()
        config.hud = "off"
        config.highlightKeywords = ["robot"]
        let decoded = try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.hud, "off")
        XCTAssertEqual(decoded.highlightKeywords, ["robot"])
    }
}

// MARK: - Claude Code bridge

final class AgentBridgeTests: XCTestCase {
    func testDescribesBash() {
        let (action, preview) = AgentBridge.describePermission(tool: "Bash", input: ["command": "ls -la", "description": "List files"])
        XCTAssertEqual(action, "run a command")
        XCTAssertEqual(preview.lines.map(\.text), ["List files", "$ ls -la"])
    }

    func testDescribesEditAsDiff() {
        let (action, preview) = AgentBridge.describePermission(
            tool: "Edit", input: ["file_path": "/x/eval.py", "old_string": "a = 1", "new_string": "a = 2"]
        )
        XCTAssertEqual(action, "edit eval.py")
        XCTAssertEqual(preview.lines.map(\.style), [.removed, .added])
    }

    func testDescribesMCPTool() {
        let (action, _) = AgentBridge.describePermission(tool: "mcp__github__create_issue", input: ["title": "x"])
        XCTAssertEqual(action, "use create_issue (github)")
    }

    func testLongPreviewIsCapped() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let (_, preview) = AgentBridge.describePermission(tool: "Write", input: ["file_path": "/tmp/new.txt", "content": long])
        XCTAssertLessThanOrEqual(preview.lines.count, 9)
    }

    func testPermissionResponses() throws {
        XCTAssertEqual(AgentBridge.permissionResponse(.ask, suggestions: nil), "")

        let allow = try decision(AgentBridge.permissionResponse(.allow, suggestions: nil))
        XCTAssertEqual(allow["behavior"] as? String, "allow")
        XCTAssertNil(allow["updatedPermissions"])

        let always = try decision(AgentBridge.permissionResponse(.allowAlways, suggestions: [["type": "addRules"]]))
        XCTAssertEqual(always["behavior"] as? String, "allow")
        XCTAssertNotNil(always["updatedPermissions"])

        let deny = try decision(AgentBridge.permissionResponse(.deny, suggestions: nil))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
    }

    private func decision(_ json: String) throws -> [String: Any] {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let output = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    func testTranscriptReaderFindsLastAssistantText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cove-transcript-\(UUID()).jsonl")
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"All 14 tests pass."}]}}"#,
            #"{"type":"user","message":{"content":"thanks"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(TranscriptReader.lastAssistantText(path: url.path), "All 14 tests pass.")
    }

    func testTranscriptUsageCountsEachMessageOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cove-usage-\(UUID()).jsonl")
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":5}}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":50}}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[],"usage":{"input_tokens":20,"cache_creation_input_tokens":200,"output_tokens":100}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = try XCTUnwrap(TranscriptReader.usage(path: url.path))
        XCTAssertEqual(usage, TokenUsage(input: 1230, output: 150))
        XCTAssertEqual(usage.short, "1k tokens")
        XCTAssertEqual(TokenUsage(input: 800, output: 40).short, "840 tokens")
        XCTAssertEqual(TokenUsage(input: 1_250_000, output: 50_000).short, "1.3M tokens")
    }
}

// MARK: - Island state

@MainActor
final class IslandModelTests: XCTestCase {
    private func makeModel() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.buddyAlwaysVisible = false
        return IslandModel(config: config)
    }

    func testIdleByDefault() {
        let model = makeModel()
        XCTAssertNil(model.compactItem)
    }

    func testBuddyNapsWhenAlwaysVisible() {
        let model = makeModel()
        model.config.buddyAlwaysVisible = true
        XCTAssertEqual(model.compactItem, .napping)
    }

    func testAgentLifecycle() {
        let model = makeModel()
        // The richer AI presentation is covered by AIWidgetTests; this checks the legacy option.
        model.config.aiWorkInNotch = false
        model.agentStarted(id: "claude:1", agent: .claude, title: "proj", detail: "Thinking", ownerApp: nil)
        XCTAssertEqual(model.compactItem, .running(count: 1, agent: .claude))

        model.agentAttention(id: "claude:1", agent: .claude, title: "proj", message: "Needs permission")
        XCTAssertEqual(model.compactItem, .attention(.claude))
        XCTAssertEqual(model.banner?.style, .attention)
        XCTAssertTrue(model.banner?.sticky ?? false)

        model.agentFinished(id: "claude:1", agent: .claude, title: "proj", summary: "Done!")
        XCTAssertEqual(model.activity("claude:1")?.state, .done)
        XCTAssertEqual(model.compactItem, .finished(count: 1, agent: .claude, failed: false))
    }

    func testGenericEventsFromTheAPI() {
        let model = makeModel()
        model.ingest(CoveEvent(id: "sweep", title: "HDC sweep", body: "4/10", kind: "running", progress: 0.4))
        XCTAssertEqual(model.activity("sweep")?.progress, 0.4)
        model.ingest(CoveEvent(id: "sweep", title: "HDC sweep", body: "best 94.7%", kind: "done"))
        XCTAssertEqual(model.activity("sweep")?.state, .done)
        model.ingest(CoveEvent(id: "sweep", title: "HDC sweep", kind: "clear"))
        XCTAssertNil(model.activity("sweep"))
    }

    func testBrowserExtensionEvents() {
        let model = makeModel()
        model.ingest(CoveEvent(id: "web:chatgpt:abc", title: "Sweep plan", body: "…", kind: "running", source: "chatgpt"))
        XCTAssertEqual(model.activity("web:chatgpt:abc")?.agent, .chatgpt)
        XCTAssertNotNil(model.lastExtensionEvent)
        model.ingest(CoveEvent(id: "web:claude:xyz", title: "Notes", kind: "running", source: "claude-web"))
        XCTAssertEqual(model.activity("web:claude:xyz")?.agent, .claude)
    }

    func testApprovalTakesOverAndResolves() {
        let model = makeModel()
        var answer: ApprovalDecision?
        let (action, preview) = AgentBridge.describePermission(tool: "Bash", input: ["command": "ls"])
        let request = ApprovalRequest(sessionID: "claude:1", project: "p", tool: "Bash", action: action, preview: preview,
                                      canAlwaysAllow: false, expiresAt: Date().addingTimeInterval(60))
        model.requestApproval(request) { answer = $0 }
        XCTAssertEqual(model.presentation, .approval)
        model.resolveApproval(request.id, .allow)
        XCTAssertEqual(answer, .allow)
        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertNotEqual(model.presentation, .approval)
    }

    func testBannersQueueAndAttentionJumpsAhead() {
        let model = makeModel()
        model.show(Banner(title: "one", body: "", style: .info, icon: .symbol("bell", .white)))
        model.show(Banner(title: "two", body: "", style: .info, icon: .symbol("bell", .white)))
        model.show(Banner(title: "urgent", body: "", style: .attention, icon: .symbol("bell", .white)))
        XCTAssertEqual(model.banner?.title, "one")
        model.dismissBanner()
        XCTAssertEqual(model.banner?.title, "urgent")
        model.dismissBanner()
        XCTAssertEqual(model.banner?.title, "two")
    }

    func testRelativeTimes() {
        let now = Date()
        XCTAssertEqual(IslandModel.relative(now.addingTimeInterval(12 * 60), from: now), "in 12 min")
        XCTAssertEqual(IslandModel.relative(now.addingTimeInterval(3 * 3600), from: now), "in 3h")
        XCTAssertEqual(IslandModel.relative(now.addingTimeInterval(-30 * 60), from: now), "30m ago")
    }

    func testTimeLeftAndLookaheadWording() {
        XCTAssertEqual(formatTimeLeft(minutes: 50), "50 min left")
        XCTAssertEqual(formatTimeLeft(minutes: 60), "1h left")
        XCTAssertEqual(formatTimeLeft(minutes: 80), "1h 20m left")
        XCTAssertEqual(formatTimeLeft(minutes: -3), "0 min left")
        XCTAssertEqual(PlaybackBar.clock(754), "12:34")
        XCTAssertEqual(PlaybackBar.clock(4500), "1:15:00")

        var config = CoveConfig()
        XCTAssertEqual(config.dueLookaheadPhrase, "week")
        config.dueLookaheadDays = 14
        XCTAssertEqual(config.dueLookaheadPhrase, "two weeks")
        config.dueLookaheadDays = 3
        XCTAssertEqual(config.dueLookaheadPhrase, "3 days")
    }
}

// MARK: - Calendar

final class ScheduleTests: XCTestCase {
    private func event(_ title: String, start: TimeInterval, minutes: Double) -> CalEvent {
        let s = Date().addingTimeInterval(start)
        return CalEvent(id: title, title: title, start: s, end: s.addingTimeInterval(minutes * 60),
                        location: nil, calendar: "Classes", color: .blue, joinURL: nil)
    }

    func testCurrentAndUpcoming() {
        let schedule = Schedule(events: [
            event("Lecture", start: -20 * 60, minutes: 75),
            event("Lab", start: 90 * 60, minutes: 120),
        ])
        XCTAssertEqual(schedule.currentEvent()?.title, "Lecture")
        XCTAssertEqual(schedule.upcomingEvent()?.title, "Lab")
    }
}

// MARK: - Screenshots

final class ScreenshotTests: XCTestCase {
    func testScreenshotNames() {
        XCTAssertTrue(ScreenshotWatcher.looksLikeScreenshotName("Screenshot 2026-10-12 at 8.09.12\u{202F}PM.png"))
        XCTAssertTrue(ScreenshotWatcher.looksLikeScreenshotName("Screen Shot 2020-01-01 at 1.00.00 PM.png"))
        XCTAssertTrue(ScreenshotWatcher.looksLikeScreenshotName("CleanShot 2026-10-12.png"))
        XCTAssertFalse(ScreenshotWatcher.looksLikeScreenshotName("resume.pdf"))
    }

    func testOnlyImagesCount() {
        XCTAssertFalse(ScreenshotWatcher.isScreenshot(URL(fileURLWithPath: "/tmp/Screenshot notes.txt")))
    }
}

// MARK: - Notifications

final class NotificationDecodeTests: XCTestCase {
    func testDecodesUsernotedRecord() throws {
        let record: [String: Any] = ["app": "com.tinyspeck.slackmacgap", "req": ["titl": "Dr. Imam", "subt": "#lab", "body": "Meeting moved to 3"]]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let item = try XCTUnwrap(NotificationMirror.decode(data, appID: "fallback"))
        XCTAssertEqual(item.appID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(item.title, "Dr. Imam")
        XCTAssertEqual(item.body, "Meeting moved to 3")
    }
}

@MainActor
final class ShelfBannerTests: XCTestCase {
    func testScreenshotBannersCoalesceAndStayOutOfHistory() {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.screenshotBanners = true
        let model = IslandModel(config: config)
        model.clearShelf()
        let a = URL(fileURLWithPath: "/tmp/Screenshot A.png"), b = URL(fileURLWithPath: "/tmp/Screenshot B.png")
        model.addScreenshots([a])
        model.addScreenshots([b])
        XCTAssertEqual(model.banner?.icon, .file(b))
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.shelf.prefix(2), [b, a])
        model.clearShelf()
    }
}

final class CalendarClassifierTests: XCTestCase {
    private let now = Date()
    private func kind(_ title: String, _ calendar: String, minutes: Double, allDay: Bool = false) -> CalendarClassifier.Kind {
        CalendarClassifier.classify(title: title, calendarTitle: calendar, start: now,
                                    end: now.addingTimeInterval(minutes * 60), isAllDay: allDay, extraLMS: [])
    }

    func testClassesInD2LFeedStayClasses() {
        XCTAssertEqual(kind("CPE 3000 Lecture", "D2L", minutes: 75), .event)
        XCTAssertEqual(kind("CPE 3000 - Section 01", "KSU D2L Calendar", minutes: 50), .event)
    }

    func testAssignmentsInD2LFeedAreDue() {
        XCTAssertEqual(kind("Lab 5 Report - Due", "D2L", minutes: 0), .due)
        XCTAssertEqual(kind("Homework 7", "D2L", minutes: 0), .due)
        XCTAssertEqual(kind("Quiz 3 - Availability Ends", "D2L", minutes: 0), .due)
        XCTAssertEqual(kind("Project proposal due", "Brightspace", minutes: 30), .due)
        XCTAssertEqual(kind("Final paper", "Canvas", minutes: 0, allDay: true), .due)
    }

    func testRegularCalendars() {
        XCTAssertEqual(kind("Swarm lab meeting", "jvthomas702@gmail.com", minutes: 60), .event)
        XCTAssertEqual(kind("Columbus Day", "jvthomas702@gmail.com", minutes: 1440, allDay: true), .skip)
        XCTAssertEqual(kind("Scholarship deadline", "Personal", minutes: 0), .due)
        XCTAssertEqual(kind("Call with Dr. Imam", "Work", minutes: 0), .event)
    }

    func testCleanDueTitle() {
        XCTAssertEqual(CalendarMonitor.cleanDueTitle("Lab 5 Report - Due"), "Lab 5 Report")
        XCTAssertEqual(CalendarMonitor.cleanDueTitle("Quiz 3 - Availability Ends"), "Quiz 3")
        XCTAssertEqual(CalendarMonitor.cleanDueTitle("Homework 7"), "Homework 7")
    }
}

// MARK: - Clipboard history

final class ClipboardTests: XCTestCase {
    func testSkipsSecretsFilesAndBlankText() {
        let plain: Set<String> = ["public.utf8-plain-text"]
        XCTAssertEqual(ClipboardMonitor.clip(from: "hello", types: plain), "hello")
        XCTAssertNil(ClipboardMonitor.clip(from: "hunter2", types: plain.union(["org.nspasteboard.ConcealedType"])))
        XCTAssertNil(ClipboardMonitor.clip(from: "/tmp/a.png", types: plain.union(["public.file-url"])))
        XCTAssertNil(ClipboardMonitor.clip(from: "  \n", types: plain))
        XCTAssertNil(ClipboardMonitor.clip(from: nil, types: plain))
    }

    @MainActor
    func testClipsAreNewestFirstAndDeduplicated() {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        let model = IslandModel(config: config)
        model.addClip("a")
        model.addClip("b")
        model.addClip("a")
        XCTAssertEqual(model.clips, ["a", "b"])
        for i in 0..<20 { model.addClip("\(i)") }
        XCTAssertEqual(model.clips.count, 12)
        XCTAssertEqual(model.clips.first, "19")
    }
}

// MARK: - GitHub Actions

final class GitHubActionsTests: XCTestCase {
    private let sample = #"""
    {"total_count": 3, "workflow_runs": [
      {"id": 1, "name": "build", "head_branch": "main", "status": "in_progress", "conclusion": null,
       "html_url": "https://github.com/me/app/actions/runs/1", "created_at": "2026-10-17T00:53:23Z",
       "actor": {"login": "me"}, "head_commit": {"message": "Fix the thing\n\nLonger body"}},
      {"id": 2, "name": "build", "head_branch": "feature", "status": "completed", "conclusion": "failure",
       "html_url": "https://github.com/me/app/actions/runs/2", "created_at": "2026-10-17T00:40:00Z",
       "actor": {"login": "me"}, "head_commit": {"message": "WIP"}},
      {"id": 3, "name": "deploy", "head_branch": "main", "status": "completed", "conclusion": "cancelled",
       "html_url": "https://github.com/me/app/actions/runs/3", "created_at": "2026-10-17T00:30:00Z",
       "actor": {"login": "bot"}}
    ]}
    """#

    func testParsesRuns() {
        let runs = CIRun.parse(Data(sample.utf8), repo: "me/app")
        XCTAssertEqual(runs.map(\.state), [.running, .failed, .cancelled])
        XCTAssertEqual(runs[0].commit, "Fix the thing")
        XCTAssertEqual(runs[0].repoName, "app")
        XCTAssertEqual(runs[1].branch, "feature")
        XCTAssertEqual(runs[2].actor, "bot")
        XCTAssertEqual(runs[2].commit, "")
    }

    @MainActor
    func testRunShowsAsActivityThenFinishes() throws {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        let model = IslandModel(config: config)
        let run = try XCTUnwrap(CIRun.parse(Data(sample.utf8), repo: "me/app").first)
        model.ciRun(run)
        XCTAssertEqual(model.activity("ci:1")?.state, .running)
        XCTAssertEqual(model.activity("ci:1")?.openURL, run.url)
        model.ciRun(CIRun(id: 1, repo: "me/app", workflow: "build", branch: "main", commit: "", actor: "me",
                          state: .failed, url: run.url, createdAt: run.createdAt))
        XCTAssertEqual(model.activity("ci:1")?.state, .failed)
    }
}

// MARK: - Bluetooth battery

final class BluetoothBatteryTests: XCTestCase {
    private let sample = #"""
    {"SPBluetoothDataType": [{
      "controller_properties": {"controller_state": "attrib_on"},
      "device_connected": [
        {"AirPods Pro": {"device_address": "AA", "device_batteryLevelLeft": "80%", "device_batteryLevelRight": "62%",
                         "device_batteryLevelCase": "45%", "device_minorType": "Headphones"}},
        {"Magic Keyboard": {"device_address": "BB", "device_batteryLevelMain": "64%"}},
        {"Speaker": {"device_address": "CC"}}
      ],
      "device_not_connected": [{"Old AirPods": {"device_address": "DD"}}]
    }]}
    """#

    func testParsesConnectedDevicesWithBatteries() {
        let devices = BluetoothBattery.parse(Data(sample.utf8))
        XCTAssertEqual(devices.map(\.name), ["AirPods Pro", "Magic Keyboard"])
        XCTAssertEqual(devices[0].lowest, 62)
        XCTAssertEqual(devices[0].summary, "L 80% · R 62% · Case 45%")
        XCTAssertEqual(devices[0].symbol, "airpodspro")
        XCTAssertEqual(devices[1].summary, "64%")
    }

    @MainActor
    func testFirstReadingIsQuietThenConnectAndLowShowBanners() {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.buddyAlwaysVisible = false
        let model = IslandModel(config: config)
        model.setBluetooth([])
        XCTAssertNil(model.banner)
        model.setBluetooth([BluetoothBattery(name: "AirPods", left: 50, right: 50)])
        XCTAssertEqual(model.banner?.title, "AirPods connected")
        XCTAssertEqual(model.banner?.body, "50%")
    }
}

final class SettingsPaneTests: XCTestCase {
    func testSidebarShowsEveryPaneOnce() {
        let listed = SettingsPane.island + SettingsPane.system
        XCTAssertEqual(listed.count, Set(listed).count)
        XCTAssertEqual(Set(listed), Set(SettingsPane.allCases))
    }
}
