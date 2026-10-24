import Foundation

/// The words of a folder's Connectors set-up (#1336) and the one Connect sheet. The same on
/// the Mac, the Remote and the web page (`Web/src/model/connectorSetup.ts`).
public enum ConnectorSetupWords {
    public typealias Slot = DaemonAPI.ConnectorSlot
    public typealias Setup = DaemonAPI.ConnectorSetup

    public static let connectTitle = "Connect GitHub once: issues, pull requests and Actions."
    public static let connectNote = "Your connection, for every folder. You choose on github.com which repositories Agents can see."
    public static let connectButton = "Connect GitHub\u{2026}"

    /// The sheet's list of what Agents will be able to do, from the App's permissions.
    public static let abilities = [
        "Read and write issues",
        "Read and write pull requests and reviews",
        "Read checks and Actions runs",
        "Read and push code",
        "Read, create, start and stop Codespaces",
    ]
    public static let sheetSubtitle = "For you, in every folder. Agents talks to GitHub's API directly."
    public static let sheetChoose = "On github.com you choose which repositories. You can take it back there, or with Disconnect on Connectors."
    public static let sheetFoot = "The token is kept by the machine, never in a log."
    public static let continueButton = "Continue on github.com"
    /// Where the person installs the App on the folder's repository.
    public static let installURL = "https://github.com/apps/agents-loops/installations/new"
    /// Where the person sees and changes which repositories the App reaches.
    public static let installationsURL = "https://github.com/settings/installations"

    /// The page's line under its title.
    public static func intro(folder: String, repository: String?, site: String = "github.com") -> String {
        guard let repository else { return "What agents in \(folder) can reach. It has no GitHub or GitLab remote." }
        return "What agents in \(folder) can reach. Repository \(site)/\(repository), from its git remote."
    }

    /// The connection, as one line once connected.
    public static func connected(_ c: DaemonAPI.Connection) -> String {
        c.state == .signInAgain ? "\(name(c.provider)) asks you to sign in again" : "Connected to \(name(c.provider)) as \(c.login ?? "you")"
    }

    // MARK: The forge (#1632): GitHub or GitLab fills Tasks, Code review and CI

    /// The card's title before the forge is connected.
    public static func connectTitle(_ forge: DaemonAPI.ConnectionProvider) -> String {
        forge == .gitlab ? "Connect GitLab once: issues, merge requests and pipelines." : connectTitle
    }

    public static func connectNote(_ forge: DaemonAPI.ConnectionProvider) -> String {
        forge == .gitlab ? "Your connection, for every folder. It reaches what your GitLab account can see." : connectNote
    }

    public static func connectButton(_ forge: DaemonAPI.ConnectionProvider) -> String {
        "Connect \(name(forge))\u{2026}"
    }

    /// The card's title when the forge asks to connect again.
    public static func connectAgain(_ forge: DaemonAPI.ConnectionProvider) -> String {
        "\(name(forge)) asks you to connect again."
    }

    /// A slot's choice note before it read.
    public static func comesWith(_ forge: DaemonAPI.ConnectionProvider) -> String {
        "Comes with the \(name(forge)) connection."
    }

    /// A slot's state in a word, for no remote.
    public static let noRemote = "No GitHub or GitLab remote"

    /// The button on a refused slot: GitHub's App is granted on github.com; on GitLab the
    /// person asks for access to the folder there.
    public static func grantButton(_ setup: Setup) -> String {
        setup.forgeOrGitHub == .gitlab ? "Open on \(setup.siteOrGitHub)" : "Grant on github.com"
    }

    /// Where the refused slot's button goes.
    public static func grantURL(_ setup: Setup) -> String {
        if setup.forgeOrGitHub == .gitlab, let page = setup.repositoryURL { return page }
        return setup.installURL ?? installURL
    }

