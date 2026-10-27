import Foundation

// Machine providers (#691, specs/691-workspace-providers): MCP servers on the control plane
// that start and stop the machines hosts run on. What is here is records and the wire; the
// MCP client and the starts are ControlPlaneKit's, handed in as `WorkspaceHandling`.

/// A provider, by the id the control plane gave it.
public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A slug of the name and four random characters: `digitalocean-x7k2`.
    public static func make(name: String) -> ProviderID {
        let mapped: [Character] = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let slug = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let tail = String((0..<4).map { _ in alphabet.randomElement()! })
        let head = String(slug.prefix(24))
        return ProviderID(rawValue: "\(head.isEmpty ? "provider" : head)-\(tail)")
    }

    public var description: String { rawValue }
}

/// A host and the workspace it runs on (data-model.md, "WorkspaceLink").
public struct WorkspaceLink: Codable, Hashable, Sendable {
    public var provider: ProviderID
    /// The workspace's id, as its provider lists it.
    public var workspace: String
    /// A prompt or agent start for it while stopped starts it (US3). Nil reads as on.
    public var startWhenUsed: Bool?
    /// Stopped once idle this long (US4); nil is off.
    public var stopWhenIdleMinutes: Int?
    /// Started a little before the host's next scheduled workflow while stopped (#1004
    /// FR-009). Nil reads as on.
    public var startForSchedules: Bool?
    /// The host's next scheduled workflow as it last said it (FR-003), kept while it is stopped.
    public var schedule: DaemonAPI.MachineSchedule?
    /// How long its last start took, from asking the provider to the host connecting (FR-004).
    public var measuredStartSeconds: Int?
    /// The due time it was last started for, so each starts it once (FR-006).
    public var wokeFor: Date?

    public static let defaultIdleMinutes = 30

    public init(provider: ProviderID, workspace: String, startWhenUsed: Bool? = true,
                stopWhenIdleMinutes: Int? = WorkspaceLink.defaultIdleMinutes) {
        self.provider = provider
        self.workspace = workspace
        self.startWhenUsed = startWhenUsed
        self.stopWhenIdleMinutes = stopWhenIdleMinutes
    }
}

/// A provider as the store keeps it, `v1/providers/<id>.json`: never its secrets' values,
/// which stay in the control plane's own home (research R3).
public struct ProviderRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The command provider Agents ships (`workspace-commands`).
        case commands
        /// An MCP server the control plane runs.
        case stdio
        /// An MCP server at an address.
        case http
    }

    public var id: ProviderID
    public var name: String
    public var kind: Kind
    public var command: String?
    public var args: [String]?
    public var url: String?
    /// Values may hold `${SECRET}`, filled in from the secrets when the server is reached.
    public var headers: [String: String]?
    /// The command provider's configuration (contracts/command-provider.md).
    public var commands: JSONValue?
    public var secretNames: [String]
    /// For a server whose tools don't follow the contract (contracts/tool-map.md).
    public var map: JSONValue?
    /// Which optional contract tools it has: `options`, `create`, `delete`.
    public var capabilities: [String]
    public var contract: Int
    public var rev: Int
    public var forgotten: Bool?
    /// Set when the map or commands were kept as an agent wrote them at Add Provider (#858).
    public var writtenBy: WrittenBy?

    /// Who wrote a provider's map or commands, when it was an agent (#858).
    public struct WrittenBy: Codable, Hashable, Sendable {
        public var runtimeID: String
        public var at: Date
        public init(runtimeID: String, at: Date) {
            self.runtimeID = runtimeID
            self.at = at
        }
    }

    public init(id: ProviderID, name: String, kind: Kind, command: String? = nil, args: [String]? = nil,
                url: String? = nil, headers: [String: String]? = nil, commands: JSONValue? = nil,
                secretNames: [String] = [], map: JSONValue? = nil, capabilities: [String] = [],
                contract: Int = 1, rev: Int = 0, forgotten: Bool? = nil, writtenBy: WrittenBy? = nil) {
        self.writtenBy = writtenBy
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.headers = headers
        self.commands = commands
        self.secretNames = secretNames
        self.map = map
        self.capabilities = capabilities
        self.contract = contract
        self.rev = rev
        self.forgotten = forgotten
    }

    /// Why it can't be used as it is, in words for the sheet; nil when it can.
    public var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give it a name." }
        if trimmed.count > 60 { return "The name is over 60 characters." }
        switch kind {
        case .commands:
            if commands?.objectValue == nil { return "Choose a preset or give its commands." }
        case .stdio:
            if (command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return "Give the command that runs the server." }
        case .http:
            guard let url, url.hasPrefix("http://") || url.hasPrefix("https://"), URL(string: url) != nil else {
                return "The address must start with http:// or https://."
            }
        }
        for name in referencedSecrets where !secretNames.contains(name) {
            return "${\(name)} isn’t one of its secrets."
        }
        return nil
    }

    /// The `${NAME}` its headers name.
    public var referencedSecrets: [String] {
        (headers ?? [:]).values.flatMap(Self.placeholders).sorted()
    }

    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            found.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }
}

