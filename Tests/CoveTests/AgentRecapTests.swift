import XCTest
@testable import Cove

@MainActor final class AgentRecapTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func run(_ id: String, finished: String, duration: TimeInterval? = 60, files: Int? = nil, failed: Bool = false) -> RecapRun {
        let end = date(finished)
        return RecapRun(id: id, activityID: "claude:\(id)", agent: "claude", title: "Project \(id)", startedAt: end.addingTimeInterval(-(duration ?? 0)),
                        finishedAt: end, duration: duration, filesChanged: files, failed: failed, ownerApp: nil, openURL: nil)
    }

    private func temporaryStore() -> AgentRecapStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cove-recap-test-\(UUID())/AgentRecap.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return AgentRecapStore(url: url)
    }

    private func model(store: AgentRecapStore) -> IslandModel {
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        return IslandModel(config: config, recapStore: store)
    }

    // MARK: Aggregation

    func testRunsAreNewestFirstReplacedByIdAndSummed() {
        var recap = AgentRecap(day: date("2026-10-17T08:00:00Z"), calendar: calendar)
        recap.record(run("a", finished: "2026-10-17T09:00:00Z", duration: 120), calendar: calendar)
        recap.record(run("b", finished: "2026-10-17T11:00:00Z", duration: 30), calendar: calendar)
        recap.record(run("c", finished: "2026-10-17T10:00:00Z", duration: nil), calendar: calendar)
        XCTAssertEqual(recap.runs.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(recap.totalDuration, 150)

        recap.record(run("a", finished: "2026-10-17T09:00:00Z", duration: 120, failed: true), calendar: calendar)
        XCTAssertEqual(recap.runs.count, 3)
        XCTAssertEqual(recap.runs.first { $0.id == "a" }?.failed, true)
    }

    func testListIsCapped() {
        var recap = AgentRecap(day: date("2026-10-17T00:00:00Z"), calendar: calendar)
        for i in 0..<(AgentRecap.limit + 5) {
            recap.record(run("r\(i)", finished: "2026-10-17T12:00:00Z"), calendar: calendar)
        }
        XCTAssertEqual(recap.runs.count, AgentRecap.limit)
    }

    // MARK: Day rollover

    func testRollStartsAFreshDayOnlyAfterMidnight() {
        var recap = AgentRecap(day: date("2026-10-17T06:00:00Z"), calendar: calendar)
        recap.record(run("a", finished: "2026-10-17T09:00:00Z"), calendar: calendar)
        XCTAssertFalse(recap.roll(to: date("2026-10-17T23:59:59Z"), calendar: calendar))
        XCTAssertEqual(recap.runs.count, 1)
        XCTAssertTrue(recap.roll(to: date("2026-10-18T00:00:01Z"), calendar: calendar))
        XCTAssertTrue(recap.runs.isEmpty)
        XCTAssertEqual(recap.day, date("2026-10-18T00:00:00Z"))
    }

    func testRunFinishingOnANewDayReplacesYesterdayAndLateRunsAreIgnored() {
        var recap = AgentRecap(day: date("2026-10-17T06:00:00Z"), calendar: calendar)
        recap.record(run("old", finished: "2026-10-17T22:00:00Z"), calendar: calendar)
        recap.record(run("new", finished: "2026-10-18T00:10:00Z"), calendar: calendar)
        XCTAssertEqual(recap.runs.map(\.id), ["new"])
        recap.record(run("late", finished: "2026-10-17T23:00:00Z"), calendar: calendar)
        XCTAssertEqual(recap.runs.map(\.id), ["new"])
    }

    func testStoreKeepsTodayAcrossRestartsAndDropsEarlierDays() throws {
        let store = temporaryStore()
        var recap = AgentRecap(day: date("2026-10-17T06:00:00Z"), calendar: calendar)
        recap.record(run("a", finished: "2026-10-17T09:00:00Z", files: 3), calendar: calendar)
        store.save(recap)

        let sameDay = store.load(now: date("2026-10-17T20:00:00Z"), calendar: calendar)
        XCTAssertEqual(sameDay, recap)
        XCTAssertEqual(sameDay.runs.first?.filesChanged, 3)

        let nextDay = store.load(now: date("2026-10-18T07:00:00Z"), calendar: calendar)
        XCTAssertTrue(nextDay.runs.isEmpty)
        XCTAssertEqual(nextDay.day, date("2026-10-18T00:00:00Z"))

        try Data("not json".utf8).write(to: store.url)
        XCTAssertTrue(store.load(now: date("2026-10-17T20:00:00Z"), calendar: calendar).runs.isEmpty)
    }

    // MARK: Files changed

    func testOnlyEditingToolsCountAndEachFileOnce() {
        var tracker = FileChangeTracker()
        tracker.note(activityID: "s", tool: "Edit", input: ["file_path": "/p/a.swift"])
        tracker.note(activityID: "s", tool: "Write", input: ["file_path": "/p/b.swift"])
        tracker.note(activityID: "s", tool: "MultiEdit", input: ["file_path": "/p/a.swift"])
        tracker.note(activityID: "s", tool: "Read", input: ["file_path": "/p/c.swift"])
        tracker.note(activityID: "s", tool: "Bash", input: ["command": "touch d"])
        tracker.note(activityID: "other", tool: "Edit", input: ["file_path": "/p/z.swift"])
        XCTAssertEqual(tracker.take("s"), 2)
        XCTAssertNil(tracker.take("s"))
        tracker.reset("other")
        XCTAssertNil(tracker.take("other"))
    }

    // MARK: Wiring

    func testClaudeAndCodexRunsAreRecordedWithFilesAndPersisted() throws {
        let store = temporaryStore()
        let model = model(store: store), bridge = AgentBridge(model: model)
        func claude(_ payload: [String: Any]) throws {
            var body = payload; body["session_id"] = "s1"; body["cwd"] = "/Users/me/cove"
            bridge.handleClaude(try JSONSerialization.data(withJSONObject: body))
        }
        try claude(["hook_event_name": "UserPromptSubmit", "prompt": "Fix it"])
        try claude(["hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/Users/me/cove/a.swift"]])
        try claude(["hook_event_name": "PreToolUse", "tool_name": "Write", "tool_input": ["file_path": "/Users/me/cove/b.swift"]])
        try claude(["hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": ["file_path": "/Users/me/cove/b.swift"]])
        try claude(["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": ["file_path": "/Users/me/cove/c.swift"]])
        try claude(["hook_event_name": "Stop"])

        let first = try XCTUnwrap(model.recap.runs.first)
        XCTAssertEqual(first.kind, .claude)
        XCTAssertEqual(first.title, "cove")
        XCTAssertEqual(first.filesChanged, 2)
        XCTAssertNotNil(first.duration)
        XCTAssertFalse(first.failed)
        XCTAssertTrue(model.showsRecap)

        bridge.handleCodex(try JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete", "thread-id": "t1", "cwd": "/Users/me/app", "last-assistant-message": "Done"]))
        model.ingest(CoveEvent(id: "web:chatgpt:1", title: "Reply", body: "Done", kind: "done", source: "chatgpt", silent: true))
        XCTAssertEqual(Set(model.recap.runs.map(\.agent)), ["claude", "codex"])
        XCTAssertNil(model.recap.runs.first { $0.kind == .codex }?.filesChanged)
        XCTAssertNil(model.recap.runs.first { $0.kind == .codex }?.duration)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.runs.map(\.id), model.recap.runs.map(\.id))
    }

    func testFailureRightAfterDoneReplacesTheRun() {
        let model = model(store: temporaryStore())
        model.agentStarted(id: "claude:s", agent: .claude, title: "Project", detail: "Working", ownerApp: nil)
        model.noteToolUse(id: "claude:s", tool: "Edit", input: ["file_path": "/p/a"])
        model.agentFinished(id: "claude:s", agent: .claude, title: "Project", summary: nil)
        model.agentFinished(id: "claude:s", agent: .claude, title: "Project", summary: nil, failed: true)
        XCTAssertEqual(model.recap.runs.count, 1)
        XCTAssertEqual(model.recap.runs.first?.failed, true)
        XCTAssertEqual(model.recap.runs.first?.filesChanged, 1)
        XCTAssertNotNil(model.recap.runs.first?.duration)
    }

    func testTurningTheRecapOffStopsRecordingAndHidesIt() {
        let model = model(store: temporaryStore())
        model.agentFinished(id: "claude:a", agent: .claude, title: "Project", summary: nil)
        XCTAssertTrue(model.showsRecap)
        model.config.agentRecap = false
        XCTAssertFalse(model.showsRecap)
        model.agentFinished(id: "codex:b", agent: .codex, title: "Other", summary: nil)
        XCTAssertEqual(model.recap.runs.count, 1)
        model.tab = .ai
        model.config.agentRecap = true
        let withRecap = model.size(for: .expanded)
        model.config.agentRecap = false
        XCTAssertEqual(withRecap.height - model.size(for: .expanded).height, IslandModel.recapHeight + 10)
    }
}
