import XCTest
@testable import Cove

final class CloudSessionsTests: XCTestCase {
    private func pulls(_ items: [String]) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

    private func pr(number: Int, body: String, state: String = "open", draft: Bool = false, merged: Bool = false) -> String {
        let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"number": \(number), "title": "PR \(number)", "html_url": "https://github.com/o/r/pull/\(number)",
         "state": "\(state)", "draft": \(draft), "merged_at": \(merged ? "\"2026-10-17T02:00:00Z\"" : "null"),
         "created_at": "2026-10-17T01:00:00Z", "updated_at": "2026-10-17T01:30:00Z",
         "head": {"sha": "sha\(number)"}, "body": "\(escaped)"}
        """
    }

    func testKeepsOnlyClaudePullRequests() {
        let data = pulls([
            pr(number: 1, body: "Before: x\n\nhttps://claude.ai/code/session_01K53mEn5Kg8qP9NhjabemHX"),
            pr(number: 2, body: "A person wrote this"),
            pr(number: 3, body: "Stuff\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"),
            pr(number: 4, body: ""),
        ])
        let found = CloudPR.parse(data, repo: "o/r")
        XCTAssertEqual(found.map(\.number), [1, 3])
        XCTAssertEqual(found[0].link.absoluteString, "https://claude.ai/code/session_01K53mEn5Kg8qP9NhjabemHX")
        XCTAssertEqual(found[1].link.absoluteString, "https://github.com/o/r/pull/3") // no session link: the PR itself
        XCTAssertEqual(found[0].headSHA, "sha1")
        XCTAssertEqual(found[0].repoName, "r")
    }

    func testPrefersTheProjectThread() {
        let body = """
        <!-- claude-projects-attribution: {"github_login":"me"} -->
        _Requested by **me** · [project thread](https://claude.ai/code/project/chan_01T6?thread=cmsg_01T6abc)_

        https://claude.ai/code/session_01K53
        """
        XCTAssertEqual(CloudPR.sessionLink(in: body)?.absoluteString, "https://claude.ai/code/project/chan_01T6?thread=cmsg_01T6abc")
    }

    func testStates() {
        let data = pulls([
            pr(number: 1, body: "https://claude.ai/code/session_a", state: "closed", merged: true),
            pr(number: 2, body: "https://claude.ai/code/session_b", state: "closed"),
            pr(number: 3, body: "https://claude.ai/code/session_c", draft: true),
        ])
        let found = CloudPR.parse(data, repo: "o/r")
        XCTAssertEqual(found.map(\.state), [.merged, .closed, .open])
        XCTAssertEqual(found[0].phase(checks: .none), .merged)
        XCTAssertEqual(found[1].phase(checks: .failed), .closed)
        XCTAssertEqual(found[2].phase(checks: .none), .draft)
        XCTAssertEqual(found[2].phase(checks: .running), .ciRunning)
        XCTAssertEqual(found[2].phase(checks: .failed), .ciFailed)
        XCTAssertEqual(found[2].phase(checks: .passed), .draftPassed)
    }

    func testReadyWhenNotDraft() {
        let found = CloudPR.parse(pulls([pr(number: 5, body: "https://claude.ai/code/session_x")]), repo: "o/r")
        XCTAssertEqual(found.first?.phase(checks: .passed), .ready)
        XCTAssertEqual(found.first?.phase(checks: .none), .ready)
    }

    func testCheckSummary() {
        func runs(_ list: [(String, String?)]) -> Data {
            let items = list.map { status, conclusion in
                #"{"status": "\#(status)", "conclusion": \#(conclusion.map { "\"\($0)\"" } ?? "null")}"#
            }
            return Data(#"{"total_count": \#(list.count), "check_runs": [\#(items.joined(separator: ","))]}"#.utf8)
        }
        XCTAssertEqual(CheckSummary.parse(runs([])), .none)
        XCTAssertEqual(CheckSummary.parse(runs([("completed", "success"), ("completed", "skipped")])), .passed)
        XCTAssertEqual(CheckSummary.parse(runs([("completed", "success"), ("in_progress", nil)])), .running)
        XCTAssertEqual(CheckSummary.parse(runs([("queued", nil), ("completed", "failure")])), .failed)
        XCTAssertEqual(CheckSummary.parse(runs([("completed", "timed_out")])), .failed)
        XCTAssertEqual(CheckSummary.parse(Data("nonsense".utf8)), .none)
        XCTAssertTrue(CheckSummary.passed.isFinal)
        XCTAssertFalse(CheckSummary.running.isFinal)
    }

    @MainActor
    func testCloudActivityOpensTheSession() {
        let model = IslandModel(config: CoveConfig())
        let cloud = CloudPR.parse(pulls([pr(number: 7, body: "https://claude.ai/code/session_q")]), repo: "o/cove").first!
        model.cloudUpdate(cloud, phase: .ciRunning, announce: true)
        XCTAssertEqual(model.activity("cloud:o/cove#7")?.state, .running)
        XCTAssertEqual(model.activity("cloud:o/cove#7")?.url?.absoluteString, "https://claude.ai/code/session_q")
        XCTAssertEqual(model.activity("cloud:o/cove#7")?.title, "cove #7")
        model.cloudUpdate(cloud, phase: .ciFailed, announce: true)
        XCTAssertEqual(model.activity("cloud:o/cove#7")?.state, .failed)
        model.cloudUpdate(cloud, phase: .ready, announce: true)
        XCTAssertEqual(model.activity("cloud:o/cove#7")?.state, .done)
        model.cloudUpdate(cloud, phase: .closed, announce: true)
        XCTAssertNil(model.activity("cloud:o/cove#7"))
    }
}
