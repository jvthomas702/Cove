import XCTest
@testable import Cove

@MainActor final class MergedWorkspaceTests: XCTestCase {
    private func model() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        return IslandModel(config: config)
    }

    func testCloudWorkAppearsInTheAIWorkspaceWithItsActualPhaseAndDestination() {
        let model = model()
        let pr = CloudPR(repo: "owner/Cove", number: 11, title: "Cloud sessions",
                         url: URL(string: "https://github.com/owner/Cove/pull/11")!,
                         link: URL(string: "https://claude.ai/code/session_example")!,
                         headSHA: "abc", draft: true, state: .open,
                         createdAt: Date(), updatedAt: Date())
        model.cloudUpdate(pr, phase: .ciRunning, announce: false)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.selectedAIActivity?.id, pr.id)
        XCTAssertEqual(model.selectedAIActivity?.phase, "CI running")
        XCTAssertEqual(model.selectedAIActivity?.openURL, pr.link)
        XCTAssertEqual(model.selectedAIActivity?.originLabel, "Claude cloud")
        model.cloudUpdate(pr, phase: .ready, announce: false)
        XCTAssertEqual(model.selectedAIActivity?.phase, "Ready for review")
        XCTAssertEqual(model.selectedAIActivity?.state, .done)
    }

    func testUsageRefreshPreservesAttentionAndItsBanner() {
        let model = model()
        model.agentAttention(id: "claude:usage", agent: .claude, title: "Cove", message: "Approve a command")
        let bannerID = model.banner?.id
        model.setUsage(id: "claude:usage", TokenUsage(input: 500, output: 100))
        XCTAssertEqual(model.selectedAIActivity?.tokens?.total, 600)
        XCTAssertEqual(model.selectedAIActivity?.state, .attention)
        XCTAssertEqual(model.banner?.id, bannerID)
        XCTAssertEqual(model.history.count, 1)
    }
}
