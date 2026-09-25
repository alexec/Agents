import Foundation

/// Which machine something lives on (037).
///
/// `mac` is this Mac and is never written down: every record from before servers existed
/// is this Mac's, and so is every record decoded without a host. A server's id is eight
/// lowercase letters and digits, short on purpose because it names the socket files the
/// window keeps for it, and those have a 104-byte ceiling.
public struct HostID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mac = HostID(rawValue: "mac")

    public static func make() -> HostID {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var id: String
        repeat {
            id = String((0..<8).map { _ in alphabet.randomElement()! })
        } while id == mac.rawValue
        return HostID(rawValue: id)
    }

    public var description: String { rawValue }
}

/// A server the person added by the name they use with `ssh`.
///
/// Everything about reaching it — address, port, user, key, jump host — stays in their
/// own ssh configuration. The window keeps the name and what it learned by asking.
public struct ServerHost: Codable, Hashable, Sendable, Identifiable {
    public var id: HostID
    /// Exactly what was typed. Handed to `ssh` as the destination, after `--`.
    public var sshName: String
    public var label: String
    public var addedAt: Date
    public var facts: ServerFacts?
    /// What was shown and accepted when it was added. `known_hosts` is what ssh checks;
    /// this is only so Settings can show it again.
    public var trustedFingerprint: String?
    /// "Use this server's own sign-in only" (043, FR-014): nothing from Settings is ever
    /// lent to it. For a box the person shares.
    public var ownSignInOnly: Bool = false
    /// The project folders last seen on it, so that after a rebuild the ones it no longer
    /// has can be shown as gone rather than offline (043, FR-019).
    public var knownProjects: [String] = []

    public struct InvalidName: Error, Equatable, Sendable {
        public var name: String
    }

    public init(sshName: String, id: HostID = .make(), addedAt: Date = Date()) throws {
        guard Self.isValid(sshName) else { throw InvalidName(name: sshName) }
        self.id = id
        self.sshName = sshName
        self.label = Self.label(for: sshName)
        self.addedAt = addedAt
    }

    /// Written by hand only so that a `hosts.json` from before 043 still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(HostID.self, forKey: .id)
        sshName = try c.decode(String.self, forKey: .sshName)
        label = try c.decode(String.self, forKey: .label)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        facts = try c.decodeIfPresent(ServerFacts.self, forKey: .facts)
        trustedFingerprint = try c.decodeIfPresent(String.self, forKey: .trustedFingerprint)
        ownSignInOnly = try c.decodeIfPresent(Bool.self, forKey: .ownSignInOnly) ?? false
        knownProjects = try c.decodeIfPresent([String].self, forKey: .knownProjects) ?? []
    }

    /// Not empty, one word, and not something ssh would read as an option. The `--` in
    /// every command line is the first guard against that; this is the second, and the
    /// one the person sees.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("-")
            && !name.contains { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }
    }

    /// `alex@devbox.lan:2222` is called `devbox.lan`; an alias is called itself.
    public static func label(for name: String) -> String {
        var rest = Substring(name)
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return rest.isEmpty ? name : String(rest)
    }
}

/// What the probe found out about a server (contracts/ssh.md § 5).
public struct ServerFacts: Codable, Hashable, Sendable {
    public var system: String
    public var architecture: Architecture
    public var home: String
    public var freeBytes: Int64
    /// From `~/.agents-server/install.json`: the app version that installed the
    /// running binary, and the binary's SHA-256, which is what identifies it. Both nil
    /// when nothing is installed.
    public var installedVersion: String?
    public var installedSHA256: String?
    /// False only when `sshd_config` turns Unix-socket forwarding off.
    public var streamLocalForwarding: Bool
    public var probedAt: Date
    /// What the rest of the probe found for installing Claude there (043, contracts/ssh.md § 1).
    public var libc: Libc = .unknown
    /// `curl` or `wget`, whichever the server has; nil for neither.
    public var downloader: String?
    /// The Claude toolset `current` points at, when it is whole (`ok` is there).
    public var toolsetID: String?
    /// The person's own `npx` on their login PATH (037's way to run Claude).
    public var hasNpx: Bool = false
    /// The server has a Claude sign-in of its own: `~/.claude/.credentials.json`, or a
    /// Claude variable in the login environment. Only ever a yes or no.
    public var hasOwnClaudeSignIn: Bool = false

    public init(system: String, architecture: Architecture, home: String, freeBytes: Int64,
                installedVersion: String?, installedSHA256: String? = nil,
                streamLocalForwarding: Bool, probedAt: Date = Date(),
                libc: Libc = .unknown, downloader: String? = nil, toolsetID: String? = nil,
                hasNpx: Bool = false, hasOwnClaudeSignIn: Bool = false) {
        self.system = system
        self.architecture = architecture
        self.home = home
        self.freeBytes = freeBytes
        self.installedVersion = installedVersion
        self.installedSHA256 = installedSHA256
        self.streamLocalForwarding = streamLocalForwarding
        self.probedAt = probedAt
        self.libc = libc
        self.downloader = downloader
        self.toolsetID = toolsetID
        self.hasNpx = hasNpx
        self.hasOwnClaudeSignIn = hasOwnClaudeSignIn
    }

