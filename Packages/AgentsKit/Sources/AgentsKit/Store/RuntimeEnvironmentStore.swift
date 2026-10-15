import Foundation
import AgentsKitCore

/// `runtime-environment.json` in the person's settings (#727, #1033): the variables of the
/// daemon's environment the person passes through to runtimes, beyond what
/// `RuntimeEnvironment` lets through itself. Names only, never values.
/// `"*"` is every runtime; a name ending in `*` is a prefix.
///
///     { "passThrough": { "*": ["AWS_PROFILE"], "claude": ["CLAUDE_CODE_USE_BEDROCK", "AWS_*"] } }
///
/// Read at each launch, so an edit counts from the next agent started. A missing file passes
/// nothing more; an unreadable one is set aside.
public struct RuntimePassThrough: Codable, Sendable, Hashable {
    public var passThrough: [String: [String]]

    public init(passThrough: [String: [String]] = [:]) {
        self.passThrough = passThrough
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passThrough = try c.decodeIfPresent([String: [String]].self, forKey: .passThrough) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case passThrough }

    /// What one runtime is passed: every runtime's, then its own.
    public func names(for runtimeID: String) -> [String] {
        (passThrough["*"] ?? []) + (passThrough[runtimeID] ?? [])
    }
}

public struct RuntimeEnvironmentStore: Sendable {
    private let file: URL

    public init(locations: StoreLocations) { file = locations.runtimeEnvironment }

    public func load() -> RuntimePassThrough {
        StoreFile.load(RuntimePassThrough.self, at: file, empty: .init(), meaning: "nothing more passed through")
    }
}
