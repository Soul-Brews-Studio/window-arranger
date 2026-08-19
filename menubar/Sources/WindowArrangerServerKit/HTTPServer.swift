import Foundation
import Network

// Minimal zero-dependency HTTP/1.1 server over NWListener. Localhost JSON only:
// parse one request, hand it to the router, write one response, close. census
// polls at 1 Hz — connection reuse isn't worth the state machine.
struct HTTPRequest {
    let method: String
    let path: String       // path only, no query
    let query: [String: String]
    let headers: [String: String] // keys lowercased
    let body: Data
    let remoteIsLoopback: Bool
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/json"
    var extraHeaders: [(String, String)] = []
    var body: Data

    init(status: Int = 200, contentType: String = "application/json", body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }

    static func json(_ value: JSONish, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(value.jsonText.utf8))
    }
}

// Tiny bridge so routes can return either ordered-JSON text or a plain string.
struct JSONish { let jsonText: String }

final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "com.soulbrews.server.http", attributes: .concurrent)

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        let params = NWParameters.tcp
        // Loopback bind — OS-enforced local-only, same as the Bun server.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() {
        // A silent bind failure (port already taken — e.g. the Bun server still
        // owns 8900 at cutover) must be LOUD: exit nonzero so the supervisor
        // sees a crash loop instead of a deaf-but-running process.
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(
                    "HTTP listener failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            // Half-open/silent clients must not leak connections forever.
            self.queue.asyncAfter(deadline: .now() + 30) { [weak conn] in
                conn?.cancel()
            }
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }
            if let request = Self.parse(buf, conn: conn) {
                let response = self.handler(request)
                self.send(response, over: conn)
            } else if done {
                conn.cancel()
            } else if buf.count > 1 << 20 {
                conn.cancel() // request too large — nothing legitimate is 1MB here
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    // Returns nil while the request is still incomplete.
    private static func parse(_ buf: Data, conn: NWConnection) -> HTTPRequest? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Clamp Content-Length: negative would trap the range below (a one-line
        // malicious request killing the server), and 1MB+ has no legitimate use.
        let contentLength = max(0, min(Int(headers["content-length"] ?? "0") ?? 0, 1 << 20))
        let bodyStart = headerEnd.upperBound
        guard buf.count - bodyStart >= contentLength else { return nil } // body incomplete
        let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k = String(kv[0]).removingPercentEncoding else { continue }
                query[k] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            }
        }
        path = path.removingPercentEncoding ?? path

        // Loopback check for the POST guard — fail CLOSED on unknown.
        var loopback = false
        if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
            let h = "\(host)"
            loopback = h.hasPrefix("127.0.0.1") || h == "::1" || h.hasPrefix("::ffff:127.0.0.1")
        }

        return HTTPRequest(method: method, path: path, query: query,
                           headers: headers, body: body, remoteIsLoopback: loopback)
    }

    private func send(_ response: HTTPResponse, over conn: NWConnection) {
        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }
        var head = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        for (k, v) in response.extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
