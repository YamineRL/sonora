import XCTest
@testable import HeadsetCompanion

/// Unit tests for the fixed JSON/HTTP contract between the bridge and the
/// Chrome extension. No Bluetooth, no network sockets.
final class BridgeProtocolTests: XCTestCase {

    private func fullStatus() -> BridgeStatus {
        BridgeStatus(
            port: 8745,
            connected: true,
            deviceName: "WH-1000XM4",
            battery: 87,
            lastUpdate: "2026-08-21T01:00:00Z",
            uptime: 123
        )
    }

    // MARK: - statusJSON

    func testStatusJSONRoundTrip() throws {
        let status = fullStatus()
        let data = BridgeProtocol.statusJSON(status)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains(#""app":"headset-companion""#), "missing app: \(json)")
        XCTAssertTrue(json.contains("\"version\":\"\(BridgeStatus.bundleVersion)\""), json)
        XCTAssertTrue(json.contains(#""port":8745"#), json)
        XCTAssertTrue(json.contains(#""connected":true"#), json)
        XCTAssertTrue(json.contains(#""deviceName":"WH-1000XM4""#), json)
        XCTAssertTrue(json.contains(#""battery":87"#), json)
        XCTAssertTrue(json.contains(#""lastUpdate":"2026-08-21T01:00:00Z""#), json)
        XCTAssertTrue(json.contains(#""uptime":123"#), json)

        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    func testStatusJSONIsDeterministic() {
        let a = BridgeProtocol.statusJSON(fullStatus())
        let b = BridgeProtocol.statusJSON(fullStatus())
        XCTAssertEqual(a, b)
    }

    func testNullFieldsAreEncodedAsNull() throws {
        let status = BridgeStatus(port: 8745, connected: false)
        let data = BridgeProtocol.statusJSON(status)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains(#""connected":false"#), json)
        XCTAssertTrue(json.contains(#""deviceName":null"#), json)
        XCTAssertTrue(json.contains(#""battery":null"#), json)
        XCTAssertTrue(json.contains(#""lastUpdate":null"#), json)
        XCTAssertTrue(json.contains(#""uptime":null"#), json)

        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    // MARK: - makeResponse

    func testMakeResponseBattery() throws {
        let status = fullStatus()
        let response = BridgeProtocol.makeResponse(path: "/battery", status: status)
        let text = String(decoding: response, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"), text)
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: *\r\n"), text)
        XCTAssertTrue(text.contains("Connection: close\r\n"), text)

        let separator = "\r\n\r\n"
        let parts = text.components(separatedBy: separator)
        XCTAssertEqual(parts.count, 2, "expected exactly one blank line: \(text)")
        let headers = parts[0]
        let body = parts[1]

        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("Content-Length: ") }
            .flatMap { Int($0.dropFirst("Content-Length: ".count)) }
        XCTAssertEqual(contentLength, body.utf8.count, "Content-Length must match body")

        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: Data(body.utf8))
        XCTAssertEqual(decoded, status)
        XCTAssertTrue(text.hasSuffix(body), "response must end with the JSON body")
    }

    func testMakeResponseHealthIs200() {
        let health = String(
            decoding: BridgeProtocol.makeResponse(path: "/health", status: fullStatus()),
            as: UTF8.self
        )
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200 OK\r\n"), health)
        XCTAssertTrue(health.contains("Access-Control-Allow-Origin: *\r\n"), health)
    }

    func testMakeResponseUnknownPathIs404() {
        let nope = String(
            decoding: BridgeProtocol.makeResponse(path: "/nope", status: fullStatus()),
            as: UTF8.self
        )
        XCTAssertTrue(nope.hasPrefix("HTTP/1.1 404 Not Found\r\n"), nope)
        let body = nope.components(separatedBy: "\r\n\r\n").last ?? ""
        XCTAssertEqual(body, #"{"error":"not found"}"#)
    }

    func testMakeResponseIgnoresQueryString() {
        let text = String(
            decoding: BridgeProtocol.makeResponse(path: "/battery?cachebust=1", status: fullStatus()),
            as: UTF8.self
        )
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
    }

    // MARK: - mediaKeys field

    func testMediaKeysDefaultsToFalseAndIsSerialized() throws {
        let off = String(decoding: BridgeProtocol.statusJSON(fullStatus()), as: UTF8.self)
        XCTAssertTrue(off.contains(#""mediaKeys":false"#), off)

        let on = BridgeStatus(port: 8745, connected: true, mediaKeys: true)
        let json = String(decoding: BridgeProtocol.statusJSON(on), as: UTF8.self)
        XCTAssertTrue(json.contains(#""mediaKeys":true"#), json)

        let decoded = try JSONDecoder().decode(
            BridgeStatus.self, from: BridgeProtocol.statusJSON(on)
        )
        XCTAssertEqual(decoded, on)
    }

    func testStatusHelperCarriesMediaKeys() {
        let status = BridgeProtocol.status(
            connected: true, deviceName: nil, battery: nil, lastUpdate: nil,
            port: 8745, uptime: 0, mediaKeys: true
        )
        XCTAssertTrue(status.mediaKeys)
    }

    // MARK: - makeEventsResponse

    private func eventsBody(
        path: String = "/events",
        events: [MediaKeyEvent],
        seq: Int,
        mediaKeys: Bool = true
    ) throws -> [String: Any] {
        let text = String(
            decoding: BridgeProtocol.makeEventsResponse(
                path: path, events: events, seq: seq, mediaKeys: mediaKeys
            ),
            as: UTF8.self
        )
        let body = text.components(separatedBy: "\r\n\r\n").last ?? ""
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        return json
    }

    func testMakeEventsResponseShape() throws {
        let events = [
            MediaKeyEvent(seq: 1, type: "play-pause", at: "2026-08-21T01:00:00Z"),
            MediaKeyEvent(seq: 2, type: "next", at: "2026-08-21T01:00:01Z"),
        ]
        let text = String(
            decoding: BridgeProtocol.makeEventsResponse(
                path: "/events", events: events, seq: 2, mediaKeys: true
            ),
            as: UTF8.self
        )
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"), text)
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: *\r\n"), text)
        XCTAssertTrue(text.contains("Connection: close\r\n"), text)

        let json = try eventsBody(events: events, seq: 2)
        XCTAssertEqual(json["app"] as? String, "headset-companion")
        XCTAssertEqual(json["seq"] as? Int, 2)
        XCTAssertEqual(json["mediaKeys"] as? Bool, true)
        let list = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["seq"] as? Int, 1)
        XCTAssertEqual(list[0]["type"] as? String, "play-pause")
        XCTAssertEqual(list[0]["at"] as? String, "2026-08-21T01:00:00Z")
        XCTAssertEqual(list[1]["type"] as? String, "next")
    }

    func testMakeEventsResponseEmptyList() throws {
        let json = try eventsBody(events: [], seq: 7, mediaKeys: false)
        XCTAssertEqual(json["seq"] as? Int, 7)
        XCTAssertEqual(json["mediaKeys"] as? Bool, false)
        XCTAssertEqual((json["events"] as? [[String: Any]])?.count, 0)
    }

    func testMakeEventsResponseKeepsTheQueryStringPath() throws {
        let json = try eventsBody(
            path: "/events?since=1&wait=5",
            events: [MediaKeyEvent(seq: 2, type: "previous", at: "2026-08-21T01:00:02Z")],
            seq: 2
        )
        XCTAssertEqual((json["events"] as? [[String: Any]])?.first?["type"] as? String, "previous")
    }

    func testMakeEventsResponseOnAnotherPathIs404() {
        let text = String(
            decoding: BridgeProtocol.makeEventsResponse(
                path: "/nope", events: [], seq: 0, mediaKeys: true
            ),
            as: UTF8.self
        )
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"), text)
    }

    // MARK: - parseEventsQuery

    func testParseEventsQueryDefaults() {
        let none = BridgeProtocol.parseEventsQuery("/events")
        XCTAssertEqual(none.since, 0)
        XCTAssertEqual(none.wait, 0)

        let empty = BridgeProtocol.parseEventsQuery("/events?")
        XCTAssertEqual(empty.since, 0)
        XCTAssertEqual(empty.wait, 0)
    }

    func testParseEventsQueryValues() {
        let both = BridgeProtocol.parseEventsQuery("/events?since=12&wait=5")
        XCTAssertEqual(both.since, 12)
        XCTAssertEqual(both.wait, 5)

        let reversed = BridgeProtocol.parseEventsQuery("/events?wait=3&since=4")
        XCTAssertEqual(reversed.since, 4)
        XCTAssertEqual(reversed.wait, 3)

        let onlySince = BridgeProtocol.parseEventsQuery("/events?since=9")
        XCTAssertEqual(onlySince.since, 9)
        XCTAssertEqual(onlySince.wait, 0)
    }

    func testParseEventsQueryClampsAndIgnoresGarbage() {
        XCTAssertEqual(BridgeProtocol.parseEventsQuery("/events?wait=999").wait, 25)
        XCTAssertEqual(BridgeProtocol.parseEventsQuery("/events?wait=-4").wait, 0)
        XCTAssertEqual(BridgeProtocol.parseEventsQuery("/events?since=-4").since, 0)

        let garbage = BridgeProtocol.parseEventsQuery("/events?since=abc&wait=&x=1&foo")
        XCTAssertEqual(garbage.since, 0)
        XCTAssertEqual(garbage.wait, 0)
    }

    // MARK: - makeOptionsResponse

    func testMakeOptionsResponse() {
        let response = BridgeProtocol.makeOptionsResponse()
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 204 No Content\r\n"), text)
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: *\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"), "204 must have no body")
    }

    // MARK: - Helpers

    func testDefaultPort() {
        XCTAssertEqual(BridgeProtocol.defaultPort, 8745)
    }

    func testStatusHelper() {
        let status = BridgeProtocol.status(
            connected: true,
            deviceName: "WH-1000XM4",
            battery: 87,
            lastUpdate: "2026-08-21T01:00:00Z",
            port: 8745,
            uptime: 123
        )
        XCTAssertEqual(status.app, "headset-companion")
        XCTAssertEqual(status.version, BridgeStatus.bundleVersion)
        XCTAssertEqual(status.port, 8745)
        XCTAssertEqual(status.connected, true)
        XCTAssertEqual(status.deviceName, "WH-1000XM4")
        XCTAssertEqual(status.battery, 87)
        XCTAssertEqual(status.lastUpdate, "2026-08-21T01:00:00Z")
        XCTAssertEqual(status.uptime, 123)
    }
}
