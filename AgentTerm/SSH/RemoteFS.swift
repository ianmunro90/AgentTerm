import Citadel
import Foundation
import NIOCore

/// Read-only access to a host's files for the explorer: one SSH connection with an SFTP channel,
/// kept while the panel is open and reopened if it drops. Git runs as exec commands on the same
/// connection.
actor RemoteFS {
    struct Entry: Identifiable, Hashable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64?
        let modified: Date?

        var id: String { path }
    }

    enum ReadResult: Sendable {
        case text(String)
        case image(Data)
        case binary(size: UInt64)
        case tooLarge(size: UInt64)
    }

    private let host: HostProfile
    private var client: SSHClient?
    private var sftp: SFTPClient?

    static let maxPreviewBytes: UInt64 = 2 * 1024 * 1024

    init(host: HostProfile) {
        self.host = host
    }

    func close() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    // MARK: Files

    /// Directory contents, folders first, `.git` hidden.
    func list(_ path: String) async throws -> [Entry] {
        let names = try await withSFTP { try await $0.listDirectory(atPath: path) }
        var entries: [Entry] = []
        for component in names.flatMap(\.components) {
            let name = component.filename
            guard name != ".", name != "..", name != ".git" else { continue }
            let full = path == "/" ? "/" + name : path + "/" + name
            let mode = (component.attributes.permissions ?? 0) & 0o170000
            var isDirectory = mode == 0o040000
            let isSymlink = mode == 0o120000
            if isSymlink, let target = try? await withSFTP({ try await $0.getAttributes(at: full) }) {
                isDirectory = (target.permissions ?? 0) & 0o170000 == 0o040000
            }
            entries.append(Entry(
                path: full, name: name, isDirectory: isDirectory, isSymlink: isSymlink,
                size: component.attributes.size,
                modified: component.attributes.accessModificationTime?.modificationTime
            ))
        }
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func read(_ path: String) async throws -> ReadResult {
        try await withSFTP { sftp in
            let size = try await sftp.getAttributes(at: path).size ?? 0
            guard size <= Self.maxPreviewBytes else { return .tooLarge(size: size) }
            var buffer = try await sftp.withFile(filePath: path, flags: .read) { try await $0.readAll() }
            let data = buffer.readData(length: buffer.readableBytes) ?? Data()
            let ext = (path as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
                return .image(data)
            }
            // NUL bytes in the first 8 KB mean binary, as git decides.
            if data.prefix(8192).contains(0) { return .binary(size: size) }
            return .text(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Commands

    /// Runs `script` under sh with `variables` in its environment (e.g. `P`, `F`), so paths never
    /// need escaping inside the script.
    func run(_ script: String, _ variables: [String: String] = [:]) async throws -> String {
        String(decoding: try await runData(script, variables), as: UTF8.self)
    }

    /// `run`, keeping the output's raw bytes (file contents, which may not be UTF-8).
    func runData(_ script: String, _ variables: [String: String] = [:]) async throws -> Data {
        let client = try await connectedClient()
        let assignments = variables.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(TmuxService.shellQuote($0.value))" }.joined(separator: " ")
        let command = "\(assignments) sh -c \(TmuxService.shellQuote(TmuxService.toolPath + script + "; true"))"
        var output = try await client.executeCommand(command, maxResponseSize: 8 * 1024 * 1024)
        return output.readData(length: output.readableBytes) ?? Data()
    }

    // MARK: Connection

    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        sftp = nil
        let fresh = try await TrustedSSH.connect(to: host, timeout: 10)
        client = fresh
        return fresh
    }

    /// Runs `body` with the SFTP channel, reconnecting once if the connection has dropped.
    private func withSFTP<T: Sendable>(_ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        for attempt in 1...2 {
            do {
                let client = try await connectedClient()
                if sftp == nil { sftp = try await client.openSFTP() }
                return try await body(sftp!)
            } catch let error as SFTPError {
                throw error
            } catch {
                sftp = nil
                self.client = nil
                if attempt == 2 { throw error }
            }
        }
        fatalError("unreachable")
    }
}
