import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A runtime the app installs itself from the vendor's own signed archive, not from npm
/// (049). Antigravity's ACP server is a zip from `dl.google.com` for each platform: a
/// Mach-O or ELF binary with Python inside it, no Node and nothing to resolve. OpenCode's is
/// one program per platform from its GitHub releases, zipped for macOS and `.tar.gz` for
/// Linux, with builds for CPUs without AVX2 (`-baseline`) and for musl (`-musl`).
///
/// It is laid out exactly as a `Toolset` is, so discovery, `current`, `ok` and **Update**
/// need nothing new: `<tools>/<runtime>/<id>/` holds the unpacked files and
/// `bin/<executable>`, a shim that runs them, and `ok` is written last.
///
/// The app carries only `manifest.json`: the URL, size and SHA-256 of each platform's
/// archive, written by `scripts/update-toolset.sh --archive`. Never the vendor's bytes —
/// Antigravity's terms are Google's, and the person's machine downloads it from Google.
public struct ArchiveToolset: Hashable, Sendable {
    public var manifest: Manifest
    /// The first sixteen hex characters of the SHA-256 of `manifest.json`, byte for byte.
    public var id: String
    public var folder: URL

    public struct Manifest: Codable, Hashable, Sendable {
        public var runtimeID: String
        /// Always `archive`; what tells this manifest from a `Toolset.Manifest`.
        public var kind: String
        /// The vendor's own version, as the row shows it.
        public var version: String
        /// Where `update-toolset.sh` read it from, e.g. `acp-registry:antigravity-acp`.
        public var source: String
        /// Under this much free space the install is refused before anything is downloaded.
        public var minFreeBytes: Int64
        /// Keyed by the ACP registry's names: `darwin-aarch64`, `darwin-x86_64`,
        /// `linux-x86_64`, `linux-aarch64`, each optionally followed by `-baseline` (for a CPU
        /// without AVX2) and then `-musl`. `platformKey(for:)` picks one.
        public var platforms: [String: Platform]

        public init(runtimeID: String, kind: String = ArchiveToolset.kind, version: String, source: String,
                    minFreeBytes: Int64, platforms: [String: Platform]) {
            self.runtimeID = runtimeID
            self.kind = kind
            self.version = version
            self.source = source
            self.minFreeBytes = minFreeBytes
            self.platforms = platforms
        }
    }

    public struct Platform: Codable, Hashable, Sendable {
        /// How the archive is packed, from the end of its URL; never written in the manifest.
        public enum Format: Sendable { case zip, tarGz }

        public var url: URL
        public var sha256: String
        /// Bytes, for progress and the row's "112 MB from Google".
        public var size: Int64
        /// The program inside the unpacked archive, relative to it.
        public var command: String
        public var arguments: [String]
        /// Why the vendor's build for this platform does not work, when it does not.
        /// Absent means fine.
        public var knownBroken: String?

        public init(url: URL, sha256: String, size: Int64, command: String, arguments: [String] = [],
                    knownBroken: String? = nil) {
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.command = command
            self.arguments = arguments
            self.knownBroken = knownBroken
        }

        /// `nil` for a URL that ends in neither: such a manifest is refused when it loads.
        public var format: Format? {
            let path = url.path.lowercased()
            if path.hasSuffix(".zip") { return .zip }
            if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") { return .tarGz }
            return nil
        }
    }

    /// What a machine is, as far as choosing its archive goes.
    public struct HostFacts: Hashable, Sendable {
        /// `darwin-aarch64`, `linux-x86_64` and so on.
        public var base: String
        /// False on an x86_64 CPU without AVX2, which needs a `-baseline` build.
        public var avx2: Bool
        /// True where the C library is musl (Alpine), which needs a `-musl` build.
        public var musl: Bool

        public init(base: String, avx2: Bool = true, musl: Bool = false) {
            self.base = base
            self.avx2 = avx2
            self.musl = musl
        }
    }

