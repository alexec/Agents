import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Everything a server needs to run one runtime that the app can install there (043).
///
/// Claude is the only one (D3): Node.js, and the ACP adapter from npm with its own
/// per-platform Claude binary. The app carries `manifest.json` and an npm lock for it in
/// `Resources/toolsets/<runtime>/`, made by `scripts/update-claude-toolset.sh`; a server
/// downloads what they name and checks it against them.
///
/// On a server it lives in `~/.agents-server/tools/<runtime>/<id>/`, with `current`
/// pointing at the one in use and an `ok` file written last, so a half-installed one is
/// never mistaken for a whole one.
public struct Toolset: Hashable, Sendable {
    public var manifest: Manifest
    /// The first sixteen hex characters of the SHA-256 of the manifest and lock files,
    /// byte for byte. A different pin is a different toolset, installed beside the old.
    public var id: String
    /// The three files, as they are sent to a server.
    public var folder: URL

    public struct Manifest: Codable, Hashable, Sendable {
        public var runtimeID: String
        public var node: Node
        public var package: String
        public var packageVersion: String
        /// The adapter's script, relative to its package folder.
        public var entry: String
        /// Under this much free space in the server's home, the install is refused before
        /// anything is downloaded. The toolset is about 484 MB once unpacked.
        public var minFreeBytes: Int64

        public struct Node: Codable, Hashable, Sendable {
            public var version: String
            /// Keyed by `Architecture.binarySuffix`: `x86_64`, `aarch64`.
            public var sha256: [String: String]
        }

        /// Where Node's tarball for this architecture is published.
        public func nodeTarball(for architecture: Architecture) -> String? {
            let arch: String
            switch architecture {
            case .x86_64: arch = "x64"
            case .aarch64: arch = "arm64"
            case .other: return nil
            }
            return "\(node.version)/node-\(node.version)-linux-\(arch).tar.xz"
        }

        public func nodeSHA256(for architecture: Architecture) -> String? {
            architecture.binarySuffix.flatMap { node.sha256[$0] }
        }

        /// The adapter's script inside an installed toolset folder.
        public var entryPath: String { "lib/node_modules/\(package)/\(entry)" }
    }

    public static let manifestFile = "manifest.json"
    public static let packageFile = "package.json"
    public static let lockFile = "package-lock.json"

    public init(manifest: Manifest, id: String, folder: URL) {
        self.manifest = manifest
        self.id = id
        self.folder = folder
    }

    /// Where a server keeps one runtime's toolsets, relative to its home.
    public static func serverFolder(runtimeID: String) -> String {
        ".agents-server/tools/\(runtimeID)"
    }

    #if canImport(CryptoKit)
    /// Read a toolset folder from the app's bundle.
    public static func load(from folder: URL) throws -> Toolset {
        let manifestData = try Data(contentsOf: folder.appendingPathComponent(manifestFile))
        let lockData = try Data(contentsOf: folder.appendingPathComponent(lockFile))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        return Toolset(manifest: manifest, id: id(manifest: manifestData, lock: lockData), folder: folder)
    }

    public static func id(manifest: Data, lock: Data) -> String {
        let digest = SHA256.hash(data: manifest + lock)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    #endif
}
