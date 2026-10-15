import XCTest
import SQLite3
@testable import Cove

@MainActor final class CodexChatsTests: XCTestCase {
    let chat = CodexChat(id: "11111111-1111-4111-8111-111111111111", title: "Cove updates", folder: "/tmp/Cove")
    func testIdleSendUsesExactChatAndLiteralTextWithoutOverridingPermissions() async throws {
        let chats = CodexChats(); var requests: [(String, [String: Any])] = []
        chats.configureForTesting(chats: [chat]) { method, params, _, completion in
            requests.append((method, params)); completion(.success([:]))
        }
        let prompt = "Fix 'quotes'\n$(literal); — hello"
        chats.prompt = prompt; chats.send(); chats.send()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].0, "thread-owner-discovery")
        XCTAssertEqual(requests[1].0, "thread-follower-start-turn")
        XCTAssertEqual(requests[1].1["conversationId"] as? String, chat.id)
        let turn = requests[1].1["turnStart"] as! [String: Any], request = turn["request"] as! [String: Any]
        XCTAssertEqual(request["threadId"] as? String, chat.id)
        XCTAssertEqual((request["input"] as! [[String: Any]])[0]["text"] as? String, prompt)
        XCTAssertNil(request["approvalPolicy"]); XCTAssertNil(request["sandboxPolicy"])
        XCTAssertEqual((turn["context"] as! [String: Any])["inheritThreadSettings"] as? Bool, true)
        XCTAssertEqual(chats.prompt, ""); XCTAssertTrue(chats.status.contains("Sent to Cove updates"))
    }
    func testActiveChatReceivesSteeringAndKeepsNewlyTypedDraft() async throws {
        let chats = CodexChats()
        var callback: ((Result<[String: Any], Error>) -> Void)?
        chats.configureForTesting(chats: [chat]) { method, params, _, completion in
            if method == "thread-owner-discovery" { completion(.success([:])) }
            else {
                XCTAssertEqual(method, "thread-follower-steer-turn")
                XCTAssertEqual((params["restoreMessage"] as? [String: Any])?["text"] as? String, "First")
                callback = completion
            }
        }
        chats.receive(id: chat.id, state: CodexChatStatus(["type": "active", "activeFlags": []])!)
        chats.prompt = "First"; chats.send()
        try await Task.sleep(for: .milliseconds(30))
        chats.prompt = "Next draft"; callback?(.success([:]))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(chats.prompt, "Next draft")
    }
    func testUncertainDeliveryKeepsDraftAndNeverRetries() async throws {
        let chats = CodexChats(); var calls = 0
        chats.configureForTesting(chats: [chat]) { method, _, _, completion in
            calls += 1
            if method == "thread-owner-discovery" { completion(.success([:])) }
            else { completion(.failure(URLError(.networkConnectionLost))) }
        }
        chats.prompt = "My task"; chats.send()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls, 2); XCTAssertEqual(chats.prompt, "My task"); XCTAssertFalse(chats.sending)
        XCTAssertTrue(chats.status.contains("Check"))
    }
    func testUnavailableOwnerAndDisappearedSelectionNeverRedirectMessage() async throws {
        let chats = CodexChats(); var calls = 0
        chats.configureForTesting(chats: [chat]) { _, _, _, completion in calls += 1; completion(.failure(URLError(.cannotConnectToHost))) }
        chats.prompt = "My task"; chats.send()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, 1); XCTAssertEqual(chats.prompt, "My task")
        chats.setChats([CodexChat(id: UUID().uuidString, title: "Other chat", folder: "/tmp")])
        XCTAssertEqual(chats.selectedID, chat.id); XCTAssertFalse(chats.canSend)
        chats.send(); XCTAssertEqual(calls, 1)
    }
    func testCatalogExcludesArchivedAndSubagentsAndKeepsNamedChatTitles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cove-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER, source TEXT, updated_at INTEGER);
        INSERT INTO threads VALUES ('\(chat.id)', 'Cove updates', 'Original prompt', '/tmp/Cove', 0, 'vscode', 3);
        INSERT INTO threads VALUES ('22222222-2222-4222-8222-222222222222', 'Archived', 'Old', '/tmp', 1, 'cli', 2);
        INSERT INTO threads VALUES ('33333333-3333-4333-8333-333333333333', 'Worker', 'Worker', '/tmp', 0, 'subAgent', 4);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try CodexChatCatalog.read(home: home), [chat])
    }
}
