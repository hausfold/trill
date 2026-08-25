import Foundation

/// Minimal POSIX unix-domain-socket line server. One serial queue owns every
/// file descriptor; callers get parsed lines via a callback on that queue.
/// No third-party networking — the same "plain and ownable" trade pounce
/// makes with shell scripts.
final class SocketServer: @unchecked Sendable {
    /// One client, from a handler's point of view: an identity that outlives
    /// the line that produced it, and the wire back. Both matter for a verb
    /// that answers late — `trill ask` is replied to minutes after its
    /// request, and its banner has to come down if the caller hangs up first.
    struct Peer: Sendable {
        /// Stable for the life of the connection, and never reused. File
        /// descriptors *are* reused, which is exactly why this isn't one.
        let id: UInt64
        /// Write one line back. Safe to hold and safe to call late: a reply
        /// to a peer that has gone is dropped, not written to whoever
        /// inherited its descriptor.
        let reply: @Sendable (Data) -> Void
    }

    typealias LineHandler = @Sendable (_ line: Data, _ peer: Peer) -> Void
    /// A connection went away. Anything still waiting on it should stop.
    typealias CloseHandler = @Sendable (_ peer: UInt64) -> Void

    private let path: String
    private let queue = DispatchQueue(label: "com.hausfold.trill.socket")
    private let onLine: LineHandler
    private let onClose: CloseHandler

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var nextPeerID: UInt64 = 1

    private final class Connection {
        let source: DispatchSourceRead
        let peerID: UInt64
        var buffer = Data()
        init(source: DispatchSourceRead, peerID: UInt64) {
            self.source = source
            self.peerID = peerID
        }
    }

    init(path: String, onClose: @escaping CloseHandler = { _ in }, onLine: @escaping LineHandler) {
        self.path = path
        self.onClose = onClose
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
            let gone = connections.values.map(\.peerID)
            connections.values.forEach { $0.source.cancel() }
            connections.removeAll()
            gone.forEach(onClose)
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
        let connection = Connection(source: source, peerID: nextPeerID)
        nextPeerID += 1
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
            let peerID = connection.peerID
            onLine(Data(line), Peer(id: peerID) { [weak self] response in
                self?.queue.async { [weak self] in
                    self?.write(response + Data([0x0A]), to: fd, peer: peerID)
                }
            })
        }
    }

    private func write(_ data: Data, to fd: Int32, peer: UInt64) {
        // The peer check, not just the descriptor: a late reply (an ask
        // answered after its caller hung up) would otherwise land on whoever
        // the kernel handed that number to next.
        guard connections[fd]?.peerID == peer else { return }
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
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.source.cancel()
        onClose(connection.peerID)
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
