import Foundation
import Darwin

/// Compatibility adapter for the installed desktop's same-user coordination socket.
/// It never launches a second server, answers an approval, or takes ownership of a chat.
final class CodexDesktopConnection: @unchecked Sendable {
    var onCatalog: ((Result<[CodexChat], Error>) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onState: ((String, CodexChatStatus) -> Void)?
    private let queue = DispatchQueue(label: "cove.codex-desktop", qos: .utility)
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var client = ""
    private var pending: [String: (Date, (Result<[String: Any], Error>) -> Void)] = [:]
    private var followed = Set<String>()
    private var states: [String: [String: Any]] = [:]
    private var revisions: [String: Int] = [:]
    private var catalog: [CodexChat] = []
    private var tick = 0
    private var stopped = false
    private let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }
    private func failure(_ message: String) -> Error { AgentLauncher.LaunchError.message(message) }

    func start() { queue.async { [self] in
        guard timer == nil else { return }
        stopped = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    } }
    func stop() { queue.async { [self] in stopped = true; timer?.cancel(); timer = nil; disconnect() } }
    func refresh() { queue.async { [self] in loadCatalog() } }
    func request(_ method: String, _ params: [String: Any], version: Int,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in requestOnQueue(method, params, version: version, completion: completion) }
    }
    private func requestOnQueue(_ method: String, _ params: [String: Any], version: Int,
                                completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard fd >= 0, !client.isEmpty || method == "initialize" else { completion(.failure(failure("Codex is disconnected."))); return }
        let id = UUID().uuidString
        pending[id] = (Date().addingTimeInterval(20), completion)
        write(["type": "request", "requestId": id, "sourceClientId": client, "version": version,
               "method": method, "params": params, "timeoutMs": 18000])
    }
    private func poll() {
        guard !stopped else { return }
        if tick % 15 == 0 { loadCatalog() }
        tick += 1
        if fd < 0 { connect() }
        let expired = pending.filter { $0.value.0 < Date() }
        for (id, value) in expired { pending[id] = nil; value.1(.failure(failure("Codex did not confirm delivery."))) }
        for (id, object) in states { if let state = CodexChatStatus(object) { onState?(id, state) } }
    }
    private func loadCatalog() {
        do { catalog = try CodexChatCatalog.read(home: home); onCatalog?(.success(catalog)); followChats() }
        catch { onCatalog?(.failure(error)) }
    }
    private func connect() {
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var info = stat(), directory = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
              lstat(home.appendingPathComponent("ipc").path, &directory) == 0,
              directory.st_uid == getuid(), directory.st_mode & 0o022 == 0 else { return }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(socketFD); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(socketFD); return }
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(socketFD); return }
        fd = socketFD
        let reader = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        reader.setEventHandler { [weak self] in self?.read() }
        // Cancellation owns the descriptor, so a queued handler cannot read a reused descriptor.
        reader.setCancelHandler { Darwin.close(socketFD) }
        self.reader = reader; reader.resume()
        requestOnQueue("initialize", ["clientType": "cove"], version: 0) { [weak self] result in
            guard let self else { return }
            guard case .success(let reply) = result, let id = reply["clientId"] as? String else { self.disconnect(); return }
            self.client = id; self.onConnection?(true); self.followChats()
        }
    }
    private func followChats() {
        guard !client.isEmpty else { return }
        let desired = Set(catalog.map(\.id))
        for id in followed.subtracting(desired) { broadcastFollowing(id, false); states[id] = nil }
        for id in desired.subtracting(followed) { broadcastFollowing(id, true) }
        followed = desired
    }
    private func broadcastFollowing(_ id: String, _ following: Bool) {
        write(["type": "broadcast", "sourceClientId": client, "method": "thread-stream-following-changed", "version": 1,
               "params": ["hostId": "local", "conversationId": id, "following": following]])
    }
    private func write(_ object: [String: Any]) {
        guard fd >= 0, let payload = try? JSONSerialization.data(withJSONObject: object), payload.count < 4_000_000 else { return }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: 4); frame.append(payload)
        // Commands are small. A partial/nonblocking write leaves delivery uncertain; never replay it.
        let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if sent != frame.count { disconnect() }
    }
    private func read() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while fd >= 0 {
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            if count == 0 { disconnect(); return }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { disconnect() }; break }
            buffer.append(contentsOf: chunk.prefix(count))
            while buffer.count >= 4 {
                let size = buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                guard size > 0, size <= 64 * 1024 * 1024 else { disconnect(); return }
                guard buffer.count >= Int(size) + 4 else { break }
                let payload = buffer.subdata(in: 4..<(Int(size) + 4)); buffer.removeSubrange(0..<(Int(size) + 4))
                if let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] { handle(object) }
            }
        }
    }
    private func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "response":
            guard let id = object["requestId"] as? String, let completion = pending.removeValue(forKey: id)?.1 else { return }
            if object["resultType"] as? String == "success" { completion(.success(object["result"] as? [String: Any] ?? [:])) }
            else { completion(.failure(failure(object["error"] as? String ?? "Codex rejected the request."))) }
        case "client-discovery-request":
            // Cove observes only; the desktop remains the chat owner and permission handler.
            if let id = object["requestId"] { write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]]) }
        case "broadcast":
            guard object["method"] as? String == "thread-stream-state-changed", object["version"] as? Int == 11,
                  let params = object["params"] as? [String: Any], params["hostId"] as? String == "local",
                  let id = params["conversationId"] as? String, followed.contains(id),
                  let change = params["change"] as? [String: Any] else { return }
            // Discard all transcript/tool contents. Keep only runtime state and its flags.
            if change["type"] as? String != "snapshot", revisions[id] != change["baseRevision"] as? Int {
                states[id] = nil; broadcastFollowing(id, true); return
            }
            revisions[id] = change["revision"] as? Int
            if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any],
               let runtime = state["threadRuntimeStatus"] as? [String: Any] { states[id] = runtime }
            else if let patches = change["patches"] as? [[String: Any]] {
                for patch in patches {
                    guard let path = patch["path"] as? [Any], path.first as? String == "threadRuntimeStatus" else { continue }
                    if path.count == 1 { states[id] = patch["value"] as? [String: Any] }
                    else if path.count == 2, let key = path[1] as? String { states[id]?[key] = patch["value"] }
                    else { states[id] = nil; broadcastFollowing(id, true) }
                }
            }
            if let runtime = states[id], let state = CodexChatStatus(runtime) { onState?(id, state) }
        default: break
        }
    }
    private func disconnect() {
        fd = -1; reader?.cancel(); reader = nil; buffer.removeAll(); client = ""
        followed.removeAll(); states.removeAll(); revisions.removeAll()
        let callbacks = pending.values.map(\.1); pending.removeAll()
        for completion in callbacks { completion(.failure(failure("Codex connection closed. Check the chat before retrying."))) }
        onConnection?(false)
    }
}
