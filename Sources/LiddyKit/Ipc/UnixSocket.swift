import Foundation

/// Shared low-level helpers for AF_UNIX stream sockets.
enum UnixSocket {
    /// `sun_path` is a fixed 104-byte buffer; anything longer is silently truncated,
    /// so refuse it loudly instead.
    static let maxPathLength = 103

    static func makeAddress(_ path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathLength else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Capacity is read up front: touching `addr.sun_path` inside the closure
        // would overlap with the exclusive access the closure already holds.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                strncpy(dst, path, UnixSocket.maxPathLength)
            }
        }
        return addr
    }

    static func withSockAddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                body(generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// The largest line this will accumulate before giving up on the connection.
    /// Every real request here is a few hundred bytes of JSON; the cap exists because
    /// the server side of this read runs as **root** in the helper, and a client that
    /// never sends a newline would otherwise grow a root process's memory without
    /// bound. 1 MiB is four orders of magnitude above the real traffic.
    static let maxLineByte = 1 << 20

    /// Read until newline. Returns nil at EOF, and also at `maxLineByte` without one —
    /// the caller treats both the same way, by dropping the connection.
    static func readLine(fd: Int32, buffer: inout Data) -> Data? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer = Data(buffer[buffer.index(after: index)...])
                return Data(line)
            }
            guard buffer.count <= maxLineByte else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base, remaining.count)
            }
            guard written > 0 else { return false }
            remaining = Data(remaining.dropFirst(written))
        }
        return true
    }

    static func setReceiveTimeout(fd: Int32, second: Int) {
        var tv = timeval(tv_sec: second, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Identifies one accepted connection for the lifetime of that connection.
///
/// It exists because "a connection closed" is not the same event as "*the* connection
/// closed", and the helper's deadman switch depends on telling them apart.
public struct ConnectionId: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// Line-delimited JSON server over AF_UNIX. One dispatch queue per connection —
/// the connection count here is a handful, not a thundering herd.
public final class LineSocketServer {
    public typealias Handler = (Data, ConnectionId) -> Data?
    /// Fired when a connection closes, naming which one. The helper's deadman switch
    /// hangs off this and reverts only for the connection that armed the toggle.
    public typealias CloseHandler = (ConnectionId) -> Void

    private let path: String
    private let handler: Handler
    private let onClose: CloseHandler?
    private var listenFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.liddy.socket.accept")
    private var isStopped = false
    private var nextConnectionRaw: UInt64 = 0

    public init(path: String, onClose: CloseHandler? = nil, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.onClose = onClose
    }

    /// - Parameters:
    ///   - mode: POSIX permission for the socket file.
    ///   - ownerUid: chown the socket to this uid so a root-owned helper socket is
    ///     still reachable by exactly one user, rather than world-writable.
    public func start(mode: mode_t = 0o600, ownerUid: uid_t? = nil) throws {
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw SocketError.cannotCreate(String(cString: strerror(errno))) }

        guard var addr = UnixSocket.makeAddress(path) else {
            throw SocketError.cannotBind("path longer than \(UnixSocket.maxPathLength) bytes")
        }
        let bound = UnixSocket.withSockAddr(&addr) { pointer, length in
            bind(listenFd, pointer, length)
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(listenFd)
            throw SocketError.cannotBind(message)
        }

        chmod(path, mode)
        if let ownerUid { chown(path, ownerUid, gid_t(0)) }

        guard listen(listenFd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(listenFd)
            throw SocketError.cannotBind(message)
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while !isStopped {
            let fd = accept(listenFd, nil, nil)
            guard fd >= 0 else {
                if isStopped { return }
                usleep(50_000)
                continue
            }
            nextConnectionRaw += 1
            let id = ConnectionId(raw: nextConnectionRaw)
            DispatchQueue(label: "com.liddy.socket.connection").async { [weak self] in
                self?.serve(fd: fd, id: id)
            }
        }
    }

    private func serve(fd: Int32, id: ConnectionId) {
        defer {
            close(fd)
            onClose?(id)
        }
        var buffer = Data()
        while let line = UnixSocket.readLine(fd: fd, buffer: &buffer) {
            guard !line.isEmpty else { continue }
            if let reply = handler(line, id) {
                var out = reply
                out.append(0x0A)
                guard UnixSocket.writeAll(fd: fd, data: out) else { return }
            }
        }
    }

    public func stop() {
        isStopped = true
        // Reset the descriptor, don't just close it. `stop()` runs twice on quit — the
        // menu's Quit button shuts the model down and then `applicationWillTerminate`
        // does it again — and without this the second call closes a number the kernel
        // may already have handed to something else. Harmless while the process is
        // exiting; a genuine close-someone-else's-socket bug anywhere it is not.
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(path)
    }
}

/// Short-lived request/response client. Also usable as a persistent connection when
/// the caller needs the server to notice a disconnect (see the helper heartbeat).
public final class LineSocketClient {
    private let path: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private let lock = NSLock()

    public init(path: String) { self.path = path }

    deinit { disconnect() }

    public var isConnected: Bool { fd >= 0 }

    public func connect(timeoutSecond: Int = 5) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }

        let newFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFd >= 0 else { throw SocketError.cannotCreate(String(cString: strerror(errno))) }

        guard var addr = UnixSocket.makeAddress(path) else {
            close(newFd)
            throw SocketError.cannotConnect("path too long")
        }
        let joined = UnixSocket.withSockAddr(&addr) { pointer, length in
            Darwin.connect(newFd, pointer, length)
        }
        guard joined == 0 else {
            let message = String(cString: strerror(errno))
            close(newFd)
            throw SocketError.cannotConnect(message)
        }
        UnixSocket.setReceiveTimeout(fd: newFd, second: timeoutSecond)
        fd = newFd
        buffer = Data()
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Send one request, read one response. Drops the connection on any failure so
    /// the next call reconnects cleanly rather than reusing a half-dead socket.
    public func roundTrip<Request: Encodable, Response: Decodable>(
        _ request: Request,
        expecting: Response.Type
    ) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SocketError.closed }

        let payload = try Wire.encodeLine(request)
        guard UnixSocket.writeAll(fd: fd, data: payload) else {
            close(fd); fd = -1
            throw SocketError.closed
        }
        guard let line = UnixSocket.readLine(fd: fd, buffer: &buffer) else {
            close(fd); fd = -1
            throw SocketError.closed
        }
        return try Wire.decode(Response.self, from: line)
    }
}
