import Foundation

/// Searching the MCP Registry and adding servers (060, contracts/mcp-methods.md).
/// A person's: none of these is in `agentMethods`.
extension DaemonAPI.Method {
    public static let mcpPreview = "mcp/preview"
    public static let mcpAdd = "mcp/add"
    public static let mcpList = "mcp/list"
    public static let mcpApprove = "mcp/approve"
    public static let mcpSetSecret = "mcp/set-secret"
    public static let mcpRemove = "mcp/remove"
    /// A server not in the registry: connect to it before anything is written (#305).
    public static let mcpVerify = "mcp/verify"
    public static let mcpAddByHand = "mcp/add-by-hand"
    /// Sign in to a server that asks for OAuth (#306): start it, wait on it, cancel it.
    public static let mcpSignIn = "mcp/sign-in"
    public static let mcpSignInWait = "mcp/sign-in/wait"
    public static let mcpSignInCancel = "mcp/sign-in/cancel"
    public static let mcpSignOut = "mcp/sign-out"

    public static let mcpCatalogMethods: [String] = [
        mcpPreview, mcpAdd, mcpList, mcpApprove, mcpSetSecret, mcpRemove, mcpVerify, mcpAddByHand,
        mcpSignIn, mcpSignInWait, mcpSignInCancel, mcpSignOut,
    ]
}

extension DaemonAPI {
    public enum CatalogKind: String, Codable, Sendable {
        case skills
        case mcp
    }

    public enum MCPRunKind: String, Codable, Hashable, Sendable {
        case remote, npx, uvx, docker
        /// A local command the person typed (#305).
        case command
    }

    public struct MCPPublisherInfo: Codable, Hashable, Sendable {
        public var label: String
        public var namespace: String
        public var known: Bool
        public init(label: String, namespace: String, known: Bool) {
            self.label = label; self.namespace = namespace; self.known = known
        }
    }

    public struct MCPCatalogResult: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var description: String
        public var version: String
        public var publisher: MCPPublisherInfo
        public var known: Bool
        public var runs: [MCPRunKind]
        public var remoteHost: String?

