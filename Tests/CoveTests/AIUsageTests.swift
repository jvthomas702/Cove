import XCTest
@testable import Cove

final class AIUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_794_398_400)

    private func activity(_ id: String, agent: AgentKind = .claude, owner: String? = nil, tokens: TokenUsage? = nil) -> Activity {
        Activity(id: id, agent: agent, title: "Example", detail: "", state: .running, startedAt: now, updatedAt: now, ownerApp: owner, tokens: tokens)
    }

    func testSourcesDistinguishDesktopCodexFromCLIAndGroupBrowserWithCloud() {
        XCTAssertEqual(activity("cloud:owner/repo:1").usageSource, .cloud)
        XCTAssertEqual(activity("web:claude:1").usageSource, .cloud)
        XCTAssertEqual(activity("desktop:chatgpt:1", agent: .chatgpt).usageSource, .desktop)
        XCTAssertEqual(activity("codex:1", agent: .codex, owner: "com.openai.codex").usageSource, .desktop)
        XCTAssertEqual(activity("codex:2", agent: .codex, owner: "com.apple.Terminal").usageSource, .terminal)
        XCTAssertEqual(activity("claude:1").usageSource, .terminal)
    }

    func testRepeatedSessionTotalsReplaceRatherThanAddAndUnknownIsNotZero() {
        var usage = AIUsage(now: now, calendar: calendar)
        let a = activity("claude:1", tokens: TokenUsage(input: 100, output: 20))
        XCTAssertTrue(usage.record(a, now: now, calendar: calendar))
        XCTAssertFalse(usage.record(a, now: now, calendar: calendar))
        usage.record(activity("claude:1", tokens: TokenUsage(input: 140, output: 30)), now: now, calendar: calendar)
        usage.record(activity("codex:2", agent: .codex), now: now, calendar: calendar)
        usage.record(activity("command", agent: .command), now: now, calendar: calendar)
        let summary = usage.summary(for: .terminal)
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.reportingSessions, 1)
        XCTAssertEqual(summary.tokens, TokenUsage(input: 140, output: 30))
        XCTAssertEqual(summary.tokenLabel, "170 tokens reported")
        usage.record(activity("desktop:chatgpt:1", agent: .chatgpt), now: now, calendar: calendar)
        XCTAssertNil(usage.summary(for: .desktop).tokens)
        XCTAssertEqual(usage.summary(for: .desktop).tokenLabel, "Tokens unavailable")
        XCTAssertEqual(usage.summary(for: .cloud).tokenLabel, "No usage observed")
        usage.record(activity("claude:1"), now: now, calendar: calendar)
        XCTAssertEqual(usage.summary(for: .terminal).tokens?.total, 170, "A hook without counts keeps the last report")
    }

    func testSourceCorrectionMovesOneSessionAndRolloverStartsFresh() {
        var usage = AIUsage(now: now, calendar: calendar)
        usage.record(activity("codex:1", agent: .codex), now: now, calendar: calendar)
        usage.record(activity("codex:1", agent: .codex, owner: "com.openai.codex"), now: now, calendar: calendar)
        XCTAssertEqual(usage.summary(for: .terminal).sessions, 0)
        XCTAssertEqual(usage.summary(for: .desktop).sessions, 1)
        XCTAssertFalse(usage.roll(to: now, calendar: calendar))
        XCTAssertTrue(usage.roll(to: now.addingTimeInterval(86400), calendar: calendar))
        XCTAssertTrue(usage.sessions.isEmpty)
    }

    func testUsageSurvivesRestartAndDropsPreviousDayOrCorruptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-usage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(url: root.appendingPathComponent("usage.json"))
        var usage = AIUsage(now: now, calendar: calendar)
        usage.record(activity("claude:1", tokens: TokenUsage(input: 42, output: 10)), now: now, calendar: calendar)
        store.save(usage)
        XCTAssertEqual(store.load(now: now, calendar: calendar), usage)
        XCTAssertTrue(store.load(now: now.addingTimeInterval(86400), calendar: calendar).sessions.isEmpty)
        try Data("invalid".utf8).write(to: store.url)
        XCTAssertTrue(store.load(now: now, calendar: calendar).sessions.isEmpty)
    }
}

@MainActor final class AIUsageModelTests: XCTestCase {
    func testDesktopRuntimeReclassifiesTheSameCodexSessionWithoutDoubleCounting() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-usage-codex-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        let model = IslandModel(config: config, recapStore: AgentRecapStore(url: root.appendingPathComponent("recap.json")),
                                usageStore: AIUsageStore(url: root.appendingPathComponent("usage.json")))
        let chat = CodexChat(id: UUID().uuidString, title: "Cove", folder: "/tmp/Cove")
        model.ingest(CoveEvent(id: "codex:\(chat.id)", title: chat.title, kind: "running", source: "codex"))
        XCTAssertEqual(model.aiUsage.summary(for: .terminal).sessions, 1)
        model.codexChats.configureForTesting(chats: [chat]) { _, _, _, _ in }
        model.codexChats.receive(id: chat.id, state: CodexChatStatus(["type": "active", "activeFlags": []])!)
        XCTAssertEqual(model.activity("codex:\(chat.id)")?.usageSource, .desktop)
        XCTAssertEqual(model.aiUsage.summary(for: .terminal).sessions, 0)
        XCTAssertEqual(model.aiUsage.summary(for: .desktop).sessions, 1)
        model.codexChats.receive(id: chat.id, state: CodexChatStatus(["type": "idle"])!)
        XCTAssertEqual(model.aiUsage.summary(for: .desktop).sessions, 1)
    }

    func testUsageRemainsAfterActivityRemovalAndSourceFiltersComposeWithState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-usage-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(url: root.appendingPathComponent("usage.json"))
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        let model = IslandModel(config: config, recapStore: AgentRecapStore(url: root.appendingPathComponent("recap.json")), usageStore: store)
        model.ingest(CoveEvent(id: "claude:test", title: "Terminal", kind: "running", source: "claude"))
        model.setUsage(id: "claude:test", TokenUsage(input: 500, output: 50))
        model.ingest(CoveEvent(id: "desktop:chatgpt:test", title: "Desktop", kind: "running", source: "chatgpt"))
        model.ingest(CoveEvent(id: "web:gemini:test", title: "Cloud", kind: "done", source: "gemini", silent: true))
        model.aiUsageSourceFilter = .desktop
        XCTAssertEqual(model.filteredAIActivities.map(\.id), ["desktop:chatgpt:test"])
        model.aiActivityFilter = .finished
        XCTAssertNil(model.selectedAIActivity)
        let terminal = try XCTUnwrap(model.activity("claude:test"))
        model.selectAIActivity(terminal)
        XCTAssertNil(model.aiUsageSourceFilter)
        XCTAssertEqual(model.aiActivityFilter, .all)
        XCTAssertEqual(model.selectedAIActivity?.id, terminal.id)
        model.removeActivity(terminal.id)
        XCTAssertEqual(model.aiUsage.summary(for: .terminal).tokens?.total, 550)
        XCTAssertEqual(store.load().summary(for: .terminal).sessions, 1)
    }
}
