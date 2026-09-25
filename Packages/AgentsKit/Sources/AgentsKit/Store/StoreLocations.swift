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
    /// What the app remembers about workflows, which is everything their files cannot
    /// say: that one is paused, which agent is a standing workflow's, and what happened
    /// the last time each fired. One file, for the same reason `projects` is one.
    ///
    /// Deliberately not in the repository. Writing a pause back to the project would
    /// raise a confirmation every time and fill its history with state nobody wants to
    /// review.
    public var workflows: URL { root.appendingPathComponent("workflows.json") }
    /// Every device that has announced itself to this daemon.
    /// One file beside `projects.json`, because a device is a fact about this root
    /// rather than about any project or agent in it.
    public var devices: URL { root.appendingPathComponent("devices.json") }
    /// What each runtime last advertised. A cache: safe to delete, and deleting it
    /// costs the next start form the wait it used to have every time.
    public var optionCache: URL { root.appendingPathComponent("option-cache.json") }
    /// The mode last chosen for each runtime, so every window and phone offers the
    /// same one first (029).
    public var modes: URL { root.appendingPathComponent("modes.json") }
    /// What the daemon has already told somebody about: which outstanding needs have
    /// been delivered, where each is showing, when the person was last alerted, and
    /// when each need was first raised.
    ///
    /// One file, for the same reason `devices.json` is one, and the daemon is its only
    /// writer. It holds **nothing about what a need says** — no headline, no title, no
    /// tool name. A `Need` is derived from the agents and the pending questions every
    /// time it is asked for, and a second copy of it here would be the one thing 021's
    /// FR-001 forbids.
    ///
    /// Safe to delete, and safe to lose: a daemon that cannot read it raises every
    /// outstanding need afresh and may alert about one twice, which is exactly what
    /// every daemon did before this file existed.
    public var attention: URL { root.appendingPathComponent("attention.json") }
    /// The two limits the reader set: the most any one agent may spend, and the most
    /// a day may. One file, because there are two facts in it and both belong to the
    /// person rather than to any agent or project.
    ///
    /// One root is one budget. A branch build pointed at its own root has its own
    /// limits and its own day, which is consistent with the root being the daemon's
    /// identity and is worth knowing before wondering why a limit did not bite.
    public var limits: URL { root.appendingPathComponent("limits.json") }
    /// Every resource lease on the Mac and every line waiting for one (036). One file
    /// for the root, like the limits: a lease is the Mac's, not a project's.
    public var leases: URL { root.appendingPathComponent("leases.json") }
    /// What each of the last few local days cost, per currency. One file, so a daemon
    /// restarted part-way through a day comes back having counted the money rather
    /// than starting the day again from zero.
    ///
    /// Not a history and must never be shown as one: what is kept beyond today exists
    /// only so every boundary question has an unambiguous answer.
    public var spend: URL { root.appendingPathComponent("spend.json") }

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
    ///
    /// Written and read with `Date.ISO8601FormatStyle`, which produces the same text
    /// `ISO8601DateFormatter` did and reads it in a sixth of the time. The formatter is
    /// what every record was written with until now, and it stays as the last resort
    /// on the way in: a stamp the style will not take is still read the old way
    /// rather than costing somebody a record.
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            // The style cuts the fraction off at the millisecond where the formatter
            // rounded it, so half a millisecond is added first: what is written is
            // then the same text for the same date as every record before it.
            try c.encode(style.format(date.addingTimeInterval(0.0005)))
        }
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? style.parse(text) { return date }
            if let date = try? wholeSecondStyle.parse(text) { return date }
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return d
    }()
}

extension StoreCoding {
    /// Move a file that exists and cannot be read out of the way, keeping it beside
    /// the original. The stores that read such a file as empty go on to write that
    /// empty value back, and without this the only copy of what somebody set is gone.
    static func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.appendingPathExtension("unreadable-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }
}

/// One element of a list that is kept only if it decodes, so that one bad entry costs
/// that entry rather than the list.
struct Lossy<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
