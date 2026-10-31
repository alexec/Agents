import Foundation

/// The words for a server's row on an MCP Servers page (#753): Activity's, with the person's
/// own servers, and each folder's. The same on the Mac, the Remote and the web page
/// (`Web/src/model/hostedMCP.ts`).
public enum MCPHealthWords {
    public typealias Server = DaemonAPI.MCPServerHealth

    /// What the row's dot says.
    public enum Tone: Equatable, Sendable {
        /// Answered, or running: a filled dot.
        case good
        /// Did not answer, or stopped while in use: the failure tint.
        case failing
        /// Not checked, or never started: a hollow dot.
        case quiet
    }

    /// How it runs, beside its name.
    public static func kind(_ server: Server) -> String {
        switch server.transport {
        case .stdio: server.hosted ? "stdio \u{00B7} hosted" : "stdio \u{00B7} run in each session"
        case .http: "http"
        case .sse: "sse"
        }
    }

    /// How it is doing, in a line.
    public static func line(_ server: Server) -> String {
        if server.hosted {
            return server.live.map(HostedMCPWords.line) ?? "Hosted \u{00B7} starts on the first call"
        }
        let checked = server.checkedAt.map { " \u{00B7} checked \(LeaseWords.clock($0))" } ?? ""
        switch server.check {
        case .unchecked: return "Not checked yet"
        case .checking: return "Checking\u{2026}"
        case .answered:
            let tools = server.tools.map { $0 == 1 ? " \u{00B7} 1 tool" : " \u{00B7} \($0) tools" } ?? ""
            return "Answered" + tools + checked
        case .failed: return "Didn't answer" + checked
        case .waiting: return "Waiting for approval in this folder's settings, so it is not started"
        case .missingSecret: return "Needs a secret that isn't set here, so it is not started"
        case .signIn: return "Wants a sign-in first, in Settings"
        case .oldTransport: return "Uses the old sse transport, which isn't checked"
        }
    }

    /// Why it last failed, when it has: shown under the line.
    public static func lastError(_ server: Server) -> String? {
        if server.hosted { return server.live.flatMap(HostedMCPWords.lastError) }
        guard server.check == .failed, let error = server.lastError, !error.isEmpty else { return nil }
        return error
    }

    public static func tone(_ server: Server) -> Tone {
        if server.hosted {
            switch server.live?.state {
            case .running?, .starting?: return .good
            case .restarting?: return .failing
            case .idle?, nil: return .quiet
            }
        }
        switch server.check {
        case .answered: return .good
        case .failed: return .failing
        default: return .quiet
        }
    }

    /// The sidebar row's count: how many do not answer, the one worth a red icon, or how
    /// many there are. Nil with none.
    public static func tally(_ servers: [Server]) -> (words: String, failing: Bool)? {
        guard !servers.isEmpty else { return nil }
        let failing = servers.filter { tone($0) == .failing }.count
        if failing > 0 { return ("\(failing) not answering", true) }
        return (servers.count == 1 ? "1 connector" : "\(servers.count) connectors", false)
    }

    /// Above the person's own servers, on Activity.
    /// The five levels in order (#1428), each with whether it is reached; all not reached
    /// when no host has seen what the connector declares.
    public static func levels(_ levels: DaemonAPI.MCPLevels?) -> [(name: String, reached: Bool)] {
        (levels ?? DaemonAPI.MCPLevels()).each
    }

    /// The levels as a sentence, for VoiceOver and the tooltip.
    public static func levelsSentence(_ levels: DaemonAPI.MCPLevels?) -> String {
        guard let levels else { return "Its levels show once its machine has checked it." }
        let reached = levels.each.filter(\.reached).map(\.name)
        let not = levels.each.filter { !$0.reached }.map(\.name)
        if not.isEmpty { return "Reaches all five levels." }
        if reached.isEmpty { return "Reaches none of the five levels yet." }
        return "Reaches " + reached.joined(separator: ", ") + ". Not yet " + not.joined(separator: ", ") + "."
    }

    public static let personalIntro = "Every connector in your own ~/.agents/mcp.json, which every agent has. "
        + "A hosted one runs once on this machine; any other is checked every four hours, and when its entry changes. "
        + "Edit them in the Mac's Settings \u{25B8} Agent Configuration \u{25B8} Connectors."

    /// Above a folder's servers.
    public static let folderIntro = "Every connector in this folder's .agents/mcp.json. "
        + "A hosted one runs once on its machine; any other is checked every four hours, and when its entry changes. "
        + "Edit them in the folder's settings."

    public static let personalEmpty = "No connectors in ~/.agents/mcp.json yet."
    public static let folderEmpty = "No connectors in this folder's .agents/mcp.json yet."

    /// What Remove… takes out (#2154), whether the app added it or it was written by hand.
    /// `machine` names a server a folder is on (#2266); nil for this Mac's. The personal file
    /// is in no git, so the daemon keeps a copy of what went, and this says where (#2195).
    public static func removes(_ name: String, inFolder: Bool, on machine: String? = nil) -> String {
        "This removes the \(name) entry from \(inFolder ? ".agents/mcp.json" : "~/.agents/mcp.json")"
            + (machine.map { " on \($0)" } ?? "") + ". Agents started after that won't have it."
            + (inFolder ? "" : removesKept)
    }

    /// Where a removed personal entry is kept (#2195).
    public static let removesKept = " A copy of the entry is kept in ~/.agents/mcp.removed.json."

    /// Remove… found the machine offline (#2266).
    public static func notRemoved(_ name: String, offline machine: String) -> String {
        "\(name) was not removed: \(machine) is offline."
    }

    /// Remove… was refused: `why` is a sentence (#2266).
    public static func notRemoved(_ name: String, because why: String) -> String {
        "\(name) was not removed. \(why)"
    }

    /// Said too for a folder's: its mcp.json is committed (#2154).
    public static let removesCommitted = "That file is committed with the folder, so the change shows in git, and git can bring back what was committed."
}
