import XCTest
@testable import HeadsetCompanion

/// End-to-end test of the loopback HTTP server (no Bluetooth, no SwiftUI):
/// binds a real socket on a test port and verifies the wire contract.
final class BridgeServerLiveTests: XCTestCase {

    private static let port = 18745

    func testBatteryEndpointServesContract() {
        let server = BridgeServer(port: Self.port) {
            BridgeProtocol.status(
                connected: false,
                deviceName: nil,
                battery: 42,
                lastUpdate: "2026-01-01T00:00:00Z",
                port: Self.port,
                uptime: 3
            )
        }
        guard server.start() else {
            XCTFail("server did not start on \(Self.port)")
            return
        }
        defer { server.stop() }

        let body = fetch("http://127.0.0.1:\(Self.port)/battery")
        XCTAssertEqual((body?["app"]) as? String, "headset-companion")
        XCTAssertEqual((body?["connected"]) as? Bool, false)
        XCTAssertEqual((body?["battery"]) as? Int, 42)
        XCTAssertEqual((body?["lastUpdate"]) as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual((body?["port"]) as? Int, Self.port)
        XCTAssertNotNil((body?["deviceName"]) as? NSNull)
    }

    func testUnknownPathIs404() {
        let port = Self.port + 1
        let server = BridgeServer(port: port) {
            BridgeProtocol.status(
                connected: false, deviceName: nil, battery: nil,
                lastUpdate: nil, port: port, uptime: 0
            )
        }
        guard server.start() else {
            XCTFail("server did not start on \(port)")
            return
        }
        defer { server.stop() }

        let body = fetch("http://127.0.0.1:\(port)/nope")
        XCTAssertEqual((body?["error"]) as? String, "not found")
    }

    // MARK: - /events

    /// Starts a server backed by a monitor that is never started (no
    /// MediaRemote handlers, no now-playing claim).
    private func startEventServer(port: Int) -> (BridgeServer, MediaKeyMonitor)? {
        let monitor = MediaKeyMonitor(policy: .passive)
        let server = BridgeServer(port: port, eventSource: monitor) {
            BridgeProtocol.status(
                connected: false, deviceName: nil, battery: nil,
                lastUpdate: nil, port: port, uptime: 0
            )
        }
        guard server.start() else {
            XCTFail("server did not start on \(port)")
            return nil
        }
        return (server, monitor)
    }

    func testEventsEndpointReturnsImmediatelyWithoutWait() {
        let port = Self.port + 2
        guard let (server, monitor) = startEventServer(port: port) else { return }
        defer { server.stop() }
        monitor.record(type: "play-pause")
        monitor.record(type: "next")

        let started = Date()
        let body = fetch("http://127.0.0.1:\(port)/events")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual((body?["app"]) as? String, "headset-companion")
        XCTAssertEqual((body?["seq"]) as? Int, 2)
        XCTAssertEqual((body?["mediaKeys"]) as? Bool, false)
        let events = (body?["events"]) as? [[String: Any]]
        XCTAssertEqual(events?.count, 2)
        XCTAssertEqual(events?.first?["type"] as? String, "play-pause")

        // …and `since` filters the tail.
        let tail = fetch("http://127.0.0.1:\(port)/events?since=1")
        let tailEvents = (tail?["events"]) as? [[String: Any]]
        XCTAssertEqual(tailEvents?.count, 1)
        XCTAssertEqual(tailEvents?.first?["seq"] as? Int, 2)
    }

    func testEventsLongPollReturnsEarlyWhenAnEventIsRecorded() {
        let port = Self.port + 3
        guard let (server, monitor) = startEventServer(port: port) else { return }
        defer { server.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            monitor.record(type: "previous")
        }
        let started = Date()
        let body = fetch("http://127.0.0.1:\(port)/events?since=0&wait=2", timeout: 6)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.8, "long poll must return as soon as the event arrives")
        let events = (body?["events"]) as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["type"] as? String, "previous")
        XCTAssertEqual((body?["seq"]) as? Int, 1)
    }

    func testEventsLongPollTimesOutWithAnEmptyList() {
        let port = Self.port + 4
        guard let (server, _) = startEventServer(port: port) else { return }
        defer { server.stop() }

        let started = Date()
        let body = fetch("http://127.0.0.1:\(port)/events?wait=1", timeout: 6)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "must hold the connection for the full wait")
        XCTAssertEqual((body?["seq"]) as? Int, 0)
        XCTAssertEqual(((body?["events"]) as? [[String: Any]])?.count, 0)
    }

    func testLongPollDoesNotBlockOtherRequests() {
        let port = Self.port + 5
        guard let (server, _) = startEventServer(port: port) else { return }
        defer { server.stop() }

        let parked = expectation(description: "long poll finished")
        DispatchQueue.global().async {
            _ = self.fetch("http://127.0.0.1:\(port)/events?wait=3", timeout: 8)
            parked.fulfill()
        }
        // Give the long poll time to be accepted and park.
        Thread.sleep(forTimeInterval: 0.4)

        let started = Date()
        let battery = fetch("http://127.0.0.1:\(port)/battery")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the accept loop must stay free")
        XCTAssertEqual((battery?["app"]) as? String, "headset-companion")
        wait(for: [parked], timeout: 10)
    }

    func testEventsMarksTheConsumerPresent() {
        let port = Self.port + 6
        let monitor = MediaKeyMonitor(policy: .auto)
        let server = BridgeServer(port: port, eventSource: monitor) {
            BridgeProtocol.status(
                connected: false, deviceName: nil, battery: nil,
                lastUpdate: nil, port: port, uptime: 0
            )
        }
        guard server.start() else {
            XCTFail("server did not start on \(port)")
            return
        }
        defer { server.stop() }

        XCTAssertFalse(monitor.shouldClaim(), "no consumer has polled yet")
        _ = fetch("http://127.0.0.1:\(port)/events")
        XCTAssertTrue(monitor.shouldClaim(), "a /events poll makes Sonora the consumer")
    }

    private func fetch(_ urlString: String, timeout: TimeInterval = 3) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: DispatchTime.now() + timeout)
        return result
    }
}
