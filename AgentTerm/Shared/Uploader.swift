import Citadel
import Foundation
import NIOCore

/// Uploads local files to a host's upload folder (`~/uploads/` unless set otherwise) over SFTP. Existing files are never overwritten:
/// a clashing name gets `-2`, `-3`, … before its extension.
enum Uploader {
    struct Item {
        let localURL: URL
        let filename: String
    }

    private static let chunkSize = 256 * 1024

    /// The host's upload folder: "uploads" (in the home folder), "~/x", or an absolute path.
    static func remoteDirectory(for host: HostProfile, home: String) -> String {
        var folder = host.uploadDirectory.trimmingCharacters(in: .whitespaces)
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        if folder.isEmpty || folder == "~" { return home }
        if folder.hasPrefix("/") { return folder }
        if folder.hasPrefix("~/") { folder.removeFirst(2) }
        return home + "/" + folder
    }

    /// How the folder reads in messages: "~/uploads", or the absolute path.
    static func displayDirectory(for host: HostProfile) -> String {
        remoteDirectory(for: host, home: "~")
    }

    /// Uploads `items` in order and returns their absolute remote paths.
    /// `progress` gets the fraction of all bytes sent so far.
    static func upload(_ items: [Item], to host: HostProfile,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        let total = items.reduce(0) { $0 + fileSize($1.localURL) }
        let client = try await TrustedSSH.connect(to: host, timeout: 10)
        defer { Task { try? await client.close() } }

        return try await client.withSFTP { sftp in
            let home = try await sftp.getRealPath(atPath: ".")
            let directory = remoteDirectory(for: host, home: home)
            if (try? await sftp.getAttributes(at: directory)) == nil {
                try await sftp.createDirectory(atPath: directory)
            }

            let sent = ByteCount()
            var paths: [String] = []
            for item in items {
                let handle = try FileHandle(forReadingFrom: item.localURL)
                defer { try? handle.close() }
                let path = try await createUnique(in: directory, name: sanitized(item.filename), sftp: sftp) { file in
                    var offset: UInt64 = 0
                    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                        try await file.write(ByteBuffer(bytes: chunk), at: offset)
                        offset += UInt64(chunk.count)
                        sent.value += chunk.count
                        progress(total > 0 ? Double(sent.value) / Double(total) : 1)
                    }
                }
                paths.append(path)
            }
            return paths
        }
    }

    /// Opens `name` (or `name-2.ext`, …) with exclusive create, so nothing is overwritten.
    private static func createUnique(in directory: String, name: String, sftp: SFTPClient,
                                     write: @escaping @Sendable (SFTPFile) async throws -> Void) async throws -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for attempt in 1...100 {
            let candidate = attempt == 1 ? name : "\(base)-\(attempt)" + (ext.isEmpty ? "" : ".\(ext)")
            let path = directory + "/" + candidate
            if (try? await sftp.getAttributes(at: path)) != nil { continue }
            try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate]) { file in
                try await write(file)
            }
            return path
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Keeps names usable unquoted: anything but letters, digits and `._-+@%` becomes `-`.
    /// Claude Code only turns a pasted image path into an attachment ([Image #1]) when the path
    /// isn't quoted, so a space in a name would leave it as plain text.
    static func sanitized(_ name: String) -> String {
        var cleaned = String(name.map { isPlain($0) ? $0 : "-" })
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "upload" : cleaned
    }

    private static func isPlain(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "._-+@%".contains(c)
    }

    /// A screenshot-style name for content that arrives without one.
    static func generatedName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).\(ext)"
    }

    /// Paths quoted for typing into a shell or a Claude Code prompt.
    static func shellQuoted(_ paths: [String]) -> String {
        paths.map { path in
            path.allSatisfy { isPlain($0) || $0 == "/" }
                ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }

    /// Bytes sent so far; files upload one at a time, so there's no concurrent access.
    private final class ByteCount: @unchecked Sendable {
        var value = 0
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
