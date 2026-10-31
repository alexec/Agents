import Foundation

/// Kept requests (#691 US3, research R9): a prompt or an agent start for a host whose
/// workspace is stopped, held by the control plane, which starts the workspace and delivers
/// the request once the host connects.
///
/// The router doesn't know about providers or the store. It asks this, for a request it
/// would otherwise refuse as offline, and tells it when a host attaches.
public protocol KeptHandling: Sendable {
    /// A prompt or an agent start for a host that can't take it now. The error to answer
    /// with: `kept` when it was kept, another refusal, or nil to refuse it as today.
    func keep(host: MachineRef, method: String, params: JSONValue?, from caller: ControlRouter.Caller) async -> JSONRPCError?
    /// A host's uplink is up: what was kept for it goes now, in order.
    func attached(_ host: MachineRef) async
}

public extension DaemonAPI.Method {
    /// The only requests that are kept, and so the only ones that start a workspace
    /// (FR-020, FR-022). Both are idempotent by an id of their own (`sendID`, `requestID`),
    /// which the control plane fills in when the client left it out.
    static let keptMethods: Set<String> = [agentsPrompt, agentsStart]
    /// `MachineStatus`, from a host on channel 0, whenever it changes (#691 US4).
    static let hostStatus = "host/status"
    /// `KeepRequest` → never a result: the `kept` error, or the host's refusal. For a client
    /// whose link to a host closes while the host is offline (the window's, the Remote's),
    /// so it can't send the request to the host itself.
    static let hostsKeep = "hosts/keep"
    /// `{}` → `{kept: [KeptRequest]}`.
    static let hostsListKept = "hosts/listKept"
    /// `KeptRequestID` → `{}`. It isn't delivered; the workspace keeps starting (US3 AS3).
    static let hostsDropKept = "hosts/dropKept"
    /// `KeptRequestID` → `{}`. A not-sent one is kept again and the workspace started.
    static let hostsRetryKept = "hosts/retryKept"
}

public extension DaemonAPI.Notification {
    /// `{kept: [KeptRequest]}`: every kept request, whenever one is kept, fails, goes or is dropped.
    static let controlKeptChanged = "control/keptChanged"
    /// `KeptDelivered`: one reached its host. For a start, the agent it made, so a client
    /// showing the kept start opens the agent.
    static let controlKeptDelivered = "control/keptDelivered"
}

public extension DaemonAPI.Failure {
    /// Not sent yet, but kept: it goes when the host connects. `data` is the `KeptRequest`.
    static let kept = -32067
}

public extension DaemonAPI {
    /// A kept request, as clients draw it: never its attachments or options.
    struct KeptRequest: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var host: MachineRef
        /// `prompt` (to an agent there) or `start` (a new agent in a folder there).
        public var kind: String
        /// For a prompt.
        public var agentID: UUID?
        /// The prompt's words, or the new agent's first prompt.
        public var text: String
        /// For a start: the folder, and the runtime it starts.
        public var folder: URL?
        public var runtimeID: String?
        public var at: Date
        /// Not sent, and why (US3 AS4): the start failed, or the host refused it.
        public var failed: String?

        public init(id: UUID, host: MachineRef, kind: String, agentID: UUID? = nil, text: String,
                    folder: URL? = nil, runtimeID: String? = nil, at: Date, failed: String? = nil) {
            self.id = id
            self.host = host
            self.kind = kind
            self.agentID = agentID
            self.text = text
            self.folder = folder
            self.runtimeID = runtimeID
            self.at = at
            self.failed = failed
        }

        public var isStart: Bool { kind == "start" }
    }

    /// `hosts/keep`: a prompt or a start, as it would have gone to the host.
    struct KeepRequest: Codable, Sendable {
        public var host: MachineRef
        public var method: String
        public var params: JSONValue
        public init(host: MachineRef, method: String, params: JSONValue) {
            self.host = host
            self.method = method
            self.params = params
        }
    }

    /// `hosts/dropKept`, `hosts/retryKept`.
    struct KeptRequestID: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var id: UUID
        public init(host: MachineRef, id: UUID) {
            self.host = host
            self.id = id
        }
    }

    struct KeptList: Codable, Sendable, Hashable {
        public var kept: [KeptRequest]
        public init(kept: [KeptRequest]) { self.kept = kept }
    }

    /// `host/status` on channel 0 (#691 US4): whether the host is idle, and what is working
    /// there when it isn't, for the stop when idle and for Stop's confirmation.
    struct MachineStatus: Codable, Sendable, Hashable {
        public var idle: Bool
        /// "Claude (fix-login)": each agent working or waiting on a person.
        public var running: [String]
        /// Its next scheduled workflow, for the control plane's wake-up call (#1004 FR-002).
        /// Nil from a host from before #1004 (FR-011); empty when nothing is scheduled.
        public var schedule: MachineSchedule?
        public init(idle: Bool, running: [String] = [], schedule: MachineSchedule? = nil) {
            self.idle = idle
            self.running = running
            self.schedule = schedule
        }
    }

    /// A host's next scheduled workflow (#1004): only workflows that run on it, are
    /// approved, on and not archived. Both nil when there is none.
    struct MachineSchedule: Codable, Sendable, Hashable {
        public var at: Date?
        /// The workflow's name, as its page shows it.
        public var workflow: String?
        public init(at: Date? = nil, workflow: String? = nil) {
            self.at = at
            self.workflow = workflow
        }
    }

    /// `control/keptDelivered`.
    struct KeptDelivered: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var id: UUID
        /// For a start: the agent it made.
        public var agentID: UUID?
        public init(host: MachineRef, id: UUID, agentID: UUID? = nil) {
            self.host = host
            self.id = id
            self.agentID = agentID
        }
    }
}
