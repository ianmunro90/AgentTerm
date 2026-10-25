import Foundation

/// A small rolling log of lifecycle events (windows, sessions, mosh), kept at
/// Library/Caches/events.log so it can be pulled off the device with
/// `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Library/Caches/events.log …`.
enum EventLog {
    private static let queue = DispatchQueue(label: "agentterm.eventlog")
    private static let maxBytes = 256 * 1024
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("events.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func record(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > UInt64(maxBytes) {
                    // Keep the newer half.
                    if let existing = try? Data(contentsOf: url) {
                        try? existing.suffix(maxBytes / 2).write(to: url)
                    }
                    _ = try? handle.seekToEnd()
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
