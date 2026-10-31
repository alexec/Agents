import Foundation

// MARK: The daemon's one answer (#175)

public extension DaemonAPI {
    /// `client/catchUp`: which agents to send with the snapshot, and which of the parts the
    /// pages on screen show to send with it.
    struct CatchUpRequest: Codable, Sendable {
        /// The first page of live agents, lean, unless said otherwise.
        public var agents: ListRequest
        /// Parts to send in the same answer (#884): through the relay each call is a round
        /// trip of two or three seconds, so one answer, not one call per part. A host that
        /// predates this sends none, and the client asks for each.
        public var parts: [CatchUpPart]

        public init(agents: ListRequest = CatchUpRequest.firstPage, parts: [CatchUpPart] = []) {
            self.agents = agents
            self.parts = parts
        }

        /// What a list on screen draws first: live agents, lean, one page (#164).
        public static let firstPage = ListRequest(includeArchived: false, lean: true)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agents = try c.decodeIfPresent(ListRequest.self, forKey: .agents) ?? Self.firstPage
            // A part this host does not know is left out: the client asks for it on its own.
            parts = (try? c.decodeIfPresent([String].self, forKey: .parts))?.compactMap(CatchUpPart.init) ?? []
        }
    }

    /// What a client needs before anything else after connecting, in one answer: the
    /// screen it opens on, and what is waiting on a person, which the badge and the widget
    /// count. Everything else is asked for when a page that shows it opens.
    struct CatchUpSnapshot: Codable, Sendable {
        public var folders: [FolderSummary]
        /// The first page of live agents. A full page means there are more, which come
        /// a folder at a time as each folder's page opens. Read a row at a time (#2650).
        @AgentRows public var agents: [Agent]
        public var permissions: [PermissionRequest]
        public var elicitations: [ElicitationRequest]
        public var attention: AttentionPending
        public var resuming: [UUID]
        /// The low-disk strip and what the host could not read, shown on every page (#884).
        /// Nil from a host that predates them.
        public var disk: DiskState?
        public var storeNotes: StoreNotes?
        /// The milestones earned (#984), for the one-time card. Nil from a host that predates them.
        public var milestones: Milestones?
        /// The parts asked for, each nil when it was not asked for or the host predates it.
        public var workflows: [WorkflowSummary]?
        public var pins: [FolderPins]?
        public var leases: Leases?

        /// The leases part: the leases, and the MCP servers read with them for their page.
        public struct Leases: Codable, Sendable {
            public var leases: LeaseSnapshot
            public var hosted: HostedMCPSnapshot
            public var health: MCPHealthSnapshot

            public init(leases: LeaseSnapshot, hosted: HostedMCPSnapshot, health: MCPHealthSnapshot) {
                self.leases = leases
                self.hosted = hosted
                self.health = health
            }
        }

        public init(folders: [FolderSummary], agents: [Agent], permissions: [PermissionRequest],
                    elicitations: [ElicitationRequest], attention: AttentionPending, resuming: [UUID]) {
            self.folders = folders
            self.agents = agents
            self.permissions = permissions
            self.elicitations = elicitations
            self.attention = attention
            self.resuming = resuming
        }

        /// The parts this answer carries.
        public var carried: Set<CatchUpPart> {
            var parts: Set<CatchUpPart> = []
            if workflows != nil { parts.insert(.workflows) }
            if pins != nil { parts.insert(.pins) }
            if leases != nil { parts.insert(.leases) }
            return parts
        }
    }
}

public extension DaemonClient {
    /// The snapshot, in one call; from a host that predates it, in one call per part,
    /// with the agents still one page. Throws only when the folders or the agents could
    /// not be read: without those there is nothing to show.
    func catchUp(_ request: DaemonAPI.CatchUpRequest = .init()) async throws -> DaemonAPI.CatchUpSnapshot {
        do {
            return try await call(DaemonAPI.Method.clientCatchUp, request, returning: DaemonAPI.CatchUpSnapshot.self)
        } catch let error as JSONRPCError where error.isMethodNotFound {
            let folders = try await call(DaemonAPI.Method.foldersList,
                                          DaemonAPI.FoldersListRequest(includeArchived: false),
                                          returning: [DaemonAPI.FolderSummary].self)
            let agents = try await call(DaemonAPI.Method.agentsList, request.agents, returning: [Agent].self)
            let none = Optional<String>.none
            let permissions = try? await call(DaemonAPI.Method.permissionsPending, none,
                                              returning: [PermissionRequest].self)
            let elicitations = try? await call(DaemonAPI.Method.elicitationsPending, none,
                                               returning: [ElicitationRequest].self)
            let attention = try? await call(DaemonAPI.Method.attentionPending, none,
                                            returning: DaemonAPI.AttentionPending.self)
            let resuming = try? await call(DaemonAPI.Method.agentsResuming, none,
                                           returning: DaemonAPI.ResumingResponse.self)
            return DaemonAPI.CatchUpSnapshot(folders: folders, agents: agents, permissions: permissions ?? [],
                                             elicitations: elicitations ?? [],
                                             attention: attention ?? DaemonAPI.AttentionPending(needs: [], deliveries: []),
                                             resuming: resuming?.agentIDs ?? [])
        }
    }
}

