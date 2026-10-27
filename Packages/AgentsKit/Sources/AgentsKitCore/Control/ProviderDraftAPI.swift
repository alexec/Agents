import Foundation

// Write It for Me (#858, specs/858-provider-map-writer): an agent on the control plane's own
// host writes a provider's tool map or commands. The control plane holds the draft, the
// secrets and every call to the server or the CLI; the agent has only the writer's tools.

public extension DaemonAPI.Method {
    /// `ProviderDraftStart` → `ProviderDraftStarted`, once the agent has started, or at once
    /// when no agent is needed (research R8).
    static let providersDraftStart = "providers/draftStart"
    /// `ProviderDraftRequest` → `{}`: the agent stops, the draft is dropped.
    static let providersDraftCancel = "providers/draftCancel"
    /// `ProviderDraftAnswer` → `{}`: the person's answer to a start, stop or check question.
    static let providersDraftAnswer = "providers/draftAnswer"
    /// `{}` → `ProviderRuntimes`: the runtimes that can write, on the control plane's host.
    static let providersRuntimes = "providers/runtimes"
    /// `MachineProviderDraftCall` → `{note}`: a host to its control plane on channel 0.
    static let hostProviderDraft = "host/providerDraft"
}

public extension DaemonAPI.Notification {
    /// `ProviderDraftUpdate`, to the client session that started the draft only.
    static let controlProviderDraft = "control/providerDraft"
}

/// Why an agent was started, when it was not for a person's work (#858). Such an agent is in
/// no list a client sees, has only the tools of its purpose, and runs in a folder of its own.
public enum AgentPurpose: Codable, Hashable, Sendable {
    /// Writes one draft of a provider's tool map or commands.
    case providerDraft(id: UUID)

    public var providerDraft: UUID? {
        switch self {
        case .providerDraft(let id): id
        }
    }
}

public extension DaemonAPI {
    /// `providers/draftStart`.
    struct ProviderDraftStart: Codable, Sendable, Hashable {
        /// The form so far: for Your commands, `kind` is `commands` and `cli` is set.
        public var form: ProviderAdd
        /// Name to value, typed in the sheet. Held in memory for the draft only.
        public var secrets: [String: String]?
        /// In Edit…: the provider whose map or commands are written again (US4).
        public var provider: ProviderID?
        public var runtimeID: String

        public init(form: ProviderAdd, secrets: [String: String]? = nil, provider: ProviderID? = nil, runtimeID: String) {
            self.form = form
            self.secrets = secrets
            self.provider = provider
            self.runtimeID = runtimeID
        }
    }

    /// What `providers/draftStart` answers.
    struct ProviderDraftStarted: Codable, Sendable, Hashable {
        /// Answered with no agent (research R8).
        public struct Answered: Codable, Sendable, Hashable {
            public var note: String
            /// The shipped map that fits.
            public var map: JSONValue?
            /// The preset whose CLI this is.
            public var preset: String?
            public init(note: String, map: JSONValue? = nil, preset: String? = nil) {
                self.note = note
                self.map = map
                self.preset = preset
            }
        }

        public var draft: UUID
        public var answered: Answered?
        public init(draft: UUID, answered: Answered? = nil) {
            self.draft = draft
            self.answered = answered
        }
    }

    /// `providers/draftCancel`.
    struct ProviderDraftRequest: Codable, Sendable, Hashable {
        public var draft: UUID
        public init(draft: UUID) { self.draft = draft }
    }

    /// `providers/draftAnswer`.
    struct ProviderDraftAnswer: Codable, Sendable, Hashable {
        public var draft: UUID
        public var question: UUID
        public var yes: Bool
        public init(draft: UUID, question: UUID, yes: Bool) {
            self.draft = draft
            self.question = question
            self.yes = yes
        }
    }

    /// `providers/runtimes`.
    struct ProviderRuntimes: Codable, Sendable, Hashable {
        public struct Runtime: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            public var name: String
            public var isDefault: Bool
            public init(id: String, name: String, isDefault: Bool) {
                self.id = id
                self.name = name
                self.isDefault = isDefault
            }
        }

