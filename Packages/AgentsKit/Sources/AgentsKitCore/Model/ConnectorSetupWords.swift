import Foundation

/// The words of a project's Connectors set-up (#1336) and the one Connect sheet. The same on
/// the Mac, the Remote and the web page (`Web/src/model/connectorSetup.ts`).
public enum ConnectorSetupWords {
    public typealias Slot = DaemonAPI.ConnectorSlot
    public typealias Setup = DaemonAPI.ConnectorSetup

    public static let connectTitle = "Connect GitHub once: issues, pull requests and Actions."
    public static let connectNote = "Your connection, for every project. You choose on github.com which repositories Agents can see."
    public static let connectButton = "Connect GitHub\u{2026}"

    /// The sheet's list of what Agents will be able to do, from the App's permissions.
    public static let abilities = [
        "Read and write issues",
        "Read and write pull requests and reviews",
        "Read checks and Actions runs",
        "Read and push code",
    ]
    public static let sheetSubtitle = "For you, in every project. Agents talks to GitHub's API directly."
    public static let sheetChoose = "On github.com you choose which repositories. You can take it back there, or with Disconnect on Your Connectors."
    public static let sheetFoot = "The token is kept by the host, never in a log."
    public static let continueButton = "Continue on github.com"
    /// Where the person installs the App on the project's repository.
    public static let installURL = "https://github.com/apps/agents-loops/installations/new"
    /// Where the person sees and changes which repositories the App reaches.
    public static let installationsURL = "https://github.com/settings/installations"

    /// The page's line under its title.
    public static func intro(project: String, repository: String?) -> String {
        guard let repository else { return "What agents in \(project) can reach. It has no GitHub remote." }
        return "What agents in \(project) can reach. Repository github.com/\(repository), from its git remote."
    }

    /// The connection, as one line once connected.
    public static func connected(_ c: DaemonAPI.Connection) -> String {
        c.state == .signInAgain ? "GitHub asks you to sign in again" : "Connected to GitHub as \(c.login ?? "you")"
    }

    public static func connectedNote(_ setup: Setup) -> String {
        var parts = ["Your connection, for every project"]
        if let n = setup.repositories { parts.append(n == 1 ? "sees 1 repository" : "sees \(n) repositories") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Said when the App is not installed on the project's repository.
    public static func notInstalled(_ repository: String) -> String {
        "The Agents app is not installed on \(repository), so agents can't write there."
    }

    public static func setUpHeading(_ setup: Setup) -> String { "Set up \u{00B7} \(setup.done) of \(setup.slots.count)" }

    /// The slot's small heading.
    public static func heading(_ kind: DaemonAPI.ConnectorSlotKind) -> String {
        switch kind {
        case .tasks: "Tasks"
        case .codeReview: "Code review"
        case .ci: "CI"
        case .workspace: "Where agents run"
        }
    }

    /// The slot's title.
    public static func title(_ slot: Slot) -> String {
        switch slot.state {
        case .skipped: "Skipped"
        case .noRemote where slot.slot == .tasks: "Choose a tracker"
        default: slot.choice
        }
    }

    /// What the slot says under its title, when it has no proof to show.
    public static func line(_ slot: Slot, project: String, repository: String?) -> String {
        let repo = repository ?? project
        switch slot.state {
        case .skipped:
            return switch slot.slot {
            case .tasks: "Agents won't use issues here. Nothing is turned on."
            case .codeReview: "Agents won't use pull requests here. Nothing is turned on."
            case .ci: "Agents won't wait on checks here. Nothing is turned on."
            case .workspace: "Agents run on this Mac."
            }
        case .noRemote:
            return "\(project) has no GitHub remote, so \(slot.choice) can't be read for it."
        case .failed, .refused:
            return slot.message ?? "The read didn't work."
        case .notRead:
            return "Reading\u{2026}"
        case .read where slot.slot == .workspace:
            return "Nothing to set up. Other places are set up in Providers."
        case .read:
            return switch slot.slot {
            case .tasks: "No issues yet in \(repo)."
            case .codeReview: "No pull requests yet in \(repo)."
            case .ci: "No workflow runs yet in \(repo)."
            case .workspace: ""
            }
        case .notConnected:
            return switch slot.slot {
            case .tasks: "Agents read, file and close issues in \(repo). Comes with the GitHub connection."
            case .codeReview: "Agents open pull requests and answer reviews. Comes with the GitHub connection."
            case .ci: "Agents see checks pass and fail, and wait on them. Comes with the GitHub connection."
            case .workspace: "Nothing to set up."
            }
        }
    }

    /// The proof's lead word: "Newest" or "Last run".
    public static func proofLead(_ kind: DaemonAPI.ConnectorSlotKind) -> String {
        kind == .ci ? "Last run" : "Newest"
    }

    /// The proof after its number, such as "Fix the walk", or "CI on main, passed 4 min ago".
    public static func proofText(_ proof: DaemonAPI.ConnectorProof, now: Date = Date()) -> String {
        var text = proof.title
        if let outcome = proof.outcome { text += ", \(outcome)" }
        if proof.number == nil, let at = proof.at { text += " \(ago(at, now: now))" }
        return text
    }

    /// The whole proof in words, for an accessibility label or a narrow screen.
    public static func proof(_ slot: Slot, now: Date = Date()) -> String? {
        guard let proof = slot.proof else { return nil }
        let number = proof.number.map { "#\($0) " } ?? ""
        return "\(proofLead(slot.slot)): \(number)\(proofText(proof, now: now))"
    }

    public static func ago(_ at: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(at))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: let h = Int(seconds / 3600); return h == 1 ? "1 hour ago" : "\(h) hours ago"
        default: let d = Int(seconds / 86_400); return d == 1 ? "yesterday" : "\(d) days ago"
        }
    }

