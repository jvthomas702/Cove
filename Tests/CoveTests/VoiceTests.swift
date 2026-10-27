import XCTest
@testable import Cove

final class FnHoldGestureTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    func testHoldingFnAloneStartsListeningAndReleaseSends() {
        var gesture = FnHoldGesture()
        XCTAssertEqual(gesture.fn(down: true, otherModifiers: false, at: start), .none)
        XCTAssertEqual(gesture.holdElapsed(at: start.addingTimeInterval(FnHoldGesture.holdDelay)), .begin)
        XCTAssertEqual(gesture.otherInput(), .none, "keys typed while listening are left alone")
        XCTAssertEqual(gesture.fn(down: false, otherModifiers: false, at: start.addingTimeInterval(2)), .end)
    }

    func testQuickTapDoesNothing() {
        var gesture = FnHoldGesture()
        _ = gesture.fn(down: true, otherModifiers: false, at: start)
        XCTAssertEqual(gesture.fn(down: false, otherModifiers: false, at: start.addingTimeInterval(0.1)), .none)
        XCTAssertEqual(gesture.holdElapsed(at: start.addingTimeInterval(FnHoldGesture.holdDelay)), .none)
    }

    func testFnAsAModifierNeverListens() {
        var arrow = FnHoldGesture()
        _ = arrow.fn(down: true, otherModifiers: false, at: start)
        _ = arrow.otherInput()   // fn+→
        XCTAssertEqual(arrow.holdElapsed(at: start.addingTimeInterval(1)), .none)
        XCTAssertEqual(arrow.fn(down: false, otherModifiers: false, at: start.addingTimeInterval(1)), .none)

        var command = FnHoldGesture()
        _ = command.fn(down: true, otherModifiers: true, at: start)   // ⌘ already held
        XCTAssertEqual(command.holdElapsed(at: start.addingTimeInterval(1)), .none)
    }

    func testEscapeCancelsAndReleaseThenDoesNothing() {
        var gesture = FnHoldGesture()
        _ = gesture.fn(down: true, otherModifiers: false, at: start)
        _ = gesture.holdElapsed(at: start.addingTimeInterval(0.3))
        XCTAssertEqual(gesture.escape(), .cancel)
        XCTAssertEqual(gesture.fn(down: false, otherModifiers: false, at: start.addingTimeInterval(1)), .none)
        XCTAssertEqual(gesture.escape(), .none)
    }
}

final class VoiceCommandTests: XCTestCase {
    func testArgumentsKeepThePromptOffTheCommandLine() {
        let fresh = VoiceCommand.arguments(resume: nil, canEdit: false)
        XCTAssertEqual(Array(fresh.prefix(5)), ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
        XCTAssertFalse(fresh.contains("--resume"))
        XCTAssertFalse(fresh.contains("--permission-mode"))
        let followUp = VoiceCommand.arguments(resume: "0b1c2d3e-aaaa-bbbb-cccc-1234567890ab", canEdit: true)
        XCTAssertEqual(followUp.suffix(4), ["--resume", "0b1c2d3e-aaaa-bbbb-cccc-1234567890ab", "--permission-mode", "acceptEdits"])
    }

    func testParsesTheStreamLinesCoveUses() {
        XCTAssertEqual(VoiceCommand.parse(#"{"type":"system","subtype":"init","session_id":"abc","tools":[]}"#), .session("abc"))
        XCTAssertEqual(VoiceCommand.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#),
                       .text("Hi"))
        XCTAssertEqual(VoiceCommand.parse(#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{}}}}"#),
                       .tool("Read"))
        XCTAssertEqual(VoiceCommand.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"abc","permission_denials":[{"tool_name":"Edit","tool_use_id":"t2","tool_input":{}}]}"#),
                       .result(text: "Done.", sessionID: "abc", isError: false, denied: ["Edit"]))
        XCTAssertEqual(VoiceCommand.parse(#"{"type":"result","subtype":"error_during_execution","result":"","session_id":"abc"}"#),
                       .result(text: "", sessionID: "abc", isError: true, denied: []))
        XCTAssertNil(VoiceCommand.parse(#"{"type":"assistant","message":{}}"#))
        XCTAssertNil(VoiceCommand.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#))
        XCTAssertNil(VoiceCommand.parse("not json"))
        XCTAssertEqual(VoiceCommand.describe(tool: "Grep"), "Searching")
        XCTAssertEqual(VoiceCommand.describe(tool: "mcp__x"), "Using mcp__x")
    }

    /// A fake `claude` that answers with the request it got on stdin, in stream-json, split across writes.
    func testRunReadsTheStreamAndTheRequestArrivesOnStdin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-voice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        request=$(cat)
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"s-1"}'
        printf '%s' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"You said "}}}'
        sleep 0.1
        printf '\\n'
        printf '{"type":"result","subtype":"success","is_error":false,"result":"You said %s","session_id":"s-1"}\\n' "$request"
        """
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

        let finished = expectation(description: "exit")
        let events = Locked<[ClaudeStreamEvent]>([])
        let run = try ClaudeRun(executable: fake, arguments: VoiceCommand.arguments(resume: nil, canEdit: false),
                                folder: root, prompt: "what time is it",
                                onEvent: { event in events.mutate { $0.append(event) } },
                                onExit: { status, _ in XCTAssertEqual(status, 0); finished.fulfill() })
        wait(for: [finished], timeout: 10)
        _ = run
        XCTAssertEqual(events.value, [
            .session("s-1"),
            .text("You said "),
            .result(text: "You said what time is it", sessionID: "s-1", isError: false, denied: []),
        ])
    }
}

/// A value shared with background callbacks in a test.
private final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

@MainActor final class VoicePresentationTests: XCTestCase {
    func testVoiceDefaultsAndTheIslandMakesRoomForIt() throws {
        let config = try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.voiceAssistant)
        XCTAssertFalse(config.voiceCanEdit)
        XCTAssertFalse(config.voiceSpeaks)
        XCTAssertNil(config.voiceFolder)

        var quiet = CoveConfig(); quiet.sounds = false; quiet.calendar = false
        let model = IslandModel(config: quiet)
        XCTAssertNotEqual(model.presentation, .voice)
        XCTAssertGreaterThan(model.size(for: .voice).width, model.notchSize.width + 300)
        XCTAssertEqual(model.voice.folder.standardizedFileURL, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }
}