        public var runtimes: [Runtime]
        /// The host the agent runs on, by name.
        public var host: String?
        /// Why none can write here.
        public var why: String?
        public init(runtimes: [Runtime], host: String? = nil, why: String? = nil) {
            self.runtimes = runtimes
            self.host = host
            self.why = why
        }
    }

    /// One thing a draft did (data-model.md, "DraftStep"), redacted.
    struct DraftStep: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case read, help, check, ask, prove, note }
        public var at: Date
        public var kind: Kind
        public var text: String
        public init(at: Date = Date(), kind: Kind, text: String) {
            self.at = at
            self.kind = kind
            self.text = text
        }
    }

    /// A draft's last check.
    struct DraftCheck: Codable, Sendable, Hashable {
        public var passed: Bool
        public var workspaces: [MachineInfo]?
        public var problem: String?
        /// What `ssh -G` resolved one workspace's destination to, in words (#975).
        public var ssh: String?
        /// The draft gives no ssh destination, so Add as Host… and an ssh start can't work (#975).
        public var noSSH: Bool?
        public init(passed: Bool, workspaces: [MachineInfo]? = nil, problem: String? = nil, ssh: String? = nil,
                    noSSH: Bool? = nil) {
            self.passed = passed
            self.workspaces = workspaces
            self.problem = problem
            self.ssh = ssh
            self.noSSH = noSSH
        }
    }

    /// A question for the person in the sheet (US3, FR-013, FR-014).
    struct DraftQuestion: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable { case start, stop, check }
        public var id: UUID
        public var kind: Kind
        public var workspace: String?
        public var cost: String?
        /// Worded whole: "Claude wants to start scratch-1 on DigitalOcean to prove the map."
        public var text: String
        /// Start It, Stop It or Run Check.
        public var yes: String
        public init(id: UUID = UUID(), kind: Kind, workspace: String? = nil, cost: String? = nil, text: String, yes: String) {
            self.id = id
            self.kind = kind
            self.workspace = workspace
            self.cost = cost
            self.text = text
            self.yes = yes
        }
    }

    /// `control/providerDraft`: where a draft stands, sent on every step and change.
    struct ProviderDraftUpdate: Codable, Sendable, Hashable {
        /// `reading`, `writing`, `checking`, `asking`, `proving`, `done`, `failed`, `cancelled`.
        public var draft: UUID
        public var state: String
        public var runtimeName: String
        public var steps: [DraftStep]
        public var cost: String?
        /// The map or config: in `done` the result; before, the last one checked.
        public var draftJSON: JSONValue?
        public var check: DraftCheck?
        public var question: DraftQuestion?
        /// In `done` the agent's note; in `failed` the reason.
        public var note: String?

        public init(draft: UUID, state: String, runtimeName: String, steps: [DraftStep] = [], cost: String? = nil,
                    draftJSON: JSONValue? = nil, check: DraftCheck? = nil, question: DraftQuestion? = nil,
                    note: String? = nil) {
            self.draft = draft
            self.state = state
            self.runtimeName = runtimeName
            self.steps = steps
            self.cost = cost
            self.draftJSON = draftJSON
            self.check = check
            self.question = question
            self.note = note
        }

        public var ended: Bool { ["done", "failed", "cancelled"].contains(state) }
    }

    /// A writer's tool call, as the agent made it, by its token.
    struct ProviderDraftToolRequest: Codable, Sendable, Hashable {
        public var token: String
        public var tool: String
        public var arguments: JSONValue?
        public init(token: String, tool: String, arguments: JSONValue? = nil) {
            self.token = token
            self.tool = tool
            self.arguments = arguments
        }
    }

    /// `host/providerDraft`: a writer's tool call, relayed by its host. `agentID` is the
    /// caller, which the control plane checks against the draft's agent (FR-011).
    struct MachineProviderDraftCall: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var draft: UUID
        public var tool: String
        public var arguments: JSONValue?
        public init(agentID: UUID, draft: UUID, tool: String, arguments: JSONValue? = nil) {
            self.agentID = agentID
            self.draft = draft
            self.tool = tool
            self.arguments = arguments
        }
    }
}
