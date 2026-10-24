import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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
    /// Where this root's caches go (#1030): everything rebuilt or downloaded again when it
    /// is missing, so deleting the folder and starting again is always safe. The platform's
    /// cache folder, so a person can reset it the ordinary way. Settable, like
    /// `personalHome`, so a test hands one in.
    public var cacheRoot: URL
    /// Where this root's logs go (#1030): the platform's log folder.
    public var logRoot: URL

    /// The home folder whose `~/.agents` every agent shares (054), or nil for none.
    ///
    /// Only the ordinary daemon lays out the person's real home. A scratch copy or a
    /// test gets one only when `AGENTS_PERSONAL_HOME` names it, so a walk on a branch
    /// build never rearranges somebody's `~/.claude` (research R4). Settable, so a test
    /// hands one in directly rather than through the environment.
    public var personalHome: URL?
    /// Where `personalSettings` is when there is no personal home to put it in: a server's
    /// daemon sets `$HOME/.agents/settings` (#1033). Nil, and it is the root's own.
    public var personalSettingsOverride: URL?

    public init(root: URL) {
        self.root = root
        let environment = ProcessInfo.processInfo.environment
        self.personalHome = Self.personalHome(root: root, environment: environment)
        (self.cacheRoot, self.logRoot) = Self.platformFolders(root: root, environment: environment)
    }

    /// The cache and log folders for `root` (#1030). Pure, so the rule is testable.
    ///
    /// - The ordinary root: `~/Library/Caches/com.alexecollins.agents` and
    ///   `~/Library/Logs/Agents` on a Mac; `$XDG_CACHE_HOME/agents` (`~/.cache/agents`) and
    ///   `$XDG_STATE_HOME/agents/logs` (`~/.local/state/agents/logs`) on Linux.
    /// - Any other root: a folder of its own under each, `roots/<name>-<hash>`, so a second
    ///   copy never shares a cache with the first.
    /// - A root in the temporary folder (a test, a walk's `/tmp/run-<slug>`): `cache` and
    ///   `logs` inside it, so that removing the root removes everything it made, and
    ///   thousands of test roots leave nothing behind in the person's folders.
    public static func platformFolders(root: URL, environment: [String: String]) -> (cache: URL, logs: URL) {
        if isTemporary(root) {
            return (root.appendingPathComponent("cache", isDirectory: true),
                    root.appendingPathComponent("logs", isDirectory: true))
        }
        #if canImport(Darwin)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.alexecollins.agents", isDirectory: true)
        var logs = library.appendingPathComponent("Logs/Agents", isDirectory: true)
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        func xdg(_ variable: String, _ fallback: String) -> URL {
            if let value = environment[variable], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        var cache = xdg("XDG_CACHE_HOME", ".cache").appendingPathComponent("agents", isDirectory: true)
        var logs = xdg("XDG_STATE_HOME", ".local/state").appendingPathComponent("agents/logs", isDirectory: true)
        #endif
        if root.standardizedFileURL.path != standardRoot.standardizedFileURL.path {
            let own = "roots/\(root.lastPathComponent)-\(pathHash(root.standardizedFileURL.path))"
            cache.appendPathComponent(own, isDirectory: true)
            logs.appendPathComponent(own, isDirectory: true)
        }
        return (cache, logs)
    }

    /// Whether `url` is under the system's temporary folder or `/tmp`, through any link.
    static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let temporaries = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path }
        return temporaries.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Eight hex digits of FNV-1a, the hash Agents Host labels a scratch set-up's jobs with.
    static func pathHash(_ path: String) -> String {
        let hash = path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(String(hash, radix: 16).suffix(8))
    }

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
    public static var standard: StoreLocations { StoreLocations(root: standardRoot) }

    /// The ordinary root on its own, so deciding a root's personal home does not build a
    /// whole `StoreLocations` (which would decide its own, and so on).
    static var standardRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Agents", isDirectory: true)
    }

    public static let rootVariable = "AGENTS_ROOT"
    public static let personalHomeVariable = "AGENTS_PERSONAL_HOME"

    /// Pure, like `chosen`: the named home first, then the real one for the ordinary
    /// root, and none for anything else.
    public static func personalHome(root: URL, environment: [String: String]) -> URL? {
        if let named = environment[personalHomeVariable], !named.isEmpty { return expand(named) }
        guard root.standardizedFileURL.path == standardRoot.standardizedFileURL.path else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)  // iOS has no homeDirectoryForCurrentUser
    }
    public static let rootArgument = "--root"

    /// The person's settings (#1033), one file each: `~/.agents/settings`, which moves with
    /// the person rather than with this machine. The Agents app writes it; the top of
    /// `~/.agents` stays the hand-written config other tools read too.
    ///
    /// A root with no personal home (a scratch copy, a test) keeps its own, in
    /// `<root>/settings`, so it never writes the real `~/.agents`; a server's daemon is
    /// given `$HOME/.agents/settings` through `personalSettingsOverride`.
    public var personalSettings: URL {
        if let personalSettingsOverride { return personalSettingsOverride }
        if let personalHome { return Self.settings(inHome: personalHome) }
        return root.appendingPathComponent("settings", isDirectory: true)
    }

    /// `<home>/.agents/settings`.
    public static func settings(inHome home: URL) -> URL {
        home.appendingPathComponent(".agents/settings", isDirectory: true)
    }

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
    /// The daemon's log, rolled to `daemon.previous.log` beside it (#1030: in `logRoot`).
    public var log: URL { logRoot.appendingPathComponent("daemon.log") }
    /// Each hosted MCP server's stderr, `<name>-<scope digest>.log`, rolled at 1 MB.
    public var mcpLogs: URL { logRoot.appendingPathComponent("mcp-logs", isDirectory: true) }
    /// What each host sign-in relay was asked and how it answered (#211), rolled at 1 MB.
    public var hostRelayLog: URL { logRoot.appendingPathComponent("host-relay.log") }
    /// Where each subscription to a server's events has got to (#383). The daemon's alone.
    public var mcpEvents: URL { root.appendingPathComponent("mcp-events.json") }
    /// Which root this is (#228): an id made the first time a daemon starts here, and
    /// the path it was made at, so a whole root copied elsewhere is a new root rather
    /// than the old one. Every agent record is stamped with the id.
    public var rootIdentity: URL { root.appendingPathComponent("root-id.json") }
    /// The links the app placed in the personal home, so one the person removed is not
    /// put back (054, FR-009). Per root, like everything else the daemon remembers.
    public var personalLayout: URL { root.appendingPathComponent("personal-layout.json") }
    /// What the app installs for this daemon (048): `tools/<runtime>/<id>/`, with
    /// `current` pointing at the one in use. Per root, so a scratch copy installs its own.
    /// A cache (#1030): a toolset that is missing is downloaded again.
    public var tools: URL { cacheRoot.appendingPathComponent("tools", isDirectory: true) }
    /// The files a runtime's policy names, written again at every launch (064), and each
    /// runtime's own temporary folder (`<cache>` in `RuntimeLaunch`).
    public var runtimeFiles: URL { cacheRoot.appendingPathComponent("runtimes", isDirectory: true) }
    /// Where copies of the daemon's binary were kept for runtimes to start as the MCP
    /// helper, until #185. Only named so a daemon starting can remove it.
    public var helpers: URL { root.appendingPathComponent("helpers", isDirectory: true) }
    public var agents: URL { root.appendingPathComponent("agents", isDirectory: true) }
    /// Skill previews fetched and not yet added (059). Held in memory, so a daemon starting
    /// removes what an earlier one left.
    public var catalogStaging: URL { cacheRoot.appendingPathComponent("catalog-staging", isDirectory: true) }
    /// Every folder we have been told about. One file, because the only things in it
    /// are the two a folder cannot tell us: that it is archived, and that it
    /// was added before anything ran in it.
    public var folders: URL { root.appendingPathComponent("folders.json") }
    /// What the app remembers about workflows, which is everything their files cannot
    /// say: that one is paused, which agent is a standing workflow's, and what happened
    /// the last time each fired. One file, for the same reason `folders` is one.
    ///
    /// Deliberately not in the repository. Writing a pause back to the folder would
    /// raise a confirmation every time and fill its history with state nobody wants to
    /// review.
    public var workflows: URL { root.appendingPathComponent("workflows.json") }
    /// The approved copy of each workflow file (#569), one file each, named by its
    /// SHA-256 (#931). Beside `workflows`, not in it, so the heartbeat that rewrites that
    /// file does not rewrite every workflow with it.
    public var workflowCopies: URL { root.appendingPathComponent("workflow-copies", isDirectory: true) }
    /// Which folder plugins the person has approved, by the digest of their folders
    /// (security review, S2). Outside the folder for the reason `workflows` is: a thing
    /// an agent can write to the folder must not be able to approve itself.
    public var pluginApprovals: URL { root.appendingPathComponent("plugin-approvals.json") }
    /// The last approved copy of each app-owned file in a folder's `.agents` (#502):
    /// `folder.json` and `pins.json`, with a change made outside the app that waits for
    /// the person's Keep or Undo. Outside the folder for the reason `workflows` is.
    public var guardedFiles: URL { root.appendingPathComponent("guarded-files.json") }
    /// Every device that has announced itself to this daemon.
    /// One file beside `folders.json`, because a device is a fact about this root
    /// rather than about any folder or agent in it.
    public var devices: URL { root.appendingPathComponent("devices.json") }
    /// The public half of the Mac's relay key, as the bridge registered it (046). Beside
    /// `devices.json` rather than in it, so that file keeps the shape older builds read.
    public var relay: URL { root.appendingPathComponent("relay.json") }
    /// The servers the window reaches over ssh (037). Written by the window only; the
    /// daemon at this root never reads it.
    public var hosts: URL { root.appendingPathComponent("hosts.json") }
    /// A host of a control plane elsewhere (058): what enrolling told it, and its own key.
    /// Written by the daemon given `--control-code`, or by the window's Run a Host Here.
    public var controlHostMembership: URL { root.appendingPathComponent("control-host.json") }
    /// Where the control plane went, once this root's set-up has moved to it (058, T085):
    /// told to every device that connects the old way.
    public var controlMoved: URL { root.appendingPathComponent("control-moved.json") }
    public var controlHostKey: URL { root.appendingPathComponent("control-host-key") }
    /// A host code left for this daemon by Agents Host (058, T055): its launch agent's
    /// arguments are fixed, so the one-time code comes this way. Read on every try, and
    /// removed once the join has saved a membership (#113).
    public var controlJoinCode: URL { root.appendingPathComponent("control-join-code") }
    /// How this host's joining its control plane stands (#113): `HostJoinFile`, written by
    /// the daemon, read by Agents Host and by the control plane on this Mac.
    public var controlJoinStatus: URL { root.appendingPathComponent(HostJoinFile.name) }
    /// Each connected server's ssh control socket and forwarded daemon socket,
    /// `<id>.ctl` and `<id>.sock`. Short names, because both count against the same
    /// 104 bytes as `daemon.sock`.
    public var hostsFolder: URL { root.appendingPathComponent("hosts", isDirectory: true) }
    /// What each runtime last advertised. A cache: safe to delete, and deleting it
    /// costs the next start form the wait it used to have every time.
    public var optionCache: URL { cacheRoot.appendingPathComponent("option-cache.json") }
    /// The mode last chosen for each runtime, so every window and phone offers the
    /// same one first (029). The person's, in `personalSettings` (#1033).
    public var modes: URL { personalSettings.appendingPathComponent("modes.json") }
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
    /// person rather than to any agent or folder: in `personalSettings` (#1033).
    public var limits: URL { personalSettings.appendingPathComponent("limits.json") }
    /// Every resource lease on the Mac and every line waiting for one (036). One file
    /// for the root, like the limits: a lease is the Mac's, not a folder's.
    public var leases: URL { root.appendingPathComponent("leases.json") }
    /// The resources the person declared, with what each is for (#116). The host's,
    /// beside its leases: how many builds a machine can take is that machine's.
    public var declaredResources: URL { root.appendingPathComponent("resources.json") }
    /// What happened (042): one event, consequence or repeat per line, appended, and
    /// rewritten only when the oldest are dropped.
    public var events: URL { root.appendingPathComponent("events.jsonl") }
    /// How long archived agents are kept (051): the person's, in `personalSettings` (#1033).
    public var retention: URL { personalSettings.appendingPathComponent("retention.json") }
    /// The clock that counts it (051): this machine's, so in the root.
    public var retentionClock: URL { root.appendingPathComponent("retention-clock.json") }
    /// Whether this Mac stays awake for agents, and for how long after they stop.
    public var wakeSettings: URL { root.appendingPathComponent("wake.json") }
    /// The person's total for workflows turned on (#506).
    public var workflowLimit: URL { personalSettings.appendingPathComponent("workflow-limit.json") }
    /// What agents call the person (#121).
    public var person: URL { personalSettings.appendingPathComponent("person.json") }
    /// Each runtime's permission mode (061).
    public var clientPermissions: URL { personalSettings.appendingPathComponent("client-permissions.json") }
    /// Each runtime's sandbox (064).
    public var sandbox: URL { personalSettings.appendingPathComponent("sandbox.json") }
    /// The names of the variables passed through to runtimes (`RuntimePassThrough`): names
    /// only, never values, so it is configuration and not a secret (#1035).
    public var runtimeEnvironment: URL { personalSettings.appendingPathComponent("runtime-environment.json") }
    /// The display choices every client shares (#1033): `DisplayPreference`.
    public var displayPreferences: URL { personalSettings.appendingPathComponent("display.json") }
    /// Which credentials are out, until when, and what credit has been spent (052).
    /// The Mac's is the one that counts: a relayed plan is one allowance (R6).
    public var allowances: URL { root.appendingPathComponent("allowances.json") }
    /// Every archived agent, slim, with its size: what start reads instead of each
    /// record (051). A cache, rebuilt when it is missing or unreadable.
    public var archiveIndex: URL { cacheRoot.appendingPathComponent("archive.json") }
    /// The little the event sources remember between runs (042): the next position,
    /// branch tips, cost crossings.
    public var eventState: URL { root.appendingPathComponent("events-state.json") }
    /// When the daemon was last alive, and when it stopped cleanly (#1219): what a
    /// restart works out how long it was down from.
    public var alive: URL { root.appendingPathComponent("alive.json") }
    /// What each of the last few local days cost, per currency. One file, so a daemon
    /// restarted part-way through a day comes back having counted the money rather
    /// than starting the day again from zero.
    ///
    /// Not a history and must never be shown as one: what is kept beyond today exists
    /// only so every boundary question has an unambiguous answer.
    public var spend: URL { root.appendingPathComponent("spend.json") }
    /// What the work used by hour and by day, per runtime (#823), for the usage charts.
    /// Bounded: 168 hours and 90 days (`UsageHistory`).
    public var usageHistory: URL { root.appendingPathComponent("usage-history.json") }
    /// Where the time of running chats went by hour and by day, per runtime (#852), for
    /// the Time page. Bounded as the usage history is (`TimeHistory`).
    public var timeHistory: URL { root.appendingPathComponent("time-history.json") }
    /// The milestones the person has earned (#984): one entry each, never more (`Milestones`).
    public var achievements: URL { root.appendingPathComponent("achievements.json") }

    public func agent(_ id: UUID) -> URL {
        agents.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func record(_ id: UUID) -> URL { agent(id).appendingPathComponent("agent.json") }
    public func transcript(_ id: UUID) -> URL { agent(id).appendingPathComponent("transcript.jsonl") }
    /// Each finished turn of the transcript, as the chat shows it by default. Derived,
    /// so it may be deleted at any time and is built again from the transcript: in the
    /// cache (#1030), one file per agent, removed with the agent.
    public func turns(_ id: UUID) -> URL { turnsFolder.appendingPathComponent("\(id.uuidString).jsonl") }
    public var turnsFolder: URL { cacheRoot.appendingPathComponent("turns", isDirectory: true) }
    /// Every call the agent made to the app's own tools, as the daemon answered it (#47).
    public func appTools(_ id: UUID) -> URL { agent(id).appendingPathComponent("app-tools.jsonl") }
    /// What the daemon made of each runtime assessment it scored (#47), by agent.
    public var assessments: URL { root.appendingPathComponent("assessments", isDirectory: true) }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: turnsFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
    }
}