    /// Written by hand only so that facts saved before 043 still read.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decode(String.self, forKey: .system)
        architecture = try c.decode(Architecture.self, forKey: .architecture)
        home = try c.decode(String.self, forKey: .home)
        freeBytes = try c.decode(Int64.self, forKey: .freeBytes)
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        installedSHA256 = try c.decodeIfPresent(String.self, forKey: .installedSHA256)
        streamLocalForwarding = try c.decode(Bool.self, forKey: .streamLocalForwarding)
        probedAt = try c.decode(Date.self, forKey: .probedAt)
        libc = try c.decodeIfPresent(Libc.self, forKey: .libc) ?? .unknown
        downloader = try c.decodeIfPresent(String.self, forKey: .downloader)
        toolsetID = try c.decodeIfPresent(String.self, forKey: .toolsetID)
        hasNpx = try c.decodeIfPresent(Bool.self, forKey: .hasNpx) ?? false
        hasOwnClaudeSignIn = try c.decodeIfPresent(Bool.self, forKey: .hasOwnClaudeSignIn) ?? false
    }

    /// Node's official Linux builds need glibc 2.28 or later; musl has none (043, R2).
    public var canInstallClaude: Bool {
        if case .glibc(let major, let minor) = libc { return (major, minor) >= (2, 28) }
        return false
    }

    /// Linux on one of the two architectures there is a binary for (FR-004).
    public var isSupported: Bool {
        system == "Linux" && architecture.isSupported
    }
}

/// The server's C library, from the first line of `ldd --version`.
public enum Libc: Codable, Hashable, Sendable {
    case glibc(major: Int, minor: Int)
    case musl
    case unknown

    /// `ldd (Debian GLIBC 2.36-9+deb12u14) 2.36`, `musl libc (aarch64)`, or anything else.
    public init(lddFirstLine line: String) {
        let lower = line.lowercased()
        if lower.contains("musl") { self = .musl; return }
        if lower.contains("glibc") || lower.contains("gnu libc") || lower.hasPrefix("ldd") {
            let last = line.split(separator: " ").last.map(String.init) ?? ""
            let parts = last.split(separator: ".").compactMap { Int($0) }
            if parts.count >= 2 { self = .glibc(major: parts[0], minor: parts[1]); return }
        }
        self = .unknown
    }

    /// How a sentence names it.
    public var display: String {
        switch self {
        case .glibc(let major, let minor): "glibc \(major).\(minor)"
        case .musl: "musl (Alpine)"
        case .unknown: "an unknown C library"
        }
    }
}

public enum Architecture: Codable, Hashable, Sendable {
    case x86_64
    case aarch64
    case other(String)

    /// From `uname -m`. ARM64 Linux says `aarch64`; a Mac says `arm64`, which is not
    /// supported here only because a Mac is not Linux.
    public init(uname machine: String) {
        switch machine {
        case "x86_64", "amd64": self = .x86_64
        case "aarch64", "arm64": self = .aarch64
        default: self = .other(machine)
        }
    }

    public var isSupported: Bool {
        if case .other = self { return false }
        return true
    }

    /// The suffix of the binary bundled for it.
    public var binarySuffix: String? {
        switch self {
        case .x86_64: "x86_64"
        case .aarch64: "aarch64"
        case .other: nil
        }
    }

    /// How Settings writes it.
    public var display: String {
        switch self {
        case .x86_64: "x86-64"
        case .aarch64: "ARM64"
        case .other(let name): name
        }
    }
}

/// Why a server cannot be used, one case per sentence the window can say (037 US3).
public enum HostProblem: Error, Hashable, Sendable {
    case unknownHost
    case loginRefused
    case keyLocked
    case hostKeyChanged
    case unsupportedSystem(system: String, architecture: String)
    case noStreamLocalForwarding
    case diskFull(freeBytes: Int64)
    case serverNewer(server: String, app: String)
    case installFailed(String)
    case timedOut(String)
    case offline
    // Installing Claude's toolset (043, contracts/ssh.md § 4). None of these makes the
    // server unusable: its other runtimes, files and terminal still work.
    case noDownloader
    case noInternet(String)
    case unsupportedLibc(String)
    case toolsetChecksum
    case toolsetInstallFailed(String)
    case diskFullForTools(needed: Int64, free: Int64)
}

/// The servers, in the order they were added. This Mac is not among them.
public struct HostList: Codable, Hashable, Sendable {
    public private(set) var all: [ServerHost] = []

    public struct Duplicate: Error, Equatable, Sendable {
        public var sshName: String
    }

    public init(_ hosts: [ServerHost] = []) { all = hosts }

    public mutating func add(_ host: ServerHost) throws {
        guard !all.contains(where: { $0.sshName == host.sshName }) else {
            throw Duplicate(sshName: host.sshName)
        }
        all.append(host)
    }

    public mutating func update(_ host: ServerHost) {
        guard let index = all.firstIndex(where: { $0.id == host.id }) else { return }
        all[index] = host
    }

    public mutating func remove(_ id: HostID) {
        all.removeAll { $0.id == id }
    }

    public subscript(id: HostID) -> ServerHost? {
        all.first { $0.id == id }
    }

    public init(from decoder: any Decoder) throws {
        all = try decoder.singleValueContainer().decode([ServerHost].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(all)
    }
}

/// Which project, now that two machines can each have `/home/alex/src/api`.
public struct ProjectKey: Hashable, Sendable, CustomStringConvertible {
    public var host: HostID
    public var folder: URL

    public init(host: HostID = .mac, folder: URL) {
        self.host = host
        self.folder = folder.standardizedFileURL
    }

    /// How it is kept in defaults: `host|path`. A bare path, which is what every copy
    /// written before servers looks like, is this Mac's.
    public var stored: String { "\(host.rawValue)|\(folder.path(percentEncoded: false))" }

    public init?(stored: String) {
        if let bar = stored.firstIndex(of: "|") {
            let host = String(stored[..<bar])
            let path = String(stored[stored.index(after: bar)...])
            guard !host.isEmpty, !path.isEmpty else { return nil }
            self.init(host: HostID(rawValue: host), folder: URL(filePath: path))
        } else {
            guard !stored.isEmpty else { return nil }
            self.init(host: .mac, folder: URL(filePath: stored))
        }
    }

    public var description: String { stored }
}
