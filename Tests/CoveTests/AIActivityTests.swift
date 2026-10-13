import XCTest
@testable import Cove

final class DesktopAITrackerTests: XCTestCase {
    private func window(_ observation: DesktopAIControls.Observation, title: String = "Study plan", id: String = "one") -> DesktopAIWindow {
        DesktopAIWindow(id: id, title: title, app: "com.openai.chat", observation: observation)
    }

    func testDetectsComposerControlsWithoutConfusingVoiceButtons() {
        XCTAssertEqual(DesktopAIControls.classify(buttons: ["Stop generating response"], hasComposer: true), .working)
        XCTAssertEqual(DesktopAIControls.classify(buttons: ["Stop"], hasComposer: true), .working)
        XCTAssertEqual(DesktopAIControls.classify(buttons: ["Stop recording"], hasComposer: false), .unavailable)
        XCTAssertEqual(DesktopAIControls.classify(buttons: ["Send message"], hasComposer: true), .ready)
        XCTAssertEqual(DesktopAIControls.classify(buttons: [], hasComposer: true), .unavailable)
    }

    func testUnreadableControlsNeverFinishTheTask() {
        var tracker = DesktopAITracker()
        XCTAssertTrue(tracker.poll([window(.working)]).isEmpty)
        XCTAssertEqual(tracker.poll([window(.working)]).first?.kind, "running")
        XCTAssertEqual(tracker.poll([window(.unavailable)]).first?.phase, "Status unavailable")
        XCTAssertTrue(tracker.poll([window(.ready)]).isEmpty)
        let finished = tracker.poll([window(.ready)])
        XCTAssertEqual(finished.first?.kind, "done")
        XCTAssertEqual(finished.first?.silent, true)
        XCTAssertTrue(tracker.poll([window(.ready)]).isEmpty)
    }

    func testSwitchingChatsClearsWithoutInventingCompletion() {
        var tracker = DesktopAITracker()
        _ = tracker.poll([window(.working)])
        _ = tracker.poll([window(.working)])
        let changed = tracker.poll([window(.ready, title: "Other chat")])
        XCTAssertEqual(changed.first?.kind, "clear")
        XCTAssertFalse(changed.contains { $0.kind == "done" })
    }

    func testMissingWindowAndLostPermissionClearOnlyRunningWork() {
        var tracker = DesktopAITracker()
        _ = tracker.poll([window(.working)])
        _ = tracker.poll([window(.working)])
        XCTAssertTrue(tracker.poll([]).isEmpty)
        XCTAssertEqual(tracker.poll([]).first?.kind, "clear")
        _ = tracker.poll([window(.working)])
        _ = tracker.poll([window(.working)])
        XCTAssertEqual(tracker.reset().first?.kind, "clear")
        XCTAssertTrue(tracker.reset().isEmpty)
    }
}

@MainActor
final class AIWidgetTests: XCTestCase {
    private func model() -> IslandModel {
        var config = CoveConfig()
        config.calendar = false
        config.sounds = false
        config.buddy = false
        return IslandModel(config: config)
    }

    func testQuietBrowserCompletionStaysInWidget() {
        let model = model()
        model.ingest(CoveEvent(id: "web:chatgpt:test:tab:1", title: "Study plan", body: "Working", kind: "running", source: "chatgpt", phase: "Generating response", url: "https://chatgpt.com/c/test"))
        model.ingest(CoveEvent(id: "web:chatgpt:test:tab:1", title: "Study plan", body: "Visible answer", kind: "running", source: "chatgpt", phase: "Writing reply"))
        XCTAssertEqual(model.aiActivities.first?.phase, "Writing reply")
        XCTAssertEqual(model.aiActivities.first?.originLabel, "Browser tab")
        model.ingest(CoveEvent(id: "web:chatgpt:test:tab:1", title: "Study plan", body: "Answer ready", kind: "done", source: "chatgpt", silent: true))
        XCTAssertEqual(model.aiActivities.first?.state, .done)
        XCTAssertEqual(model.aiActivities.first?.detail, "Answer ready")
        XCTAssertEqual(model.aiActivities.first?.openURL?.host, "chatgpt.com")
        XCTAssertNil(model.banner)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testCompletionAfterReconnectionStillCreatesWidgetActivity() {
        let model = model()
        model.ingest(CoveEvent(id: "web:gemini:fast", title: "Quick reply", kind: "done", source: "gemini", silent: true))
        XCTAssertEqual(model.aiActivities.first?.state, .done)
    }

    func testLiveAIHasCompactPriorityAndCanBeTurnedOff() {
        let model = model()
        model.ingest(CoveEvent(id: "desktop:chatgpt:one", title: "ChatGPT", kind: "running", source: "chatgpt", phase: "Generating response"))
        guard case .ai(_, count: 1) = model.compactItem else { return XCTFail("AI work should be visible beside the notch") }
        XCTAssertNil(model.lastExtensionEvent)
        model.config.aiWorkInNotch = false
        guard case .running = model.compactItem else { return XCTFail("Existing running activity display should remain") }
    }

    func testChatLinksAreLimitedToSupportedSites() {
        XCTAssertNotNil(IslandModel.chatURL("https://claude.ai/chat/one"))
        XCTAssertNil(IslandModel.chatURL("javascript:alert(1)"))
        XCTAssertNil(IslandModel.chatURL("https://chatgpt.com.evil.example/c/one"))
        XCTAssertNil(IslandModel.chatURL("https://secret@chatgpt.com/c/one"))
    }
}
