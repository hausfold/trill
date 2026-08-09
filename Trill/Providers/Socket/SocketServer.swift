import Foundation

/// Minimal POSIX unix-domain-socket line server. One serial queue owns every
/// file descriptor; callers get parsed lines via a callback on that queue.
/// No third-party networking — the same "plain and ownable" trade pounce
/// makes with shell scripts.
final class SocketServer: @unchecked Sendable {
    typealias LineHandler = @Sendable (_ line: Data, _ reply: @escaping @Sendable (Data) -> Void) -> Void

    private let path: String
    private let queue = DispatchQueue(label: "com.hausfold.trill.socket")
    private let onLine: LineHandler

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        init(source: DispatchSourceRead) { self.source = source }
    }

    init(path: String, onLine: @escaping LineHandler) {
        self.path = path
        self.onLine = onLine
    }

    /// Bind + listen. Throws with a readable message; the socket provider
    /// turns that into `ProviderHealth.unavailable`, never a crash.
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
            unlink(path)
        }
    }

    private func startLocked() throws {
        // A stale socket file from a crashed run blocks bind; a *live* one
        // means another trill owns the lane. connect() tells them apart.
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(to: path) {
                throw SocketError("another trill instance is already listening at \(path)")
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard ok else { close(fd); throw SocketError("socket path too long: \(path)") }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw SocketError.errno("bind") }
        // Owner-only: events can carry private text.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); unlink(path); throw SocketError.errno("listen") }

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
                // A peer that streams unbounded garbage gets cut, not buffered.
                if connection.buffer.count > 1024 * 1024 { return drop(fd) }
            } else if n == 0 {
                return drop(fd)
            } else {
                break // EAGAIN — wait for the next readability event
            }
        }
        deliverLines(from: connection, fd: fd)
    }

    private func deliverLines(from connection: Connection, fd: Int32) {
        while let nl = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer.prefix(upTo: nl)
            connection.buffer.removeSubrange(...nl)
            guard !line.isEmpty else { continue }
            onLine(Data(line)) { [weak self] response in
                self?.queue.async { self?.write(response + Data([0x0A]), to: fd) }
            }
        }
    }

    private func write(_ data: Data, to fd: Int32) {
        guard connections[fd] != nil else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.source.cancel()
    }

    private static func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        } == 0
    }
}

struct SocketError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
    static func errno(_ call: String) -> SocketError {
        SocketError("\(call) failed: \(String(cString: strerror(Foundation.errno)))")
    }
}