/// The control plane's part that talks to providers, handed to `ControlMethods` by the
/// executable. Absent on a control plane with several copies (research R4).
public protocol WorkspaceHandling: Sendable {
    func answer(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue
    /// A host said whether it is idle (`machine/status`, #691 US4).
    func heard(_ host: MachineRef, status: DaemonAPI.MachineStatus) async
    /// An agent on `host` asked through its workspace tools (US6): one of
    /// `agentWorkspaceMethods`, logged as that agent's.
    func agentCall(from host: MachineRef, agent: String, method: String, params: JSONValue) async throws -> JSONValue
    /// A writing agent on `host` called one of the writer's tools (#858).
    func draftCall(from host: MachineRef, call: DaemonAPI.MachineProviderDraftCall) async throws -> JSONValue
}

public extension WorkspaceHandling {
    func draftCall(from host: MachineRef, call: DaemonAPI.MachineProviderDraftCall) async throws -> JSONValue {
        throw JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "This control plane has no drafts.")
    }
}

public extension DaemonAPI.Method {
    /// `{}` → `{providers: [ProviderSummary]}`, as last listed.
    static let providersList = "providers/list"
    /// `ProviderAdd` → `ProviderSummary`, once the server has been checked and has listed.
    static let providersAdd = "providers/add"
    /// `ProviderAdd` with `id`; secrets left out are kept, and so are its command, address,
    /// headers, and map or commands (#858).
    static let providersUpdate = "providers/update"
    /// `ProviderRequest`. Its hosts stay, unlinked.
    static let providersRemove = "providers/remove"
    /// `{id?}`: list again, said as `control/providersChanged`.
    static let providersRefresh = "providers/refresh"
    /// `MachineLink` → `ControlMachine`. A workspace linked to another host moves here.
    static let hostsLink = "machines/link"
    /// `MachineRequest` → `ControlMachine`.
    static let hostsUnlink = "machines/unlink"
    /// `MachineOptions` → `ControlMachine`.
    static let hostsSetMachineOptions = "machines/setMachineOptions"
    /// `MachineRequest` → `ControlMachine`, at once; the start goes on, said as `control/hostChanged`.
    static let hostsStart = "machines/start"
    /// `MachineStop` → `ControlMachine`, at once.
    static let hostsStop = "machines/stop"
    /// `ProviderRequest` → `ProviderOptions`: the New Machine form (US5).
    static let providersOptions = "providers/options"
    /// `ProviderCreate` → `ProviderCreated`, once the provider has made it (US5).
    static let providersCreate = "providers/create"
    /// `MachineRequest` → `{}`: its workspace deleted, then the host removed (US5).
    static let hostsDeleteMachine = "machines/deleteMachine"

