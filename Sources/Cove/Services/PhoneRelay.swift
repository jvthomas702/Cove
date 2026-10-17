import Foundation
import os

/// Sends agent pings to your phone through ntfy (https://ntfy.sh), and takes answers back.
///
/// Cove only listens on 127.0.0.1, so a phone away from home can't reach it. ntfy is a free push
/// relay: Cove posts to a private topic, the ntfy app (iOS, Android, or the web app) buzzes, and
/// buttons on the notification post back to a second topic that Cove listens to. Nothing to host,
/// no account. The topic name is the only secret, so Cove makes a long random one.
struct PhoneNote: Equatable {
    struct Action: Equatable {
        let label: String
        /// What the phone posts back to the reply topic (see PhoneCommand).
        let reply: String
    }

    var title: String
    var message: String
    /// ntfy priority: 1 silent … 3 normal … 5 urgent (breaks through Focus on Android).
    var priority: Int = 3
    var tags: [String] = []
    var actions: [Action] = []
}

/// Something the phone asked for, read from the reply topic.
enum PhoneCommand: Equatable {
    case status
    case approval(UUID, ApprovalDecision)

    /// "status", "allow <id>", "always <id>", "deny <id>", "terminal <id>". Anything else is ignored.
    static func parse(_ text: String) -> PhoneCommand? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = words.first else { return nil }
        if ["status", "agents", "?", "s"].contains(verb), words.count == 1 { return .status }
        guard words.count == 2, let id = UUID(uuidString: words[1]) else { return nil }
        switch verb {
        case "allow": return .approval(id, .allow)
        case "always": return .approval(id, .allowAlways)
        case "deny": return .approval(id, .deny)
        case "terminal": return .approval(id, .ask)
        default: return nil
        }
    }
}

enum PhoneMessages {
    static func attention(agent: AgentKind, title: String, message: String) -> PhoneNote {
        PhoneNote(title: "\(agent.displayName) needs you · \(title)", message: message, priority: 4,
                  tags: ["raising_hand"], actions: [statusAction])
    }

    static func finished(agent: AgentKind, title: String, summary: String, failed: Bool) -> PhoneNote {
        PhoneNote(title: failed ? "\(agent.displayName) failed · \(title)" : "\(agent.doneTitle) · \(title)",
                  message: summary, priority: failed ? 4 : 3,
                  tags: [failed ? "x" : "white_check_mark"], actions: [statusAction])
    }

    static func approval(_ request: ApprovalRequest, buttons: Bool) -> PhoneNote {
        let preview = request.preview.lines.prefix(4).map(\.text).joined(separator: "\n")
        let id = request.id.uuidString
        var actions = [PhoneNote.Action]()
        if buttons {
            actions = [
                .init(label: "Allow", reply: "allow \(id)"),
                .init(label: "Deny", reply: "deny \(id)"),
            ]
            // ntfy shows at most three buttons.
            if request.canAlwaysAllow { actions.append(.init(label: "Always allow", reply: "always \(id)")) }
        }
        return PhoneNote(title: "Claude wants to \(request.action) · \(request.project)",
                         message: preview.isEmpty ? "Answer in the notch or the terminal." : preview,
                         priority: 5, tags: ["lock"], actions: actions)
    }

    /// The reply to "status": every live agent, then the last few that finished.
    static func status(_ activities: [Activity], now: Date = Date()) -> PhoneNote {
        let live = activities.filter(\.isLive).sorted { $0.updatedAt > $1.updatedAt }
        let recent = activities.filter { !$0.isLive }.sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }.prefix(3)
        func line(_ a: Activity) -> String {
            let mark: String
            switch a.state {
            case .running: mark = "●"
            case .attention: mark = "!"
            case .done: mark = "✓"
            case .failed: mark = "✕"
            }
            let detail = a.detail.oneLine(max: 80)
            return "\(mark) \(a.agent.displayName) · \(a.title)" + (detail.isEmpty ? "" : ": \(detail)")
        }
        var lines = live.map(line)
        if !recent.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Recently finished")
            lines += recent.map(line)
        }
        let waiting = live.filter { $0.state == .attention }.count
        let title: String
        if live.isEmpty {
            title = "No agents running"
        } else {
            title = "\(live.count) agent\(live.count == 1 ? "" : "s") working" + (waiting > 0 ? ", \(waiting) need\(waiting == 1 ? "s" : "") you" : "")
        }
        return PhoneNote(title: title, message: lines.isEmpty ? "Nothing has run since Cove started." : lines.joined(separator: "\n"),
                         priority: 2, tags: ["robot"], actions: [statusAction])
    }

    static let statusAction = PhoneNote.Action(label: "Refresh", reply: "status")
}

