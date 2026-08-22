import Foundation

/// Loopback-only HTTP/1.1 server for the HeadsetCompanion contract.
///
/// Implemented directly on POSIX sockets so it binds to `127.0.0.1` with no
/// extra frameworks, entitlements, or launchd configuration. For each
/// connection: read until the request line is complete, route it through
/// the pure `BridgeProtocol` functions, send the response, close.
public final class BridgeServer {

    /// The port the server listens on (validated to 1–65535).
    public let port: Int

    private let statusProvider: () -> BridgeStatus
    private let eventSource: MediaKeyEventSource?
    private var listenFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    /// Connections are served here, off the accept loop: an `/events` long
    /// poll parks its thread for up to 25 s and must not stall the listener
    /// or any other request.
    private let connectionQueue = DispatchQueue(
        label: "io.sonora.headsetcompanion.connection", attributes: .concurrent
    )
    private static let maxRequestBytes = 8192

    /// Creates a server.
    ///
    /// - Parameters:
    ///   - port: explicit port; when `nil`, resolved from the environment
    ///     (`SONORA_BRIDGE_PORT`) or the default 8745.
    ///   - eventSource: media-key buffer backing `GET /events`; when `nil`
    ///     the endpoint answers with an empty, inactive event list.
    ///   - statusProvider: closure returning the current status; called for
    ///     every request.
    public init(
        port: Int? = nil,
        eventSource: MediaKeyEventSource? = nil,
        statusProvider: @escaping () -> BridgeStatus
    ) {
        let candidate = port ?? BridgeServer.portFromEnvironment()
        self.port = (1...65535).contains(candidate) ? candidate : BridgeProtocol.defaultPort
        self.eventSource = eventSource
        self.statusProvider = statusProvider
    }

    /// Resolves the HTTP port: `$SONORA_BRIDGE_PORT` when set and valid,
    /// otherwise `BridgeProtocol.defaultPort` (8745).
    public static func portFromEnvironment() -> Int {
        if let raw = ProcessInfo.processInfo.environment["SONORA_BRIDGE_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Int(raw), (1...65535).contains(value) {
            return value
        }
        return BridgeProtocol.defaultPort
    }

    /// Starts listening on `127.0.0.1:<port>`.
    ///
    /// Logs `[bridge] listening on http://127.0.0.1:<port>` once ready, and a
    /// helpful error when the port is already taken.
    @discardableResult
    public func start() -> Bool {
        guard listenFD < 0 else { return true }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            BridgeLog.log("[bridge] ERROR: socket() failed: \(String(cString: strerror(errno)))")
            return false
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            let err = String(cString: strerror(errno))
            close(fd)
            BridgeLog.log("[bridge] ERROR: could not bind 127.0.0.1:\(port): \(err). "
                + "Quit the other HeadsetCompanion instance, or re-run with "
                + "SONORA_BRIDGE_PORT=<free-port> swift run")
            return false
        }
        guard listen(fd, 16) == 0 else {
            BridgeLog.log("[bridge] ERROR: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }

        listenFD = fd
        let queue = DispatchQueue(label: "io.sonora.headsetcompanion.server")
        acceptQueue = queue
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        BridgeLog.log("[bridge] listening on http://127.0.0.1:\(port)")
        return true
    }

    /// Stops accepting new connections.
    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        acceptQueue = nil
        BridgeLog.log("[bridge] stopped")
    }

    // MARK: - Connection handling

    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            connectionQueue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handleClient(fd: client)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0 ..< n])
            guard let line = Self.firstRequestLine(in: received) else {
                if received.count > Self.maxRequestBytes { break }
                continue
            }
            let (method, path) = Self.parseRequestLine(line)
            let pathNoQuery = String(path.split(separator: "?").first.map(String.init) ?? "")
            let response: Data
            if method.uppercased() == "OPTIONS" {
                response = BridgeProtocol.makeOptionsResponse()
            } else if pathNoQuery == "/debug" {
                response = BridgeProtocol.makeDebugResponse(
                    text: BridgeLog.recentLines(80)
                )
            } else if pathNoQuery == "/events" {
                response = eventsResponse(path: path)
            } else {
                response = BridgeProtocol.makeResponse(path: path, status: statusProvider())
            }
            var offset = 0
            while offset < response.count {
                let written = response.withUnsafeBytes { ptr in
                    write(fd, ptr.baseAddress!.advanced(by: offset), response.count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
            break
        }
    }

    /// Answers `GET /events?since=<int>&wait=<seconds>`.
    ///
    /// Every call marks a Sonora consumer as present (that's what lets the
    /// `.auto` policy claim the keys). With `wait > 0` and nothing
    /// newer than `since`, the connection is held on this connection's own
    /// thread until an event arrives or the wait elapses.
    private func eventsResponse(path: String) -> Data {
        let query = BridgeProtocol.parseEventsQuery(path)
        guard let eventSource else {
            return BridgeProtocol.makeEventsResponse(
                path: path, events: [], seq: 0, mediaKeys: false
            )
        }
        eventSource.noteConsumerSeen()
        let result = query.wait > 0
            ? eventSource.events(since: query.since, waitingUpTo: TimeInterval(query.wait))
            : eventSource.events(since: query.since)
        return BridgeProtocol.makeEventsResponse(
            path: path,
            events: result.events,
            seq: result.seq,
            mediaKeys: eventSource.mediaKeysActive
        )
    }

    // MARK: - Request parsing

    /// Returns the complete first request line ("GET /battery HTTP/1.1"),
    /// or `nil` while it is still arriving.
    static func firstRequestLine(in data: Data) -> String? {
        let bytes = [UInt8](data)
        for i in bytes.indices where bytes[i] == 0x0A {
            // The request line is always the first line: 0..<i (trim trailing CR).
            var end = i
            if end > 0 && bytes[end - 1] == 0x0D { end -= 1 }
            return String(decoding: bytes[0 ..< end], as: UTF8.self)
        }
        return nil // no complete line yet
    }

    /// Splits "GET /battery HTTP/1.1" into (method, path).
    static func parseRequestLine(_ line: String) -> (method: String, path: String) {
        let parts = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0) }
        guard parts.count >= 2 else { return ("", "") }
        return (parts[0], parts[1])
    }
}
