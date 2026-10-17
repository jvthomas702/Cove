import XCTest
@testable import Cove

@MainActor final class PhoneRelayTests: XCTestCase {
    private func model() -> IslandModel {
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        return IslandModel(config: config)
    }

    func testParsesPhoneAnswers() {
        let id = UUID()
        XCTAssertEqual(PhoneCommand.parse("status"), .status)
        XCTAssertEqual(PhoneCommand.parse("  Status \n"), .status)
        XCTAssertEqual(PhoneCommand.parse("allow \(id.uuidString)"), .approval(id, .allow))
        XCTAssertEqual(PhoneCommand.parse("deny \(id.uuidString.lowercased())"), .approval(id, .deny))
        XCTAssertEqual(PhoneCommand.parse("always \(id.uuidString)"), .approval(id, .allowAlways))
        XCTAssertNil(PhoneCommand.parse("allow"))
        XCTAssertNil(PhoneCommand.parse("allow not-a-uuid"))
        XCTAssertNil(PhoneCommand.parse("rm -rf \(id.uuidString)"))
        XCTAssertNil(PhoneCommand.parse(""))
    }

    func testReadsOnlyMessagesFromTheStream() {
        XCTAssertEqual(PhoneRelay.command(fromStreamLine: #"{"id":"a","event":"message","topic":"t-reply","message":"status"}"#), .status)
        XCTAssertNil(PhoneRelay.command(fromStreamLine: #"{"id":"b","event":"keepalive","topic":"t-reply"}"#))
        XCTAssertNil(PhoneRelay.command(fromStreamLine: #"{"id":"c","event":"open","topic":"t-reply"}"#))
        XCTAssertNil(PhoneRelay.command(fromStreamLine: "not json"))
    }

    func testPublishPayloadPointsButtonsAtTheReplyTopic() throws {
        let preview = ApprovalPreview(lines: [.init(id: 0, text: "$ npm test", style: .code)])
        let request = ApprovalRequest(sessionID: "claude:s", project: "Cove", tool: "Bash", action: "run a command",
                                      preview: preview, canAlwaysAllow: true, expiresAt: Date().addingTimeInterval(60))
        let note = PhoneMessages.approval(request, buttons: true)
        let server = PhoneRelay.serverURL("ntfy.sh/")
        XCTAssertEqual(server.absoluteString, "https://ntfy.sh")
        let body = PhoneRelay.payload(note, server: server, topic: "cove-abc", token: "")
        XCTAssertEqual(body["topic"] as? String, "cove-abc")
        XCTAssertEqual(body["title"] as? String, "Claude wants to run a command · Cove")
        XCTAssertEqual(body["message"] as? String, "$ npm test")
        XCTAssertEqual(body["priority"] as? Int, 5)
        let actions = try XCTUnwrap(body["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["label"] as? String }, ["Allow", "Deny", "Always allow"])
        XCTAssertEqual(actions[0]["url"] as? String, "https://ntfy.sh/cove-abc-reply")
        XCTAssertEqual(actions[0]["body"] as? String, "allow \(request.id.uuidString)")
        XCTAssertNil(actions[0]["headers"])

        let withToken = PhoneRelay.payload(note, server: server, topic: "cove-abc", token: "tk_1")
        let headers = (withToken["actions"] as? [[String: Any]])?.first?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer tk_1")

        let request2 = try XCTUnwrap(PhoneRelay.publishRequest(note, server: server, topic: "cove-abc", token: "tk_1"))
        XCTAssertEqual(request2.url?.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(request2.value(forHTTPHeaderField: "Authorization"), "Bearer tk_1")
        XCTAssertNil(PhoneRelay.publishRequest(note, server: server, topic: "", token: ""))
    }

    func testApprovalWithoutPhoneAnswersHasNoButtons() {
        let request = ApprovalRequest(sessionID: "claude:s", project: "Cove", tool: "Read", action: "read a file",
                                      preview: ApprovalPreview(lines: []), canAlwaysAllow: false, expiresAt: Date())
        XCTAssertTrue(PhoneMessages.approval(request, buttons: false).actions.isEmpty)
        XCTAssertEqual(PhoneMessages.approval(request, buttons: true).actions.map(\.label), ["Allow", "Deny"])
    }

    func testStatusListsLiveAgentsFirst() {
        let model = model()
        model.agentStarted(id: "claude:a", agent: .claude, title: "Cove", detail: "Editing PhoneRelay.swift", ownerApp: nil)
        model.agentAttention(id: "claude:b", agent: .claude, title: "Site", message: "Wants to run a command")
        model.agentFinished(id: "codex:c", agent: .codex, title: "API", summary: "Tests pass")
        let note = PhoneMessages.status(model.activities)
        XCTAssertEqual(note.title, "2 agents working, 1 needs you")
        let lines = note.message.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].hasPrefix("! Claude · Site"))
        XCTAssertEqual(lines[1], "● Claude · Cove: Editing PhoneRelay.swift")
        XCTAssertEqual(lines[3], "Recently finished")
        XCTAssertEqual(lines[4], "✓ Codex · API: Tests pass")
        XCTAssertEqual(note.actions.map(\.reply), ["status"])

        XCTAssertEqual(PhoneMessages.status([]).title, "No agents running")
    }

    func testModelPushesNeedsYouAndFinishedToThePhone() async throws {
        let model = model()
        var sent: [PhoneNote] = []
        model.phoneNotify = { sent.append($0) }
        model.agentAttention(id: "claude:a", agent: .claude, title: "Cove", message: "Pick an option")
        model.agentAttention(id: "claude:a", agent: .claude, title: "Cove", message: "Pick an option")
        XCTAssertEqual(sent.map(\.title), ["Claude needs you · Cove"])
        model.agentFinished(id: "codex:b", agent: .codex, title: "API", summary: "Done and dusted")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent.last?.message, "Done and dusted")
        model.agentFinished(id: "codex:c", agent: .codex, title: "Quiet", summary: "x", notify: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent.count, 2)
    }

    func testTopicsAreLongAndRandom() {
        let a = PhoneRelay.newTopic(), b = PhoneRelay.newTopic()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("cove-"))
        XCTAssertEqual(a.count, 27)
    }
}