        public init(id: String, title: String, description: String, version: String,
                    publisher: MCPPublisherInfo, known: Bool, runs: [MCPRunKind], remoteHost: String?) {
            self.id = id; self.title = title; self.description = description; self.version = version
            self.publisher = publisher; self.known = known; self.runs = runs; self.remoteHost = remoteHost
        }
    }

    public struct MCPVariable: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case secret, plain }
        public var name: String
        public var description: String
        public var kind: Kind
        public var required: Bool
        public var alreadySet: Bool
        public var placeholder: String?

        public init(name: String, description: String, kind: Kind, required: Bool,
                    alreadySet: Bool, placeholder: String?) {
            self.name = name; self.description = description; self.kind = kind
            self.required = required; self.alreadySet = alreadySet; self.placeholder = placeholder
        }
    }

    public enum MCPDestinationState: Codable, Hashable, Sendable {
        case free
        case managedSame
        case managedOther(registryName: String)
        case unmanaged(path: String)
        case unavailable(MCPCatalogError)
    }

    public enum MCPPreviewProblem: Codable, Hashable, Sendable {
        case unreachable(host: String)
        case noRunnableWay
        case nameTakenUnmanaged
        case mcpUnreadable(path: String)
        case noPersonalHome
    }

    public enum MCPCatalogError: Error, Codable, Hashable, Sendable {
        case unreachable(host: String)
        case noPersonalHome
        case unmanaged(path: String)
        case mcpUnreadable(path: String)
        case missingSecret(name: String)
        case staleDigest
        case secretStillInUse(name: String)
        case previewExpired
        case noRunnableWay
        case replaceMismatch
        case notAProject(path: String)
        /// The name is already in that `mcp.json` (#305).
        case nameTaken(name: String)
        /// Something typed on the by-hand sheet that cannot be written as it is (#305).
        case invalid(String)
        case failed(String)
    }

    public struct MCPPreview: Codable, Equatable, Sendable {
        public var previewID: UUID
        public var result: MCPCatalogResult
        public var nameHere: String
        public var chosenRun: MCPRunKind
        public var commandOrURL: String
        public var host: String?
        /// The `mcpServers` entry as a JSON object (string values only), with `${NAME}`.
        public var entry: [String: JSONValue]
        public var variables: [MCPVariable]
        public var reach: [String: Reach]
        public var destinationState: MCPDestinationState
        public var problems: [MCPPreviewProblem]

        public init(previewID: UUID, result: MCPCatalogResult, nameHere: String, chosenRun: MCPRunKind,
                    commandOrURL: String, host: String?, entry: [String: JSONValue], variables: [MCPVariable],
                    reach: [String: Reach], destinationState: MCPDestinationState,
                    problems: [MCPPreviewProblem]) {
            self.previewID = previewID; self.result = result; self.nameHere = nameHere
            self.chosenRun = chosenRun; self.commandOrURL = commandOrURL; self.host = host
            self.entry = entry; self.variables = variables; self.reach = reach
            self.destinationState = destinationState; self.problems = problems
        }
    }

    public struct ManagedMCPServer: Codable, Hashable, Sendable {
        public var name: String
        /// Empty for one added by hand.
        public var registryName: String
        public var version: String
        public var run: MCPRunKind
        public var addedAt: Date
        public var destination: SkillDestination
        /// Added on the sheet by hand, not from the registry (#305).
        public var byHand: Bool

        public init(name: String, registryName: String, version: String, run: MCPRunKind,
                    addedAt: Date, destination: SkillDestination, byHand: Bool = false) {
            self.name = name; self.registryName = registryName; self.version = version
            self.run = run; self.addedAt = addedAt; self.destination = destination; self.byHand = byHand
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            registryName = try c.decode(String.self, forKey: .registryName)
            version = try c.decode(String.self, forKey: .version)
            run = try c.decode(MCPRunKind.self, forKey: .run)
            addedAt = try c.decode(Date.self, forKey: .addedAt)
            destination = try c.decode(SkillDestination.self, forKey: .destination)
            byHand = try c.decodeIfPresent(Bool.self, forKey: .byHand) ?? false
        }
    }

    // MARK: By hand (#305)

    /// One env variable or header typed on the sheet. A secret's value goes to the person's
    /// `secrets.env` as `secretName`, and the entry holds `${secretName}`. An empty secret
    /// value keeps the one already set under that name.
    public struct MCPHandValue: Codable, Hashable, Sendable {
        public var name: String
        public var value: String
        public var secret: Bool
        public var secretName: String?

        public init(name: String, value: String, secret: Bool = false, secretName: String? = nil) {
            self.name = name; self.value = value; self.secret = secret; self.secretName = secretName
        }
    }

    /// A server typed on the sheet: a local command, or a remote URL.
    public struct MCPHandServer: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable { case command, url }
        public var name: String
        public var kind: Kind
        public var command: String
        public var args: [String]
        public var env: [MCPHandValue]
        public var url: String
        public var headers: [MCPHandValue]

        public init(name: String, kind: Kind, command: String = "", args: [String] = [],
                    env: [MCPHandValue] = [], url: String = "", headers: [MCPHandValue] = []) {
            self.name = name; self.kind = kind; self.command = command; self.args = args
            self.env = env; self.url = url; self.headers = headers
        }

        /// The name `${…}` a secret is stored under when the person names none: the
        /// variable's own name, or the server's and the header's for a header.
        public static func defaultSecretName(server: String, value: String, header: Bool) -> String {
            let raw = header ? "\(server)_\(value)" : value
            let mapped = raw.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
            var name = String(mapped)
            if let first = name.first, first.isNumber { name = "_" + name }
            return name
        }

        /// Arguments typed on one line: split on spaces, with '…', "…" and \ as a shell would.
        public static func splitArguments(_ line: String) -> [String] {
            var args: [String] = []
            var current = ""
            var started = false
            var quote: Character?
            var escaped = false
            for char in line {
                if escaped {
                    current.append(char); escaped = false; started = true
                } else if char == "\\" && quote != "'" {
                    escaped = true
                } else if let open = quote {
                    if char == open { quote = nil } else { current.append(char) }
                } else if char == "'" || char == "\"" {
                    quote = char; started = true
                } else if char == " " || char == "\t" {
                    if started { args.append(current); current = ""; started = false }
                } else {
                    current.append(char); started = true
                }
            }
            if started { args.append(current) }
            return args
        }
    }

    public struct MCPVerifyRequest: Codable, Sendable {
        public var destination: SkillDestination
        public var server: MCPHandServer
        public init(destination: SkillDestination, server: MCPHandServer) {
            self.destination = destination; self.server = server
        }
    }

    /// What connecting to it found.
    public enum MCPVerifyOutcome: Codable, Hashable, Sendable {
        /// It answered `initialize`, and listed these tools.
        case answered(serverName: String?, version: String?, tools: [String])
        /// It wants a sign-in first (an HTTP 401). `resourceMetadata` is where its
        /// `WWW-Authenticate` points, when it says.
        case authRequired(resourceMetadata: String?)
        /// It did not answer as an MCP server, in words.
        case failed(String)
    }

    public struct MCPVerifyAnswer: Codable, Sendable {
        /// Set only when it answered: what `mcp/add-by-hand` adds.
        public var verifyID: UUID?
        public var outcome: MCPVerifyOutcome?
        /// The entry that would be written, with `${NAME}` where a secret goes.
        public var entry: [String: JSONValue]?
        /// What stopped it before it connected: a name taken, a secret missing, a bad URL.
        public var error: MCPCatalogError?

        public init(verifyID: UUID? = nil, outcome: MCPVerifyOutcome? = nil,
                    entry: [String: JSONValue]? = nil, error: MCPCatalogError? = nil) {
            self.verifyID = verifyID; self.outcome = outcome; self.entry = entry; self.error = error
        }
    }

    public struct MCPAddByHandRequest: Codable, Sendable {
        public var verifyID: UUID
        public var destination: SkillDestination
        public init(verifyID: UUID, destination: SkillDestination) {
            self.verifyID = verifyID; self.destination = destination
        }
    }

    public struct MCPPreviewRequest: Codable, Sendable {
        public var result: MCPCatalogResult
        public var destination: SkillDestination
        public var run: MCPRunKind?
        public init(result: MCPCatalogResult, destination: SkillDestination, run: MCPRunKind? = nil) {
            self.result = result; self.destination = destination; self.run = run
        }
    }

    public struct MCPPreviewAnswer: Codable, Sendable {
        public var preview: MCPPreview?
        public var error: MCPCatalogError?
        public init(preview: MCPPreview? = nil, error: MCPCatalogError? = nil) {
            self.preview = preview; self.error = error
        }
    }

    public struct MCPAddRequest: Codable, Sendable {
        public var previewID: UUID
        public var destination: SkillDestination
        public var secrets: [String: String]
        public var plain: [String: String]
        public var replace: Bool
        public init(previewID: UUID, destination: SkillDestination, secrets: [String: String] = [:],
                    plain: [String: String] = [:], replace: Bool = false) {
            self.previewID = previewID; self.destination = destination
            self.secrets = secrets; self.plain = plain; self.replace = replace
        }
    }

    public struct MCPAddAnswer: Codable, Sendable {
        public var server: ManagedMCPServer?
        public var error: MCPCatalogError?
        public init(server: ManagedMCPServer? = nil, error: MCPCatalogError? = nil) {
            self.server = server; self.error = error
        }
    }

    public struct MCPSearchAnswer: Codable, Sendable, Equatable {
        public var results: [MCPCatalogResult]
        public var error: MCPCatalogError?
        public init(results: [MCPCatalogResult], error: MCPCatalogError? = nil) {
            self.results = results; self.error = error
        }
    }

    public struct MCPSetSecretRequest: Codable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public struct MCPSetSecretAnswer: Codable, Sendable {
        public var set: Bool
        public init(set: Bool) { self.set = set }
    }

    public struct MCPRemoveRequest: Codable, Sendable {
        public var destination: SkillDestination
        public var name: String
        public var forgetSecret: String?
        public init(destination: SkillDestination, name: String, forgetSecret: String? = nil) {
            self.destination = destination
            self.name = name
            self.forgetSecret = forgetSecret
        }
    }

    public struct MCPRemoveAnswer: Codable, Sendable {
        public var ok: Bool
        public init(ok: Bool) { self.ok = ok }
    }

    /// A project entry is approved, or waiting on the digest the person was shown.
    public enum MCPApprovalState: Codable, Hashable, Sendable {
        case approved
        case waiting(digest: String, isNew: Bool)
    }

    /// One server on the project page, or in `mcp/list` (060, frame D).
    public struct ProjectMCPServer: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var summary: String
        public var managed: ManagedMCPServer?
        public var approval: MCPApprovalState
        public var missingSecrets: [String]
        /// Every `${NAME}` the entry names, set or not.
        public var secretNames: [String]
        public var entryDigest: String
        /// Signed in, or asking for a sign-in (#306). Nil for a server that never asked.
        /// Never the grant itself.
        public var signIn: MCPSignInState?

        public var id: String { name }

        public init(name: String, summary: String, managed: ManagedMCPServer?, approval: MCPApprovalState,
                    missingSecrets: [String], secretNames: [String] = [], entryDigest: String,
                    signIn: MCPSignInState? = nil) {
            self.name = name
            self.summary = summary
            self.managed = managed
            self.approval = approval
            self.missingSecrets = missingSecrets
            self.secretNames = secretNames
            self.entryDigest = entryDigest
            self.signIn = signIn
        }
    }

    public struct MCPListRequest: Codable, Sendable {
        public var destination: SkillDestination
        public init(destination: SkillDestination) { self.destination = destination }
    }

    public struct MCPListAnswer: Codable, Sendable {
        public var servers: [ProjectMCPServer]
        public var problem: String?
        /// The approvals file could not be read, so every server waits (#169): what the
        /// section says above them.
        public var approvalsProblem: String?
        public init(servers: [ProjectMCPServer], problem: String? = nil, approvalsProblem: String? = nil) {
            self.servers = servers
            self.problem = problem
            self.approvalsProblem = approvalsProblem
        }
    }

    public struct MCPApproveRequest: Codable, Sendable {
        public var destination: SkillDestination
        public var name: String
        public var digest: String
        public init(destination: SkillDestination, name: String, digest: String) {
            self.destination = destination
            self.name = name
            self.digest = digest
        }
    }
}

