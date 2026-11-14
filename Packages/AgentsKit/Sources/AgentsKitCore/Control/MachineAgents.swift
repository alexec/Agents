import Foundation

// A machine page's Agent Loops section (#5273, spec 5239 board 6): the version the machine
// runs, since when, the changes since the version before, the other machines' versions and its
// history. The control plane answers it from each machine's machine/hello (#5272) and GitHub's
// compare of two versions' commits.

public extension DaemonAPI {
    /// `machines/agents`'s answer.
    struct MachineAgents: Codable, Sendable, Equatable {
        public var host: MachineRef
        public var version: String
        public var since: Date?
        public var previous: String?
        public var changes: AgentsChanges?
        public var changesError: String?
        public var history: [MachineAgentsVersion]
        public var others: [MachineAgentsOther]

        public init(host: MachineRef, version: String, since: Date? = nil, previous: String? = nil,
                    changes: AgentsChanges? = nil, changesError: String? = nil,
                    history: [MachineAgentsVersion] = [], others: [MachineAgentsOther] = []) {
            self.host = host
            self.version = version
            self.since = since
            self.previous = previous
            self.changes = changes
            self.changesError = changesError
            self.history = history
            self.others = others
        }
    }

    /// One version a machine ran, and when it came.
    struct MachineAgentsVersion: Codable, Sendable, Equatable, Hashable {
        public var version: String
        public var since: Date?

        public init(version: String, since: Date? = nil) {
            self.version = version
            self.since = since
        }
    }

    /// Another of the person's machines: its version, and how far it is ahead of and behind
    /// the page's machine, when GitHub could say.
    struct MachineAgentsOther: Codable, Sendable, Equatable, Identifiable {
        public var host: MachineRef
        public var name: String
        public var version: String
        public var since: Date?
        public var ahead: Int?
        public var behind: Int?

        public var id: MachineRef { host }

        public init(host: MachineRef, name: String, version: String, since: Date? = nil, ahead: Int? = nil, behind: Int? = nil) {
            self.host = host
            self.name = name
            self.version = version
            self.since = since
            self.ahead = ahead
            self.behind = behind
        }
    }

    /// The changes from version `base` to version `head`, newest first.
    struct AgentsChanges: Codable, Sendable, Equatable {
        public var base: String
        public var head: String
        public var ahead: Int
        public var behind: Int
        public var changes: [AgentsChange]
        public var complete: Bool

        public init(base: String, head: String, ahead: Int, behind: Int = 0, changes: [AgentsChange], complete: Bool) {
            self.base = base
            self.head = head
            self.ahead = ahead
            self.behind = behind
            self.changes = changes
            self.complete = complete
        }
    }

    /// One change: a commit, its PR's number when its title says one.
    struct AgentsChange: Codable, Sendable, Equatable, Identifiable {
        public var number: Int?
        public var title: String
        public var sha: String
        public var date: Date?

        public var id: String { sha }

        public init(number: Int? = nil, title: String, sha: String, date: Date? = nil) {
            self.number = number
            self.title = title
            self.sha = sha
            self.date = date
        }
    }

    /// `machines/agentsChanges`'s request: with no limit, every change, up to 1,000.
    struct AgentsChangesRequest: Codable, Sendable, Equatable {
        public var base: String
        public var head: String
        public var limit: Int?

        public init(base: String, head: String, limit: Int? = nil) {
            self.base = base
            self.head = head
            self.limit = limit
        }
    }
}

public extension DaemonAPI.Method {
    /// `MachineRequest` → `MachineAgents` (#5273).
    static let machinesAgents = "machines/agents"
    /// `AgentsChangesRequest` → `AgentsChanges` (#5273).
    static let machinesAgentsChanges = "machines/agentsChanges"
}

/// The section's words (#5273), the same on the Mac, the Remote and the web page
/// (`Web/src/model/agentsVersions.ts`).
public enum AgentsVersionWords {
    /// The section's title: the product's name (#5297).
    public static let title = "Agent Loops"

    /// The repo Agent Loops is built from, for a change's link.
    public static let repo = "agentloops-dev/agent-loops"

    /// A version as the page draws it: `0.18.1-dev.544` large, `+g8162a5a06` after it.
    public static func parts(_ version: String) -> (name: String, build: String?) {
        guard let plus = version.firstIndex(of: "+") else { return (version, nil) }
        return (String(version[..<plus]), String(version[plus...]))
    }