    /// The events line's lead.
    public static func eventsLead(_ events: DaemonAPI.ConnectorEvents) -> String {
        switch events.state {
        case .on: "On for Agents:"
        case .off: "Off. They go on once a slot has read from GitHub."
        case .taken, .failed: events.message ?? "Not turned on."
        }
    }

    /// The events as the page shows them: whole nouns, such as issue.* pr.* checks.*.
    public static func eventNouns(_ names: [String]) -> [String] {
        var nouns: [String] = []
        for name in names {
            let noun = (name.split(separator: ".").first.map(String.init) ?? name) + ".*"
            if !nouns.contains(noun) { nouns.append(noun) }
        }
        return nouns
    }

    public static func workflowsLead(_ events: DaemonAPI.ConnectorEvents) -> String {
        events.workflows.isEmpty ? "No workflow here starts on them yet." : "Now usable by"
    }

    /// The Change… slot's other places, on the Remote and the web page.
    public static let otherProvidersElsewhere = "Other providers are set up on the Mac."

    // MARK: Your Connectors ▸ Connections

    public static func connectionTitle(_ c: DaemonAPI.Connection) -> String {
        c.login.map { "GitHub \u{00B7} \($0)" } ?? "GitHub"
    }

    public static func connectionNote(_ c: DaemonAPI.Connection) -> String {
        c.state == .signInAgain ? "GitHub refused the renewal: sign in again" : "OAuth \u{00B7} renews by itself"
    }

    public static let disconnectNote = "Disconnect deletes the host's tokens. Every project's GitHub slots wait for a connection again. To revoke the App too, go to github.com \u{25B8} Settings \u{25B8} Applications."

    /// A project on Your Connectors: what its set-up uses.
    public static func projectLine(_ setup: Setup) -> String {
        if setup.repository == nil { return "No GitHub remote" }
        let used = setup.slots.filter { $0.state == .read }.map(\.choice)
        return used.isEmpty ? "Not set up" : used.joined(separator: ", ")
    }

    // MARK: The sheet

    public static func sheetStatus(_ s: DaemonAPI.ConnectionSignIn) -> String {
        switch s.status {
        case .waiting: "Waiting for github.com\u{2026} Type the code there, then approve."
        case .connected: "Connected."
        case .expired: s.message ?? "The code expired before it was approved. Try again."
        case .denied: s.message ?? "The sign-in was cancelled on GitHub."
        case .cancelled: "Cancelled."
        case .failed: s.message ?? "The sign-in didn't work."
        }
    }
}
