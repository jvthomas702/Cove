import Foundation
import Network

/// A tiny HTTP server bound to the loopback interface. Hooks and scripts talk to Cove through it:
///
///   GET  /health        → {"ok":true}
///   POST /event         → generic event (see CoveEvent)
///   POST /hook/claude   → raw Claude Code hook payload (piped from stdin)
///   POST /hook/codex    → raw Codex `notify` payload
final class EventServer {
    typealias Handler = @MainActor (_ method: String, _ path: String, _ body: Data) -> (Int, String)

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private static let maxBody = 8 * 1024 * 1024

    var onState: (@MainActor (String) -> Void)?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            let text: String?
            switch state {
            case .ready: text = "listening on :\(self?.port ?? 0)"
            case .failed(let error): text = "server error: \(error.localizedDescription)"
            default: text = nil
            }
            if let text { MainActor.assumeIsolated { self?.onState?(text) } }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let (status, body) = MainActor.assumeIsolated { self.handler(request.method, request.path, request.body) }
                self.respond(connection, status: status, body: body)
            case .needsContinue:
                // Client sent "Expect: 100-continue"; tell it to go ahead with the body.
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.receive(connection, buffer: buffer)
            case .incomplete:
                if isComplete || error != nil || buffer.count > Self.maxBody {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .invalid:
                self.respond(connection, status: 400, body: #"{"error":"bad request"}"#)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        default: reason = "Bad Request"
        }
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case needsContinue
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return .invalid }

        var contentLength = 0
        var expectsContinue = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { contentLength = Int(value) ?? 0 }
            if name == "expect", value.lowercased() == "100-continue" { expectsContinue = true }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.endIndex - bodyStart
        if available < contentLength {
            // Only ask for the body once: the 100 Continue goes out when nothing after the headers has arrived yet.
            return (expectsContinue && available == 0) ? .needsContinue : .incomplete
        }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let rawPath = String(requestLine[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, body: body))
    }
}