public enum StoreCoding {
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

    public static let encoder: JSONEncoder = {
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

    public static let decoder: JSONDecoder = {
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
    /// How many set-aside copies of one file are kept; the oldest go first (#205).
    public static let asidesKept = 3

    /// Move a file that exists and cannot be read out of the way, keeping it as
    /// `<name>.corrupt-<time>` (#171): beside the original, or in `folder` when given
    /// (#205: a folder's file is never set aside inside the person's tree). The stores
    /// that read such a file as empty go on to write that empty value back, and without
    /// this the only copy of what somebody set is gone. Answers where it went, or nil
    /// when it could not be moved (then it is still where it was, and a store must not
    /// write over it). With `copy`, the original stays where it is.
    @discardableResult
    public static func setAside(_ url: URL, in folder: URL? = nil, copy: Bool = false) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let aside = asideName(for: url, in: folder)
            if copy {
                try FileManager.default.copyItem(at: url, to: aside)
            } else {
                try FileManager.default.moveItem(at: url, to: aside)
            }
            pruneAsides(of: url, in: folder)
            return aside
        } catch {
            return nil
        }
    }

    /// Where a file outside the daemon's root is set aside: a folder of its own under
    /// `root/set-aside`, named for the folder it came from, so two folders' `pins.json`
    /// never meet.
    public static func asideFolder(for url: URL, under root: URL) -> URL {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parent.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let name = url.deletingLastPathComponent().lastPathComponent
        return root.appendingPathComponent("set-aside", isDirectory: true)
            .appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
    }