@MainActor
final class PhoneRelay {
    enum Status: Equatable {
        case connecting
        case listening
        case error(String)
    }

    var onCommand: ((PhoneCommand) -> Void)?
    var onStatus: ((Status) -> Void)?

    private(set) var server: URL
    private(set) var topic: String
    private var token: String
    private var listener: Task<Void, Never>?
    private let session: URLSession

    init(server: String, topic: String, token: String, session: URLSession = .shared) {
        self.server = Self.serverURL(server)
        self.topic = topic
        self.token = token
        self.session = session
    }

    /// Where the phone subscribes. Open it on the phone, or add the topic in the ntfy app.
    var subscribeURL: URL { server.appendingPathComponent(topic) }
    var replyTopic: String { topic + "-reply" }

    func start() {
        guard listener == nil else { return }
        onStatus?(.connecting)
        listener = Task { [weak self] in await self?.listen() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func update(server: String, topic: String, token: String) {
        let url = Self.serverURL(server)
        guard url != self.server || topic != self.topic || token != self.token else { return }
        self.server = url
        self.topic = topic
        self.token = token
        stop()
        start()
    }

    func send(_ note: PhoneNote) {
        guard let request = Self.publishRequest(note, server: server, topic: topic, token: token) else { return }
        session.dataTask(with: request) { _, response, error in
            if let error {
                coveLog.error("Phone: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                coveLog.error("Phone: ntfy answered \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: Listening for answers

    private func listen() async {
        var delay: UInt64 = 2
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: server.appendingPathComponent(replyTopic).appendingPathComponent("json"))
                request.timeoutInterval = 90 // ntfy sends a keepalive every 45 s
                if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (bytes, response) = try await session.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "ntfy answered \(http.statusCode)"])
                }
                onStatus?(.listening)
                delay = 2
                for try await line in bytes.lines {
                    if let command = Self.command(fromStreamLine: line) { onCommand?(command) }
                }
            } catch {
                if Task.isCancelled { return }
                coveLog.error("Phone: \(error.localizedDescription, privacy: .public)")
                onStatus?(.error("Can't reach \(server.host ?? "ntfy"). Retrying…"))
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 60)
        }
    }

    // MARK: Pure helpers (tested)

    nonisolated static func serverURL(_ text: String) -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        return URL(string: text) ?? URL(string: "https://ntfy.sh")!
    }

    /// A long random topic name. It works like a password: anyone who knows it can read your pings.
    nonisolated static func newTopic() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return "cove-" + String((0..<22).map { _ in alphabet.randomElement()! })
    }

    /// One line of ntfy's JSON stream → a command (keepalives and other events are ignored).
    nonisolated static func command(fromStreamLine line: String) -> PhoneCommand? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["event"] as? String == "message",
              let message = obj["message"] as? String else { return nil }
        return PhoneCommand.parse(message)
    }

    nonisolated static func payload(_ note: PhoneNote, server: URL, topic: String, token: String) -> [String: Any] {
        let replyURL = server.appendingPathComponent(topic + "-reply").absoluteString
        var body: [String: Any] = [
            "topic": topic,
            "title": String(note.title.prefix(200)),
            "message": String(note.message.prefix(2000)),
            "priority": min(max(note.priority, 1), 5),
        ]
        if !note.tags.isEmpty { body["tags"] = note.tags }
        if !note.actions.isEmpty {
            body["actions"] = note.actions.prefix(3).map { action -> [String: Any] in
                var entry: [String: Any] = [
                    "action": "http", "label": action.label, "url": replyURL,
                    "method": "POST", "body": action.reply, "clear": true,
                ]
                if !token.isEmpty { entry["headers"] = ["Authorization": "Bearer \(token)"] }
                return entry
            }
        }
        return body
    }

    nonisolated static func publishRequest(_ note: PhoneNote, server: URL, topic: String, token: String) -> URLRequest? {
        guard !topic.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload(note, server: server, topic: topic, token: token)) else { return nil }
        // JSON publishing goes to the server root, with the topic inside the body.
        var request = URLRequest(url: server)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
