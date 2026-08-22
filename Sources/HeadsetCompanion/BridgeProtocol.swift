import Foundation

/// Snapshot of the bridge state, serialized exactly as the HeadsetCompanion
/// JSON contract (all keys always present; `null` when unknown).
///
/// `lastUpdate` is deliberately stored as the ISO 8601 UTC *string* it is
/// serialized as, so encoding can never reformat it.
public struct BridgeStatus: Codable, Sendable, Equatable {
    /// Always `"headset-companion"`.
    public let app: String
    /// Bridge version (the bundle's `CFBundleShortVersionString`).
    public let version: String
    /// HTTP port the bridge listens on.
    public let port: Int
    /// Whether the BLE link to the headphones is up.
    public let connected: Bool
    /// Whether Sonora currently owns the media keys — true while the bridge
    /// holds the MediaRemote "now playing" claim, so the headset's touch
    /// panel and the keyboard's media keys are routed here. `false` means
    /// they keep their default OS behavior (the browser, usually).
    public let mediaKeys: Bool
    /// Peripheral name as advertised (trimmed); `nil` when empty/unknown.
    public let deviceName: String?
    /// Battery level 0–100 from GATT 0x2A19; `nil` before the first reading.
    public let battery: Int?
    /// ISO 8601 UTC timestamp of the last battery reading.
    public let lastUpdate: String?
    /// Whole seconds since the app started.
    public let uptime: Int?

    /// Version of the running bundle; "0.0.0" outside a bundle (tests).
    public static let bundleVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    public enum CodingKeys: String, CodingKey {
        case app, version, port, connected, mediaKeys, deviceName, battery, lastUpdate, uptime
    }

    /// Creates a status. `app` and `version` default to the contract values;
    /// the optional fields default to `nil` (encoded as JSON `null`).
    public init(
        app: String = "headset-companion",
        version: String = BridgeStatus.bundleVersion,
        port: Int,
        connected: Bool,
        mediaKeys: Bool = false,
        deviceName: String? = nil,
        battery: Int? = nil,
        lastUpdate: String? = nil,
        uptime: Int? = nil
    ) {
        self.app = app
        self.version = version
        self.port = port
        self.connected = connected
        self.mediaKeys = mediaKeys
        self.deviceName = deviceName
        self.battery = battery
        self.lastUpdate = lastUpdate
        self.uptime = uptime
    }
}

/// Pure, testable functions implementing the HeadsetCompanion HTTP contract.
///
/// The Chrome extension polls `GET http://127.0.0.1:8745/battery` (the same
/// body is served on `GET /health`) and may send CORS preflights.
public enum BridgeProtocol {

    /// Default loopback port; overridable via `SONORA_BRIDGE_PORT`.
    public static let defaultPort: Int = 8745

