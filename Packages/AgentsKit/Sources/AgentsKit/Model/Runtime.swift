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

    public init(id: String, name: String, executable: String, arguments: [String]) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
    }
}

/// Whether a runtime can actually be used, and what to say when it cannot.
public enum RuntimeAvailability: Codable, Hashable, Sendable {
    case available(path: String, supportsResume: Bool)
    case missing(lookedIn: [String])
    case needsSignIn(authMethods: [String], fixCommand: String?)
    case failed(reason: String)

    public var isAvailable: Bool { if case .available = self { return true }; return false }

    public var supportsResume: Bool {
        if case .available(_, let resume) = self { return resume }
        return false
    }
}

/// A runtime and what we found out about it on this Mac.
public struct RuntimeStatus: Codable, Hashable, Sendable, Identifiable {
    public var runtime: Runtime
    public var availability: RuntimeAvailability
    public var checkedAt: Date

    public var id: String { runtime.id }

    public init(runtime: Runtime, availability: RuntimeAvailability, checkedAt: Date = Date()) {
        self.runtime = runtime
        self.availability = availability
        self.checkedAt = checkedAt
    }
}
