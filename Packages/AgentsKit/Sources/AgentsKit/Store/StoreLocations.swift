import Foundation

/// Where everything lives. Injectable, so tests use a temporary directory and never go
/// near the real one.
///
/// The root is also the daemon's identity. Everything that makes one daemon one daemon
/// is in here — the lock it holds, the socket it answers on, the agents it owns — so
/// two processes pointed at two roots are two daemons that know nothing of each other,
/// and a window, the daemon it starts, and the MCP helper that daemon hands out all
/// find each other by agreeing on this one path.
///
/// That is what makes a second copy possible: a branch build can be run beside the
/// ordinary one without either touching the other's agents.
public struct StoreLocations: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// The one every process uses unless it was told otherwise.
    ///
    /// `--root <path>` first, because that is what survives `open`: macOS will pass
    /// arguments to a second copy of an app bundle and will not pass environment.
    /// `AGENTS_ROOT` second, for a daemon or a helper started from a shell, and
    /// because that is what the app hands its own daemon. Neither, and it is the
    /// ordinary place, which is what nearly every run is.
    public static var `default`: StoreLocations {
        chosen(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// The ordinary place: one daemon, one set of agents, no arguments.
    public static var standard: StoreLocations {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StoreLocations(root: base.appendingPathComponent("Agents", isDirectory: true))
    }

    public static let rootVariable = "AGENTS_ROOT"
    public static let rootArgument = "--root"

    /// Pure, so the rule is testable without a process to run it in.
    public static func chosen(arguments: [String], environment: [String: String]) -> StoreLocations {
        if let named = path(inArguments: arguments) { return StoreLocations(root: expand(named)) }
        if let named = environment[rootVariable], !named.isEmpty {
            return StoreLocations(root: expand(named))
        }
        return standard
    }

    /// `--root /some/where` or `--root=/some/where`. An empty one is not a root and is
    /// ignored rather than turning into the current directory.
    private static func path(inArguments arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == rootArgument, index + 1 < arguments.count {
                let next = arguments[index + 1]
                return next.isEmpty ? nil : next
            }
            if argument.hasPrefix(rootArgument + "=") {
                let value = String(argument.dropFirst(rootArgument.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func expand(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Whether this is the ordinary daemon rather than one somebody asked for.
    public var isStandard: Bool {
        root.standardizedFileURL.path == Self.standard.root.standardizedFileURL.path
    }

    /// What to call this one when it is not the ordinary one, so two windows on screen
    /// at once can be told apart.
    public var name: String { root.lastPathComponent }

    public var socket: URL { root.appendingPathComponent("daemon.sock") }
    public var lock: URL { root.appendingPathComponent("daemon.lock") }
    public var log: URL { root.appendingPathComponent("daemon.log") }
    public var agents: URL { root.appendingPathComponent("agents", isDirectory: true) }
    /// Every project we have been told about. One file, because the only things in it
    /// are the two a project's folder cannot tell us: that it is archived, and that it
    /// was added before anything ran in it.
    public var projects: URL { root.appendingPathComponent("projects.json") }
    /// What each runtime last advertised. A cache: safe to delete, and deleting it
    /// costs the next start form the wait it used to have every time.
    public var optionCache: URL { root.appendingPathComponent("option-cache.json") }

    public func agent(_ id: UUID) -> URL {
        agents.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func record(_ id: UUID) -> URL { agent(id).appendingPathComponent("agent.json") }
    public func transcript(_ id: UUID) -> URL { agent(id).appendingPathComponent("transcript.jsonl") }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }
}

enum StoreCoding {
    /// ISO 8601 with fractional seconds: the record stays readable with `cat`, and a
    /// timestamp survives a round trip to the millisecond. Anything finer than that
    /// does not, which matters nowhere and is worth knowing anyway.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return d
    }()
}
