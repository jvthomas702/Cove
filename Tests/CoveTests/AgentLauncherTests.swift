import AppKit
import XCTest
@testable import Cove

@MainActor final class AgentLauncherTests: XCTestCase {
    func testPromptAndFolderStayLiteralAndTemporaryCommandRemovesItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-launch-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project ' with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake agent")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > received-arguments\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let prompt = "Explain 'quotes'\n$(touch SHOULD_NOT_EXIST); `touch ALSO_NOT` — hello"
        let command = try AgentLauncher.prepareCommand(executable: executable, folder: folder, prompt: prompt)
        defer { try? FileManager.default.removeItem(at: command.deletingLastPathComponent()) }
        let permissions = try FileManager.default.attributesOfItem(atPath: command.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = [command.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let values = try Data(contentsOf: folder.appendingPathComponent("received-arguments"))
        XCTAssertEqual(String(decoding: values, as: UTF8.self), "--\0\(prompt)\0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHOULD_NOT_EXIST").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ALSO_NOT").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.deletingLastPathComponent().path))
    }

    func testFloatingPanelSelectAllWorksWithoutAnEditMenu() throws {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsKeyboardInput = true
        let editor = NSTextView(frame: panel.contentView!.bounds)
        editor.string = "A draft to replace"
        panel.contentView = editor
        XCTAssertTrue(panel.makeFirstResponder(editor))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
    }

    func testInvalidInputsDoNotCreateCommands() {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let folder = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try AgentLauncher.prepareCommand(executable: executable, folder: folder, prompt: "\0"))
        XCTAssertThrowsError(try AgentLauncher.prepareCommand(executable: executable, folder: folder, prompt: " \n"))
        XCTAssertThrowsError(try AgentLauncher.prepareCommand(executable: executable, folder: folder.appendingPathComponent(UUID().uuidString), prompt: "Task"))
    }

    func testUnavailableAgentPreservesDraft() {
        let launcher = AgentLauncher()
        launcher.folder = FileManager.default.temporaryDirectory; launcher.prompt = "Explain this project"
        launcher.resolveExecutable = { _ in nil }
        launcher.launch()
        XCTAssertEqual(launcher.prompt, "Explain this project")
        XCTAssertTrue(launcher.status.contains("Install Codex"))
        XCTAssertFalse(launcher.launching)
    }

    func testLaunchFailureKeepsDraftAndCleansTemporaryCommand() async {
        let launcher = AgentLauncher()
        launcher.folder = FileManager.default.temporaryDirectory; launcher.prompt = "Explain this project"
        launcher.resolveExecutable = { _ in URL(fileURLWithPath: "/usr/bin/true") }
        var command: URL?
        launcher.openCommand = { url, completion in
            command = url; completion(AgentLauncher.LaunchError.message("Test failure"))
        }
        launcher.launch()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(launcher.prompt, "Explain this project")
        XCTAssertTrue(launcher.status.contains("Test failure"))
        XCTAssertFalse(launcher.launching)
        if let command {
            XCTAssertFalse(FileManager.default.fileExists(atPath: command.path))
            try? FileManager.default.removeItem(at: command.deletingLastPathComponent())
        } else { XCTFail("Expected a prepared command") }
    }
}
