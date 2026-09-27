import Foundation

/// Searching the MCP Registry and adding servers (060, contracts/mcp-methods.md).
/// Control-only: none of these is in `deviceMethods` or `agentMethods`.
extension DaemonAPI.Method {
    public static let mcpPreview = "mcp/preview"
    public static let mcpAdd = "mcp/add"
    public static let mcpList = "mcp/list"
    public static let mcpApprove = "mcp/approve"
    public static let mcpSetSecret = "mcp/set-secret"
    public static let mcpRemove = "mcp/remove"

    public static let mcpCatalogMethods: [String] = [
        mcpPreview, mcpAdd, mcpList, mcpApprove, mcpSetSecret, mcpRemove,
    ]
}

extension DaemonAPI {
    public enum CatalogKind: String, Codable, Sendable {
        case skills
        case mcp
    }

    public enum MCPRunKind: String, Codable, Hashable, Sendable {
        case remote, npx, uvx, docker
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
        public var registryName: String
        public var version: String
        public var run: MCPRunKind
        public var addedAt: Date
        public var destination: SkillDestination

        public init(name: String, registryName: String, version: String, run: MCPRunKind,
                    addedAt: Date, destination: SkillDestination) {
            self.name = name; self.registryName = registryName; self.version = version
            self.run = run; self.addedAt = addedAt; self.destination = destination
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

        public var id: String { name }

        public init(name: String, summary: String, managed: ManagedMCPServer?, approval: MCPApprovalState,
                    missingSecrets: [String], secretNames: [String] = [], entryDigest: String) {
            self.name = name
            self.summary = summary
            self.managed = managed
            self.approval = approval
            self.missingSecrets = missingSecrets
            self.secretNames = secretNames
            self.entryDigest = entryDigest
        }
    }

    public struct MCPListRequest: Codable, Sendable {
        public var destination: SkillDestination
        public init(destination: SkillDestination) { self.destination = destination }
    }

    public struct MCPListAnswer: Codable, Sendable {
        public var servers: [ProjectMCPServer]
        public var problem: String?
        public init(servers: [ProjectMCPServer], problem: String? = nil) {
            self.servers = servers
            self.problem = problem
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

/// Failure payload for MCP catalogue calls. Reuses catalogRefused.
extension DaemonAPI.Failure {
    /// Same code as skills catalogue refusal; discriminate by payload shape.
    public static let mcpCatalogRefused = catalogRefused
}