    /// Every method the control plane's workspace part answers.
    static let workspaceMethods: Set<String> = [
        providersList, providersAdd, providersUpdate, providersRemove, providersRefresh,
        hostsLink, hostsUnlink, hostsSetMachineOptions, hostsStart, hostsStop,
        hostsKeep, hostsListKept, hostsDropKept, hostsRetryKept,
        providersOptions, providersCreate, hostsDeleteMachine,
        providersDraftStart, providersDraftCancel, providersDraftAnswer, providersRuntimes,
    ]
}

public extension DaemonAPI.Notification {
    /// `{providers: [ProviderSummary]}`.
    static let controlProvidersChanged = "control/providersChanged"
}

public extension DaemonAPI.Failure {
    /// Providers run only on a control plane with one copy, for now (research R4).
    static let providersNeedOneCopy = -32064
    /// A start or stop for a host that isn't linked to a workspace.
    static let notLinked = -32065
    /// The provider said no, in its own words.
    static let providerFailed = -32066
    /// Stop while agents are working there, not confirmed (US4 AS4). `data` is `{running: [names]}`.
    static let agentsWorking = -32068
}

public extension DaemonAPI {
    /// One workspace, as its provider last listed it (contracts/provider-contract.md).
    struct MachineInfo: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        /// `running`, `starting`, `stopping`, `stopped` or `unknown`.
        public var state: String
        public var ssh: String?
        public var tunnel: Bool?
        /// Its ssh host key is made again at each start (#1701).
        public var hostKeyRenews: Bool?
        public var cost: String?
        /// The host it is linked to, in `providers/list`.
        public var host: MachineRef?

        public init(id: String, name: String, state: String, ssh: String? = nil, tunnel: Bool? = nil,
                    hostKeyRenews: Bool? = nil, cost: String? = nil, host: MachineRef? = nil) {
            self.id = id
            self.name = name
            self.state = state
            self.ssh = ssh
            self.tunnel = tunnel
            self.hostKeyRenews = hostKeyRenews
            self.cost = cost
            self.host = host
        }

