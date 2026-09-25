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
public struct Host: Codable, Hashable, Sendable, Identifiable {
    public var id: HostID
    /// Exactly what was typed. Handed to `ssh` as the destination, after `--`.
    public var sshName: String
    public var label: String
    public var addedAt: Date
    public var facts: ServerFacts?
    /// What was shown and accepted when it was added. `known_hosts` is what ssh checks;
    /// this is only so Settings can show it again.
    public var trustedFingerprint: String?

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
    /// `agentsd --version` on the server, or nil when nothing is installed.
    public var installedVersion: String?
    /// False only when `sshd_config` turns Unix-socket forwarding off.
    public var streamLocalForwarding: Bool
    public var probedAt: Date

    public init(system: String, architecture: Architecture, home: String, freeBytes: Int64,
                installedVersion: String?, streamLocalForwarding: Bool, probedAt: Date = Date()) {
        self.system = system
        self.architecture = architecture
        self.home = home
        self.freeBytes = freeBytes
        self.installedVersion = installedVersion
        self.streamLocalForwarding = streamLocalForwarding
        self.probedAt = probedAt
    }

    /// Linux on one of the two architectures there is a binary for (FR-004).
    public var isSupported: Bool {
        system == "Linux" && architecture.isSupported
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
}

/// The servers, in the order they were added. This Mac is not among them.
public struct HostList: Codable, Hashable, Sendable {
    public private(set) var all: [Host] = []

    public struct Duplicate: Error, Equatable, Sendable {
        public var sshName: String
    }

    public init(_ hosts: [Host] = []) { all = hosts }

    public mutating func add(_ host: Host) throws {
        guard !all.contains(where: { $0.sshName == host.sshName }) else {
            throw Duplicate(sshName: host.sshName)
        }
        all.append(host)
    }

    public mutating func update(_ host: Host) {
        guard let index = all.firstIndex(where: { $0.id == host.id }) else { return }
        all[index] = host
    }

    public mutating func remove(_ id: HostID) {
        all.removeAll { $0.id == id }
    }

    public subscript(id: HostID) -> Host? {
        all.first { $0.id == id }
    }

    public init(from decoder: any Decoder) throws {
        all = try decoder.singleValueContainer().decode([Host].self)
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
