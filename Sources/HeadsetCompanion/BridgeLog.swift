import Foundation

/// Tiny append-only file logger for the menu-bar app.
///
/// A GUI app launched via LaunchServices has stdout/stderr going to
/// /dev/null, so `print`/`NSLog` are invisible. This writes to
/// `~/Library/Logs/headset-companion.log` and is exposed over the
/// network at `GET /debug`.
public enum BridgeLog {

    private static let queue = DispatchQueue(label: "io.sonora.headsetcompanion.log")

    static var url: URL? = {
        guard let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = logs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("headset-companion.log")
    }()

    /// Appends a timestamped line (thread-safe, non-blocking for callers).
    private static let ts = ISO8601DateFormatter()

    public static func log(_ message: String) {
        queue.async {
            guard let url else { return }
            let ts = ts.string(from: Date())
            let line = "[\(ts)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// The last `n` log lines, for the /debug endpoint.
    public static func recentLines(_ n: Int = 80) -> String {
        queue.sync {
            guard let url, let content = try? String(
                contentsOf: url, encoding: .utf8
            ) else {
                return "(no log file yet)"
            }
            let lines = content.components(separatedBy: "\n")
            return lines.suffix(n).joined(separator: "\n")
        }
    }
}
