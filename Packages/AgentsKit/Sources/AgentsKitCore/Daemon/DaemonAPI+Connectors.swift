import Foundation

/// The person's connections to tools (#1335), and each folder's Connectors set-up (#1336).
///
/// A connection is the person's: one GitHub sign-in on a host covers every folder there. The
/// host does the device flow and keeps the tokens; a client shows the code and the links, and
/// waits. Linear (#1343) is the authorization code with PKCE: the host keeps the verifier, the
/// client opens the address in an authentication session, and gives back the code that the
/// hand-back page sends to agents://oauth/callback. GitLab (#1630) is the device flow on
/// gitlab.com, or a personal access token on any GitLab. Email (#1780) is one IMAP mailbox and
/// its app password, which the host checks once and keeps. Atlassian (#3304) is one sign-in for
/// Jira and Confluence: Linear's code flow on Atlassian Cloud, or a token on one Jira site. A folder's set-up is the folder's: its repository, four slots that each prove
/// themselves with one real read, and the github events it turned on.
extension DaemonAPI.Method {
    public static let connectionsList = "connections/list"
    /// Starts a sign-in, or answers with the one already waiting, so two clients show one code.
    public static let connectionsSignIn = "connections/sign-in"
    /// A long poll: answers when the sign-in ends, or after 25 seconds with it still waiting.
    public static let connectionsSignInWait = "connections/sign-in/wait"
    public static let connectionsSignInCancel = "connections/sign-in/cancel"
    /// The code and the state the hand-back page gave the client; the host spends the code.
    public static let connectionsSignInComplete = "connections/sign-in/complete"
    /// A personal access token the person made (GitLab, #1630): the host checks and keeps it.
    public static let connectionsSignInToken = "connections/sign-in/token"
    /// An IMAP mailbox and its app password (Email, #1780): the host signs in once and keeps it.
    public static let connectionsSignInEmail = "connections/sign-in/email"
    public static let connectionsDisconnect = "connections/disconnect"
    /// The person's agents' bot on this host (#3858), with the accounts it is installed on.
    public static let connectionsBot = "connections/bot"
    /// The bot's App manifest, which the client posts to GitHub.
    public static let connectionsBotStart = "connections/bot/start"
    /// The code and the state the hand-back page gave the client; the host turns the code into
    /// the App's key and keeps it.
    public static let connectionsBotComplete = "connections/bot/complete"
    /// Forgets the bot's key on this host. The App stays on GitHub until the person deletes it.
    public static let connectionsBotRemove = "connections/bot/remove"
    public static let connectorsSetup = "connectors/setup"
    public static let connectorsSetupSkip = "connectors/setup/skip"
    public static let connectorsCodespaces = "connectors/codespaces"
}

