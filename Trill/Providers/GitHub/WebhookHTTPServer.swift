import Foundation

/// A parsed HTTP request. `parse` is static and pure (the
/// `SocketProvider.handle` pattern) so the wire handling is testable without
/// a socket.
struct HTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Keys lowercased — HTTP headers are case-insensitive and cloudflared
    /// exercises that freedom.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable {
        /// Keep reading — the head or the declared body hasn't all arrived.
        case incomplete
        /// Not HTTP we accept (bad request line, or a body past the cap).
        case invalid
        case complete(HTTPRequest)
    }

    /// GitHub caps webhook payloads at 25 MB but the events this bridge maps
    /// are a few KB; anything past this cap is not a delivery we'd banner.
    static let bodyLimit = 2 * 1024 * 1024

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }

        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= bodyLimit else { return .invalid }
        let bodyStart = headEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            return .incomplete
        }

        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
        ))
    }
}

/// Minimal HTTP/1.1 receiver for webhook deliveries. Binds 127.0.0.1 only —
/// the public leg is the tunnel's job (haus's wiring, not trill's) — answers
/// one request per connection with an empty status-only response, and closes.
/// Same POSIX-and-a-serial-queue shape as `SocketServer`: no third-party
/// networking, every fd owned by one queue.
final class WebhookHTTPServer: @unchecked Sendable {
    /// Handle a complete request, return the HTTP status to answer with.
    typealias Handler = @Sendable (HTTPRequest) -> Int

    private let port: UInt16
    private let queue = DispatchQueue(label: "com.hausfold.trill.github-http")
    private let handler: Handler

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        init(source: DispatchSourceRead) { self.source = source }
    }

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Can the bridge bind its port right now? Probed before `start` so a
    /// squatting process becomes a visible health reason, not a silent
    /// restart loop.
    static func portAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port: port)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        } == 0
    }

    func start() throws {
        try queue.sync { try startLocked() }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            connections.values.forEach { $0.source.cancel() }
            connections.removeAll()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return addr
    }

    private func startLocked() throws {
        guard listenFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno("socket") }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = Self.loopback(port: port)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw SocketError.errno("bind 127.0.0.1:\(port)") }
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.errno("listen") }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let connection = Connection(source: source)
        connections[fd] = connection
        source.setEventHandler { [weak self] in self?.readAvailable(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readAvailable(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                connection.buffer.append(contentsOf: chunk[0..<n])
                // Head cap + body cap with headroom; past that it's not a
                // webhook, it's a hose.
                if connection.buffer.count > HTTPRequest.bodyLimit + 128 * 1024 { return drop(fd) }
            } else if n == 0 {
                return drop(fd)
            } else {
                break // EAGAIN — wait for the next readability event
            }
        }

        switch HTTPRequest.parse(connection.buffer) {
        case .incomplete:
            break
        case .invalid:
            respond(400, to: fd)
        case .complete(let request):
            respond(handler(request), to: fd)
        }
    }

    /// Status line only, then close: webhook deliverers read the code and
    /// nothing else, and one-shot connections keep the state machine flat.
    private func respond(_ status: Int, to fd: Int32) {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 405: "Method Not Allowed"]
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        Data(head.utf8).withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        drop(fd)
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.source.cancel()
    }
}
