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
    /// The host is up at the control plane, and this window is not reaching it (#445):
    /// the window's own connection, not the host. Try Again dials a fresh one.
    case windowLost

    /// `macState` is this Mac's row in `hosts/list` (`online`, `offline`, …), or nil when
    /// it has no row. `join` is `control/status.thisMacHost`. A plane that is not on this
    /// Mac does not read that file, so a missing join there is not "the process is down".
    /// `windowMissed` is a try of the window's own that failed, so a host that is up is
    /// the window's connection, not "still connecting".
    static func decide(planeOnThisMac: Bool, macState: String?, join: DaemonAPI.HostJoinStatus?,
                       windowMissed: Bool = false) -> MacHostNotice? {
        let up: MacHostNotice? = windowMissed ? .windowLost : nil
        if let join {
            if !join.member { return .notJoined(problem: join.problem) }
            if !join.connected { return .notAnswering }
            // The join says connected and the control plane's list says otherwise.
            if let macState, macState != "online" { return .notAnswering }
            return up
        }
        guard planeOnThisMac else { return macState == nil ? nil : (macState == "online" ? up : .notAnswering) }
        // Beside this Mac, a live host writes its join. No report, and not online, means
        // the process is down. Online with no report yet is the window still connecting.
        return macState == "online" ? up : .notRunning
    }

    var title: String {
        switch self {
        case .notRunning: "This Mac’s host isn’t running"
        case .notJoined: "This Mac’s host hasn’t joined"
        case .notAnswering: "This Mac’s host isn’t answering"
        case .windowLost: "This window lost its connection to this Mac’s host"
        }
    }

    var detail: String {
        switch self {
        case .notRunning:
            "Open Agents Host. It starts this Mac’s host, and Try Again there joins it if it never enrolled."
        case .notJoined(let problem):
            if let problem, !problem.isEmpty {
                "It’s running, and it has no membership. \(Self.sentence(problem)) Open Agents Host and press Try Again there."
            } else {
                "It’s running, and it still needs to join. Open Agents Host and press Try Again there."
            }
        case .notAnswering:
            "What’s listed is what it last said. The window is trying again by itself."
        case .windowLost:
            "The host and the control plane are both up. What’s listed is what the window last heard, and it’s reconnecting by itself."
        }
    }

    /// What an action aimed at this Mac's host says.
    var action: String {
        switch self {
        case .notRunning:
            "This Mac’s host isn’t running, so that didn’t happen. Open Agents Host."
        case .notJoined:
            "This Mac’s host hasn’t joined the control plane, so that didn’t happen. Open Agents Host and press Try Again there."
        case .notAnswering:
            "This Mac’s host isn’t answering, so that didn’t happen. The window is trying again by itself; Try Again tries now."
        case .windowLost:
            "This window lost its connection to this Mac’s host, so that didn’t happen. It’s reconnecting by itself; Try Again tries now."
        }
    }

    /// The strip over a chat, with since when the window lost it.
    func strip(since: String?) -> String {
        switch self {
        case .notRunning:
            "This Mac’s host isn’t running\(Self.since(since)). Open Agents Host. Nothing here can change until it is."
        case .notJoined:
            "This Mac’s host hasn’t joined the control plane\(Self.since(since)). Open Agents Host and press Try Again there. Nothing here can change until it has."
        case .notAnswering:
            OfflineWords.line(host: .mac, name: "This Mac", since: since)
        case .windowLost:
            "This window lost its connection to this Mac’s host\(Self.since(since)). The host is up, and the window is reconnecting by itself."
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
