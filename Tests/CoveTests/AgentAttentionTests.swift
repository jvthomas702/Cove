import XCTest
@testable import Cove

@MainActor final class AgentAttentionTests: XCTestCase {
    func model() -> IslandModel {
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        return IslandModel(config: config)
    }
    func testOptionalNotificationSetupIsQuietNonstickyAndDoesNotRepeat() {
        let model = model()
        model.notificationAccessDenied()
        model.notificationAccessDenied()
        XCTAssertEqual(model.banner?.style, .info)
        XCTAssertEqual(model.banner?.sticky, false)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertNil(model.aiStatusState)
    }
    func testRepeatedWaitRingsOnceAndNewPromptClearsStickyBanner() {
        let model = model()
        for _ in 0..<4 { model.agentAttention(id: "a", agent: .codex, title: "Project", message: "Answer needed") }
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.banner?.style, .attention)
        model.agentStarted(id: "a", agent: .codex, title: "Project", detail: "Working", ownerApp: nil)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.activity("a")?.state, .running)
        model.agentAttention(id: "a", agent: .codex, title: "Project", message: "Another question")
        XCTAssertEqual(model.history.count, 2)
    }
    func testTypedClaudeNotificationsIgnoreIdleAndAuthButAcceptRealQuestions() throws {
        let model = model(), bridge = AgentBridge(model: model)
        func notify(_ type: String) throws {
            bridge.handleClaude(try JSONSerialization.data(withJSONObject: ["hook_event_name": "Notification", "session_id": "s", "notification_type": type, "message": "Notice"]))
        }
        for type in ["idle_prompt", "auth_success", "agent_completed", "", "unknown"] { try notify(type) }
        XCTAssertNil(model.activity("claude:s")); XCTAssertTrue(model.history.isEmpty)
        for type in ["permission_prompt", "elicitation_dialog", "agent_needs_input"] {
            try notify(type)
            XCTAssertEqual(model.activity("claude:s")?.state, .attention)
            model.agentUpdate(id: "claude:s", agent: .claude, title: "Project", detail: "Resumed")
            XCTAssertNil(model.banner)
        }
        XCTAssertEqual(model.history.count, 3)
    }
    func testLateTranscriptCannotFinishNewClaudeTurn() async throws {
        let model = model(), bridge = AgentBridge(model: model)
        bridge.handleClaude(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8))
        bridge.handleClaude(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"Next task"}"#.utf8))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.activity("claude:s")?.state, .running)
        XCTAssertEqual(model.activity("claude:s")?.detail, "Next task")
    }
    func testPermissionArrivingFirstCreatesActivityAndCancellationClearsAttention() {
        let model = model()
        let request = ApprovalRequest(sessionID: "claude:s", project: "Project", tool: "Read", action: "read a file", preview: ApprovalPreview(lines: []), canAlwaysAllow: false, expiresAt: Date().addingTimeInterval(60))
        model.requestApproval(request) { _ in }
        XCTAssertEqual(model.activity("claude:s")?.state, .attention)
        model.cancelApproval(request.id)
        XCTAssertEqual(model.activity("claude:s")?.state, .running)
        XCTAssertTrue(model.approvals.isEmpty)
    }
    func testDesktopWaitDebouncesAutomaticApprovalAndIncludesUserInput() {
        let model = model(), chats = model.codexChats
        let chat = CodexChat(id: UUID().uuidString, title: "Existing chat", folder: "/tmp")
        chats.configureForTesting(chats: [chat]) { _, _, _, _ in XCTFail("An observation must never send a prompt") }
        let now = Date()
        let waiting = CodexChatStatus(["type": "active", "activeFlags": ["waitingOnApproval"]])!
        let running = CodexChatStatus(["type": "active", "activeFlags": []])!
        chats.receive(id: chat.id, state: waiting, now: now)
        chats.receive(id: chat.id, state: running, now: now.addingTimeInterval(0.3))
        XCTAssertTrue(model.history.isEmpty)
        let question = CodexChatStatus(["type": "active", "activeFlags": ["waitingOnUserInput"]])!
        chats.receive(id: chat.id, state: question, now: now.addingTimeInterval(1))
        chats.receive(id: chat.id, state: question, now: now.addingTimeInterval(3))
        chats.receive(id: chat.id, state: question, now: now.addingTimeInterval(5))
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.activity("codex:\(chat.id)")?.state, .attention)
        // An early tool hook or delayed completion cannot overwrite the live desktop state.
        model.ingest(CoveEvent(id: "codex:\(chat.id)", title: "Project", kind: "running", source: "codex"))
        let bridge = AgentBridge(model: model)
        bridge.handleCodex(try! JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete", "thread-id": chat.id]))
        XCTAssertEqual(model.activity("codex:\(chat.id)")?.state, .attention)
        chats.receive(id: chat.id, state: running, now: now.addingTimeInterval(6))
        XCTAssertNil(model.banner)
        model.ingest(CoveEvent(id: "codex:\(chat.id)", title: "Project", body: "Reading", kind: "running", source: "codex", phase: "Read"))
        XCTAssertEqual(model.activity("codex:\(chat.id)")?.phase, "Read")
        chats.receive(id: chat.id, state: CodexChatStatus(["type": "idle"])!)
        XCTAssertEqual(model.activity("codex:\(chat.id)")?.state, .done)
    }
}