    /// The most specific key `platforms` holds for these facts: `-baseline` only without
    /// AVX2, `-musl` only on musl, dropping `-baseline` first and then `-musl` when the
    /// vendor has no such build. A glibc machine is never given a musl build.
    public static func platformKey(for facts: HostFacts, in platforms: some Collection<String>) -> String? {
        let baseline = facts.avx2 ? [""] : ["-baseline", ""]
        let musl = facts.musl ? ["-musl", ""] : [""]
        for m in musl {
            for b in baseline {
                let key = facts.base + b + m
                if platforms.contains(key) { return key }
            }
        }
        return nil
    }

    /// This Mac's facts: its architecture, and on Intel whether the CPU has AVX2.
    public static var macFacts: HostFacts {
        #if arch(x86_64) && canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let avx2 = sysctlbyname("hw.optional.avx2_0", &value, &size, nil, 0) == 0 && value == 1
        return HostFacts(base: macPlatform, avx2: avx2)
        #else
        return HostFacts(base: macPlatform)
        #endif
    }

    /// The key of this Mac's archive in this toolset, or the plain platform name when there is
    /// none, so the caller's "publishes no … for this Mac" still reads right.
    public var macPlatformKey: String {
        Self.platformKey(for: Self.macFacts, in: manifest.platforms.keys) ?? Self.macPlatform
    }

    public static let kind = "archive"

    public init(manifest: Manifest, id: String, folder: URL) {
        self.manifest = manifest
        self.id = id
        self.folder = folder
    }

    /// This Mac's platform, in the registry's words.
    public static var macPlatform: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    /// A Linux server's platform, in the registry's words.
    public static func linuxPlatform(_ architecture: Architecture) -> String? {
        architecture.binarySuffix.map { "linux-\($0)" }
    }

    /// The name of the shim in `bin/`: the runtime's own `executable`.
    public var shimName: String {
        RuntimeCatalog.runtime(id: manifest.runtimeID)?.executable ?? manifest.runtimeID
    }

    /// `bin/<shimName>`: the vendor's program with its platform's arguments and whatever
    /// the shim was given. One line per element, none containing a single quote, as
    /// `Toolset.shimLines`.
    public func shimLines(for platform: Platform) -> [String] {
        let arguments = platform.arguments.map { #" "\#($0)""# }.joined()
        return ["#!/bin/sh",
                "# Agents: runs the \(manifest.runtimeID) \(manifest.version) this toolset was installed with.",
                #"d=$(cd "$(dirname "$0")/.." && pwd -P)"#,
                #"exec "$d/"# + platform.command + #"""# + arguments + #" "$@""#]
    }

    /// Who the row says the download comes from: "Google" for `dl.google.com`, "GitHub" for
    /// a release on `github.com`, otherwise the host itself.
    public static func vendor(of toolset: ArchiveToolset) -> String {
        guard let url = toolset.manifest.platforms.values.first?.url, let host = url.host() else { return "the vendor" }
        if host == "google.com" || host.hasSuffix(".google.com") { return "Google" }
        if host == "github.com" || host.hasSuffix(".github.com") { return "GitHub" }
        return host
    }

    /// "112 MB": how the row names the download before it starts.
    public static func megabytes(_ bytes: Int64) -> String {
        "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    #if canImport(CryptoKit)
    /// Read an archive toolset folder from the app's bundle. Throws for a folder whose
    /// manifest is not an archive's, so `loadAll` leaves Node toolsets to `Toolset`.
    public static func load(from folder: URL) throws -> ArchiveToolset {
        let data = try Data(contentsOf: folder.appendingPathComponent(Toolset.manifestFile))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.kind == kind,
              manifest.platforms.values.allSatisfy({ $0.format != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        return ArchiveToolset(manifest: manifest, id: id(manifest: data), folder: folder)
    }

    /// Every archive toolset under the bundle's `toolsets/`, by runtime.
    public static func loadAll(from folder: URL) -> [String: ArchiveToolset] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var toolsets: [String: ArchiveToolset] = [:]
        for name in names.sorted() {
            guard let toolset = try? load(from: folder.appendingPathComponent(name, isDirectory: true)) else { continue }
            toolsets[toolset.manifest.runtimeID] = toolset
        }
        return toolsets
    }

    public static func id(manifest: Data) -> String {
        let digest = SHA256.hash(data: manifest)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    #endif
}
