import XCTest
@testable import Cove

@MainActor final class BannerReplyTests: XCTestCase {
    private let session = "4f1c2b9e-7d3a-4c55-9e0b-2a6f8d1c3e77"

    private func model() -> IslandModel {
        var config = CoveConfig(); config.sounds = false; config.calendar = false
        return IslandModel(config: config)
    }

    private func temporaryFolder(_ name: String = "project ' with spaces") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-reply-test-\(UUID())")
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return folder
    }

    private func finishClaude(_ bridge: AgentBridge, cwd: String) throws {
        var payload: [String: Any] = ["cwd": cwd, "session_id": session]
        payload["hook_event_name"] = "UserPromptSubmit"; payload["prompt"] = "Fix the tests"
        bridge.handleClaude(try JSONSerialization.data(withJSONObject: payload))
        payload["hook_event_name"] = "Stop"
        bridge.handleClaude(try JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: Command building and quoting

    func testClaudeCommandQuotesEveryValue() throws {
        let target = try XCTUnwrap(ResumeTarget(agent: .claude, sessionID: session, cwd: "/Users/me/it's here"))
        let line = ResumeCommand.shellLine(target, text: "don't $(rm -rf ~) `x`", executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        XCTAssertEqual(line, #"cd -- '/Users/me/it'\''s here' && exec '/opt/homebrew/bin/claude' --resume '4f1c2b9e-7d3a-4c55-9e0b-2a6f8d1c3e77' -- 'don'\''t $(rm -rf ~) `x`'"#)
    }

    func testCodexCommandUsesResumeSubcommand() throws {
        let target = try XCTUnwrap(ResumeTarget(agent: .codex, sessionID: session, cwd: "/tmp/app"))
        let line = ResumeCommand.shellLine(target, text: "Ship it", executable: URL(fileURLWithPath: "/usr/local/bin/codex"))
        XCTAssertEqual(line, "cd -- '/tmp/app' && exec '/usr/local/bin/codex' resume '\(session)' -- 'Ship it'")
    }

    func testOnlyResumableSessionsAndAbsoluteFoldersAreOffered() {
        XCTAssertNotNil(ResumeTarget(agent: .claude, sessionID: session, cwd: "/tmp"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: nil, cwd: "/tmp"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: "default", cwd: "/tmp"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: "--dangerously-skip", cwd: "/tmp"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: "abc def; rm", cwd: "/tmp"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: session, cwd: "relative/path"))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: session, cwd: nil))
        XCTAssertNil(ResumeTarget(agent: .claude, sessionID: session, cwd: ""))
    }

    func testPreparedScriptPassesReplyLiterallyFromTheProjectFolder() throws {
        let folder = try temporaryFolder()
        let executable = folder.deletingLastPathComponent().appendingPathComponent("fake claude")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > received-arguments\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let target = try XCTUnwrap(ResumeTarget(agent: .claude, sessionID: session, cwd: folder.path))
        let reply = "Now 'also' add docs\n$(touch SHOULD_NOT_EXIST); `touch ALSO_NOT`"
        let script = try ResumeCommand.prepare(target, text: reply, executable: executable)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = [script.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let values = try Data(contentsOf: folder.appendingPathComponent("received-arguments"))
        XCTAssertEqual(String(decoding: values, as: UTF8.self), "--resume\0\(session)\0--\0\(reply)\0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHOULD_NOT_EXIST").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ALSO_NOT").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
    }

    func testEmptyRepliesAndMissingFoldersAreRejected() throws {
        let target = try XCTUnwrap(ResumeTarget(agent: .claude, sessionID: session, cwd: "/tmp/\(UUID().uuidString)"))
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try ResumeCommand.prepare(target, text: " \n", executable: executable))
        XCTAssertThrowsError(try ResumeCommand.prepare(target, text: "a\0b", executable: executable))
        XCTAssertThrowsError(try ResumeCommand.prepare(target, text: "Continue", executable: executable))
    }

    // MARK: Banner wiring

    func testClaudeDoneBannerOffersReplyForItsSession() throws {
        let model = model(), bridge = AgentBridge(model: model)
        try finishClaude(bridge, cwd: "/tmp/cove-project")
        let banner = try XCTUnwrap(model.banner)
        XCTAssertEqual(banner.style, .success)
        let target = try XCTUnwrap(model.replyTarget(for: banner))
        XCTAssertEqual(target.agent, .claude)
        XCTAssertEqual(target.sessionID, session)
        XCTAssertEqual(target.cwd, "/tmp/cove-project")
        XCTAssertTrue(model.bannerAcceptsReply)
        XCTAssertGreaterThan(model.size(for: .banner).height, model.notchSize.height + 60)

        model.config.bannerReplies = false
        XCTAssertNil(model.replyTarget(for: banner))
        XCTAssertEqual(model.size(for: .banner).height, model.notchSize.height + 60)
    }

    func testNoReplyWithoutARealSessionOrWhileWorking() throws {
        let model = model(), bridge = AgentBridge(model: model)
        bridge.handleClaude(Data(#"{"hook_event_name":"Stop","cwd":"/tmp/x"}"#.utf8))
        XCTAssertNil(model.banner.flatMap(model.replyTarget(for:)))

        let other = self.model(), otherBridge = AgentBridge(model: other)
        try finishClaude(otherBridge, cwd: "/tmp/cove-project")
        let banner = try XCTUnwrap(other.banner)
        otherBridge.handleClaude(try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": "/tmp/cove-project", "prompt": "Next"]))
        XCTAssertNil(other.replyTarget(for: banner))
    }

    func testCodexNotifyWithThreadIDOffersCodexResume() throws {
        let model = model(), bridge = AgentBridge(model: model)
        bridge.handleCodex(try JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete", "thread-id": session, "cwd": "/tmp/app", "last-assistant-message": "Done"]))
        let target = try XCTUnwrap(model.banner.flatMap(model.replyTarget(for:)))
        XCTAssertEqual(target.agent, .codex)
        XCTAssertEqual(target.sessionID, session)
    }

    func testSendingOpensTerminalAndDismissesBanner() throws {
        let model = model(), bridge = AgentBridge(model: model)
        let folder = try temporaryFolder("app")
        try finishClaude(bridge, cwd: folder.path)
        let banner = try XCTUnwrap(model.banner)
        model.agentLauncher.resolveExecutable = { _ in URL(fileURLWithPath: "/usr/bin/true") }
        var opened: URL?
        model.agentLauncher.openCommand = { url, completion in opened = url; completion(nil) }
        model.setBannerReplyEngaged(true)
        XCTAssertTrue(model.bannerHeld)
        XCTAssertNil(model.sendBannerReply("Add a test", for: banner))
        let script = try XCTUnwrap(opened)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(source.contains("--resume '\(session)' -- 'Add a test'"))
        XCTAssertNil(model.banner)
    }

    func testMissingCLIKeepsBannerAndExplains() throws {
        let model = model(), bridge = AgentBridge(model: model)
        try finishClaude(bridge, cwd: "/tmp")
        let banner = try XCTUnwrap(model.banner)
        model.agentLauncher.resolveExecutable = { _ in nil }
        let error = model.sendBannerReply("Hello", for: banner)
        XCTAssertEqual(error?.contains("Install Claude Code"), true)
        XCTAssertEqual(model.banner?.id, banner.id)
    }

    func testHeldBannerResumesCountdownWhenReplyIsAbandoned() throws {
        let model = model(), bridge = AgentBridge(model: model)
        try finishClaude(bridge, cwd: "/tmp")
        model.setBannerReplyEngaged(true)
        XCTAssertTrue(model.bannerHeld)
        model.setBannerReplyEngaged(false)
        XCTAssertFalse(model.bannerHeld)
        XCTAssertNotNil(model.banner)
    }
}