extension DaemonAPI {
    public enum ConnectionProvider: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
        case github, linear, gitlab, email, atlassian, forgejo, bitbucket, azuredevops
        public var id: String { rawValue }
    }

    public enum ConnectionState: String, Codable, Sendable, Hashable {
        /// The host has a token and renews it.
        case connected
        /// The provider refused the renewal: the person signs in again.
        case signInAgain
    }

    /// The person's sign-in to one provider, as the host keeps it. Never its tokens.
    public struct Connection: Codable, Sendable, Hashable {
        public var provider: ConnectionProvider
        public var login: String?
        public var state: ConnectionState
        public var connectedAt: Date
        /// Where the person installs the provider's App on more repositories.
        public var installURL: String?
        /// The part of the provider the token reaches, such as a Linear workspace, or a
        /// self-managed GitLab's host.
        public var workspace: String?
        /// When a token the host cannot renew ends: a GitLab access token's expiry.
        public var expiresAt: Date?
        /// A token the person made, which the host does not renew and whose end it does not
        /// know: a Jira API token (#3304). Nil for OAuth.
        public var byToken: Bool?
        /// Only in the answer that made the connection: the one real read that proves it, such
        /// as Jira's newest issue (#3304).
        public var newest: ConnectorProof?

        public init(provider: ConnectionProvider, login: String? = nil, state: ConnectionState = .connected,
                    connectedAt: Date, installURL: String? = nil, workspace: String? = nil, expiresAt: Date? = nil,
                    byToken: Bool? = nil, newest: ConnectorProof? = nil) {
            self.provider = provider; self.login = login; self.state = state
            self.connectedAt = connectedAt; self.installURL = installURL; self.workspace = workspace
            self.expiresAt = expiresAt; self.byToken = byToken; self.newest = newest
        }
    }

    public struct ConnectionsList: Codable, Sendable, Hashable {
        public var connections: [Connection]
        /// The providers this host connects (#3824), with the names this client does not know
        /// dropped. Nil from a host older than #3824.
        public var providers: [ConnectionProvider]?
        public init(connections: [Connection], providers: [ConnectionProvider]? = nil) {
            self.connections = connections; self.providers = providers
        }

        private enum CodingKeys: String, CodingKey { case connections, providers }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A connection to a provider this client does not know (a newer host's) is dropped.
            connections = try c.decode([Known<Connection>].self, forKey: .connections).compactMap(\.value)
            providers = try c.decodeIfPresent([String].self, forKey: .providers)?.compactMap(ConnectionProvider.init(rawValue:))
        }

        /// The providers Connect… offers on this host, in this client's order: the ones it says
        /// it connects, or what a host older than #3824 connects (Email with connections.email/1).
        public func offered(hostHasEmail: Bool) -> [ConnectionProvider] {
            let takes = providers ?? [.github, .linear, .gitlab, .atlassian] + (hostHasEmail ? [.email] : [])
            return ConnectionProvider.allCases.filter(takes.contains)
        }
    }

    /// A value this client may not know, such as a newer host's provider: nil when it does not decode.
    struct Known<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    public struct ConnectionProviderRequest: Codable, Sendable, Hashable {
        public var provider: ConnectionProvider
        /// The web page's origin, for a code flow that hands back by postMessage. Nil on the
        /// Mac and the Remote, which take it back at agents://oauth/callback.
        public var origin: String?
        public init(provider: ConnectionProvider, origin: String? = nil) { self.provider = provider; self.origin = origin }
    }

    /// What the hand-back page gave the client: the code and the state, or the provider's error.
    public struct ConnectionSignInCompleteRequest: Codable, Sendable, Hashable {
        public var flowID: UUID
        public var state: String
        public var code: String?
        public var error: String?
        public init(flowID: UUID, state: String, code: String? = nil, error: String? = nil) {
            self.flowID = flowID; self.state = state; self.code = code; self.error = error
        }

        /// The scheme the hand-back page sends the Mac and the Remote to.
        public static let callbackScheme = "agents"

        /// The answer in agents://oauth/callback?code=…&state=…, or nil for another address.
        public init?(flowID: UUID, callback: URL) {
            guard callback.scheme == Self.callbackScheme, callback.host == "oauth", callback.path == "/callback",
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else { return nil }
            self.init(flowID: flowID, state: state, code: items.first(where: { $0.name == "code" })?.value,
                      error: items.first(where: { $0.name == "error" })?.value)
        }
    }

    public enum ConnectionSignInGrant: String, Codable, Sendable, Hashable {
        /// The person types userCode at verificationURL (GitHub); the host polls.
        case deviceCode
        /// The person approves at verificationURL in an authentication session (Linear).
        case authorizationCode
    }

    public struct ConnectionSignInFlowRequest: Codable, Sendable, Hashable {
        public var flowID: UUID
        public init(flowID: UUID) { self.flowID = flowID }
    }

    public enum ConnectionSignInStatus: String, Codable, Sendable, Hashable {
        case waiting, connected, expired, denied, cancelled, failed
    }

    /// A sign-in under way on the host.
    public struct ConnectionSignIn: Codable, Sendable, Hashable {
        public var flowID: UUID
        public var provider: ConnectionProvider
        public var status: ConnectionSignInStatus
        public var grant: ConnectionSignInGrant
        /// deviceCode only: the code the person types on the provider's page, such as WDJB-MJHT.
        public var userCode: String?
        /// The device page, or the provider's authorize page.
        public var verificationURL: String
        public var installURL: String?
        public var expiresAt: Date
        public var connection: Connection?
        /// Why it failed, in words.
        public var message: String?

        public init(flowID: UUID, provider: ConnectionProvider, status: ConnectionSignInStatus,
                    grant: ConnectionSignInGrant = .deviceCode, userCode: String? = nil,
                    verificationURL: String, installURL: String? = nil, expiresAt: Date,
                    connection: Connection? = nil, message: String? = nil) {
            self.flowID = flowID; self.provider = provider; self.status = status; self.grant = grant; self.userCode = userCode
            self.verificationURL = verificationURL; self.installURL = installURL; self.expiresAt = expiresAt
            self.connection = connection; self.message = message
        }
    }

    /// A personal access token for a provider with no Agents application there (a
    /// self-managed GitLab, a Jira site). The host checks it, keeps it, and never gives it back.
    public struct ConnectionTokenRequest: Codable, Sendable, Hashable {
        public var provider: ConnectionProvider
        /// The provider's address, such as gitlab.example.com; gitlab.com when nil. A Jira site
        /// must be given.
        public var url: String?
        /// Atlassian only: the account's email, with a Jira Cloud API token; nil for a Jira Data
        /// Center personal access token.
        public var user: String?
        public var token: String
        public init(provider: ConnectionProvider, url: String? = nil, user: String? = nil, token: String) {
            self.provider = provider; self.url = url; self.user = user; self.token = token
        }
    }

    /// One IMAP mailbox for the email server (#1780). The host signs in once to check it, keeps
    /// the app password, and never gives it back. The answer is a ConnectionTokenAnswer.
    public struct ConnectionEmailRequest: Codable, Sendable, Hashable {
        /// The IMAP server, such as imap.fastmail.com.
        public var server: String
        /// Who signs in, usually the mail address.
        public var user: String
        public var password: String
        public init(server: String, user: String, password: String) {
            self.server = server; self.user = user; self.password = password
        }
    }

    /// The connection the token made, or why it made none.
    public struct ConnectionTokenAnswer: Codable, Sendable, Hashable {
        public var connection: Connection?
        public var error: String?
        public init(connection: Connection? = nil, error: String? = nil) { self.connection = connection; self.error = error }
    }

    public struct ConnectionDisconnectAnswer: Codable, Sendable, Hashable {
        public var error: String?
        public init(error: String? = nil) { self.error = error }
    }

    /// Make the person's agents' bot (#3858): public is true when an organisation must install it.
    public struct ConnectionBotStartRequest: Codable, Sendable, Hashable {
        public var origin: String?
        public var `public`: Bool?
        public init(origin: String? = nil, public isPublic: Bool? = nil) { self.origin = origin; self.public = isPublic }
    }

    /// What the client posts to GitHub: a form to action, with one field, manifest.
    public struct ConnectionBotStart: Codable, Sendable, Hashable {
        public var action: String
        public var manifest: String
        public var state: String
        public var expiresAt: Date
        public init(action: String, manifest: String, state: String, expiresAt: Date) {
            self.action = action; self.manifest = manifest; self.state = state; self.expiresAt = expiresAt
        }

        /// The hand-back site's page that posts the manifest to GitHub, for an authentication
        /// session, which opens only an address (#3858). The manifest is in the fragment, which
        /// the browser never sends.
        public var formURL: URL? {
            var parts = URLComponents()
            parts.queryItems = [URLQueryItem(name: "action", value: action), URLQueryItem(name: "manifest", value: manifest)]
            guard let fragment = parts.percentEncodedQuery else { return nil }
            return URL(string: "https://oauth.agentloops.dev/oauth/github-app#" + fragment)
        }
    }

    /// What the hand-back page gave the client after GitHub made the App.
    public struct ConnectionBotCompleteRequest: Codable, Sendable, Hashable {
        public var state: String
        public var code: String?
        public var error: String?
        public init(state: String, code: String? = nil, error: String? = nil) {
            self.state = state; self.code = code; self.error = error
        }

        /// The answer in agents://oauth/callback?code=…&state=…, or nil for another address.
        public init?(callback: URL) {
            guard let r = ConnectionSignInCompleteRequest(flowID: UUID(), callback: callback) else { return nil }
            self.init(state: r.state, code: r.code, error: r.error)
        }
    }

    /// An account the bot is installed on.
    public struct ConnectionBotInstallation: Codable, Sendable, Hashable {
        public var account: String
        /// Every repository of the account, or the ones chosen.
        public var all: Bool
        public var settingsURL: String?
        public init(account: String, all: Bool, settingsURL: String? = nil) {
            self.account = account; self.all = all; self.settingsURL = settingsURL
        }
    }

    /// The person's agents' bot on the host (#3858). Never its key.
    public struct ConnectionBot: Codable, Sendable, Hashable {
        public var made: Bool
        /// <slug>[bot]
        public var name: String?
        public var slug: String?
        public var owner: String?
        public var installURL: String?
        /// The App's page on GitHub, where the person deletes it.
        public var appURL: String?
        /// Nil when GitHub could not be asked.
        public var installations: [ConnectionBotInstallation]?
        public var message: String?
        public init(made: Bool, name: String? = nil, slug: String? = nil, owner: String? = nil, installURL: String? = nil,
                    appURL: String? = nil, installations: [ConnectionBotInstallation]? = nil, message: String? = nil) {
            self.made = made; self.name = name; self.slug = slug; self.owner = owner; self.installURL = installURL
            self.appURL = appURL; self.installations = installations; self.message = message
        }
    }

    /// One slot of a folder's set-up, in the page's order. Docs is where the folder's docs live
    /// (#3248); Messaging is where agents reach the person (#1787).
    public enum ConnectorSlotKind: String, Codable, Sendable, Hashable, CaseIterable {
        case tasks, codeReview, ci, docs, messaging, workspace

        /// A slot that a folder's project can set (#2669): the forge's three.
        public var isProjects: Bool { [.tasks, .codeReview, .ci].contains(self) }
    }

    public enum ConnectorSlotState: String, Codable, Sendable, Hashable {
        /// It comes with a connection that is not there yet.
        case notConnected
        /// Connected, but not read yet (a stored reading).
        case notRead
        /// Its one read worked: a tick.
        case read
        /// The read did not reach the provider.
        case failed
        /// The provider refused the read: the person grants it on the provider's site.
        case refused
        /// The folder has no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote.
        case noRemote
        /// Skipped: it counts as done.
        case skipped

        /// Done: it read, or the person skipped it.
        public var isDone: Bool { self == .read || self == .skipped }
    }

    /// The one real thing a slot read.
    public struct ConnectorProof: Codable, Sendable, Hashable {
        public var number: Int?
        /// Its title, or the run's workflow and branch, such as "CI on main".
        public var title: String
        /// A run's outcome in a word: passed, failed, running, cancelled.
        public var outcome: String?
        public var url: String?
        public var at: Date?

        public init(number: Int? = nil, title: String, outcome: String? = nil, url: String? = nil, at: Date? = nil) {
            self.number = number; self.title = title; self.outcome = outcome; self.url = url; self.at = at
        }
    }

    public struct ConnectorSlot: Codable, Sendable, Hashable, Identifiable {
        public var slot: ConnectorSlotKind
        /// What fills it, in words: GitHub Issues, This Mac.
        public var choice: String
        public var state: ConnectorSlotState
        public var proof: ConnectorProof?
        public var readAt: Date?
        public var message: String?
        /// The repository that fills it: the project's when `fromProject`, else the folder's
        /// own (#2669).
        public var repository: String?
        /// The folder's project sets it, for every folder in the project (#2669).
        public var fromProject: Bool?
        /// Docs only (#3248): the docs connectors beside this folder, by their mcp.json names.
        public var servers: [String]?
        /// Docs only (#3307): each docs connector's one real search, through its map.
        public var docsServers: [DocsServer]?
        /// Messaging only (#1787): each messaging connector with its one real read. There also
        /// when the slot is skipped; absent when it is None.
        public var messagingServers: [MessagingServer]?

        public var id: ConnectorSlotKind { slot }
        public var isFromProject: Bool { fromProject == true }

        public init(slot: ConnectorSlotKind, choice: String, state: ConnectorSlotState, proof: ConnectorProof? = nil,
                    readAt: Date? = nil, message: String? = nil, repository: String? = nil, fromProject: Bool? = nil,
                    servers: [String]? = nil, docsServers: [DocsServer]? = nil, messagingServers: [MessagingServer]? = nil) {
            self.slot = slot; self.choice = choice; self.state = state; self.proof = proof
            self.readAt = readAt; self.message = message; self.repository = repository; self.fromProject = fromProject
            self.servers = servers; self.docsServers = docsServers; self.messagingServers = messagingServers
        }
    }

    /// One messaging connector in the Messaging slot (#1787): its mcp.json name, what it is
    /// (Slack, Email, Google Chat), its one real read and the events it declares.
    public struct MessagingServer: Codable, Sendable, Hashable {
        public var name: String
        public var word: String
        public var state: MessagingServerState
        /// What the read found: "3 channels", or its first line.
        public var proof: ConnectorProof?
        /// failed: why, in a sentence.
        public var message: String?
        /// The events it declares, such as slack.message.
        public var events: [String]?

        public init(name: String, word: String, state: MessagingServerState, proof: ConnectorProof? = nil,
                    message: String? = nil, events: [String]? = nil) {
            self.name = name; self.word = word; self.state = state; self.proof = proof
            self.message = message; self.events = events
        }
    }

    public enum MessagingServerState: String, Codable, Sendable, Hashable {
        case notRead, read, failed
    }

    /// One docs connector in the Docs slot (#3307): its mcp.json name, and what its one real
    /// search, through the map an agent wrote of its tools, found.
    public struct DocsServer: Codable, Sendable, Hashable {
        public var name: String
        public var state: DocsServerState
        /// The first doc the search found.
        public var proof: ConnectorProof?
        /// failed: why, in a sentence.
        public var message: String?

        public init(name: String, state: DocsServerState, proof: ConnectorProof? = nil, message: String? = nil) {
            self.name = name; self.state = state; self.proof = proof; self.message = message
        }
    }

    public enum DocsServerState: String, Codable, Sendable, Hashable {
        /// No agent has written a map of its search and read tools yet.
        case noMap
        /// Mapped, not searched yet.
        case notRead
        /// Its one search worked.
        case read
        /// The search did not work.
        case failed
    }

    public enum ConnectorEventsState: String, Codable, Sendable, Hashable {
        case on, off, taken, failed
    }

    public struct ConnectorWorkflow: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// The github events the set-up turned on, and the workflows that start on one of them.
    public struct ConnectorEvents: Codable, Sendable, Hashable {
        public var state: ConnectorEventsState
        public var names: [String]
        public var server: String?
        public var workflows: [ConnectorWorkflow]
        public var message: String?

        public init(state: ConnectorEventsState, names: [String] = [], server: String? = nil,
                    workflows: [ConnectorWorkflow] = [], message: String? = nil) {
            self.state = state; self.names = names; self.server = server; self.workflows = workflows; self.message = message
        }
    }

    /// A folder's Connectors set-up (#1336), on GitHub or GitLab (#1632).
    public struct ConnectorSetup: Codable, Sendable, Hashable {
        public var folder: String
        /// owner/name on GitHub, group/folder on GitLab, from the folder's git remote. Nil
        /// with no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote.
        public var repository: String?
        /// The forge that fills Tasks, Code review and CI; nil is GitHub.
        public var forge: ConnectionProvider?
        /// The forge's name when this client does not know it (a newer host's, #3802): the
        /// set-up says to update Agents, and offers no Connect.
        public var unknownForge: String?
        /// The repository's host: github.com, gitlab.com, or a self-managed GitLab's.
        public var site: String?
        /// The repository's page on its forge.
        public var repositoryURL: String?
        public var connection: Connection?
        /// Whether the Agents App is installed on the repository; nil when not known.
        public var installed: Bool?
        public var installURL: String?
        /// How many repositories the connection sees through the App.
        public var repositories: Int?
        public var slots: [ConnectorSlot]
        public var events: ConnectorEvents
        /// Slots that read or were skipped, of the four.
        public var done: Int
        /// The folder's project id (#2669), whose owner or an admin sets Tasks, Code review
        /// and CI for every folder in it; nil when the folder is in no project.
        public var project: String?
        /// The project's name, as the machine last heard it.
        public var projectName: String?

        public init(folder: String, repository: String? = nil, forge: ConnectionProvider? = nil, site: String? = nil,
                    repositoryURL: String? = nil, connection: Connection? = nil, installed: Bool? = nil,
                    installURL: String? = nil, repositories: Int? = nil, slots: [ConnectorSlot],
                    events: ConnectorEvents, done: Int, project: String? = nil, projectName: String? = nil) {
            self.folder = folder; self.repository = repository; self.forge = forge; self.site = site
            self.repositoryURL = repositoryURL
            self.connection = connection; self.installed = installed
            self.installURL = installURL; self.repositories = repositories; self.slots = slots; self.events = events
            self.done = done; self.project = project; self.projectName = projectName
        }

        private enum CodingKeys: String, CodingKey {
            case folder, repository, forge, site, repositoryURL, connection, installed, installURL, repositories, slots, events, done
            case project, projectName
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            folder = try c.decode(String.self, forKey: .folder)
            repository = try c.decodeIfPresent(String.self, forKey: .repository)
            if let raw = try c.decodeIfPresent(String.self, forKey: .forge) {
                forge = ConnectionProvider(rawValue: raw)
                unknownForge = forge == nil ? raw : nil
            }
            site = try c.decodeIfPresent(String.self, forKey: .site)
            repositoryURL = try c.decodeIfPresent(String.self, forKey: .repositoryURL)
            connection = try c.decodeIfPresent(Known<Connection>.self, forKey: .connection)?.value
            installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
            installURL = try c.decodeIfPresent(String.self, forKey: .installURL)
            repositories = try c.decodeIfPresent(Int.self, forKey: .repositories)
            slots = try c.decode([ConnectorSlot].self, forKey: .slots)
            events = try c.decode(ConnectorEvents.self, forKey: .events)
            done = try c.decode(Int.self, forKey: .done)
            project = try c.decodeIfPresent(String.self, forKey: .project)
            projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        }

        public func slot(_ kind: ConnectorSlotKind) -> ConnectorSlot? { slots.first { $0.slot == kind } }

        /// The forge, GitHub when the host did not say.
        public var forgeOrGitHub: ConnectionProvider { forge ?? .github }

        /// The repository's host, github.com when the host did not say.
        public var siteOrGitHub: String { site ?? "github.com" }
    }

    public enum ConnectorSetupReading: String, Codable, Sendable, Hashable {
        /// No call to the provider: only what was read before.
        case stored
        /// A read at most five minutes old is used again.
        case cached
        /// Read now (Try Again).
        case fresh
    }

    public struct ConnectorSetupRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var reading: ConnectorSetupReading?
        public init(folder: String, reading: ConnectorSetupReading? = nil) { self.folder = folder; self.reading = reading }
    }

    public struct ConnectorCodespace: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var repository: String
        public var state: String
        public var ref: String?
        public var ssh: String

        public init(id: String, name: String, repository: String, state: String, ref: String? = nil, ssh: String) {
            self.id = id; self.name = name; self.repository = repository; self.state = state; self.ref = ref; self.ssh = ssh
        }
    }

    public struct ConnectorCodespacesRequest: Codable, Sendable, Hashable {
        public enum Action: String, Codable, Sendable, Hashable { case list, create, start, stop, prepareSSH }
        public var folder: String
        public var action: Action
        public var id: String?
        public var name: String?
        public init(folder: String, action: Action, id: String? = nil, name: String? = nil) {
            self.folder = folder; self.action = action; self.id = id; self.name = name
        }
    }

    public struct ConnectorCodespaces: Codable, Sendable, Hashable {
        public var repository: String?
        public var codespaces: [ConnectorCodespace]
        public var message: String?
        public init(repository: String? = nil, codespaces: [ConnectorCodespace] = [], message: String? = nil) {
            self.repository = repository; self.codespaces = codespaces; self.message = message
        }
    }

    public struct ConnectorSkipRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var slot: ConnectorSlotKind
        public var skipped: Bool
        public init(folder: String, slot: ConnectorSlotKind, skipped: Bool) {
            self.folder = folder; self.slot = slot; self.skipped = skipped
        }
    }
}
