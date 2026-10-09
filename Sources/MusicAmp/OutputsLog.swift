import Foundation

/// A small log of what the network speakers do (requests to the stream, Cast messages), for diagnosing a
/// speaker that connects but doesn't behave: ~/Library/Application Support/MusicAmp/Logs/outputs.log.
enum OutputsLog {
    private static let queue = DispatchQueue(label: "musicamp.outputslog")
    private static var lines: [String] = []
    private static var lastLine = ""

    static var file: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("outputs.log")
    }

    /// Tests (`--test-…`) don't write into the user's log.
    private static let enabled = !CommandLine.arguments.contains { $0.hasPrefix("--test-") }

    static func add(_ s: String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        queue.async {
            // Repeated playlist polls once, not every two seconds.
            if s == lastLine { return }
            lastLine = s
            lines.append(stamp + "  " + s)
            if lines.count > 600 { lines.removeFirst(lines.count - 600) }
            try? Data(lines.joined(separator: "\n").utf8).write(to: file, options: .atomic)
        }
    }
}
