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
        guard let repository else { return "What agents in \(folder) can reach. It has no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote." }
        return "What agents in \(folder) can reach. Repository \(site)/\(repository), from its git remote."
    }

    /// The connection, as one line once connected.
    public static func connected(_ c: DaemonAPI.Connection) -> String {
        c.state == .signInAgain ? "\(name(c.provider)) asks you to sign in again" : "Connected to \(name(c.provider)) as \(c.login ?? "you")"
    }

    // MARK: The forge (#1632, #3752, #3785, #3802): GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps fills Tasks, Code review and CI

    /// The card's title before the forge is connected.
    public static func connectTitle(_ forge: DaemonAPI.ConnectionProvider) -> String {
        switch forge {
        case .gitlab: "Connect GitLab once: issues, merge requests and pipelines."
        case .forgejo: Forgejo.connectTitle
        case .bitbucket: Bitbucket.connectTitle
        case .azuredevops: AzureDevOps.connectTitle
        default: connectTitle
        }
    }

    public static func connectNote(_ forge: DaemonAPI.ConnectionProvider) -> String {
        switch forge {
        case .gitlab, .forgejo, .bitbucket, .azuredevops: "Your connection, for every folder. It reaches what your \(name(forge)) account can see."
        default: connectNote
        }
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
    public static let noRemote = "No GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote"

    /// The card in place of Connect when the folder's forge is one this client does not know
    /// (a newer host's, #3802): the set-up is the host's, but this app can't connect it.
    public static func unknownForge(_ setup: Setup) -> String {
        "\(setup.siteOrGitHub) is on a forge this version of Agents can't connect (\(setup.unknownForge ?? "unknown")). Update Agents to set it up here."
    }

    /// The button on a refused slot: GitHub's App is granted on github.com; on GitLab, Forgejo,
    /// Bitbucket and Azure DevOps the person asks for access to the repository there.
    public static func grantButton(_ setup: Setup) -> String {
        setup.forgeOrGitHub == .github ? "Grant on github.com" : "Open on \(setup.siteOrGitHub)"
    }

    /// Where the refused slot's button goes.
    public static func grantURL(_ setup: Setup) -> String {
        if setup.forgeOrGitHub != .github, let page = setup.repositoryURL { return page }
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
        case .docs: "Docs"
        case .messaging: "Messaging"
        case .workspace: "Where agents run"
        }
    }

    /// The slot's title.
    public static func title(_ slot: Slot) -> String {
        switch slot.state {
        case .skipped where slot.slot == .messaging: "None"
        case .skipped: "Skipped"
        case .noRemote where slot.slot == .tasks: "Choose a tracker"
        default: slot.choice
        }
    }

    /// What the slot says under its title, when it has no proof to show.
    public static func line(_ slot: Slot, folder: String, repository: String?,
                            forge: DaemonAPI.ConnectionProvider = .github) -> String {
        let repo = repository ?? folder
        let gitlab = forge == .gitlab, checks = forge == .forgejo || forge == .bitbucket, azure = forge == .azuredevops
        switch slot.state {
        case .skipped:
            return switch slot.slot {
            case .tasks: "Agents won't use issues here. Nothing is turned on."
            case .codeReview: gitlab ? "Agents won't use merge requests here. Nothing is turned on."
                : "Agents won't use pull requests here. Nothing is turned on."
            case .ci: "Agents won't wait on checks here. Nothing is turned on."
            case .docs: "Agents won't look for docs before they work. Nothing is turned on."
            case .messaging: Messaging.noneLine(skipped: !(slot.servers ?? []).isEmpty)
            case .workspace: "Agents run on this Mac."
            }
        case .noRemote:
            return "\(folder) has no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote, so \(slot.choice) can't be read for it."
        case .failed, .refused:
            return slot.message ?? "The read didn't work."
        case .notRead:
            return "Reading\u{2026}"
        case .read where slot.slot == .docs:
            return Docs.none
        case .read where slot.slot == .workspace:
            return "Nothing to set up. Other places are set up in Providers."
        case .read:
            return switch slot.slot {
            case .tasks: azure ? "No work items yet in \(repo)'s project." : "No issues yet in \(repo)."
            case .codeReview: gitlab ? "No merge requests yet in \(repo)." : "No pull requests yet in \(repo)."
            case .ci: gitlab ? "No pipelines yet in \(repo)." : azure ? "No builds yet in \(repo)."
                : checks ? "No checks yet on \(repo)'s default branch." : "No workflow runs yet in \(repo)."
            case .docs, .messaging, .workspace: ""
            }
        case .notConnected:
            return switch slot.slot {
            case .tasks: azure ? "Agents read, file and close work items in \(repo)'s project. " + comesWith(forge)
                : "Agents read, file and close issues in \(repo). " + comesWith(forge)
            case .codeReview: gitlab ? "Agents read merge requests and answer their comments. " + comesWith(forge)
                : "Agents open pull requests and answer reviews. " + comesWith(forge)
            case .ci: gitlab || azure ? "Agents see pipelines pass and fail, and wait on them. " + comesWith(forge)
                : "Agents see checks pass and fail, and wait on them. " + comesWith(forge)
            case .docs: Docs.none
            case .messaging: Messaging.noneLine(skipped: false)
            case .workspace: "Nothing to set up."
            }
        }
    }

    /// The Docs slot (#3248): where the folder's docs live, so that agents read the requirements
    /// and designs behind an issue before they work on it.
    public enum Docs {
        public static let question = "Where do your docs live?"
        /// A read of this folder that found no docs.
        public static let none = "No docs yet in specs/, docs/ or a *.md file at the top."
        public static let thisFolderNote = "specs/, docs/ and the *.md files at the top. Nothing to connect."
        public static let confluenceNote = "Atlassian's own connector, with the same sign-in as Jira."
        public static let notionNote = "Notion's own connector."
        public static let googleDriveNote = "A Google Drive connector."
        public static let catalogueNote = "Any other connector that can search and read docs."
        public static let noneNote = "Skip: agents won't look for docs here."
        /// The web page has no catalogue: the connectors are added on the Mac.
        public static let addOnTheMac = "Confluence, Notion, Google Drive and other docs connectors: add them on the Mac, in Add Connector\u{2026}."

        /// The catalogue's search for each choice.
        public static let confluenceSearch = "atlassian"
        public static let notionSearch = "notion"
        public static let googleDriveSearch = "google drive"

        /// The docs connectors beside this folder, under the title.
        public static func servers(_ names: [String]) -> String? {
            names.isEmpty ? nil : "Connectors: " + names.joined(separator: ", ")
        }

        /// One docs connector's line (#3307): the first doc its one search found, or why not.
        public static func serverLine(_ server: DaemonAPI.DocsServer) -> String {
            let words: String = switch server.state {
            case .read: server.proof.map { "found \u{201C}\($0.title)\u{201D}" } ?? "searched, and found no doc."
            case .notRead: "searching\u{2026}"
            case .noMap: "no map of its search yet. Ask an agent to map it (the map-a-docs-server skill)."
            case .failed: server.message ?? "the search didn't work."
            }
            return "\(server.name): \(words)"
        }
    }

    /// The Messaging slot (#1787): where agents reach you. Slack, email and chat apps are MCP
    /// servers with events and tools, so the slot is the connectors that reach the folder.
    public enum Messaging {
        public static let question = "Where do agents reach you?"
        public static let slackNote = "A Slack connector: messages to and from your channels."
        public static let emailNote = "Connect Email, then add its connector. It reads mail and never sends it."
        public static let googleChatNote = "A Google Chat connector."
        public static let catalogueNote = "WhatsApp, Discord, Telegram, Teams or another chat connector."
        public static let noneNote = "Agents reach you in the app only."

        /// The catalogue's search for each choice.
        public static let slackSearch = "slack"
        public static let googleChatSearch = "google chat"

        /// The line of a slot that is None: with no connector yet, or skipped with some.
        public static func noneLine(skipped: Bool) -> String {
            skipped ? "Agents reach you in the app only. Its connectors stay, and their events with them."
                : "Agents reach you in the app only. Add a Slack, email or chat connector to reach you there too."
        }

        /// One messaging connector's line: what its one read found and the events it declares,
        /// or why not.
        public static func serverLine(_ server: DaemonAPI.MessagingServer) -> String {
            let label = server.word == server.name ? server.name : "\(server.word) (\(server.name))"
            var words: String = switch server.state {
            case .read: "read \(server.proof?.title ?? "it")"
            case .notRead: "reading\u{2026}"
            case .failed: server.message ?? "the read didn't work."
            }
            if server.state == .read, let events = server.events, !events.isEmpty {
                words += "; events " + events.joined(separator: ", ")
            }
            return "\(label): \(words)"
        }
    }

    /// The proof's lead word: "Newest", "Last run" or "Read".
    public static func proofLead(_ kind: DaemonAPI.ConnectorSlotKind) -> String {
        switch kind {
        case .ci: "Last run"
        case .messaging: "Read"
        default: "Newest"
        }
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

    /// The Tasks slot's way to Jira (#3304): the Atlassian connection first, then its connector.
    public static let connectJira = "Connect Jira\u{2026}"

    /// The Tasks slot's other trackers, on the Remote and the web page, which have no catalogue.
    public static func otherTrackers(linearConnected: Bool) -> String {
        linearConnected ? "Linear and other trackers: Add Connector on the Mac."
            : "Then add its connector, or another tracker's, with Add Connector on the Mac."
    }

    // MARK: Connectors ▸ Connections

    public static let noConnections = "No connections yet. Connect GitHub to give agents issues, pull requests and Actions in every folder, Linear or Jira for their issues, GitLab for merge requests, pipelines and issues, Forgejo for pull requests, checks and issues on Codeberg or your own Forgejo or Gitea, Bitbucket for the same on Bitbucket Cloud, Azure DevOps for pull requests, pipelines and work items on dev.azure.com or your own Azure DevOps Server, and Email for the mail they wait for."

    /// The provider's name: GitHub, Linear.
    public static func name(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "GitHub"
        case .linear: "Linear"
        case .gitlab: "GitLab"
        case .email: Email.name
        case .atlassian: Jira.provider
        case .forgejo: Forgejo.name
        case .bitbucket: Bitbucket.name
        case .azuredevops: AzureDevOps.name
        }
    }

    /// The provider in Connect…'s menu: Atlassian's connection says what it is for (#3304).
    public static func menuName(_ p: DaemonAPI.ConnectionProvider) -> String {
        p == .atlassian ? Jira.menuName : name(p)
    }

    /// The provider's two letters on its mark.
    public static func letters(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "GH"
        case .linear: "L"
        case .gitlab: "GL"
        case .email: Email.letters
        case .atlassian: Jira.letters
        case .forgejo: Forgejo.letters
        case .bitbucket: Bitbucket.letters
        case .azuredevops: AzureDevOps.letters
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
        let how = c.expiresAt.map { "Access token \u{00B7} " + tokenEnds($0, now: now) }
            ?? tokenHow(c.provider) ?? (c.byToken == true ? Jira.tokenWay : "OAuth \u{00B7} renews by itself")
        return [c.workspace, how].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// How a token sheet's connection signs in, after its host; nil for the others.
    private static func tokenHow(_ p: DaemonAPI.ConnectionProvider) -> String? {
        switch p {
        case .forgejo: Forgejo.how
        case .bitbucket: Bitbucket.how
        case .azuredevops: AzureDevOps.how
        default: nil
        }
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

    // MARK: A connection that ended (#3407): the Connectors rows turn red

    /// Whether a connection ended: the provider refused its renewal (a grant taken back), or
    /// its access token's end has passed (a GitLab token).
    public static func hasEnded(_ c: DaemonAPI.Connection, now: Date = Date()) -> Bool {
        c.state == .signInAgain || c.expiresAt.map { $0 <= now } == true
    }

    /// The connections that ended, in the list's order.
    public static func ended(_ connections: [DaemonAPI.Connection], now: Date = Date()) -> [DaemonAPI.Connection] {
        connections.filter { hasEnded($0, now: now) }
    }

    /// What a Connectors row's tooltip says of them: "Your GitLab connection ended". Nil with none.
    public static func endedLine(_ ended: [DaemonAPI.Connection]) -> String? {
        let names = ended.map { name($0.provider) }
        switch names.count {
        case 0: return nil
        case 1: return "Your \(names[0]) connection ended"
        default: return "Your \(names.dropLast().joined(separator: ", ")) and \(names.last!) connections ended"
        }
    }

    /// A provider with no connection yet, on Connectors.
    public static func notConnectedNote(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: "Issues, pull requests and Actions in every folder."
        case .linear: "Linear issues in every folder, and their events."
        case .gitlab: "Merge requests, pipelines and issues on gitlab.com or your own GitLab."
        case .email: Email.notConnectedNote
        case .atlassian: Jira.notConnectedNote
        case .forgejo: Forgejo.notConnectedNote
        case .bitbucket: Bitbucket.notConnectedNote
        case .azuredevops: AzureDevOps.notConnectedNote
        }
    }

    public static let disconnectNote = "Disconnect deletes the machine's tokens. Every folder's GitHub slots wait for a connection again. To revoke the App too, go to github.com \u{25B8} Settings \u{25B8} Applications."

    public static func disconnectNote(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: disconnectNote
        case .linear: "Disconnect deletes the machine's tokens. Linear's events stop until you connect again or set LINEAR_API_KEY. To revoke Agents too, go to linear.app \u{25B8} Settings \u{25B8} Security & access."
        case .gitlab: GitLab.disconnectNote
        case .email: Email.disconnectNote
        case .atlassian: Jira.disconnectNote
        case .forgejo: Forgejo.disconnectNote
        case .bitbucket: Bitbucket.disconnectNote
        case .azuredevops: AzureDevOps.disconnectNote
        }
    }

    /// Disconnect's message: which folders lose which slots, before it goes, then the note.
    /// Only a folder on that connection's forge loses anything (#1868): GitHub fills a GitHub
    /// folder's slots, GitLab a GitLab folder's (#1632), Forgejo a Forgejo folder's (#3752),
    /// Bitbucket a Bitbucket folder's (#3785) and Azure DevOps an Azure DevOps folder's (#3802);
    /// other connections fill none.
    public static func disconnectMessage(_ p: DaemonAPI.ConnectionProvider,
                                         folders: [(name: String, setup: Setup)]) -> String {
        guard p == .github || p == .gitlab || p == .forgejo || p == .bitbucket || p == .azuredevops else { return disconnectNote(p) }
        let losing = folders.compactMap { folder -> String? in
            guard folder.setup.forgeOrGitHub == p else { return nil }
            let slots = folder.setup.slots.filter { $0.slot.isProjects && $0.state == .read }.map { heading($0.slot) }
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
    /// The person's agents' bot (#3858): a GitHub App of their own, so agents post as
    /// <login>-agents[bot] and not as the person. The web page's words are the same
    /// (Web/src/model/connectorSetup.ts, botWords).
    public enum Bot {
        public static let title = "Agents' bot"
        public static let makeButton = "Make My Agents' Bot\u{2026}"
        public static let sheetTitle = "Make your agents' bot"
        public static let notMade = "Your agents post as you. A bot of their own posts as <login>-agents[bot], and names you."
        /// What the bot can do: the manifest's fixed permissions (connections.BotPermissions).
        public static let abilities = [
            "Read and write code, on branches and pull requests",
            "Open and comment on issues and pull requests",
            "Read checks and statuses, and run workflows again",
        ]
        public static let never = "Never: change workflows, secrets, environments, settings or members. Those stay yours."
        public static let publicToggle = "Organisations can install it"
        public static let publicHelp = "Turn on to use the bot on an organisation's repositories. The organisation's owner approves the install."
        public static let keyNote = "GitHub gives the bot's key to this machine only. It never goes to Agents' servers."
        public static let continueButton = "Continue on github.com"
        public static let waiting = "Waiting for github.com\u{2026} Choose Create GitHub App there, and Agents comes back by itself."
        public static let finishing = "Taking the bot's key on this machine\u{2026}"
        public static let installButton = "Install on Repositories\u{2026}"
        public static let removeButton = "Forget the Bot\u{2026}"
        public static let removeTitle = "Forget your agents' bot?"
        public static let removeMessage = "This machine deletes the bot's key, and agents post as you again. The App stays on GitHub until you delete it there."

        /// The bot's line under the GitHub row: its name, and where it is installed.
        public static func note(_ bot: DaemonAPI.ConnectionBot) -> String {
            guard bot.made else { return notMade }
            let name = bot.name ?? "Your bot"
            guard let list = bot.installations else { return bot.message ?? "\(name). GitHub could not be asked where it is installed." }
            if list.isEmpty { return "\(name), not installed yet: install it on the repositories agents work on." }
            let places = list.map { $0.all ? "\($0.account) (all repositories)" : "\($0.account) (chosen repositories)" }
            return "\(name), on " + places.joined(separator: ", ") + "."
        }
    }

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

    /// Connect Forgejo (#3752): an access token on Codeberg or any Forgejo or Gitea. Forgejo
    /// has no device page, so the sheet has one way in.
    public enum Forgejo {
        public static let name = "Forgejo"
        public static let letters = "FJ"
        public static let title = "Connect Forgejo"
        public static let connectTitle = "Connect Forgejo once: issues, pull requests and checks."
        public static let notConnectedNote = "Pull requests, checks and issues on Codeberg or your own Forgejo or Gitea."
        public static let subtitle = "For you, in every folder. Agents talks to Forgejo's API directly."
        public static let abilities = [
            "Read and write pull requests and their comments",
            "Read checks (commit statuses)",
            "Read and write issues",
        ]
        public static let tokenIntro = "Codeberg, or your own Forgejo or Gitea: make an access token with read and write on repository and issue, and read on user, and paste it here."
        public static let addressLabel = "Forgejo address"
        public static let addressPrompt = "https://codeberg.org"
        public static let tokenLabel = "Access token"
        public static let tokenPrompt = "Paste the token"
        public static let tokenButton = "Connect"
        public static let newTokenButton = "Make a Token on Forgejo"
        public static let checking = "Checking the token with Forgejo\u{2026}"
        public static let choose = "The token does not end. You can take it back on Forgejo \u{25B8} Settings \u{25B8} Applications, or with Disconnect on Connectors."
        /// The connection's note after its host: how it signs in.
        public static let how = "Access token"
        public static let disconnectNote = "Disconnect deletes the machine's token. Every folder's Forgejo slots wait for a connection again. Forgejo's events stop until you connect again or set FORGEJO_TOKEN. To revoke it too, go to Forgejo \u{25B8} Settings \u{25B8} Applications."

        /// The address Connect Again\u{2026} opens with: the connection's Forgejo.
        public static func again(_ c: DaemonAPI.Connection) -> String {
            c.workspace.map { "https://" + $0 } ?? ""
        }

        /// Where the person makes a token on the Forgejo at address (Codeberg when empty).
        public static func newTokenURL(_ address: String) -> String {
            var root = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.isEmpty { root = addressPrompt }
            if !root.contains("://") { root = "https://" + root }
            while root.hasSuffix("/") { root.removeLast() }
            if root.hasSuffix("/api/v1") { root.removeLast("/api/v1".count) }
            return root + "/user/settings/applications"
        }
    }

    /// Connect Bitbucket (#3785): a token on Bitbucket Cloud, as the bitbucket server takes it:
    /// an Atlassian API token with its account's email, or a repository, project or workspace
    /// access token with no email. Bitbucket has no device page, so the sheet has one way in.
    public enum Bitbucket {
        public static let name = "Bitbucket"
        public static let letters = "BB"
        public static let title = "Connect Bitbucket"
        public static let connectTitle = "Connect Bitbucket once: issues, pull requests and checks."
        public static let notConnectedNote = "Pull requests, checks and issues on Bitbucket Cloud."
        public static let subtitle = "For you, in every folder. Agents talks to Bitbucket Cloud's API directly."
        public static let abilities = [
            "Read and write pull requests and their comments",
            "Read checks (Pipelines and other commit statuses)",
            "Read and write issues",
        ]
        public static let tokenIntro = "Make an Atlassian API token with the Bitbucket scopes and give its account's email. Or paste a repository, project or workspace access token, and leave the email empty."
        public static let emailLabel = "Atlassian email"
        public static let emailPrompt = "Empty for an access token"
        public static let tokenLabel = "Token"
        public static let tokenPrompt = "Paste the token"
        public static let tokenButton = "Connect"
        public static let newTokenButton = "Make an API Token on Atlassian"
        /// Where the person makes an Atlassian API token.
        public static let newTokenURL = "https://id.atlassian.com/manage-profile/security/api-tokens"
        public static let checking = "Checking the token with Bitbucket\u{2026}"
        public static let choose = "An API token ends on the date you gave it. You can take it back at id.atlassian.com \u{25B8} Security \u{25B8} API tokens (an access token in the repository's settings), or with Disconnect on Connectors."
        /// The connection's note after its host: how it signs in.
        public static let how = "Token"
        public static let disconnectNote = "Disconnect deletes the machine's token. Every folder's Bitbucket slots wait for a connection again. Bitbucket's events stop until you connect again or set BITBUCKET_TOKEN. To revoke it too, go to id.atlassian.com \u{25B8} Security \u{25B8} API tokens, or the repository's Access tokens."
    }

    /// Connect Azure DevOps (#3802): a personal access token on one organization of
    /// dev.azure.com or one collection of an Azure DevOps Server, as the azuredevops and
    /// azureboards servers take it. No device page for Agents, so the sheet has one way in.
    public enum AzureDevOps {
        public static let name = "Azure DevOps"
        public static let letters = "AZ"
        public static let title = "Connect Azure DevOps"
        public static let connectTitle = "Connect Azure DevOps once: work items, pull requests and pipelines."
        public static let notConnectedNote = "Pull requests, pipelines and work items on dev.azure.com or your own Azure DevOps Server."
        public static let subtitle = "For you, in every folder. Agents talks to Azure DevOps's API directly."
        public static let abilities = [
            "Read and write pull requests and their comments",
            "Read Azure Pipelines builds",
            "Read and write Azure Boards work items",
        ]
        public static let tokenIntro = "In your organization, open User settings \u{25B8} Personal access tokens, make a token with Code (read and write), Build (read) and Work Items (read and write), and paste it here with the organization."
        public static let addressLabel = "Organization"
        public static let addressPrompt = "dev.azure.com/your-organization"
        public static let tokenLabel = "Personal access token"
        public static let tokenPrompt = "Paste the token"
        public static let tokenButton = "Connect"
        public static let newTokenButton = "Make a Token on Azure DevOps"
        public static let checking = "Checking the token with Azure DevOps\u{2026}"
        public static let choose = "The token ends on the date you gave it. You can take it back in User settings \u{25B8} Personal access tokens, or with Disconnect on Connectors."
        /// The connection's note after its organization: how it signs in.
        public static let how = "Personal access token"
        public static let disconnectNote = "Disconnect deletes the machine's token. Every folder's Azure DevOps slots wait for a connection again. Azure DevOps's and Azure Boards' events stop until you connect again or set AZURE_DEVOPS_TOKEN. To revoke it too, go to User settings \u{25B8} Personal access tokens in the organization."

        /// The organization Connect Again\u{2026} opens with: the connection's.
        public static func again(_ c: DaemonAPI.Connection) -> String { c.workspace ?? "" }

        /// Where the person makes a token in the organization at address: its User settings
        /// \u{25B8} Personal access tokens (dev.azure.com's own when no organization is given).
        public static func newTokenURL(_ address: String) -> String {
            var root = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.isEmpty { return "https://dev.azure.com/" }
            if !root.contains(".") && !root.contains("/") && !root.contains(":") { root = "dev.azure.com/" + root }
            if !root.contains("://") { root = "https://" + root }
            guard var url = URLComponents(string: root), let host = url.host?.lowercased() else { return "https://dev.azure.com/" }
            var parts = url.path.split(separator: "/").map(String.init)
            if host.hasSuffix(".visualstudio.com") && host != "vs-ssh.visualstudio.com" {
                parts = [String(host.dropLast(".visualstudio.com".count))]
                url.host = "dev.azure.com"
            } else if host == "dev.azure.com" {
                parts = Array(parts.prefix(1))
            }
            url.path = "/" + (parts + ["_usersSettings", "tokens"]).joined(separator: "/")
            url.query = nil; url.fragment = nil
            return url.string ?? "https://dev.azure.com/"
        }
    }

    /// The one token sheet (#3802): Connect Forgejo, Connect Bitbucket and Connect Azure DevOps,
    /// each with its own words and its one field beside the token (an address or an email).
    public struct TokenSheet: Sendable {
        /// What the field beside the token is sent as: the provider's address, or the user.
        public enum Field: Sendable { case url, user }
        public let provider: DaemonAPI.ConnectionProvider
        public let title: String
        public let intro: String
        public let field: Field
        public let fieldLabel: String
        public let fieldPrompt: String
        public let tokenLabel: String
        public let tokenPrompt: String
        public let newTokenButton: String
        public let checking: String
        /// Where the person makes a token, from what the field says.
        public let newTokenURL: @Sendable (String) -> String
        /// What the field opens with for Connect Again\u{2026}.
        public let again: @Sendable (DaemonAPI.Connection) -> String
    }

    /// The token sheet of a provider that has one: Forgejo, Bitbucket and Azure DevOps.
    public static func tokenSheet(_ p: DaemonAPI.ConnectionProvider) -> TokenSheet? {
        switch p {
        case .forgejo:
            TokenSheet(provider: p, title: Forgejo.title, intro: Forgejo.tokenIntro, field: .url, fieldLabel: Forgejo.addressLabel,
                       fieldPrompt: Forgejo.addressPrompt, tokenLabel: Forgejo.tokenLabel, tokenPrompt: Forgejo.tokenPrompt,
                       newTokenButton: Forgejo.newTokenButton, checking: Forgejo.checking,
                       newTokenURL: Forgejo.newTokenURL, again: Forgejo.again)
        case .bitbucket:
            TokenSheet(provider: p, title: Bitbucket.title, intro: Bitbucket.tokenIntro, field: .user, fieldLabel: Bitbucket.emailLabel,
                       fieldPrompt: Bitbucket.emailPrompt, tokenLabel: Bitbucket.tokenLabel, tokenPrompt: Bitbucket.tokenPrompt,
                       newTokenButton: Bitbucket.newTokenButton, checking: Bitbucket.checking,
                       newTokenURL: { _ in Bitbucket.newTokenURL }, again: { _ in "" })
        case .azuredevops:
            TokenSheet(provider: p, title: AzureDevOps.title, intro: AzureDevOps.tokenIntro, field: .url,
                       fieldLabel: AzureDevOps.addressLabel, fieldPrompt: AzureDevOps.addressPrompt, tokenLabel: AzureDevOps.tokenLabel,
                       tokenPrompt: AzureDevOps.tokenPrompt, newTokenButton: AzureDevOps.newTokenButton, checking: AzureDevOps.checking,
                       newTokenURL: AzureDevOps.newTokenURL, again: AzureDevOps.again)
        default: nil
        }
    }

    /// Connect Jira (#3304): one Atlassian sign-in for Jira and Confluence (#3248), by Atlassian
    /// Cloud's page, or a token on one Jira site (Jira Data Center, or Cloud without the sign-in).
    /// The connection is Atlassian's; the sheet and the Tasks slot say Jira.
    public enum Jira {
        /// The connection's name on Connectors: it serves Confluence too.
        public static let provider = "Atlassian"
        public static let menuName = "Jira and Confluence"
        public static let letters = "JI"
        public static let title = "Connect Jira"
        public static let site = "atlassian.com"
        public static let notConnectedNote = "Jira issues and Confluence docs, with one sign-in."
        public static let subtitle = "For you, in every folder. One Atlassian sign-in for Jira and Confluence."
        public static let abilities = [
            "Read Jira issues, their comments and their history",
            "Read Confluence pages and spaces, for the Docs slot",
            "Know your account, to find the issues assigned to you",
        ]
        public static let choose = "On atlassian.com you choose the site. You can take it back at id.atlassian.com \u{25B8} Connected apps, or with Disconnect on Connectors."
        public static let continueButton = "Continue on atlassian.com"
        public static let waiting = "Waiting for atlassian.com\u{2026} Approve there, and Agents comes back by itself."
        /// The two ways in, as the sheet's picker says them.
        public static let signInWay = "Atlassian Cloud"
        public static let tokenWay = "API token"
        public static let tokenIntro = "For Jira Data Center, or Jira Cloud without the sign-in. On Jira Cloud, make an API token at id.atlassian.com and give your email. On Data Center, make a personal access token and leave the email empty."
        public static let siteLabel = "Jira site"
        public static let sitePrompt = "example.atlassian.net"
        public static let emailLabel = "Email"
        public static let emailPrompt = "you@example.com (Jira Cloud only)"
        public static let tokenLabel = "Token"
        public static let tokenPrompt = "API token or personal access token"
        public static let tokenButton = "Connect"
        public static let newTokenURL = "https://id.atlassian.com/manage-profile/security/api-tokens"
        public static let newTokenButton = "Make an API Token on Atlassian"
        public static let checking = "Checking the token with Jira\u{2026}"
        public static let disconnectNote = "Disconnect deletes the machine's tokens. Jira's events stop until you connect again or set JIRA_API_TOKEN. To revoke Agents too, go to id.atlassian.com \u{25B8} Connected apps."
        /// The Tasks slot's note on its Jira choice.
        public static let tasksNote = "Connect Jira, then add its connector."
        public static let done = "Done"

        /// The sheet's line once connected: where, and as whom.
        public static func connected(_ c: DaemonAPI.Connection) -> String {
            let place = c.workspace.map { " to \($0)" } ?? ""
            return "Connected\(place) as \(c.login ?? "you")."
        }

        /// The one real read that proves the connection: the site's newest issue.
        public static func proof(_ c: DaemonAPI.Connection, now: Date = Date()) -> String {
            guard let newest = c.newest else { return "No issues read yet: the site has none, or the token cannot see them." }
            return "Newest issue: " + proofText(newest, now: now)
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
        case .atlassian: Jira.subtitle
        case .forgejo: Forgejo.subtitle
        case .bitbucket: Bitbucket.subtitle
        case .azuredevops: AzureDevOps.subtitle
        }
    }

    public static func abilities(_ p: DaemonAPI.ConnectionProvider) -> [String] {
        switch p {
        case .github: abilities
        case .linear: Linear.abilities
        case .gitlab: GitLab.abilities
        case .email: Email.abilities
        case .atlassian: Jira.abilities
        case .forgejo: Forgejo.abilities
        case .bitbucket: Bitbucket.abilities
        case .azuredevops: AzureDevOps.abilities
        }
    }

    public static func sheetChoose(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: sheetChoose
        case .linear: Linear.choose
        case .gitlab: GitLab.choose
        case .email: Email.choose
        case .atlassian: Jira.choose
        case .forgejo: Forgejo.choose
        case .bitbucket: Bitbucket.choose
        case .azuredevops: AzureDevOps.choose
        }
    }

    public static func continueButton(_ p: DaemonAPI.ConnectionProvider) -> String {
        switch p {
        case .github: continueButton
        case .linear: Linear.continueButton
        case .gitlab: GitLab.continueButton
        case .email: Email.button
        case .atlassian: Jira.continueButton
        case .forgejo: Forgejo.tokenButton
        case .bitbucket: Bitbucket.tokenButton
        case .azuredevops: AzureDevOps.tokenButton
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
        case .atlassian: Jira.site
        // Forgejo, Bitbucket and Azure DevOps have no device page either.
        case .forgejo, .bitbucket, .azuredevops: ""
        }
    }

    public static func sheetStatus(_ s: DaemonAPI.ConnectionSignIn) -> String {
        switch s.status {
        case .waiting where s.grant == .authorizationCode && s.provider == .atlassian: Jira.waiting
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