    /// `<name>.corrupt-<time>` beside `url` (or in `folder`), one not yet taken.
    public static func asideName(for url: URL, in folder: URL? = nil, at date: Date = Date()) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let folder = folder ?? url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(stamp)"
        // After any copy of this second, even one pruned since, so the names still sort
        // oldest first.
        let taken = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name -> Int? in
            if name == base { return 1 }
            guard name.hasPrefix(base + "-") else { return nil }
            return Int(name.dropFirst(base.count + 1))
        }
        guard let last = taken.max() else { return folder.appendingPathComponent(base) }
        var n = last + 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(base)-\(n)").path) { n += 1 }
        return folder.appendingPathComponent("\(base)-\(n)")
    }

    /// Every set-aside copy of `url` in `folder` (beside it by default), oldest first.
    public static func asides(of url: URL, in folder: URL? = nil) -> [URL] {
        let folder = folder ?? url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// Keep only the newest `asidesKept` copies of `url`.
    public static func pruneAsides(of url: URL, in folder: URL? = nil) {
        for old in asides(of: url, in: folder).dropLast(asidesKept) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Write `data` to `url` whole: to a temporary file beside it, synced to the disk,
    /// then renamed into place (#171). A crash at any moment leaves the old file or the
    /// new one, never a torn one; `.atomic` alone renames without the sync, so a power
    /// cut could still leave the new name pointing at nothing written.
    public static func writeAtomically(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        func failure(_ code: Int32) -> CocoaError { writeError(code, at: url) }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(permissions ?? 0o644))
        guard fd >= 0 else { throw failure(errno) }
        var code: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; code = errno; return }
                offset += n
            }
        }
        if code == 0, fsync(fd) != 0 { code = errno }
        close(fd)
        if code == 0, rename(temporary.path, url.path) != 0 { code = errno }
        guard code == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw failure(code)
        }
    }

    /// What Foundation's own write throws, with the errno underneath, so a refusal
    /// still says why (`WriteFailure`: full, not allowed, read-only).
    public static func writeError(_ code: Int32, at url: URL) -> CocoaError {
        let kind: CocoaError.Code = switch code {
        case ENOSPC, EDQUOT: .fileWriteOutOfSpace
        case EACCES, EPERM: .fileWriteNoPermission
        case EROFS: .fileWriteVolumeReadOnly
        default: .fileWriteUnknown
        }
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: url.path,
                                           NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
    }

    /// A file opened to add to, made if it is not there. One call, so a disk that cannot
    /// make it says why (#212): `createFile` then `FileHandle(forWritingTo:)` turned a full
    /// disk into "doesn't exist", which no alert recognised. Appending puts every write
    /// at the end; otherwise it is opened to read too, at the start.
    public static func openForAdding(_ url: URL, appending: Bool = true) throws -> FileHandle {
        let flags = (appending ? O_WRONLY | O_APPEND : O_RDWR) | O_CREAT | O_CLOEXEC
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { throw writeError(errno, at: url) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// One element of a list that is kept only if it decodes, so that one bad entry costs
/// that entry rather than the list.
public struct Lossy<Element: Decodable>: Decodable {
    public let value: Element?
    public init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