// MARK: Signing in to a server (#306)

extension DaemonAPI {
    /// What a row says of a server's sign-in. The grant stays in the daemon.
    public enum MCPSignInState: String, Codable, Hashable, Sendable {
        case signedIn
        case needsSignIn
    }

    /// The server to sign in to: one in an `mcp.json`, or one typed on the by-hand sheet
    /// and not written yet.
    public enum MCPSignInTarget: Codable, Hashable, Sendable {
        case entry(destination: SkillDestination, name: String)
        case url(name: String, url: String)

        public var name: String {
            switch self {
            case .entry(_, let name), .url(let name, _): name
            }
        }
    }

    /// A client the person registered with the server's sign-in themselves, for one that
    /// does not let apps register (GitHub's). The secret, when there is one, is kept with
    /// the sign-ins and never shown again.
    public struct MCPSignInClient: Codable, Hashable, Sendable {
        public var id: String
        public var secret: String?
        public init(id: String, secret: String? = nil) {
            self.id = id; self.secret = secret
        }
    }

    public struct MCPSignInRequest: Codable, Sendable {
        public var target: MCPSignInTarget
        public var client: MCPSignInClient?
        public init(target: MCPSignInTarget, client: MCPSignInClient? = nil) {
            self.target = target; self.client = client
        }
    }