    public static func connectedNote(_ setup: Setup) -> String {
        var parts = ["Your connection, for every folder"]
        if let n = setup.repositories { parts.append(n == 1 ? "sees 1 repository" : "sees \(n) repositories") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Said when the App is not installed on the folder's repository.
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
    public static func line(_ slot: Slot, folder: String, repository: String?,
                            forge: DaemonAPI.ConnectionProvider = .github) -> String {
        let repo = repository ?? folder
        let gitlab = forge == .gitlab
        switch slot.state {
        case .skipped:
            return switch slot.slot {
            case .tasks: "Agents won't use issues here. Nothing is turned on."
            case .codeReview: gitlab ? "Agents won't use merge requests here. Nothing is turned on."
                : "Agents won't use pull requests here. Nothing is turned on."
            case .ci: "Agents won't wait on checks here. Nothing is turned on."
            case .workspace: "Agents run on this Mac."
            }
        case .noRemote:
            return "\(folder) has no GitHub or GitLab remote, so \(slot.choice) can't be read for it."
        case .failed, .refused:
            return slot.message ?? "The read didn't work."
        case .notRead:
            return "Reading\u{2026}"
        case .read where slot.slot == .workspace:
            return "Nothing to set up. Other places are set up in Providers."
        case .read:
            return switch slot.slot {
            case .tasks: "No issues yet in \(repo)."
            case .codeReview: gitlab ? "No merge requests yet in \(repo)." : "No pull requests yet in \(repo)."
            case .ci: gitlab ? "No pipelines yet in \(repo)." : "No workflow runs yet in \(repo)."
            case .workspace: ""
            }
        case .notConnected:
            return switch slot.slot {
            case .tasks: "Agents read, file and close issues in \(repo). " + comesWith(forge)
            case .codeReview: gitlab ? "Agents read merge requests and answer their comments. " + comesWith(forge)
                : "Agents open pull requests and answer reviews. " + comesWith(forge)
            case .ci: gitlab ? "Agents see pipelines pass and fail, and wait on them. " + comesWith(forge)
                : "Agents see checks pass and fail, and wait on them. " + comesWith(forge)
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
    public static func eventsLead(_ events: DaemonAPI.ConnectorEvents, forge: DaemonAPI.ConnectionProvider = .github) -> String {
        switch events.state {
        case .on: "On for Agents:"
        case .off: "Off. They go on once a slot has read from \(name(forge))."
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

    /// The Tasks slot's way to Linear (#1682): the connection first, then its connector.
    public static let connectLinear = "Connect Linear\u{2026}"

    /// The Tasks slot's other trackers, on the Remote and the web page, which have no catalogue.
    public static func otherTrackers(linearConnected: Bool) -> String {
        linearConnected ? "Linear and other trackers: Add Connector on the Mac."
            : "Then add its connector, or another tracker's, with Add Connector on the Mac."
    }

    // MARK: Connectors ▸ Connections

    public static let noConnections = "No connections yet. Connect GitHub to give agents issues, pull requests and Actions in every folder, Linear for its issues, GitLab for merge requests, pipelines and issues, and Email for the mail they wait for."

    /// The provider's name: GitHub, Linear.
    public static func name(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "GitHub"
        case .linear: "Linear"
        case .gitlab: "GitLab"
        case .email: Email.name
        }
    }

    /// The provider's two letters on its mark.
    public static func letters(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "GH"
        case .linear: "L"
        case .gitlab: "GL"
        case .email: Email.letters
        }
    }

    public static func connectionTitle(_ c: DaemonAPI.Connection) -> String {
        c.login.map { "\(name(c.provider)) \u{00B7} \($0)" } ?? name(c.provider)
    }

    public static func connectionNote(_ c: DaemonAPI.Connection, now: Date = Date()) -> String {
        // An app password does not end and is not renewed: the server and how it signs in.
        if c.provider == .email { return [c.workspace, Email.how].compactMap { $0 }.joined(separator: " \u{00B7} ") }
        if c.state == .signInAgain {
            return c.expiresAt == nil ? "\(name(c.provider)) refused the renewal: sign in again"
                : "The access token ended: connect again with a new one"
        }
        let how = c.expiresAt.map { "Access token \u{00B7} " + tokenEnds($0, now: now) } ?? "OAuth \u{00B7} renews by itself"
        return [c.workspace, how].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// When an access token ends, such as "ends 18 Oct 2027".
    public static func tokenEnds(_ at: Date, now: Date = Date()) -> String {
        // GitLab gives a day, in UTC; the same words as the web page's, in any locale.
        var style = Date.VerbatimFormatStyle(format: "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)",
                                             timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian))
        style.locale = Locale(identifier: "en_GB")
        // The host keeps the end of GitLab's last day (midnight after it): say that day.
        return at <= now ? "ended" : "ends \(at.addingTimeInterval(-1).formatted(style))"
    }

    /// A provider with no connection yet, on Connectors.
    public static func notConnectedNote(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "Issues, pull requests and Actions in every folder."
        case .linear: "Linear issues in every folder, and their events."
        case .gitlab: "Merge requests, pipelines and issues on gitlab.com or your own GitLab."
        case .email: Email.notConnectedNote
        }
    }

    public static let disconnectNote = "Disconnect deletes the machine's tokens. Every folder's GitHub slots wait for a connection again. To revoke the App too, go to github.com \u{25B8} Settings \u{25B8} Applications."

    public static func disconnectNote(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: disconnectNote
        case .linear: "Disconnect deletes the machine's tokens. Linear's events stop until you connect again or set LINEAR_API_KEY. To revoke Agents too, go to linear.app \u{25B8} Settings \u{25B8} Security & access."
        case .gitlab: GitLab.disconnectNote
        case .email: Email.disconnectNote
        }
    }

    /// Disconnect's message: which folders lose which slots, before it goes, then the note.
    /// Only a folder on that connection's forge loses anything (#1868): GitHub fills a GitHub
    /// folder's slots and GitLab a GitLab folder's (#1632); other connections fill none.
    public static func disconnectMessage(_ p: DaemonAPI.ConnectionProvider,
                                         folders: [(name: String, setup: Setup)]) -> String {
        guard p == .github || p == .gitlab else { return disconnectNote(p) }
        let losing = folders.compactMap { folder -> String? in
            guard folder.setup.forgeOrGitHub == p else { return nil }
            let slots = folder.setup.slots.filter { $0.slot != .workspace && $0.state == .read }.map { heading($0.slot) }
            return slots.isEmpty ? nil : "\(folder.name) loses \(slots.joined(separator: ", "))."
        }
        return (losing + [disconnectNote(p)]).joined(separator: " ")
    }

    /// A folder on Connectors: what its set-up uses.
    public static func folderLine(_ setup: Setup) -> String {
        if setup.repository == nil { return noRemote }
        let used = setup.slots.filter { $0.state == .read }.map(\.choice)
        return used.isEmpty ? "Not set up" : used.joined(separator: ", ")
    }

    // MARK: The sheet

    /// Connect Linear (#1343, frame H): the same sheet, its own list.
    public enum Linear {
        public static let abilities = [
            "Read and write issues",
            "Read folders and cycles",
            "Comment as you",
        ]
        public static let subtitle = "For you, in every folder. Agents talks to Linear's API directly."
        public static let choose = "On linear.app you choose the workspace. You can take it back there, or with Disconnect on Connectors."
        public static let continueButton = "Continue on linear.app"
        public static let waiting = "Waiting for linear.app\u{2026} Approve there, and Agents comes back by itself."
        public static let finishing = "Finishing the sign-in\u{2026}"
    }

    /// Connect GitLab (#1630): gitlab.com by its device page, or any GitLab by an access token.
    public enum GitLab {
        public static let abilities = [
            "Read and write merge requests and their comments",
            "Read pipelines and jobs",
            "Read and write issues",
        ]
        public static let subtitle = "For you, in every folder. Agents talks to GitLab's API directly."
        public static let choose = "GitLab asks for the api scope. You can take it back on GitLab \u{25B8} Preferences \u{25B8} Applications, or with Disconnect on Connectors."
        public static let continueButton = "Continue on gitlab.com"
        /// The two ways in, as the sheet's picker says them.
        public static let signInWay = "gitlab.com"
        public static let tokenWay = "Access token"
        public static let tokenIntro = "For a self-managed GitLab, or gitlab.com without the sign-in: make a personal access token with the api scope, and paste it here."
        public static let addressLabel = "GitLab address"
        public static let addressPrompt = "https://gitlab.com"
        public static let tokenLabel = "Access token"
        public static let tokenPrompt = "glpat-\u{2026}"
        public static let tokenButton = "Connect"
        public static let checking = "Checking the token with GitLab\u{2026}"
        public static let disconnectNote = "Disconnect deletes the machine's token. Every folder's GitLab slots wait for a connection again. GitLab's events stop until you connect again or set GITLAB_TOKEN. To revoke it too, go to GitLab \u{25B8} Preferences \u{25B8} Applications or Access tokens."

        /// How Connect Again\u{2026} opens for an ended GitLab connection (#1865): on Access token,
        /// with its GitLab's address, when it was an access token or a self-managed GitLab; on the
        /// gitlab.com sign-in when it was that sign-in.
        public static func again(_ c: DaemonAPI.Connection) -> (withToken: Bool, address: String) {
            if let host = c.workspace { return (true, "https://" + host) }
            return c.expiresAt == nil ? (false, "") : (true, addressPrompt)
        }

        /// Where the person makes a token on the GitLab at address (gitlab.com when empty).
        public static func newTokenURL(_ address: String) -> String {
            var root = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.isEmpty { root = "https://gitlab.com" }
            if !root.contains("://") { root = "https://" + root }
            while root.hasSuffix("/") { root.removeLast() }
            if root.hasSuffix("/api/v4") { root.removeLast("/api/v4".count) }
            return root + "/-/user_settings/personal_access_tokens?name=Agents&scopes=api"
        }
    }

    /// Connect Email (#1780): one IMAP mailbox and its app password. No device page.
    public enum Email {
        public static let name = "Email"
        public static let letters = "EM"
        /// The sheet's foot: an app password, not a token.
        public static let sheetFoot = "The app password is kept by the machine, never in a log."
        public static let notConnectedNote = "One mailbox for agents: they wait for mail, such as a sign-up code, and read it."
        public static let subtitle = "For you, in every folder. Agents reads the mailbox over IMAP and never sends mail."
        public static let abilities = [
            "Know when mail comes, by sender and subject",
            "List, search and read messages",
            "Mark messages read and move them to another folder",
        ]
        public static let intro = "Use a mailbox made for agents, not your own. Make an app password for Agents at your mail provider, and give its IMAP server."
        public static let serverLabel = "IMAP server"
        public static let serverPrompt = "imap.fastmail.com"
        public static let userLabel = "User"
        public static let userPrompt = "agents@example.com"
        public static let passwordLabel = "App password"
        public static let passwordPrompt = "App password"
        public static let button = "Connect"
        public static let checking = "Signing in to the mail server\u{2026}"
        public static let choose = "Agents can read every message in this mailbox. It never sends, answers or deletes mail. Take the app password back at your mail provider, or with Disconnect on Connectors."
        public static let disconnectNote = "Disconnect deletes the machine's app password. The email server's events stop until you connect again or set EMAIL_PASSWORD. To revoke it too, delete the app password at your mail provider."
        /// The connection's note after its server: how it signs in.
        public static let how = "App password"
        /// When the host gives no words of its own for a failed sign-in.
        public static let failed = "The mail server did not take the sign-in."
    }

    /// The sheet's subtitle, list and button, by provider.
    public static func sheetSubtitle(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: sheetSubtitle
        case .linear: Linear.subtitle
        case .gitlab: GitLab.subtitle
        case .email: Email.subtitle
        }
    }

    public static func abilities(_ p: DaemonAPI.ConnectionProvider) -> [String] {
        switch p {
        case .github: abilities
        case .linear: Linear.abilities
        case .gitlab: GitLab.abilities
        case .email: Email.abilities
        }
    }

    public static func sheetChoose(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: sheetChoose
        case .linear: Linear.choose
        case .gitlab: GitLab.choose
        case .email: Email.choose
        }
    }

    public static func continueButton(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: continueButton
        case .linear: Linear.continueButton
        case .gitlab: GitLab.continueButton
        case .email: Email.button
        }
    }

    /// The device page's site, for "Open github.com Again".
    public static func site(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "github.com"
        case .linear: "linear.app"
        case .gitlab: "gitlab.com"
        // Email has no device page: the sheet never shows this.
        case .email: ""
        }
    }

    public static func sheetStatus(_ s: DaemonAPI.ConnectionSignIn) -> String {
        switch s.status {
        case .waiting where s.grant == .authorizationCode: Linear.waiting
        case .waiting: "Waiting for \(site(s.provider))\u{2026} Type the code there, then approve."
        case .connected: "Connected."
        case .expired: s.message ?? "The code expired before it was approved. Try again."
        case .denied: s.message ?? "The sign-in was cancelled on \(name(s.provider))."
        case .cancelled: "Cancelled."
        case .failed: s.message ?? "The sign-in didn't work."
        }
    }
}
