import AppKit
import Combine
import SQLite3

struct CodexChat: Identifiable, Equatable {
    let id: String
    let title: String
    let folder: String
}

/// Reads titles and project paths only. Never opens transcripts or writes Codex's database.
enum CodexChatCatalog {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) throws -> [CodexChat] {
        let path = home.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw AgentLauncher.LaunchError.message("Open Codex to load your local chats.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let sql = "SELECT id, COALESCE(NULLIF(name,''), title), cwd FROM threads WHERE archived=0 AND (source IN ('cli','vscode','appServer') OR source LIKE '%appServer%') ORDER BY updated_at DESC LIMIT 100"
        // Parent relationships vary between CLI versions; source filtering excludes subagents.
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgentLauncher.LaunchError.message("This Codex version uses an unsupported chat catalog.")
        }
        defer { sqlite3_finalize(statement) }
        var result: [CodexChat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            let id = text(0)
            guard UUID(uuidString: id) != nil else { continue }
            result.append(CodexChat(id: id, title: text(1).isEmpty ? "Untitled chat" : text(1), folder: text(2)))
        }
        return result
    }
}

struct CodexChatStatus: Equatable {
    var type: String
    var flags: [String]
    init?(_ object: [String: Any]) {
        guard let type = object["type"] as? String, ["active", "idle", "notLoaded", "systemError"].contains(type) else { return nil }
        self.type = type
        flags = object["activeFlags"] as? [String] ?? []
    }
    var needsYou: Bool { type == "active" && flags.contains(where: { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) }
    var phase: String { flags.contains("waitingOnUserInput") ? "Waiting for your answer" : needsYou ? "Waiting for approval" : "Working" }
}

@MainActor final class CodexChats: ObservableObject {
    @Published var selectedID = ""
    @Published var prompt = ""
    @Published private(set) var chats: [CodexChat] = []
    @Published private(set) var status = "Choose a local Codex chat."
    @Published private(set) var sending = false
    @Published private(set) var connected = false
    var onState: ((CodexChat, CodexChatStatus) -> Void)?
    var onDisconnect: (() -> Void)?
    var sendRequest: ((String, [String: Any], Int, @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
    private var connection: CodexDesktopConnection?
    private var states: [String: CodexChatStatus] = [:]
    private var delivered: [String: CodexChatStatus] = [:]
    private var waits: [String: Date] = [:]
    var selectedChat: CodexChat? { chats.first { $0.id == selectedID } }
    var canSend: Bool { connected && selectedChat != nil && !sending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prompt.contains("\0") }

    func start() {
        guard connection == nil else { return }
        let connection = CodexDesktopConnection()
        self.connection = connection
        connection.onCatalog = { [weak self] result in Task { @MainActor in
            guard let self else { return }
            switch result {
            case .success(let chats): self.setChats(chats)
            case .failure(let error): self.status = error.localizedDescription
            }
        } }
        connection.onConnection = { [weak self] connected in Task { @MainActor in
            guard let self else { return }
            self.connected = connected
            if !connected { self.states.removeAll(); self.waits.removeAll(); self.delivered.removeAll(); self.onDisconnect?() }
            self.status = connected ? "Sends to the selected chat. Working chats receive a follow-up." : "Open Codex to connect. Your draft stays here."
        } }
        connection.onState = { [weak self] id, state in Task { @MainActor in self?.receive(id: id, state: state) } }
        sendRequest = { [weak connection] method, params, version, completion in connection?.request(method, params, version: version, completion: completion) }
        connection.start()
    }
    func stop() { connection?.stop(); connection = nil }
    func refresh() { connection?.refresh() }
    func setChats(_ chats: [CodexChat]) {
        self.chats = chats
        let ids = Set(chats.map(\.id))
        states = states.filter { ids.contains($0.key) }
        delivered = delivered.filter { ids.contains($0.key) }
        waits = waits.filter { ids.contains($0.key) }
        // A disappeared destination never silently changes to another chat.
        if selectedID.isEmpty { selectedID = chats.first?.id ?? "" }
    }
    func configureForTesting(chats: [CodexChat], send: @escaping (String, [String: Any], Int, @escaping (Result<[String: Any], Error>) -> Void) -> Void) {
        setChats(chats); connected = true; sendRequest = send
    }
    func receive(id: String, state: CodexChatStatus, now: Date = Date()) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        states[id] = state
        if state.needsYou {
            let start = waits[id] ?? now; waits[id] = start
            // Automatic approval may briefly enter a waiting state. Require a sustained wait.
            guard now.timeIntervalSince(start) >= 1.5 else { return }
        } else { waits[id] = nil }
        guard delivered[id] != state else { return }
        delivered[id] = state
        onState?(chat, state)
    }
    func hasLiveState(_ id: String) -> Bool { connected && states[id] != nil }

    func send() {
        guard canSend, let chat = selectedChat, let transport = sendRequest else { return }
        let text = prompt
        sending = true; status = "Sending to \(chat.title)…"
        // Discovery verifies that the desktop owns this exact chat; never start a second server.
        transport("thread-owner-discovery", ["hostId": "local", "conversationId": chat.id], 1) { [weak self] result in Task { @MainActor in
            guard let self else { return }
            switch result {
            case .failure:
                self.sending = false; self.status = "Open ‘\(chat.title)’ in Codex, then Send again. Your draft is saved."
            case .success:
                let active = self.states[chat.id]?.type == "active"
                let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
                let messageID = UUID().uuidString.lowercased()
                let restore: [String: Any] = ["id": messageID, "text": text, "cwd": chat.folder, "createdAt": Date().timeIntervalSince1970 * 1000,
                    "context": ["prompt": text, "addedFiles": [], "fileAttachments": [], "imageAttachments": [], "workspaceRoots": [chat.folder]]]
                let params: [String: Any] = active
                    ? ["conversationId": chat.id, "input": input, "clientUserMessageId": messageID, "restoreMessage": restore]
                    : ["conversationId": chat.id, "turnStart": ["request": ["threadId": chat.id, "input": input, "clientUserMessageId": messageID], "context": ["inheritThreadSettings": true, "useUserMessageAdmission": true, "restoreMessage": restore]]]
                transport(active ? "thread-follower-steer-turn" : "thread-follower-start-turn", params, active ? 1 : 2) { [weak self] result in Task { @MainActor in
                    guard let self else { return }
                    self.sending = false
                    switch result {
                    case .success:
                        if self.prompt == text { self.prompt = "" }
                        self.status = "Sent to \(chat.title)."
                    case .failure:
                        // Never retry a possibly delivered message automatically.
                        self.status = "Delivery wasn’t confirmed. Check ‘\(chat.title)’ before retrying. Draft kept."
                    }
                } }
            }
        } }
    }
    func openSelected() {
        guard let chat = selectedChat, let url = URL(string: "codex://threads/\(chat.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