        /// Whether a host added by hand may be this workspace (#976): its name is the
        /// workspace's ssh destination, or one of its dot-separated parts is the workspace's
        /// name, as `cws.devstack-d7539e59` is for `devstack-d7539e59`. Never a part of a
        /// part: `dev` is not `devstack`.
        public func mayBe(hostNamed hostName: String) -> Bool {
            let host = hostName.lowercased()
            if let ssh, !ssh.isEmpty, ssh.lowercased() == host { return true }
            let name = name.lowercased()
            guard !name.isEmpty else { return false }
            if host == name { return true }
            // The name may hold dots of its own, so match it as a run of whole parts.
            return ".\(host).".contains(".\(name).")
        }
    }

    /// A provider for the Providers page: never its commands, headers or secrets' values.
    struct ProviderSummary: Codable, Sendable, Hashable, Identifiable {
        public var id: ProviderID
        public var name: String
        public var kind: String
        /// Each secret's name, and whether it has a value.
        public var secrets: [String: Bool]
        public var capabilities: [String]
        public var contract: Int
        public var mapped: Bool
        /// The command provider's preset, when it uses one.
        public var preset: String?
        public var workspaces: [MachineInfo]
        public var listedAt: Date?
        /// False once a list has failed after a good one: `workspaces` is what it last said.
        public var current: Bool
        public var problem: String?
        /// The group whose users may use it (#1761); none is the admins' alone.
        public var group: String?
        /// The caller may start machines from it (#1761). Nil from an older control plane,
        /// which lets everyone.
        public var mayUse: Bool?

        public init(id: ProviderID, name: String, kind: String, secrets: [String: Bool] = [:],
                    capabilities: [String] = [], contract: Int = 1, mapped: Bool = false, preset: String? = nil,
                    workspaces: [MachineInfo] = [], listedAt: Date? = nil, current: Bool = true,
                    problem: String? = nil, group: String? = nil, mayUse: Bool? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.secrets = secrets
            self.capabilities = capabilities
            self.contract = contract
            self.mapped = mapped
            self.preset = preset
            self.workspaces = workspaces
            self.listedAt = listedAt
            self.current = current
            self.problem = problem
            self.group = group
            self.mayUse = mayUse
        }

        /// Whether the caller may start machines from it.
        public var usable: Bool { mayUse ?? true }
    }

    /// A linked host's workspace, on its `machines/list` row and in `control/hostChanged`.
    struct MachineWorkspace: Codable, Sendable, Hashable {
        public var provider: ProviderID
        public var providerName: String
        public var workspace: String
        public var workspaceName: String
        /// As the provider last listed it.
        public var workspaceState: String
        /// What the host is shown as while it isn't online, over its uplink's own state:
        /// `stopped`, `starting` or `stopping`. `stopping` shows while it is still online too.
        public var hostState: String?
        /// While starting: `provider` (asked to start it), `connecting` (waiting for its
        /// agentsd) or `sshStart` (starting agentsd over ssh).
        public var phase: String?
        /// When the start or stop began, for the strip's timer.
        public var since: Date?
        /// Why the last start or stop failed, in the provider's words.
        public var problem: String?
        /// "Stopped by Agents after 30 minutes idle", already worded.
        public var stoppedBy: String?
        public var canStart: Bool
        public var canStop: Bool
        public var startWhenUsed: Bool
        public var stopWhenIdleMinutes: Int?
        public var cost: String?
        /// False when the provider's last list failed.
        public var current: Bool
        /// The Start for scheduled workflows switch (#1004 FR-009).
        public var startForSchedules: Bool?
        /// Whether the host says when its next scheduled workflow is due (FR-011): one from
        /// before #1004 doesn't, so it gets no wake-up calls and keeps the old warning.
        public var tellsSchedule: Bool?
        /// Its next scheduled workflow, as it last said it.
        public var nextWorkflow: String?
        public var nextWorkflowAt: Date?
        /// When the control plane will start it for that workflow (FR-007): while it is
        /// stopped, with the switch on.
        public var wakeAt: Date?

        public init(provider: ProviderID, providerName: String, workspace: String, workspaceName: String,
                    workspaceState: String, hostState: String? = nil, phase: String? = nil, since: Date? = nil,
                    problem: String? = nil, stoppedBy: String? = nil, canStart: Bool = false, canStop: Bool = false,
                    startWhenUsed: Bool = true, stopWhenIdleMinutes: Int? = nil, cost: String? = nil,
                    current: Bool = true, startForSchedules: Bool? = nil, tellsSchedule: Bool? = nil,
                    nextWorkflow: String? = nil, nextWorkflowAt: Date? = nil, wakeAt: Date? = nil) {
            self.startForSchedules = startForSchedules
            self.tellsSchedule = tellsSchedule
            self.nextWorkflow = nextWorkflow
            self.nextWorkflowAt = nextWorkflowAt
            self.wakeAt = wakeAt
            self.provider = provider
            self.providerName = providerName
            self.workspace = workspace
            self.workspaceName = workspaceName
            self.workspaceState = workspaceState
            self.hostState = hostState
            self.phase = phase
            self.since = since
            self.problem = problem
            self.stoppedBy = stoppedBy
            self.canStart = canStart
            self.canStop = canStop
            self.startWhenUsed = startWhenUsed
            self.stopWhenIdleMinutes = stopWhenIdleMinutes
            self.cost = cost
            self.current = current
        }
    }

    /// `providers/add` and `providers/update`.
    struct ProviderAdd: Codable, Sendable, Hashable {
        /// For an update.
        public var id: ProviderID?
        public var name: String
        public var kind: ProviderRecord.Kind
        public var command: String?
        public var args: [String]?
        public var url: String?
        public var headers: [String: String]?
        public var commands: JSONValue?
        public var map: JSONValue?
        /// Name to value. Only ever sent to the control plane; never given back.
        public var secrets: [String: String]?
        /// Your commands: the program its commands use, for Write It for Me (#858). Not kept.
        public var cli: String?
        /// The draft this accepts (#858): its map or commands, unchanged, mark the record
        /// `writtenBy`.
        public var draft: UUID?

        public init(id: ProviderID? = nil, name: String, kind: ProviderRecord.Kind, command: String? = nil,
                    args: [String]? = nil, url: String? = nil, headers: [String: String]? = nil,
                    commands: JSONValue? = nil, map: JSONValue? = nil, secrets: [String: String]? = nil,
                    cli: String? = nil, draft: UUID? = nil) {
            self.cli = cli
            self.draft = draft
            self.id = id
            self.name = name
            self.kind = kind
            self.command = command
            self.args = args
            self.url = url
            self.headers = headers
            self.commands = commands
            self.map = map
            self.secrets = secrets
        }
    }

    struct ProviderRequest: Codable, Sendable, Hashable {
        public var id: ProviderID?
        public init(id: ProviderID?) { self.id = id }
    }

    /// `machines/link`.
    struct MachineLink: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var provider: ProviderID
        public var workspace: String
        public var startWhenUsed: Bool?
        public var stopWhenIdleMinutes: Int?

        public init(host: MachineRef, provider: ProviderID, workspace: String, startWhenUsed: Bool? = nil,
                    stopWhenIdleMinutes: Int? = nil) {
            self.host = host
            self.provider = provider
            self.workspace = workspace
            self.startWhenUsed = startWhenUsed
            self.stopWhenIdleMinutes = stopWhenIdleMinutes
        }
    }

    /// `machines/setMachineOptions`. `stopWhenIdleMinutes` 0 turns it off.
    struct MachineOptions: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var startWhenUsed: Bool?
        public var stopWhenIdleMinutes: Int?
        /// Start for scheduled workflows (#1004 FR-009).
        public var startForSchedules: Bool?

        public init(host: MachineRef, startWhenUsed: Bool? = nil, stopWhenIdleMinutes: Int? = nil,
                    startForSchedules: Bool? = nil) {
            self.startForSchedules = startForSchedules
            self.host = host
            self.startWhenUsed = startWhenUsed
            self.stopWhenIdleMinutes = stopWhenIdleMinutes
        }
    }

    /// `providers/options`: a flat JSON Schema object of strings, integers, booleans and
    /// enums with titles. An enum's `x-costs` may name each value's cost, for the confirmation.
    struct ProviderOptions: Codable, Sendable, Hashable {
        public var schema: JSONValue
        public init(schema: JSONValue) { self.schema = schema }
    }

    /// `providers/create`.
    struct ProviderCreate: Codable, Sendable, Hashable {
        public var id: ProviderID
        public var name: String
        public var options: JSONValue?
        /// Git URLs the new host clones once it has joined (#1122), as File ▸ Clone Folder
        /// does, one after another. Nil or empty for none.
        public var clones: [String]?
        /// The repository to start it from (#1809), an https git address. A provider whose
        /// New Machine form has `repository`, such as Codespaces, makes the workspace from
        /// it; any other has the host clone it once it joins, before `clones`.
        public var repository: String?
        public init(id: ProviderID, name: String, options: JSONValue? = nil, clones: [String]? = nil,
                    repository: String? = nil) {
            self.id = id
            self.name = name
            self.options = options
            self.clones = clones
            self.repository = repository
        }
    }

    /// What `providers/create` made. `joining`: it runs the install on its first boot, and is
    /// linked when it joins. Otherwise it is added over its `ssh`, as Add as Host… does.
    struct ProviderCreated: Codable, Sendable, Hashable {
        public var workspace: MachineInfo
        public var joining: Bool
        public init(workspace: MachineInfo, joining: Bool) {
            self.workspace = workspace
            self.joining = joining
        }
    }

    /// `machines/stop`.
    struct MachineStop: Codable, Sendable, Hashable {
        public var host: MachineRef
        /// Stop even though turns are running there (US4).
        public var confirmRunning: Bool?

        public init(host: MachineRef, confirmRunning: Bool? = nil) {
            self.host = host
            self.confirmRunning = confirmRunning
        }
    }
}
