import AgentsKitCore
import Foundation

/// Why this Mac's host is quiet, as the window says it (#303).
///
/// The control plane being unreachable is its own strip. This is only the host: the
/// process is down, it is up and has no membership, it enrolled and its uplink is down,
/// or all of that is fine and this window lost its own way to it.
enum MacHostNotice: Equatable {
    /// The process is not reporting a join. Open Agents Host.
    case notRunning
    /// The process is up and has no membership. `problem` is the reason it gave.
    case notJoined(problem: String?)
    /// It enrolled, and its uplink is down. Try Again redials.
    case notAnswering
    /// It is running and enrolled, and says why its uplink keeps failing (#678): the
    /// control plane or the way to it, not the host process.
    case uplinkFailing(problem: String)
    /// The host is up at the control plane, and this window is not reaching it (#445):
    /// the window's own connection, not the host. Try Again dials a fresh one.
    case windowLost

    /// `macState` is this Mac's row in `machines/list` (`online`, `offline`, …), or nil when
    /// it has no row. `join` is `control/status.thisMacHost`. A plane that is not on this
    /// Mac does not read that file, so a missing join there is not "the process is down".
    /// `windowMissed` is a try of the window's own that failed, so a host that is up is
    /// the window's connection, not "still connecting".
    static func decide(planeOnThisMac: Bool, macState: String?, join: DaemonAPI.MachineJoinStatus?,
                       windowMissed: Bool = false) -> MacHostNotice? {
        let up: MacHostNotice? = windowMissed ? .windowLost : nil
        if let join {
            if !join.member { return .notJoined(problem: join.problem) }
            if !join.connected {
                if let problem = join.problem, !problem.isEmpty { return .uplinkFailing(problem: problem) }
                return .notAnswering
            }
            // The join says connected and the control plane's list says otherwise.
            if let macState, !DaemonAPI.ControlMachine.answers(macState) { return .notAnswering }
            return up
        }
        guard planeOnThisMac else { return macState == nil ? nil : (DaemonAPI.ControlMachine.answers(macState) ? up : .notAnswering) }
        // Beside this Mac, a live host writes its join. No report, and not online, means
        // the process is down. Online with no report yet is the window still connecting.
        return DaemonAPI.ControlMachine.answers(macState) ? up : .notRunning
    }

    var title: String {
        switch self {
        case .notRunning: "This Mac isn’t running as a machine"
        case .notJoined: "This Mac hasn’t joined"
        case .notAnswering: "This Mac isn’t answering"
        case .uplinkFailing: "This Mac can’t reach the control plane"
        case .windowLost: "This window lost its connection to this Mac"
        }
    }

    var detail: String {
        switch self {
        case .notRunning:
            "Open Agents Host. It says why, Repair there starts it again, and Copy Diagnostics there is what to send with a report."
        case .notJoined(let problem):
            if let problem, !problem.isEmpty {
                "It’s running, and it has no membership. \(Self.sentence(problem)) Open Agents Host and press Try Again there."
            } else {
                "It’s running, and it still needs to join. Open Agents Host and press Try Again there."
            }
        case .notAnswering:
            "What’s listed is what it last said. The window is trying again by itself."
        case .uplinkFailing(let problem):
            "It’s running, and its link to the control plane keeps failing. \(Self.sentence(problem)) It’s trying again by itself; Agents Host’s Copy Diagnostics says more."
        case .windowLost:
            "This Mac and the control plane are both up. What’s listed is what the window last heard, and it’s reconnecting by itself."
        }
    }

    /// What an action aimed at this Mac's host says.
    var action: String {
        switch self {
        case .notRunning:
            "This Mac isn’t running as a machine, so that didn’t happen. Open Agents Host."
        case .notJoined:
            "This Mac hasn’t joined the control plane, so that didn’t happen. Open Agents Host and press Try Again there."
        case .notAnswering:
            "This Mac isn’t answering, so that didn’t happen. The window is trying again by itself; Try Again tries now."
        case .uplinkFailing:
            "This Mac can’t reach the control plane, so that didn’t happen. It’s trying again by itself; Try Again tries now."
        case .windowLost:
            "This window lost its connection to this Mac, so that didn’t happen. It’s reconnecting by itself; Try Again tries now."
        }
    }

    /// The strip over a chat, with since when the window lost it.
    func strip(since: String?) -> String {
        switch self {
        case .notRunning:
            "This Mac isn’t running as a machine\(Self.since(since)). Open Agents Host. Nothing here can change until it is."
        case .notJoined:
            "This Mac hasn’t joined the control plane\(Self.since(since)). Open Agents Host and press Try Again there. Nothing here can change until it has."
        case .notAnswering:
            OfflineWords.line(host: .mac, name: "This Mac", since: since)
        case .uplinkFailing(let problem):
            "This Mac is up and can’t reach the control plane\(Self.since(since)). \(Self.sentence(problem)) It’s trying again by itself."
        case .windowLost:
            "This window lost its connection to this Mac\(Self.since(since)). This Mac is up, and the window is reconnecting by itself."
        }
    }

    /// A tooltip's few words.
    var tooltip: String { title }

    private static func since(_ since: String?) -> String {
        since.map { " since \($0)" } ?? ""
    }

    /// The daemon's reason, as one sentence.
    private static func sentence(_ problem: String) -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let head = String(first).uppercased() + trimmed.dropFirst()
        return head.hasSuffix(".") ? head : head + "."
    }
}
