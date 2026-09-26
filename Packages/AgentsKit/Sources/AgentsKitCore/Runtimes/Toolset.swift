import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Everything a server (043) or this Mac (048) needs to run one runtime the app installs.
///
/// Node.js and one npm package: Claude's ACP adapter, with its per-platform Claude binary,
/// or Gemini CLI, which speaks ACP itself (046). The app carries `manifest.json` and an npm
/// lock for each in `Resources/toolsets/<runtime>/`, made by
/// `scripts/update-<runtime>-toolset.sh`; whoever installs it downloads what they name and
/// checks it against them.
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
        /// anything is downloaded. Claude's is about 484 MB once unpacked.
        public var minFreeBytes: Int64
        /// Whether the shim hands its own arguments on (046). Gemini is started with
        /// `--acp` and the policy file's `--policy <path>`; Claude's adapter takes none, and
        /// its recipe's `-y <package>` were only ever meant for a real npx.
        public var forwardsArguments: Bool

        public init(runtimeID: String, node: Node, package: String, packageVersion: String,
                    entry: String, minFreeBytes: Int64, forwardsArguments: Bool = false) {
            self.runtimeID = runtimeID
            self.node = node
            self.package = package
            self.packageVersion = packageVersion
            self.entry = entry
            self.minFreeBytes = minFreeBytes
            self.forwardsArguments = forwardsArguments
        }

        private enum CodingKeys: String, CodingKey {
            case runtimeID, node, package, packageVersion, entry, minFreeBytes, forwardsArguments
        }

        /// `forwardsArguments` is absent from Claude's manifest and every one before 046.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            node = try c.decode(Node.self, forKey: .node)
            package = try c.decode(String.self, forKey: .package)
            packageVersion = try c.decode(String.self, forKey: .packageVersion)
            entry = try c.decode(String.self, forKey: .entry)
            minFreeBytes = try c.decode(Int64.self, forKey: .minFreeBytes)
            forwardsArguments = try c.decodeIfPresent(Bool.self, forKey: .forwardsArguments) ?? false
        }

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

    /// The shim's name in the toolset's `bin/`: the runtime's own executable, so the same
    /// discovery that looks for it on a PATH finds it here — `bin/npx` for Claude, whose
    /// recipe runs npx, and `bin/gemini` for Gemini (046).
    public var shimName: String {
        RuntimeCatalog.runtime(id: manifest.runtimeID)?.executable ?? "npx"
    }

    /// The shim a toolset is started through: the pinned package run by the toolset's own
    /// Node, never whatever the name finds elsewhere. One line per element, none containing
    /// a single quote, so the server's script can hand them to `printf` quoted.
    public var shimLines: [String] {
        let arguments = manifest.forwardsArguments ? #" "$@""# : ""
        return ["#!/bin/sh",
                "# Agents: not the \(shimName) on a PATH. Runs \(manifest.package) as this toolset installed it.",
                #"d=$(cd "$(dirname "$0")/.." && pwd -P)"#,
                #"PATH="$d/node/bin:$PATH" exec "$d/node/bin/node" "$d/"# + manifest.entryPath + #"""# + arguments]
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

    /// Every whole toolset folder in `folder` (the bundle's `toolsets/`), in name order. A
    /// folder that does not read is left out rather than failing the rest.
    public static func loadAll(in folder: URL) -> [Toolset] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { try? load(from: folder.appendingPathComponent($0, isDirectory: true)) }
    }

    public static func id(manifest: Data, lock: Data) -> String {
        let digest = SHA256.hash(data: manifest + lock)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    #endif
}
