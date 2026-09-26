import Foundation

/// A way of getting an agent that speaks the protocol, which is not the same thing as
/// an installed command.
///
/// Copilot and Grok are themselves; Claude is an npm package run through the user's
/// Node. Treating a runtime as a recipe rather than a binary with a flag is what lets
/// the third one exist at all.
public struct Runtime: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var executable: String
    public var arguments: [String]
    /// How the app can put it on this Mac when it is missing (048), or nil when all it
    /// can do is send the person to `installPage`.
    public var install: RuntimeInstall?
    /// The vendor's own instructions. Always there, because an install that fails has to
    /// leave the person somewhere better than an error.
    public var installPage: URL

    /// Where a runtime with no page of its own sends people: the protocol's list of agents.
    public static let genericInstallPage = URL(string: "https://agentclientprotocol.com/overview/agents")!

    public init(id: String, name: String, executable: String, arguments: [String],
                install: RuntimeInstall? = nil, installPage: URL? = nil) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.install = install
        self.installPage = installPage ?? Self.genericInstallPage
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, executable, arguments, install, installPage
    }

    /// Lenient about the two recipe fields, which a daemon from before 048 never sends.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decode([String].self, forKey: .arguments)
        install = try? c.decodeIfPresent(RuntimeInstall.self, forKey: .install)
        installPage = (try? c.decodeIfPresent(URL.self, forKey: .installPage))
            ?? RuntimeCatalog.runtime(id: id)?.installPage ?? Self.genericInstallPage
    }
}

/// How the app installs a runtime that is missing (048).
public enum RuntimeInstall: Codable, Hashable, Sendable {
    /// Pinned and owned by the app, in the daemon's own folder: Node and the adapter,
    /// checked against the SHA-256 and lock the app carries (043's toolset, for the Mac).
    case toolset(runtimeID: String)
    /// The vendor's own `curl -fsSL <url> | <shell>`.
    case script(url: URL, shell: String = "bash")
    /// `npm install -g <package>`, which needs an npm of the person's own.
    case npmGlobal(package: String)
}

/// Whether a runtime can actually be used, and what to say when it cannot.
public enum RuntimeAvailability: Codable, Hashable, Sendable {
    case available(path: String, supportsResume: Bool)
    case missing(lookedIn: [String])
    case needsSignIn(authMethods: [String], fixCommand: String?)
    case failed(reason: String)
    /// The app is installing it (048). `progress` is the step it is on, in words.
    case installing(progress: String?)
    /// The app tried to install it and could not. Said with the vendor's page beside it.
    case installFailed(reason: String)

    public var isAvailable: Bool { if case .available = self { return true }; return false }

    public var supportsResume: Bool {
        if case .available(_, let resume) = self { return resume }
        return false
    }

    public var isInstalling: Bool { if case .installing = self { return true }; return false }

    // Written out rather than synthesised so that a case this build has never heard of
    // decodes as a failure with its name in it, instead of failing the whole runtime
    // list (048: a phone from before installing still reads a Mac that is installing).
    // The shape is the one the compiler would write: `{"case": {"label": value}}`.

    private enum CaseKey: String, CodingKey {
        case available, missing, needsSignIn, failed, installing, installFailed
    }

    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: Field.self)
        guard let key = outer.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "no availability case"))
        }
        guard let known = CaseKey(rawValue: key.stringValue) else {
            self = .failed(reason: "Unavailable (\(key.stringValue)). A newer app says more.")
            return
        }
        let c = try outer.nestedContainer(keyedBy: Field.self, forKey: key)
        switch known {
        case .available:
            self = .available(path: try c.decode(String.self, forKey: Field("path")),
                              supportsResume: try c.decode(Bool.self, forKey: Field("supportsResume")))
        case .missing:
            self = .missing(lookedIn: try c.decode([String].self, forKey: Field("lookedIn")))
        case .needsSignIn:
            self = .needsSignIn(authMethods: try c.decode([String].self, forKey: Field("authMethods")),
                                fixCommand: try c.decodeIfPresent(String.self, forKey: Field("fixCommand")))
        case .failed:
            self = .failed(reason: try c.decode(String.self, forKey: Field("reason")))
        case .installing:
            self = .installing(progress: try c.decodeIfPresent(String.self, forKey: Field("progress")))
        case .installFailed:
            self = .installFailed(reason: try c.decode(String.self, forKey: Field("reason")))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .available(let path, let supportsResume):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .available)
            try c.encode(path, forKey: Field("path"))
            try c.encode(supportsResume, forKey: Field("supportsResume"))
        case .missing(let lookedIn):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .missing)
            try c.encode(lookedIn, forKey: Field("lookedIn"))
        case .needsSignIn(let authMethods, let fixCommand):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .needsSignIn)
            try c.encode(authMethods, forKey: Field("authMethods"))
            try c.encodeIfPresent(fixCommand, forKey: Field("fixCommand"))
        case .failed(let reason):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .failed)
            try c.encode(reason, forKey: Field("reason"))
        case .installing(let progress):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .installing)
            try c.encodeIfPresent(progress, forKey: Field("progress"))
        case .installFailed(let reason):
            var c = outer.nestedContainer(keyedBy: Field.self, forKey: .installFailed)
            try c.encode(reason, forKey: Field("reason"))
        }
    }
}

/// A runtime and what we found out about it on this Mac.
public struct RuntimeStatus: Codable, Hashable, Sendable, Identifiable {
    public var runtime: Runtime
    public var availability: RuntimeAvailability
    public var checkedAt: Date

    public var id: String { runtime.id }

    /// Why it cannot be started, in the runtime's own terms, or nil when it can. One
    /// sentence, the same on the Mac and on a phone (029).
    public var unavailableReason: String? {
        switch availability {
        case .available:
            return nil
        case .missing(let lookedIn):
            return "Looked for \(runtime.executable) in \(lookedIn.prefix(4).joined(separator: ", "))…"
        case .needsSignIn(_, let fixCommand):
            return fixCommand.map { "Signed out. Run \($0)." } ?? "Signed out."
        case .failed(let reason):
            return reason
        case .installing(let progress):
            return progress.map { "Installing: \($0)" } ?? "Installing…"
        case .installFailed(let reason):
            return "\(reason) Install it from \(runtime.installPage.absoluteString)."
        }
    }

    public init(runtime: Runtime, availability: RuntimeAvailability, checkedAt: Date = Date()) {
        self.runtime = runtime
        self.availability = availability
        self.checkedAt = checkedAt
    }
}
