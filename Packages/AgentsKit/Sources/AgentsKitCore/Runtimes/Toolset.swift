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
    /// Node for this Mac (048), from `mac-node.json` beside the manifest. Kept out of the
    /// manifest on purpose: the manifest's bytes are the toolset's id, and a Mac pin
    /// added there would make every server install the same toolset again.
    public var macNode: MacNode?

    /// Node's version and the SHA-256 of its two macOS tarballs.
    public struct MacNode: Codable, Hashable, Sendable {
        public var version: String
        /// Keyed by nodejs.org's own names: `arm64`, `x64`.
        public var sha256: [String: String]

        public init(version: String, sha256: [String: String]) {
            self.version = version
            self.sha256 = sha256
        }

        /// This Mac's architecture, in nodejs.org's words.
        public static var hostArchitecture: String {
            #if arch(arm64)
            "arm64"
            #else
            "x64"
            #endif
        }

        /// Where Node's tarball for `architecture` is published, relative to `/dist/`.
        /// Gzip rather than xz: macOS's tar reads either, and nodejs.org ships both.
        public func tarball(for architecture: String) -> String {
            "\(version)/node-\(version)-darwin-\(architecture).tar.gz"
        }
    }

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
    public static let macNodeFile = "mac-node.json"

    public init(manifest: Manifest, id: String, folder: URL, macNode: MacNode? = nil) {
        self.manifest = manifest
        self.id = id
        self.folder = folder
        self.macNode = macNode
    }

    // MARK: Shared by the server's install script and the Mac's installer

    /// What `npm ci` is given besides `--prefix` and `--cache`: the lock and nothing else,
    /// no install scripts, and nothing said to a server about audits or funding.
    public static let npmCIArguments = ["ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund"]

    /// The `bin/npx` a toolset is started through: not npx, but the pinned adapter run by
    /// the toolset's own Node. One line per element, none containing a single quote, so
    /// the server's script can hand them to `printf` quoted.
    public var shimLines: [String] {
        ["#!/bin/sh",
         "# Agents (043): not npx. Runs the Claude adapter this toolset was installed with.",
         #"d=$(cd "$(dirname "$0")/.." && pwd -P)"#,
         #"PATH="$d/node/bin:$PATH" exec "$d/node/bin/node" "$d/"# + manifest.entryPath + #"""#]
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
        let macNode = (try? Data(contentsOf: folder.appendingPathComponent(macNodeFile)))
            .flatMap { try? JSONDecoder().decode(MacNode.self, from: $0) }
        return Toolset(manifest: manifest, id: id(manifest: manifestData, lock: lockData), folder: folder,
                       macNode: macNode)
    }

    public static func id(manifest: Data, lock: Data) -> String {
        let digest = SHA256.hash(data: manifest + lock)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    #endif
}
