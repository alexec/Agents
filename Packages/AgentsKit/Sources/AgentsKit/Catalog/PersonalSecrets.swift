import AgentsKitCore
import Foundation

/// `~/.agents-secrets/` (#1035): the person's secrets, kept apart from `~/.agents`, which is
/// configuration a person may copy, sync or commit. A 0700 folder of 0600 files, on macOS
/// and Linux alike; a scratch root's in its scratch home, never the real one.
///
///     ~/.agents-secrets/secrets.env          values for `${NAME}` in mcp.json
///     ~/.agents-secrets/mcp-sign-ins.json    MCP sign-ins
enum PersonalSecrets {
    static let folder = ".agents-secrets"

    static func url(home: URL, file: String) -> URL {
        home.appending(path: folder).appending(path: file)
    }

    /// Write one file whole, mode 0600, in a folder only its owner can open: the folder
    /// is made 0700, and put back to 0700 if it was changed.
    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try StoreCoding.writeAtomically(data, to: url, permissions: 0o600)
    }
}
