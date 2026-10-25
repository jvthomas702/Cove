import XCTest
@testable import Cove

@MainActor final class CloudAgentsTests: XCTestCase {
    private func makeAgents() -> (CloudAgents, UserDefaults) {
        let name = "cove-cloud-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let agents = CloudAgents(defaults: defaults)
        agents.resolveExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
        return (agents, defaults)
    }

    func testFindsTheSessionIDInLinksAndText() {
        XCTAssertEqual(CloudAgents.sessionID(in: "https://claude.ai/code/session_01DiUkqY2kzbUbDmW1w96rfi?from=cli&m=0"),
                       "session_01DiUkqY2kzbUbDmW1w96rfi")
        XCTAssertEqual(CloudAgents.sessionID(in: "claude.ai/code/cse_0123456789abcdef"), "cse_0123456789abcdef")
        XCTAssertEqual(CloudAgents.sessionID(in: "session_abcDEF12"), "session_abcDEF12")
        XCTAssertNil(CloudAgents.sessionID(in: "https://claude.ai/chat/1234"))
        XCTAssertNil(CloudAgents.sessionID(in: "session_short"))
        XCTAssertNil(CloudAgents.sessionID(in: "mysession_0123456789"))
    }

    func testReadsTheCLIAnswer() {
        let ok = Data(#"{"ok":true,"session_id":"session_x","url":"https://claude.ai/code/session_x"}"#.utf8)
        XCTAssertEqual(CloudAgents.parse(stdout: ok, stderr: Data(), status: 0), .sent(url: URL(string: "https://claude.ai/code/session_x")))
        let archived = Data(#"{"ok":false,"session_id":"session_x","error":"cloud session session_x is archived and cannot accept new messages"}"#.utf8)
        XCTAssertEqual(CloudAgents.parse(stdout: archived, stderr: Data(), status: 1),
                       .failed("Cloud session session_x is archived and cannot accept new messages."))
        let policy = Data("Error: Cloud sessions are disabled by your organization's policy. Contact your organization admin to enable them.\n".utf8)
        XCTAssertEqual(CloudAgents.parse(stdout: Data(), stderr: policy, status: 1),
                       .failed("Cloud sessions are disabled by your organization's policy. Contact your organization admin to enable them."))
        let wrapped = Data("Error: failed to send message to cloud session session_x: Session not found: session_x\n".utf8)
        XCTAssertEqual(CloudAgents.parse(stdout: Data(), stderr: wrapped, status: 1), .failed("Session not found: session_x."))
        XCTAssertEqual(CloudAgents.parse(stdout: Data(), stderr: Data(), status: 2), .failed("Claude Code couldn’t send it (exit 2)."))
    }

    func testPastedLinksAndPullRequestsBecomeSessionsThatPersist() {
        let (agents, defaults) = makeAgents()
        XCTAssertTrue(agents.sessions.isEmpty)
        agents.linkDraft = "not a link"
        XCTAssertFalse(agents.addFromDraft())
        XCTAssertEqual(agents.status, "That isn’t a claude.ai/code session link.")

        agents.linkDraft = "https://claude.ai/code/session_0123456789ABCDEF"
        XCTAssertTrue(agents.addFromDraft())
        XCTAssertEqual(agents.selected?.title, "Cloud session ABCDEF")
        XCTAssertEqual(agents.linkDraft, "")

        // The PR the session opens names it properly, and moves it to the top.
        agents.note(id: "session_ffffffffffff", title: "Other", repo: nil)
        agents.note(id: "session_0123456789ABCDEF", title: "Cove: Fix the build", repo: "jv/Cove")
        XCTAssertEqual(agents.sessions.map(\.title), ["Cove: Fix the build", "Other"])

        let reloaded = CloudAgents(defaults: defaults)
        XCTAssertEqual(reloaded.sessions.map(\.id), ["session_0123456789ABCDEF", "session_ffffffffffff"])
        XCTAssertEqual(reloaded.selectedID, "session_0123456789ABCDEF")

        reloaded.remove("session_0123456789ABCDEF")
        XCTAssertEqual(reloaded.selectedID, "session_ffffffffffff")
    }

    func testKeepsOnlyRecentSessions() {
        let (agents, _) = makeAgents()
        for n in 0..<(CloudAgents.maxSessions + 5) { agents.note(id: "session_\(String(format: "%010d", n))", title: "\(n)", repo: nil) }
        XCTAssertEqual(agents.sessions.count, CloudAgents.maxSessions)
        XCTAssertEqual(agents.sessions.first?.title, "\(CloudAgents.maxSessions + 4)")
    }

    func testSendPassesTheMessageOnStdinAndKeepsTheDraftOnFailure() async throws {
        let (agents, _) = makeAgents()
        agents.note(id: "session_0123456789abcdef", title: "Fix CI", repo: "jv/Cove")
        var calls: [([String], String)] = []
        var answer = CloudSendResult.failed("Session not found: session_0123456789abcdef.")
        agents.runCLI = { _, arguments, input in calls.append((arguments, input)); return answer }

        agents.prompt = "  also update the docs  "
        XCTAssertTrue(agents.canSend)
        agents.send()
        XCTAssertTrue(agents.sending)
        for _ in 0..<100 where agents.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.first?.0, ["-p", "--cloud", "session_0123456789abcdef", "--output-format", "json"])
        XCTAssertEqual(calls.first?.1, "also update the docs")
        XCTAssertEqual(agents.prompt, "  also update the docs  ")
        XCTAssertEqual(agents.status, "Session not found: session_0123456789abcdef. Your draft is saved.")
        XCTAssertTrue(agents.selectedMessages.isEmpty)

        answer = .sent(url: nil)
        agents.send()
        for _ in 0..<100 where agents.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(agents.prompt, "")
        XCTAssertEqual(agents.selectedMessages.map(\.text), ["also update the docs"])
        XCTAssertEqual(agents.status, "Sent to Fix CI. Claude picks it up next.")
    }

    func testCloudPullRequestsOfferMessagingFromTheAITab() {
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        let model = IslandModel(config: config)
        let pr = CloudPR(repo: "jv/Cove", number: 7, title: "Fix the build", url: URL(string: "https://github.com/jv/Cove/pull/7")!,
                         link: URL(string: "https://claude.ai/code/session_0123456789abcdef")!, headSHA: "abc", draft: true,
                         state: .open, createdAt: Date(), updatedAt: Date())
        model.cloudUpdate(pr, phase: .draft, announce: false)
        let activity = try? XCTUnwrap(model.activities.first { $0.id == pr.id })
        XCTAssertEqual(activity.flatMap(model.cloudSessionID(for:)), "session_0123456789abcdef")
        XCTAssertTrue(model.cloudAgents.sessions.contains { $0.id == "session_0123456789abcdef" && $0.title == "Cove: Fix the build" })
        if let activity { model.messageCloudSession(for: activity) }
        XCTAssertEqual(model.composeTarget, .cloud)
        XCTAssertEqual(model.cloudAgents.selectedID, "session_0123456789abcdef")
    }
}