    /// Escapes a string for embedding in a JSON string literal (contract
    /// responses are hand-rolled, so this is shared with `statusJSON`).
    static func jsonEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        out = out.replacingOccurrences(of: "\t", with: "\\t")
        return out
    }

    /// Encodes a status as compact JSON (deterministic bytes).
    public static func statusJSON(_ status: BridgeStatus) -> Data {
        // Hand-rolled so the contract is exact: every key is always
        // present, unknown values are explicit nulls (JSONEncoder would
        // omit nil optionals).
        let esc = BridgeProtocol.jsonEscape
        let json = "{"
            + "\"app\":\"\(esc(status.app))\","
            + "\"version\":\"\(esc(status.version))\","
            + "\"port\":\(status.port),"
            + "\"connected\":\(status.connected ? "true" : "false"),"
            + "\"mediaKeys\":\(status.mediaKeys ? "true" : "false"),"
            + "\"deviceName\":\(status.deviceName.map { "\"\(esc($0))\"" } ?? "null"),"
            + "\"battery\":\(status.battery.map { String($0) } ?? "null"),"
            + "\"lastUpdate\":\(status.lastUpdate.map { "\"\(esc($0))\"" } ?? "null"),"
            + "\"uptime\":\(status.uptime.map { String($0) } ?? "null")"
            + "}"
        return Data(json.utf8)
    }

    /// Builds the complete HTTP/1.1 response bytes for a GET request.
    ///
    /// - `/battery` and `/health` → `200` with the status JSON.
    /// - any other path → `404` with `{"error":"not found"}`.
    ///
    /// A trailing query string is ignored (`/battery?x=1` → 200). If `status`
    /// is nil on a known path a `404` is returned; the server always has a
    /// status in practice.
    public static func makeResponse(path: String, status: BridgeStatus?) -> Data {
        switch cleanPath(path) {
        case "/battery", "/health":
            if let status {
                return buildResponse(statusLine: "HTTP/1.1 200 OK", body: statusJSON(status))
            }
            return buildResponse(statusLine: "HTTP/1.1 404 Not Found", body: notFoundBody)
        default:
            return buildResponse(statusLine: "HTTP/1.1 404 Not Found", body: notFoundBody)
        }
    }

    /// Builds the complete HTTP/1.1 response for `GET /events`:
    /// `{"app":"headset-companion","seq":<max-seq>,"mediaKeys":<bool>,"events":[...]}`
    /// where `events` are the media-key events newer than the caller's cursor
    /// (`seq > since`), oldest first. Any other path → `404`.
    ///
    /// The server does the `since` filtering and the long-poll wait; this
    /// function only owns the wire format.
    public static func makeEventsResponse(
        path: String,
        events: [MediaKeyEvent],
        seq: Int,
        mediaKeys: Bool
    ) -> Data {
        guard cleanPath(path) == "/events" else {
            return buildResponse(statusLine: "HTTP/1.1 404 Not Found", body: notFoundBody)
        }
        var list = ""
        for (i, event) in events.enumerated() {
            if i > 0 { list += "," }
            list += "{\"seq\":\(event.seq),\"type\":\"\(jsonEscape(event.type))\",\"at\":\"\(jsonEscape(event.at))\"}"
        }
        let body = "{"
            + "\"app\":\"headset-companion\","
            + "\"seq\":\(seq),"
            + "\"mediaKeys\":\(mediaKeys ? "true" : "false"),"
            + "\"events\":[\(list)]"
            + "}"
        return buildResponse(statusLine: "HTTP/1.1 200 OK", body: Data(body.utf8))
    }

    /// Longest long-poll a caller may ask for, in seconds.
    public static let maxEventsWait = 25

    /// Parses the `/events` query string: `since` (cursor, default 0, never
    /// negative) and `wait` (long-poll seconds, default 0, clamped to
    /// `maxEventsWait`). Unparseable values fall back to the defaults.
    public static func parseEventsQuery(_ path: String) -> (since: Int, wait: Int) {
        guard let question = path.firstIndex(of: "?") else { return (0, 0) }
        var since = 0
        var wait = 0
        for pair in path[path.index(after: question)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "since": since = max(0, value)
            case "wait": wait = min(max(0, value), maxEventsWait)
            default: break
            }
        }
        return (since, wait)
    }

    /// Builds the complete HTTP/1.1 response for `GET /debug`: recent log lines
    /// as `text/plain` (loopback debugging aid; the extension never calls it).
    public static func makeDebugResponse(text: String) -> Data {
        let body = Data(text.utf8)
        let headerBlock = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain; charset=utf-8",
            "Access-Control-Allow-Origin: *",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
        ].joined(separator: "\r\n")
        return Data((headerBlock + "\r\n").utf8) + body
    }

    /// Builds the complete HTTP/1.1 response bytes for a CORS preflight
    /// (`OPTIONS`): `204 No Content` with CORS headers and no body.
    public static func makeOptionsResponse() -> Data {
        let headerBlock = [
            "HTTP/1.1 204 No Content",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "",
        ].joined(separator: "\r\n")
        return Data((headerBlock + "\r\n").utf8)
    }

    /// Convenience to build a status from raw monitor state.
    public static func status(
        connected: Bool,
        deviceName: String?,
        battery: Int?,
        lastUpdate: String?,
        port: Int,
        uptime: Int,
        mediaKeys: Bool = false
    ) -> BridgeStatus {
        BridgeStatus(
            port: port,
            connected: connected,
            mediaKeys: mediaKeys,
            deviceName: deviceName,
            battery: battery,
            lastUpdate: lastUpdate,
            uptime: uptime
        )
    }

    // MARK: - Internal

    private static let notFoundBody = Data(#"{"error":"not found"}"#.utf8)

    /// Strips a query string, if any ("/battery?x=1" → "/battery").
    static func cleanPath(_ path: String) -> String {
        guard let question = path.firstIndex(of: "?") else { return path }
        return String(path[..<question])
    }

    private static func buildResponse(statusLine: String, body: Data) -> Data {
        let headerBlock = [
            statusLine,
            "Content-Type: application/json",
            "Access-Control-Allow-Origin: *",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
        ].joined(separator: "\r\n")
        return Data((headerBlock + "\r\n").utf8) + body
    }
}