// MARK: What a client catches up on

/// What a page shows beyond the folder list and the open chat, fetched when a page that
/// shows it opens rather than on every connection (#175).
public enum CatchUpPart: String, CaseIterable, Codable, Sendable, Hashable {
    case workflows
    case pins
    case leases
    case runtimes
    case allowances
    case modes
    case sandbox
    case costs
}

/// The calls a client makes after connecting, in order: the snapshot, the open chat, and
/// whatever the pages on screen show. One after another, never side by side: a phone on a
/// poor link is helped by asking less, not by asking it all at once.
public struct CatchUpPlan: Equatable, Sendable {
    public enum Step: Hashable, Sendable {
        case snapshot
        case chat(UUID)
        case part(CatchUpPart)
    }

    public let steps: [Step]

    public init(chat: UUID?, onScreen: Set<CatchUpPart>) {
        var steps: [Step] = [.snapshot]
        if let chat { steps.append(.chat(chat)) }
        steps += CatchUpPart.allCases.filter(onScreen.contains).map(Step.part)
        self.steps = steps
    }

    public var parts: Set<CatchUpPart> {
        Set(steps.compactMap { if case .part(let part) = $0 { part } else { nil } })
    }
}

/// Which parts the pages on screen show, and which have been read on this connection.
///
/// A page says what it shows as it appears and as it goes; two pages can show the same
/// part. A part read once on a connection is kept true by the daemon's notifications, so
/// it is not read again until the connection is lost.
public struct OnScreenParts: Sendable {
    private var showing: [CatchUpPart: Int] = [:]
    private var read: Set<CatchUpPart> = []
    private var connected = false

    public init() {}

    public var onScreen: Set<CatchUpPart> { Set(showing.keys) }

    /// A page showing `parts` appeared: the ones to read now. None while disconnected;
    /// the catch-up reads them once the host answers.
    public mutating func appeared(_ parts: Set<CatchUpPart>) -> Set<CatchUpPart> {
        for part in parts { showing[part, default: 0] += 1 }
        guard connected else { return [] }
        let unread = parts.subtracting(read)
        read.formUnion(unread)
        return unread
    }

    public mutating func disappeared(_ parts: Set<CatchUpPart>) {
        for part in parts {
            guard let count = showing[part] else { continue }
            showing[part] = count > 1 ? count - 1 : nil
        }
    }

    /// Connected again: what to catch up on, with the parts on screen counted as read.
    public mutating func plan(chat: UUID?) -> CatchUpPlan {
        connected = true
        let plan = CatchUpPlan(chat: chat, onScreen: onScreen)
        read = plan.parts
        return plan
    }

    /// Nothing read before this holds once the connection has gone.
    public mutating func connectionLost() {
        connected = false
        read = []
    }

    /// The host said `part` changed in a way its notifications do not carry: whether to
    /// read it now. Off screen it is only forgotten, and read when a page shows it.
    public mutating func changed(_ part: CatchUpPart) -> Bool {
        guard connected, showing[part] != nil else {
            read.remove(part)
            return false
        }
        return true
    }
}

// MARK: What a client lets go (#175)

public enum ClientHolding {
    /// Of the archived agents held, the ones no screen can show any more: anything
    /// outside the open folder, unless it is the open chat. An Archived fold or a
    /// workflow's runs fetched them for a page, and that page has gone.
    public static func archivedToLetGo(_ agents: [Agent], folder: URL?, chat: UUID?) -> [UUID] {
        archivedToLetGo(agents, folders: folder.map { [$0] } ?? [], chat: chat)
    }

    /// The same, where several folders can show their archived sessions at once: the
    /// open folder and each open Archived fold of the Remote's sidebar (#226).
    public static func archivedToLetGo(_ agents: [Agent], folders: Set<URL>, chat: UUID?) -> [UUID] {
        let folders = Set(folders.map(Folder.standardize))
        return agents.filter { agent in
            agent.state == .archived && agent.id != chat && !folders.contains(Folder.standardize(agent.folderPath))
        }.map(\.id)
    }
}