    public struct MCPSignInAnswer: Codable, Sendable {
        /// What to wait on.
        public var flowID: UUID?
        /// The page to open in the browser.
        public var authorizationURL: String?
        /// The sign-in has no registration: ask the person for a client of their own,
        /// registered with this issuer, and start again with it.
        public var needsClient: String?
        /// The loopback address that client must allow as its callback.
        public var callback: String?
        /// Why it could not start, in words.
        public var error: String?

        public init(flowID: UUID? = nil, authorizationURL: String? = nil, needsClient: String? = nil,
                    callback: String? = nil, error: String? = nil) {
            self.flowID = flowID; self.authorizationURL = authorizationURL; self.needsClient = needsClient
            self.callback = callback; self.error = error
        }
    }

    public struct MCPSignInFlowRequest: Codable, Sendable {
        public var flowID: UUID
        public init(flowID: UUID) { self.flowID = flowID }
    }

    public enum MCPSignInStatus: Codable, Hashable, Sendable {
        /// Still waiting for the browser: ask again.
        case waiting
        case signedIn
        case failed(String)
        case cancelled
    }

    public struct MCPSignInWaitAnswer: Codable, Sendable {
        public var status: MCPSignInStatus
        public init(status: MCPSignInStatus) { self.status = status }
    }

    public struct MCPSignOutRequest: Codable, Sendable {
        public var target: MCPSignInTarget
        public init(target: MCPSignInTarget) { self.target = target }
    }

    public struct MCPSignOutAnswer: Codable, Sendable {
        public var error: String?
        public init(error: String? = nil) { self.error = error }
    }
}

/// Failure payload for MCP catalogue calls. Reuses catalogRefused.
extension DaemonAPI.Failure {
    /// Same code as skills catalogue refusal; discriminate by payload shape.
    public static let mcpCatalogRefused = catalogRefused
}