    /// A version without its build: `0.18.1-dev.544`.
    public static func short(_ version: String) -> String { parts(version).name }

    /// The months as the app's copy says them, the same as the web page's.
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `13 Nov, 15:22`: the day and the time, in this device's zone.
    public static func when(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        let hour = (c.hour ?? 0) < 10 ? "0\(c.hour ?? 0)" : "\(c.hour ?? 0)"
        let minute = (c.minute ?? 0) < 10 ? "0\(c.minute ?? 0)" : "\(c.minute ?? 0)"
        return "\(day(date, calendar: calendar)), \(hour):\(minute)"
    }

    /// `13 Nov`: a change's day.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: date)
        return "\(c.day ?? 0) \(months[max(0, min(11, (c.month ?? 1) - 1))])"
    }

    /// `1 change`, `544 changes`.
    public static func count(_ n: Int) -> String { n == 1 ? "1 change" : "\(n) changes" }

    /// The line under the version: `since 13 Nov, 15:22 · 544 changes since 0.18.0, the version before`.
    public static func sinceLine(_ agents: DaemonAPI.MachineAgents, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let since = agents.since { parts.append("since \(when(since, calendar: calendar))") }
        if let previous = agents.previous {
            if let changes = agents.changes {
                parts.append("\(count(changes.ahead)) since \(short(previous)), the version before")
            } else {
                parts.append("the version before was \(short(previous)); its changes can’t be read now")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The list's heading: `544 changes since 0.18.0 · newest first`.
    public static func listHeading(_ changes: DaemonAPI.AgentsChanges) -> String {
        "\(count(changes.ahead)) since \(short(changes.base)) · newest first"
    }

    /// `Show all 544`.
    public static func showAll(_ changes: DaemonAPI.AgentsChanges) -> String? {
        changes.complete ? nil : "Show all \(changes.ahead)"
    }

    /// Another machine's second line: `0.18.0 · since 8 Nov, 11:02`.
    public static func otherLine(_ other: DaemonAPI.MachineAgentsOther, calendar: Calendar = .current) -> String {
        guard let since = other.since else { return short(other.version) }
        return "\(short(other.version)) · since \(when(since, calendar: calendar))"
    }

    /// How far another machine is from this one: `544 changes behind this one`; nil when it
    /// runs the same commit or GitHub could not say.
    public static func behindLine(_ other: DaemonAPI.MachineAgentsOther) -> String? {
        guard let ahead = other.ahead, let behind = other.behind else { return nil }
        switch (ahead, behind) {
        case (0, 0): return nil
        case (0, _): return "\(count(behind)) behind this one"
        case (_, 0): return "\(count(ahead)) ahead of this one"
        default: return "\(ahead) ahead of and \(behind) behind this one"
        }
    }

    /// Whether another machine is behind, so its line is in the warning tint.
    public static func isBehind(_ other: DaemonAPI.MachineAgentsOther) -> Bool { (other.behind ?? 0) > 0 }

    /// The compare whose changes another machine's line opens: what this one has that it has not,
    /// else what it has that this one has not.
    public static func compare(from other: DaemonAPI.MachineAgentsOther, to version: String,
                               limit: Int? = nil) -> DaemonAPI.AgentsChangesRequest {
        (other.behind ?? 0) > 0
            ? DaemonAPI.AgentsChangesRequest(base: other.version, head: version, limit: limit)
            : DaemonAPI.AgentsChangesRequest(base: version, head: other.version, limit: limit)
    }

    /// How many changes a list shows before its Show all, as the control plane's page answer.
    public static let shown = 6

    /// A change's link: its PR, else its commit.
    public static func link(_ change: DaemonAPI.AgentsChange) -> URL? {
        if let number = change.number { return URL(string: "https://github.com/\(repo)/pull/\(number)") }
        return URL(string: "https://github.com/\(repo)/commit/\(change.sha)")
    }

    /// A change's label before its title: `#5250`, or the commit's first 7.
    public static func label(_ change: DaemonAPI.AgentsChange) -> String {
        change.number.map { "#\($0)" } ?? String(change.sha.prefix(7))
    }

    /// What the section says when the machine has said no version yet.
    public static let none = "This machine has not said its version yet."
}
