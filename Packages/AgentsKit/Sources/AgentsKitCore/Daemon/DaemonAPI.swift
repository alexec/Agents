import Foundation

/// What the app asks the daemon, and what the daemon tells every window.
///
/// The same JSON-RPC as the runtimes, over a Unix socket instead of a pipe.
public enum DaemonAPI {
    public enum Method {
        public static let runtimesList = "runtimes/list"
        public static let runtimesAccounts = "runtimes/accounts"
        public static let runtimeAuthenticate = "runtimes/authenticate"
        public static let runtimeLogOut = "runtimes/logout"
        public static let runtimeSetProvider = "runtimes/setProvider"
        public static let sessionsList = "sessions/list"
        public static let sessionsAdopt = "sessions/adopt"
        public static let sessionsDelete = "sessions/delete"
        public static let agentsFork = "agents/fork"
        public static let agentsList = "agents/list"
        /// Which chats are still queued to be picked back up after a restart. A
        /// window that connects part-way through the batch asks this rather than
        /// guessing from the notifications it was not there to hear.
        public static let agentsResuming = "agents/resuming"
        public static let agentsOptions = "agents/options"
        /// What a runtime last advertised for a folder, out of `OptionCache`.
        ///
        /// Not `agents/options`, and the difference is the whole reason this exists:
        /// that one *starts a session*, because it is answering "what may this agent I
        /// am about to run be allowed to do", and it must not be answered from memory.
        /// This one starts nothing and spawns no process, because it is answering
        /// "what shall I put in this menu" — and reading a workflow must not start a
        /// runtime. An empty answer is a real answer: the page then shows the value the
        /// file holds and says the choices are not known here yet, rather than offering
        /// an empty menu or inventing one.
        public static let optionsRemembered = "options/remembered"
        /// Let go of a draft made by `agents/options` that is not going to be started:
        /// its runtime is a process nobody will talk to. A draft already used, already
        /// ended or never known is not an error — gone is what was asked for (029).
        public static let agentsDiscardDraft = "agents/discardDraft"
        /// The mode last chosen for each runtime, held once on the Mac so that every
        /// window and every phone offers the same one first (029). The whole map: it is
        /// a handful of entries, and a client holding a copy needs all of it.
        public static let modesRemembered = "modes/remembered"
        /// Modes a window remembered before the daemon did. Fills gaps only: a runtime
        /// the daemon already has a mode for keeps it, so an old window's memory can
        /// never overwrite a choice made since on another device (029).
        public static let modesImport = "modes/import"
        /// Where the person is, told by every surface when it comes to the front, goes
        /// behind, changes conversation, or sees input after a quiet spell (021 FR-011).
        /// No timestamp is accepted: the daemon stamps arrival with its own clock.
        public static let presenceReport = "presence/report"
        /// What wants a person and where it is showing, asked once on connect, beside
        /// `permissions/pending` and for the same reason: a surface that was not
        /// listening is put right rather than left guessing.
        public static let attentionPending = "attention/pending"
        /// A remote saying which device it is, once, right after it connects. The
        /// server takes the identity from this and then owns it: every later request
        /// on the connection is that device's, and `presence/report` never carries it
        /// (021 T051). A stand-in until pairing verifies it against the device store —
        /// Phase 7 makes the bridge refuse an unpaired device at accept.
        public static let surfaceIdentify = "surface/identify"
        /// A connection saying it carries mail: that it hears `mailbox/post` and takes
        /// what it hears to the devices' mailboxes. Said once, by the bridge, right after
        /// it connects (025).
        ///
        /// It exists because nothing else can tell the daemon so. Every connection starts
        /// as the Mac and the bridge never says otherwise, and a withdrawal broadcast
        /// while no carrier is listening is lost for good — the need it withdraws is
        /// over, so there is no later decision to post it again. A withdrawal waits in
        /// `attention.json` until a connection has said this.
        public static let mailboxCarry = "mailbox/carry"
        /// The paired devices (021 US5).
        public static let devicesList = "devices/list"
        /// A device saying who it is and handing over its public key, once — which is
        /// all pairing is. Returns the record; the same id with the same key is the
        /// same device and gets its record back, and the same id with a **different**
        /// key is refused `notSupported` — a key never changes under an identity.
        public static let devicesAnnounce = "devices/announce"
        public static let agentsStart = "agents/start"
        public static let agentsPrompt = "agents/prompt"
        public static let agentsUnqueue = "agents/unqueue"
        /// Files under an agent's folders matching what follows an `@`, found on the
        /// Mac, so a phone can name them too (033).
        public static let filesMention = "files/mention"
        /// An agent's folder, file and changes, read by the daemon for a device that has
        /// no disk to read (034). The Mac's own panes read the disk themselves; these are
        /// the same readers, behind the same scope as `show_file`.
        public static let filesList = "files/list"
        public static let filesRead = "files/read"
        /// Hear `files/changed` for an agent's folders, on this connection only, until
        /// `files/unwatch` or the connection ends.
        public static let filesWatch = "files/watch"
        public static let filesUnwatch = "files/unwatch"
        public static let agentsStop = "agents/stop"
        public static let agentsArchive = "agents/archive"
        public static let agentsUnarchive = "agents/unarchive"
        /// Put a chat down to come back to, or pick it back up (040). The person's
        /// word about their own attention: no agent tool reaches either.
        public static let agentsPark = "agents/park"
        public static let agentsUnpark = "agents/unpark"
        public static let agentsTranscript = "agents/transcript"
        /// What an agent changed: the files its runtime reported editing, and — where its
        /// folder is in git — what git sees changed since it started (035). Built by the
        /// daemon because a window holds only a page of the transcript, and the list has
        /// to be all of it. Never polled; asked on the Changes pane's triggers.
        public static let changesList = "changes/list"
        /// One file from `changes/list`: its reported edits, and git's view of it.
        public static let changesFile = "changes/file"
        public static let agentsSetOption = "agents/setOption"
        /// Letting one agent carry on past the per-agent limit, or giving it a
        /// tighter ceiling of its own. The reader's call, never an agent's.
        public static let agentsSetCeiling = "agents/setCeiling"
        /// Not the app's to call. This is how the MCP server we hand to every agent
        /// gets what the agent passed it back to the agent's own record. Since 023
        /// the older door for the chips half of `agentsFinishTurn`.
        public static let agentsSuggestPrompts = "agents/suggestPrompts"
        /// Nor this one. Another of that MCP server's tools: the agent asking that a
        /// file be put in front of the user.
        public static let agentsShowFile = "agents/showFile"
        /// A window asking the daemon to write what the person typed on a live page
        /// (022). The daemon writes rather than the window, so that it knows the
        /// person did — that is what lets it tell the agent on its next turn.
        public static let artifactWrite = "artifact/write"
        // A project is a folder. These four are everything that can be done to one,
        // which is to say: notice it, and put it away.
        public static let projectsList = "projects/list"
        public static let projectsAdd = "projects/add"
        public static let projectsArchive = "projects/archive"
        public static let projectsUnarchive = "projects/unarchive"
        /// Clone a Git URL into the home folder and add it (027). Answers when the
        /// project exists, which for a big repository is minutes: the window shows the
        /// clone from `clone/changed`, not from waiting on this.
        public static let projectsClone = "projects/clone"
        /// The clones under way, for a window that connects in the middle of one.
        public static let projectsClones = "projects/clones"

        // Workflows: the prompts a project keeps that run themselves.
        public static let workflowsList = "workflows/list"
        public static let workflowsRun = "workflows/run"
        /// Put one away, or bring it back. The user's one way of overruling a workflow
        /// an agent wrote, which is why it is here and not only in the file system.
        public static let workflowsArchive = "workflows/archive"
        /// Change what a workflow is allowed to do, by writing its own file. The daemon
        /// is the writer for the reason it writes every other workflow change: a second
        /// window — or a phone — must not become a second author of the same file.
        public static let workflowsSettings = "workflows/settings"
        /// What the MCP helper relays when an agent calls the workflow tool.
        public static let agentsManageWorkflows = "agents/manageWorkflows"
        /// What the MCP helper relays when an agent calls `start_agent`,
        /// `stop_agent`, `archive_agent` or `list_my_agents` (028). The caller is the
        /// token, and the token alone decides the project and what it may touch.
        public static let agentsStartHelper = "agents/startHelper"
        public static let agentsStopHelper = "agents/stopHelper"
        public static let agentsArchiveHelper = "agents/archiveHelper"
        public static let agentsListHelpers = "agents/listHelpers"
        /// What the MCP helper relays for `lease_resource`, `release_resource` and
        /// `list_resources` (036). The caller is the token. `leases/lease` may stay open
        /// for up to `LeaseLimits.waitLimit` while the agent waits its turn.
        public static let leasesLease = "leases/lease"
        public static let leasesRelease = "leases/release"
        public static let leasesList = "leases/list"
        /// Every resource and who holds and waits for it, for a window that has just
        /// connected. Kept up to date after that by `leases/changed`.
        public static let leasesSnapshot = "leases/snapshot"
        /// The person ending whoever holds a resource, and taking one agent out of a
        /// line (036 US4). There is no method for the person to take one: only agents
        /// hold leases.
        public static let leasesEnd = "leases/end"
        public static let leasesRemoveWaiter = "leases/removeWaiter"
        /// A folder's repository and its worktrees, for the start bar's chooser and the
        /// project page (030). Asked for when something is shown, never polled.
        public static let worktreesList = "worktrees/list"
        /// What removing a worktree would lose, asked before it is removed.
        public static let worktreesCheck = "worktrees/check"
        /// Remove a worktree the app made, and its branch when that is safe.
        public static let worktreesRemove = "worktrees/remove"
        /// A GitHub project's pull requests, from the daemon's cache (038). Never runs
        /// `gh`; `null` when the project is not on GitHub.
        public static let pullRequestsList = "pullRequests/list"
        /// Refresh them now, unless the last attempt was under a minute ago (FR-008).
        public static let pullRequestsRefresh = "pullRequests/refresh"
        /// Start babysitting a stopped pull request again (FR-024).
        public static let pullRequestsResume = "pullRequests/resume"
        /// Check a pull request's branch out into a new worktree (FR-007).
        public static let pullRequestsCheckout = "pullRequests/checkout"
        /// Write the starter babysitting workflow (FR-026).
        public static let pullRequestsAddBabysitter = "pullRequests/addBabysitter"
        /// The helper relaying `push_pull_request` (038 R7).
        public static let agentsPushPullRequest = "agents/pushPullRequest"
        /// The helper relaying `reply_on_pull_request` (038 R7).
        public static let agentsReplyOnPullRequest = "agents/replyOnPullRequest"
        /// The agent saying how the work actually went, at the end of it. The app
        /// cannot know this any other way — a turn giving itself back says nothing
        /// about whether the work is finished. Since 023 the older door for the
        /// outcome half of `agentsFinishTurn`.
        public static let agentsReportOutcome = "agents/reportOutcome"
        /// Both of those at once (023): the one call that ends a turn, relayed by the
        /// helper when an agent calls `finish_turn`. The two above stay for the older
        /// names the helper still relays.
        public static let agentsFinishTurn = "agents/finishTurn"

        public static let permissionsPending = "permissions/pending"
        public static let elicitationsPending = "elicitations/pending"
        public static let elicitationsAnswer = "elicitations/answer"
        public static let permissionsAnswer = "permissions/answer"
        public static let ping = "daemon/ping"
        /// How busy a daemon is, so a server is updated only between turns and removed
        /// only after saying how many agents that stops (037).
        public static let daemonStatus = "daemon/status"
        /// Go now, rather than when idle. A server's daemon never leaves for being idle.
        public static let daemonQuit = "daemon/quit"
        /// The folders at a path, before there is any project or agent to scope it to:
        /// what the window browses to choose a server folder as a project (037).
        public static let filesBrowse = "files/browse"
        /// A file attached on one machine, for an agent on another (037): written into
        /// the agent's folder so it can read it, and the path handed back.
        public static let filesWrite = "files/write"

        // The user's own shell in an agent's folder. Deliberately not `terminal/*`,
        // which is 003's and belongs to the agent. Different owner, different
        // identifier space, different lifetime, and nothing crosses (FR-025).
        public static let shellAttach = "shell/attach"
        public static let shellDetach = "shell/detach"
        public static let shellInput = "shell/input"
        public static let shellResize = "shell/resize"
        public static let shellSignal = "shell/signal"
        public static let shellRestart = "shell/restart"

        // What the reader will allow to be spent. All three are window calls: none is
        // advertised to `AppService`, added to the MCP tool surface, or named in any
        // standing instruction given to an agent. A runaway that can raise its own
        // limit is not stopped.
        public static let costState = "cost/state"
        public static let costSetLimits = "cost/setLimits"

        /// Why the Mac is, or is not, being kept awake (024). A question about state,
        /// which is why it is `wake/state` while the notification below is
        /// `wake/changed` — the same pairing `cost` uses.
        ///
        /// Asked once on connecting: a window opened while a hold is already in place
        /// has heard no broadcast, and for a long turn would otherwise show nothing
        /// for half an hour.
        public static let wakeState = "wake/state"
    }

    public enum Notification {
        public static let agentChanged = "agent/changed"
        public static let agentEntry = "agent/entry"
        public static let agentPermission = "agent/permission"
        public static let runtimeChanged = "runtime/changed"
        public static let runtimeAccountChanged = "runtime/account"
        public static let agentUsage = "agent/usage"
        public static let agentPlan = "agent/plan"
        public static let agentElicitation = "agent/elicitation"
        public static let agentTerminalOutput = "agent/terminalOutput"
        /// An agent has asked that a file be shown. Unlike a suggested prompt, which
        /// goes on the agent's record, this is an event: a window that is not there to
        /// hear it has missed nothing, because the moment it was about has passed.
        public static let agentShowFile = "agent/showFile"
        /// A chat has joined or left the queue to be picked back up after a restart.
        /// Like `agent/showFile` this is an event and not a field on the record: the
        /// queue lives and dies with the daemon that made it.
        public static let agentResuming = "agent/resuming"
        /// What a runtime really offers, for a start form that was drawn from what it
        /// offered last time. Carries the failure instead when the runtime being
        /// started behind that form would not start.
        public static let draftOptions = "agents/draftOptions"
        /// The remembered modes changed: the whole map, as `modes/remembered` answers
        /// (029).
        public static let modesChanged = "modes/changed"
        /// The whole resolved fact for one need: where it should be showing and whether
        /// the person may be buzzed. Broadcast to every connection, not only to `to`,
        /// which is what lets the losers withdraw (021).
        public static let attentionChanged = "attention/changed"
        /// A device announced or was heard from: the whole record (021).
        public static let deviceChanged = "device/changed"
        /// Something for a device's mailbox: a `MailboxItem`, sealed. The daemon has no
        /// CloudKit and must not; the bridge hears this and posts it. Every connection
        /// hears it, and that is safe: a need id, a device id and ciphertext name
        /// nothing (021 FR-022).
        public static let mailboxPost = "mailbox/post"
        /// A project appeared, was archived, or its counts moved. Windows upsert by
        /// folder, the way they upsert agents by id.
        public static let projectChanged = "project/changed"
        /// A clone began, or ended either way (027). Every window hears it, because a
        /// clone belongs to the Mac and not to the window that asked for it.
        public static let cloneChanged = "clone/changed"

        /// A workflow appeared, changed, ran, was refused, or was archived. Carries the
        /// whole resolved summary rather than a delta, for the reason `project/changed`
        /// does: two windows cannot then disagree, and one that missed a notification
        /// is put right by the next rather than drifting.
        public static let workflowChanged = "workflow/changed"
        public static let workflowRemoved = "workflow/removed"
        /// A project's pull requests changed: a refresh, a fire, a refusal or a run
        /// ending (038). The whole `PullRequestList`, for the reason `workflow/changed`
        /// carries the whole summary. Mac windows only (FR-010).
        public static let pullRequestsChanged = "pullRequests/changed"
        /// The user's shell printed something. Raw bytes, base64. Not the agent's
        /// terminal, which is `agentTerminalOutput` above.
        public static let shellOutput = "shell/output"
        public static let shellStateChanged = "shell/stateChanged"
        /// Folders changed under something a connection is watching (034). Sent only to
        /// the connections that asked, never broadcast.
        public static let filesChanged = "files/changed"

        /// A limit changed, a turn's cost was banked, or the local day rolled over.
        /// Carries the whole resolved fact rather than a delta, for the reason
        /// `project/changed` does: two windows cannot then disagree, and one that
        /// missed a notification is put right by the next rather than drifting.
        public static let costChanged = "cost/changed"

        /// A lease was granted, extended, released, ended or expired, or a line moved:
        /// the whole `LeaseSnapshot`, which clients replace rather than merge (036).
        /// Also once a minute while anything is held, so "minutes left" stays true
        /// without each client counting against its own clock.
        public static let leasesChanged = "leases/changed"

        /// The Mac is now being kept awake, or is not. Sent only when the verdict
        /// moves — `reviseWakefulness` is reached on every streamed token, and a
        /// notification per token would be a flood (024 FR-015, FR-016).
        public static let wakeChanged = "wake/changed"
    }

    // MARK: Requests

    /// Which projects to list. Archived ones come back too by default, the same way
    /// archived agents do: the window decides what to draw, not us.
    public struct ProjectsListRequest: Codable, Sendable {
        public var includeArchived: Bool
        public init(includeArchived: Bool = true) { self.includeArchived = includeArchived }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? true
        }
    }

    /// One project, named by its folder, because the folder is the identity.
    public struct ProjectRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    /// A Git URL, as pasted (027).
    public struct CloneRequest: Codable, Sendable {
        public var url: String
        public init(url: String) { self.url = url }
    }

    /// One clone under way: what it is of, and where it is going.
    public struct CloneSummary: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var url: String
        /// Where the project will be. Nothing is there until the clone has finished.
        public var folder: URL
        public var startedAt: Date
        public init(id: UUID, url: String, folder: URL, startedAt: Date) {
            self.id = id
            self.url = url
            self.folder = folder
            self.startedAt = startedAt
        }
    }

    public struct CloneNotification: Codable, Sendable {
        public var clone: CloneSummary
        /// Ended, whichever way. Success is the `project/changed` that follows; failure
        /// is the error the caller was answered with.
        public var finished: Bool
        public init(clone: CloneSummary, finished: Bool) {
            self.clone = clone
            self.finished = finished
        }
    }

    /// A project, plus the parts only the daemon can know.
    ///
    /// The name and the counts are worked out here rather than in the window, so that
    /// two windows cannot disagree and so a sidebar row can say a project needs you
    /// without that window having looked at the project's agents at all.
    public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
        public var project: Project
        /// Disambiguated against every project in the same response.
        public var name: String
        /// Whether the directory is there, stamped when this was made.
        public var exists: Bool
        /// The newest activity of any agent in it, or `addedAt` when it has none.
        public var lastActivityAt: Date
        /// How many agents are in each group — computed **without** knowing whether an
        /// agent asked to be looked at, because the daemon has no window and stores
        /// nothing for one. Complete for a surface that cannot show a file (the phone);
        /// on the Mac, `AgentsModel.counts(in:)` completes it from the window's own
        /// grouping, and the row reads that instead (019, FR-009).
        public var counts: [AgentGroup: Int]
        /// What every agent in this folder has spent over its whole life, per currency.
        /// **Empty when nothing has been spent**, which is how a view knows to show no
        /// figure rather than a zero. Like `counts`, recomputed on every call and never
        /// stored.
        public var costToDate: [String: Decimal]
        /// How many agents here finished a turn the runtime would not price. **Zero in
        /// the ordinary case; non-zero means `costToDate` is a floor rather than the
        /// whole.** Like `counts`, recomputed on every call and never stored.
        public var unmeasuredAgents: Int
        /// Which machine the project is on, stamped by the window that heard of it and
        /// never sent (037). Not in `CodingKeys`.
        public var host: HostID = .mac

        public var id: URL { project.folder }
        public var folder: URL { project.folder }
        public var key: ProjectKey { ProjectKey(host: host, folder: project.folder) }

        enum CodingKeys: String, CodingKey {
            case project, name, exists, lastActivityAt, counts, costToDate, unmeasuredAgents
        }

        /// Whether anything in this project wants the user.
        /// From the daemon's counts, so with the same blind spot: an agent waiting to be
        /// looked at is not in here. The phone's dot; the Mac asks its own window.
        public var needsInput: Bool { (counts[.needsAttention] ?? 0) > 0 }

        public init(project: Project, name: String, exists: Bool, lastActivityAt: Date,
                    counts: [AgentGroup: Int],
                    costToDate: [String: Decimal] = [:],
                    unmeasuredAgents: Int = 0) {
            self.project = project
            self.name = name
            self.exists = exists
            self.lastActivityAt = lastActivityAt
            self.counts = counts
            self.costToDate = costToDate
            self.unmeasuredAgents = unmeasuredAgents
        }

        /// An older daemon sends neither new field. Both default rather than fail, so
        /// the response degrades to silence — no figure at all — never to a wrong
        /// number.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project = try c.decode(Project.self, forKey: .project)
            name = try c.decode(String.self, forKey: .name)
            exists = try c.decode(Bool.self, forKey: .exists)
            lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
            // By the group's name, dropping any this build has never heard of. A plain
            // `[AgentGroup: Int]` decode throws on an unknown key, which would take the
            // whole project list down on a phone older than the group (039's `blocked`, 040's `parked`).
            counts = [:]
            for (name, count) in try c.decode([String: Int].self, forKey: .counts) {
                if let group = AgentGroup(rawValue: name) { counts[group] = count }
            }
            costToDate = try c.decodeIfPresent([String: Decimal].self, forKey: .costToDate) ?? [:]
            unmeasuredAgents = try c.decodeIfPresent(Int.self, forKey: .unmeasuredAgents) ?? 0
        }
    }

    public struct OptionsRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        /// The servers chosen so far. The draft session this makes is the one the
        /// start that follows uses, and a server named after it was made would never
        /// reach the runtime, so they are sent now and checked again at the start.
        public var mcpServers: [MCPServer]

        public init(runtimeID: String, cwd: URL, mcpServers: [MCPServer] = []) {
            self.runtimeID = runtimeID
            self.cwd = cwd
            self.mcpServers = mcpServers
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            cwd = try c.decode(URL.self, forKey: .cwd)
            mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        }
    }

    /// A session exists before the user has chosen anything, because the options are
    /// advertised by `session/new`. The draft is that session, waiting to be used by
    /// the start that follows, so the user sees one dialog and the runtime is started
    /// once.
    public struct OptionsResponse: Codable, Sendable {
        public var draftID: UUID
        public var options: [ConfigOption]
        public var commands: [SlashCommand]

        public init(draftID: UUID, options: [ConfigOption], commands: [SlashCommand] = []) {
            self.draftID = draftID
            self.options = options
            self.commands = commands
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            draftID = try c.decode(UUID.self, forKey: .draftID)
            options = try c.decodeIfPresent([ConfigOption].self, forKey: .options) ?? []
            commands = try c.decodeIfPresent([SlashCommand].self, forKey: .commands) ?? []
        }
    }

    /// The correction to a start form that was answered from memory.
    ///
    /// A window holding this draft replaces what it is showing, keeping what the user
    /// has chosen where the runtime still offers it. A window holding a different one
    /// ignores this.
    public struct DraftOptionsNotification: Codable, Sendable {
        public var draftID: UUID
        public var options: [ConfigOption]
        public var commands: [SlashCommand]
        /// Why there will be no runtime, when there will be none.
        public var failure: String?

        public init(draftID: UUID, options: [ConfigOption] = [], commands: [SlashCommand] = [],
                    failure: String? = nil) {
            self.draftID = draftID
            self.options = options
            self.commands = commands
            self.failure = failure
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            draftID = try c.decode(UUID.self, forKey: .draftID)
            options = try c.decodeIfPresent([ConfigOption].self, forKey: .options) ?? []
            commands = try c.decodeIfPresent([SlashCommand].self, forKey: .commands) ?? []
            failure = try c.decodeIfPresent(String.self, forKey: .failure)
        }
    }

    public struct StartRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public var prompt: String
        /// What was attached to the prompt: pictures, references to files, the
        /// contents of one. Empty is the ordinary case.
        public var attachments: [Attachment]
        public var startOptions: StartOptions
        public var draftID: UUID?
        public var additionalDirectories: [URL]
        public var mcpServers: [MCPServer]
        /// Where in the project to work, when it is not the project folder itself
        /// (030). `cwd` stays the project folder: the worktree is made, or found, from it.
        public var worktree: WorktreeChoice?
        /// Minted once per send by the caller and reused on every retry of that send.
        /// A second start with the same one answers with the first start's agent
        /// rather than making another, which is what lets a phone whose reply was lost
        /// on the way back try again without starting the work twice. `nil` from
        /// callers that do not retry.
        public var requestID: UUID?

        public init(runtimeID: String, cwd: URL, prompt: String,
                    attachments: [Attachment] = [],
                    startOptions: StartOptions = .none, draftID: UUID? = nil,
                    additionalDirectories: [URL] = [], mcpServers: [MCPServer] = [],
                    worktree: WorktreeChoice? = nil, requestID: UUID? = nil) {
            self.worktree = worktree
            self.runtimeID = runtimeID
            self.cwd = cwd
            self.prompt = prompt
            self.attachments = attachments
            self.startOptions = startOptions
            self.draftID = draftID
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
            self.requestID = requestID
        }

        /// Fields with a sensible default may be left out. A caller that wants an
        /// agent started with whatever the runtime offers should not have to send an
        /// empty object to say so.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            cwd = try c.decode(URL.self, forKey: .cwd)
            prompt = try c.decode(String.self, forKey: .prompt)
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            startOptions = try c.decodeIfPresent(StartOptions.self, forKey: .startOptions) ?? .none
            draftID = try c.decodeIfPresent(UUID.self, forKey: .draftID)
            additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
            mcpServers = try c.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
            worktree = try c.decodeIfPresent(WorktreeChoice.self, forKey: .worktree)
            requestID = try c.decodeIfPresent(UUID.self, forKey: .requestID)
        }

        /// What goes to the runtime: the words, then whatever was attached.
        public var blocks: [ContentBlock] {
            [.text(prompt)] + attachments.map(\.block)
        }
    }

    public struct AgentRequest: Codable, Sendable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }

    public struct ChangesListRequest: Codable, Sendable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }

    public struct ChangesFileRequest: Codable, Sendable {
        public var agentID: UUID
        public var path: String
        /// Also the whole current file, with removed lines in place. Needs git.
        public var whole: Bool
        public init(agentID: UUID, path: String, whole: Bool = false) {
            self.agentID = agentID
            self.path = path
            self.whole = whole
        }
    }

    public struct PromptRequest: Codable, Sendable {
        public var agentID: UUID
        public var text: String
        public var attachments: [Attachment]
        /// Whose prompt this is. The daemon sends itself one of these after a turn
        /// that ended without saying how it went, and only the person's clears what
        /// the agent last said about the turn before.
        public var from: PromptOrigin
        /// Made by the window once per send, and sent again unchanged if the first try's
        /// reply was lost with the connection. A daemon that has seen it already does
        /// nothing and answers as it did (037, FR-020). Nil from the phone and from any
        /// older window, which is today's behaviour.
        public var sendID: UUID?

        public init(agentID: UUID, text: String, attachments: [Attachment] = [],
                    from: PromptOrigin = .person, sendID: UUID? = nil) {
            self.agentID = agentID
            self.text = text
            self.attachments = attachments
            self.from = from
            self.sendID = sendID
        }

        /// An older app sends only the text, so attachments are optional on the way in.
        /// A remote built before 014 sends no origin, and its prompts are the person's,
        /// which is correct.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            text = try c.decode(String.self, forKey: .text)
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            from = try c.decodeIfPresent(PromptOrigin.self, forKey: .from) ?? .person
            sendID = try c.decodeIfPresent(UUID.self, forKey: .sendID)
        }

        public var blocks: [ContentBlock] {
            [.text(text)] + attachments.map(\.block)
        }
    }

    /// Take one back off the queue before its turn comes.
    public struct FileMentionRequest: Codable, Sendable {
        public var agentID: UUID
        public var term: String
        public init(agentID: UUID, term: String) {
            self.agentID = agentID
            self.term = term
        }
    }

    /// A file on the Mac, named by an `@`. The path is the Mac's, which is where the
    /// agent reads it, so a phone attaches it as a reference and never by value.
    public struct FileMentionDTO: Codable, Sendable, Hashable {
        public var path: String
        public var relativePath: String
        public init(path: String, relativePath: String) {
            self.path = path
            self.relativePath = relativePath
        }

        public var mention: FileMention {
            FileMention(url: URL(filePath: path), relativePath: relativePath)
        }
    }

    public struct UnqueueRequest: Codable, Sendable {
        public var agentID: UUID
        public var promptID: UUID
        public init(agentID: UUID, promptID: UUID) {
            self.agentID = agentID
            self.promptID = promptID
        }
    }

    /// What the MCP helper sends when an agent calls the older suggestion tool.
    ///
    /// The token, not an agent id: the helper is a process the runtime started, and
    /// anything on this Mac can reach the daemon's socket. A token the daemon minted
    /// for one session is the only thing that says which agent this is, and it is
    /// refused the moment that session is over.
    /// What the MCP helper sends when an agent says how the work went.
    ///
    /// The token does the same work it does for a suggestion: the helper is a process
    /// the runtime started, anything on this Mac can reach the socket, and a token the
    /// daemon minted for one session is the only thing that says which agent this is.
    /// The outcome is the wire spelling, checked at the daemon rather than here — a
    /// word this build does not know must be refused, never rounded.
    public struct ReportOutcomeRequest: Codable, Sendable {
        public var token: String
        public var outcome: String
        public var message: String
        /// Only with `blocked` (039): the agents it waits on, as it wrote them — ids or
        /// titles, resolved by the daemon. Optional, so an older helper still relays.
        public var waitingOn: [String]?
        public var checkAgainInMinutes: Int?

        public init(token: String, outcome: String, message: String,
                    waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil) {
            self.token = token
            self.outcome = outcome
            self.message = message
            self.waitingOn = waitingOn
            self.checkAgainInMinutes = checkAgainInMinutes
        }
    }

    public struct SuggestPromptsRequest: Codable, Sendable {
        public var token: String
        public var prompts: [SuggestedPrompt]

        public init(token: String, prompts: [SuggestedPrompt]) {
            self.token = token
            self.prompts = prompts
        }
    }

    /// What the MCP helper sends when an agent ends its turn with the one call (023).
    ///
    /// The token does the work it does for a report. The outcome is the wire
    /// spelling, checked at the daemon and never rounded. The prompts have already
    /// been cleaned by the service — trimmed, cut to four, empties dropped — and may
    /// be empty, which means no chips: the call is the whole account of the turn.
    public struct FinishTurnRequest: Codable, Sendable {
        public var token: String
        public var outcome: String
        public var message: String
        public var prompts: [SuggestedPrompt]
        /// What the conversation is about now, in the agent's words. Required by the
        /// tool, optional here: an agent's MCP helper is started from whatever binary
        /// was on disk when its session began, so one begun before this field existed
        /// relays a call without it, and that call still lands — with the title left
        /// as it was.
        public var title: String?
        /// Only with `blocked` (039). See `ReportOutcomeRequest`.
        public var waitingOn: [String]?
        public var checkAgainInMinutes: Int?

        public init(token: String, outcome: String, message: String,
                    prompts: [SuggestedPrompt], title: String? = nil,
                    waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil) {
            self.token = token
            self.outcome = outcome
            self.message = message
            self.prompts = prompts
            self.title = title
            self.waitingOn = waitingOn
            self.checkAgainInMinutes = checkAgainInMinutes
        }
    }

    /// What the MCP helper sends when an agent calls the show-file tool. The token
    /// does the same work it does for a suggestion, and the path is checked against
    /// that agent's folders before any window hears about it.
    /// The whole document, as the page now has it, for the daemon to put on disk.
    /// Whole rather than a patch: the page is the one thing that knows how the
    /// passages join back up, and the daemon diffs the two versions itself to learn
    /// which passages the person changed.
    public struct ArtifactWriteRequest: Codable, Sendable {
        public var agentID: UUID
        public var path: String
        public var text: String

        public init(agentID: UUID, path: String, text: String) {
            self.agentID = agentID
            self.path = path
            self.text = text
        }
    }

    // MARK: Files, for a device (034)

    public struct FilesListRequest: Codable, Sendable {
        public var agentID: UUID
        public var folder: String

        public init(agentID: UUID, folder: String) {
            self.agentID = agentID
            self.folder = folder
        }
    }

    public struct FilesReadRequest: Codable, Sendable {
        public var agentID: UUID
        public var path: String
        /// What the caller already holds. When the file still has it, the answer is
        /// `unchanged` and nothing is carried again.
        public var knownStamp: FileStamp?

        public init(agentID: UUID, path: String, knownStamp: FileStamp? = nil) {
            self.agentID = agentID
            self.path = path
            self.knownStamp = knownStamp
        }
    }

    /// `files/watch` and `files/unwatch`.
    public struct FilesWatchRequest: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var folder: String

        public init(agentID: UUID, folder: String) {
            self.agentID = agentID
            self.folder = folder
        }
    }

    public struct FilesChangedNotification: Codable, Sendable, Equatable {
        public var agentID: UUID
        /// Directories, as FSEvents names them: re-list one being shown, re-read a file
        /// whose folder is here.
        public var folders: [String]

        public init(agentID: UUID, folders: [String]) {
            self.agentID = agentID
            self.folders = folders
        }
    }

    public struct ShowFileRequest: Codable, Sendable {
        public var token: String
        public var file: ShownFile

        public init(token: String, file: ShownFile) {
            self.token = token
            self.file = file
        }
    }

    /// One agent, one file, to every window.
    public struct ShowFileNotification: Codable, Sendable {
        public var agentID: UUID
        public var file: ShownFile

        public init(agentID: UUID, file: ShownFile) {
            self.agentID = agentID
            self.file = file
        }
    }

    /// One chat, joining or leaving the pick-up queue, to every window.
    public struct ResumingNotification: Codable, Sendable {
        public var agentID: UUID
        /// True when the chat has joined the queue to be picked back up, false when it
        /// has left it — whether because its prompt went, because it could not be
        /// sent, or because the person stopped it first.
        public var isResuming: Bool

        public init(agentID: UUID, isResuming: Bool) {
            self.agentID = agentID
            self.isResuming = isResuming
        }
    }

    /// Everything still queued to be picked back up, for a window that connected late.
    public struct ResumingResponse: Codable, Sendable {
        public var agentIDs: [UUID]

        public init(agentIDs: [UUID]) {
            self.agentIDs = agentIDs
        }
    }

    public struct TranscriptRequest: Codable, Sendable {
        public var agentID: UUID
        public var before: Int?
        public var limit: Int

        public init(agentID: UUID, before: Int? = nil, limit: Int = 200) {
            self.agentID = agentID
            self.before = before
            self.limit = limit
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            before = try c.decodeIfPresent(Int.self, forKey: .before)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 200
        }
    }

    // MARK: Cost

    /// The whole truth about money, as it stands. Carried by `cost/changed` and
    /// returned by `cost/state` and `cost/setLimits`, so a caller sees the result
    /// rather than assuming it.
    public struct CostState: Codable, Sendable, Hashable {
        /// What the reader has set.
        public var limits: CostLimits
        /// What this local day has cost, per currency. Empty until something is
        /// spent, so a view shows nothing rather than a zero.
        public var today: [String: Decimal]
        /// Which local day `today` is about, `yyyy-MM-dd`.
        ///
        /// The only signal a window should use to notice a rollover. A window must
        /// never consult its own clock: it may be in a different time zone from the
        /// daemon's, and the daemon's is the one the limit uses.
        public var day: String

        public init(limits: CostLimits, today: [String: Decimal], day: String) {
            self.limits = limits
            self.today = today
            self.day = day
        }

        /// Derived here rather than sent, so there is one place the rule lives.
        public var dayLimitReached: Bool { limits.isDayLimitReached(spentToday: today) }
        public var dayHeadroom: Decimal? { limits.dailyHeadroom(against: today) }

        /// Close enough to be worth saying before it arrives, on the app's existing
        /// threshold for a nearly full context rather than a second number.
        public var dayIsCloseToFull: Bool {
            guard let daily = limits.daily, daily.amount > 0 else { return false }
            let spent = today[daily.currency] ?? 0
            return (spent / daily.amount) >= Decimal(Usage.closeToFull)
        }
    }

    /// Setting or clearing either limit. The only way either changes.
    ///
    /// Each field is a double optional and the distinction is the whole point:
    /// **absent** means "leave it as it is", **present and null** means "no limit".
    /// A limit of zero is a limit; clearing one requires an explicit null.
    public struct SetLimitsRequest: Codable, Sendable {
        public var perAgent: Cost??
        public var daily: Cost??

        public init(perAgent: Cost?? = nil, daily: Cost?? = nil) {
            self.perAgent = perAgent
            self.daily = daily
        }

        enum CodingKeys: String, CodingKey { case perAgent, daily }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            perAgent = c.contains(.perAgent)
                ? .some(try c.decodeIfPresent(Cost.self, forKey: .perAgent)) : .none
            daily = c.contains(.daily)
                ? .some(try c.decodeIfPresent(Cost.self, forKey: .daily)) : .none
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if case .some(let value) = perAgent {
                if let value { try c.encode(value, forKey: .perAgent) }
                else { try c.encodeNil(forKey: .perAgent) }
            }
            if case .some(let value) = daily {
                if let value { try c.encode(value, forKey: .daily) }
                else { try c.encodeNil(forKey: .daily) }
            }
        }
    }

    /// One agent's own ceiling. Null means "no ceiling of its own": the app-wide
    /// per-agent limit applies again.
    public struct SetCeilingRequest: Codable, Sendable {
        public var agentID: UUID
        public var ceiling: Cost?
        public init(agentID: UUID, ceiling: Cost?) {
            self.agentID = agentID
            self.ceiling = ceiling
        }
    }

    public struct SetOptionRequest: Codable, Sendable {
        public var agentID: UUID
        public var optionID: String
        public var value: JSONValue
        public init(agentID: UUID, optionID: String, value: JSONValue) {
            self.agentID = agentID
            self.optionID = optionID
            self.value = value
        }
    }

    public struct AnswerRequest: Codable, Sendable {
        public var permissionID: UUID
        public var optionID: String
        /// Made by the window once per send, and sent again unchanged if the first try's
        /// reply was lost with the connection. A daemon that has seen it already does
        /// nothing and answers as it did (037, FR-020). Nil from the phone and from any
        /// older window, which is today's behaviour.
        public var sendID: UUID?
        public init(permissionID: UUID, optionID: String, sendID: UUID? = nil) {
            self.permissionID = permissionID
            self.optionID = optionID
            self.sendID = sendID
        }
    }

    public struct ListRequest: Codable, Sendable {
        public var includeArchived: Bool
        /// Whether an archived agent comes with its slash commands. The Mac's archived
        /// chat still has a prompt bar and wants them; the phone's has none. They were
        /// nine tenths of a 5.4 MB `agents/list` on 2026-09-25 (seventy commands each,
        /// 220 archived agents). Unarchiving sends the whole agent again.
        public var archivedCommands: Bool
        /// Only archived agents. With `folder`, one project's Archived section, which
        /// the phone asks for when it is opened rather than with everything else:
        /// archived agents outnumber the live ones many times over.
        public var archivedOnly: Bool
        /// Only agents in this project.
        public var folder: URL?
        /// Only the agents this workflow started, for its Recent runs.
        public var startedByWorkflow: String?
        /// At most this many, newest activity first.
        public var limit: Int?

        public init(includeArchived: Bool = true, archivedCommands: Bool = true,
                    archivedOnly: Bool = false, folder: URL? = nil,
                    startedByWorkflow: String? = nil, limit: Int? = nil) {
            self.includeArchived = includeArchived
            self.archivedCommands = archivedCommands
            self.archivedOnly = archivedOnly
            self.folder = folder
            self.startedByWorkflow = startedByWorkflow
            self.limit = limit
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? true
            archivedCommands = try c.decodeIfPresent(Bool.self, forKey: .archivedCommands) ?? true
            archivedOnly = try c.decodeIfPresent(Bool.self, forKey: .archivedOnly) ?? false
            folder = try c.decodeIfPresent(URL.self, forKey: .folder)
            startedByWorkflow = try c.decodeIfPresent(String.self, forKey: .startedByWorkflow)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        }
    }

    // MARK: Notifications

    public struct EntryNotification: Codable, Sendable {
        public var agentID: UUID
        public var entry: TranscriptEntry
        public init(agentID: UUID, entry: TranscriptEntry) {
            self.agentID = agentID
            self.entry = entry
        }
    }

    public struct PermissionNotification: Codable, Sendable {
        public var agentID: UUID
        /// Nil when the question has been answered and is no longer waiting.
        public var request: PermissionRequest?
        public init(agentID: UUID, request: PermissionRequest?) {
            self.agentID = agentID
            self.request = request
        }
    }

    public struct RuntimeRequest: Codable, Sendable {
        public var runtimeID: String
        public init(runtimeID: String) { self.runtimeID = runtimeID }
    }

    public struct AuthenticateRequest: Codable, Sendable {
        public var runtimeID: String
        public var methodID: String
        public init(runtimeID: String, methodID: String) {
            self.runtimeID = runtimeID
            self.methodID = methodID
        }
    }

    public struct SetProviderRequest: Codable, Sendable {
        public var runtimeID: String
        public var providerID: String
        public init(runtimeID: String, providerID: String) {
            self.runtimeID = runtimeID
            self.providerID = providerID
        }
    }

    public struct SessionsListRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public init(runtimeID: String, cwd: URL) {
            self.runtimeID = runtimeID
            self.cwd = cwd
        }
    }

    public struct AdoptRequest: Codable, Sendable {
        public var runtimeID: String
        public var sessionID: String
        public var cwd: URL
        public init(runtimeID: String, sessionID: String, cwd: URL) {
            self.runtimeID = runtimeID
            self.sessionID = sessionID
            self.cwd = cwd
        }
    }

    /// The only call in this API that cannot be undone, so it will not happen without
    /// being told twice.
    public struct DeleteSessionRequest: Codable, Sendable {
        public var runtimeID: String
        public var sessionID: String
        public var confirmed: Bool

        public init(runtimeID: String, sessionID: String, confirmed: Bool) {
            self.runtimeID = runtimeID
            self.sessionID = sessionID
            self.confirmed = confirmed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeID = try c.decode(String.self, forKey: .runtimeID)
            sessionID = try c.decode(String.self, forKey: .sessionID)
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        }
    }

    public struct ElicitationNotification: Codable, Sendable {
        public var agentID: UUID
        public var requestID: UUID
        /// Nil when the form has been answered or withdrawn.
        public var request: ElicitationRequest?

        public init(agentID: UUID, requestID: UUID, request: ElicitationRequest?) {
            self.agentID = agentID
            self.requestID = requestID
            self.request = request
        }
    }

    public struct TerminalOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var terminalID: String
        public var chunk: String

        public init(agentID: UUID, terminalID: String, chunk: String) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.chunk = chunk
        }
    }

    public struct AnswerElicitationRequest: Codable, Sendable {
        public var requestID: UUID
        public var action: Action
        public var content: [String: JSONValue]
        /// Made by the window once per send, and sent again unchanged if the first try's
        /// reply was lost with the connection. A daemon that has seen it already does
        /// nothing and answers as it did (037, FR-020). Nil from the phone and from any
        /// older window, which is today's behaviour.
        public var sendID: UUID?

        public enum Action: String, Codable, Sendable {
            case accept, decline, cancel
        }

        public init(requestID: UUID, action: Action, content: [String: JSONValue] = [:],
                    sendID: UUID? = nil) {
            self.requestID = requestID
            self.action = action
            self.content = content
            self.sendID = sendID
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try c.decode(UUID.self, forKey: .requestID)
            action = try c.decodeIfPresent(Action.self, forKey: .action) ?? .cancel
            content = try c.decodeIfPresent([String: JSONValue].self, forKey: .content) ?? [:]
            sendID = try c.decodeIfPresent(UUID.self, forKey: .sendID)
        }
    }

    public struct UsageNotification: Codable, Sendable {
        public var agentID: UUID
        public var usage: Usage
        public init(agentID: UUID, usage: Usage) {
            self.agentID = agentID
            self.usage = usage
        }
    }

    // MARK: Errors the app shows

    // MARK: Shells

    public struct ShellAttachRequest: Codable, Sendable {
        public var agentID: UUID
        public var rows: Int
        public var cols: Int

        public init(agentID: UUID, rows: Int = 24, cols: Int = 80) {
            self.agentID = agentID
            self.rows = rows
            self.cols = cols
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 24
            cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 80
        }
    }

    /// What a window gets on attach: the state, and the bytes to replay.
    ///
    /// Bytes, not a screen. The daemon parses nothing; the window feeds these to its
    /// own emulator and arrives at the screen it would have had if it had been watching
    /// all along (plan decision 2).
    public struct ShellAttachResponse: Codable, Sendable {
        public var state: ShellState
        public var scrollback: Data
        public var dropped: Int
        public var startedAt: Date

        public init(state: ShellState, scrollback: Data, dropped: Int, startedAt: Date) {
            self.state = state
            self.scrollback = scrollback
            self.dropped = dropped
            self.startedAt = startedAt
        }
    }

    public struct ShellInputRequest: Codable, Sendable {
        public var agentID: UUID
        /// What the user typed, as bytes. Never a `String`: a keystroke is not always a
        /// character, and an escape sequence is not text.
        public var bytes: Data
        /// The typist's screen, when it says (034). The shell takes the size of whoever
        /// typed last, and the daemon is the one place that knows who that was. Older
        /// clients send neither and nothing is resized.
        public var rows: Int?
        public var cols: Int?

        public init(agentID: UUID, bytes: Data, rows: Int? = nil, cols: Int? = nil) {
            self.agentID = agentID
            self.bytes = bytes
            self.rows = rows
            self.cols = cols
        }
    }

    public struct ShellResizeRequest: Codable, Sendable {
        public var agentID: UUID
        public var rows: Int
        public var cols: Int

        public init(agentID: UUID, rows: Int, cols: Int) {
            self.agentID = agentID
            self.rows = rows
            self.cols = cols
        }
    }

    public struct ShellSignalRequest: Codable, Sendable {
        public var agentID: UUID
        public var signal: Int32

        public init(agentID: UUID, signal: Int32) {
            self.agentID = agentID
            self.signal = signal
        }
    }

    public struct ShellOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var bytes: Data

        public init(agentID: UUID, bytes: Data) {
            self.agentID = agentID
            self.bytes = bytes
        }

        /// Read straight off the value that came in, without the round trip.
        ///
        /// `JSONValue.decode` encodes the value back to JSON and decodes it again.
        /// That is a fair price for a thing that arrives when an agent changes, and
        /// the wrong one for the thing that arrives whenever a shell prints a line,
        /// on the main actor, with a window waiting. This is the only notification on
        /// that path, so it is the only one that reads its own two fields.
        ///
        /// The names and the encodings are the ones `Codable` uses above — a UUID as
        /// its string, `Data` as base64 — and `ShellOutputTests` holds the two to each
        /// other so this cannot quietly drift from the type it is reading.
        public init?(params: JSONValue) {
            guard let agentID = params["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let encoded = params["bytes"]?.stringValue,
                  let bytes = Data(base64Encoded: encoded) else { return nil }
            self.agentID = agentID
            self.bytes = bytes
        }
    }

    public struct ShellStateNotification: Codable, Sendable {
        public var agentID: UUID
        public var state: ShellState

        public init(agentID: UUID, state: ShellState) {
            self.agentID = agentID
            self.state = state
        }
    }

    public enum Failure {
        public static let runtimeNotFound = -32001
        public static let runtimeWillNotStart = -32002
        public static let sessionGone = -32003
        public static let folderGone = -32004
        public static let noSuchAgent = -32005
        /// No longer raised: a prompt sent to a working agent waits its turn rather
        /// than being refused. The number is kept so an older window still reads it.
        public static let alreadyRunning = -32006
        /// The user's login shell is missing, or the agent's folder has gone (FR-024).
        public static let shellWillNotStart = -32010
        /// A restart was asked for on a shell that is still running.
        public static let shellNotLive = -32011
        /// The runtime is installed and will not work until somebody signs in. Its own
        /// auth methods come back in the error's data, including the command Copilot
        /// names for the terminal.
        public static let needsSignIn = -32007
        /// The runtime answered the handshake with a version we do not speak.
        public static let wrongProtocolVersion = -32008
        /// The runtime never said it could do the thing that was asked of it.
        public static let notSupported = -32009
        /// A destructive call that nobody confirmed.
        public static let notConfirmed = -32010
        /// A folder that is not a project, on archive or unarchive.
        public static let noSuchProject = -32012
        /// Archiving a project while one of its agents is still working. Deliberately
        /// unlike archiving an agent, which stops the one it was given: cancelling
        /// several turns because somebody tidied their sidebar is not a small thing,
        /// so this refuses and names them.
        public static let projectHasLiveAgents = -32013
        /// A workflow id that is not one of this project's.
        public static let noSuchWorkflow = -32014
        /// Front matter that could not be read, on a write. Refused before anything is
        /// written: a file that could never fire is worth telling the agent about while
        /// it can still fix it.
        public static let workflowUnreadable = -32015
        /// A path outside the calling agent's own workflow folder.
        public static let notInWorkflowFolder = -32016
        /// A new workflow in a project that already has all the live ones it may have.
        public static let workflowLimitReached = -32017
        /// A new agent asked for while the day's spending limit is reached. Raised by
        /// `agents/start` only: a prompt to an agent that already exists succeeds and
        /// waits on that agent's queue, because losing what somebody typed because a
        /// budget was reached would be the worst possible reading of "control cost".
        public static let dayLimitReached = -32018
        /// A question that was already settled — by another device, by the Mac, or by
        /// the agent giving up on it. Raised instead of `noSuchAgent`, which is what a
        /// second answer used to be told and which reads as though the agent had gone.
        ///
        /// 013's tasks proposed -32018 for this. Feature 010 took that number first,
        /// so it is -32019 here and `noSuchDevice` is -32020. The file already carries
        /// one collision at -32010; it does not need a second.
        public static let alreadyAnswered = -32019
        /// A device id that is not in the store — never paired, or revoked since.
        public static let noSuchDevice = -32020
        /// A need id that is not outstanding — met, or never existed (021).
        public static let noSuchNeed = -32021
        /// A daemon asked to quit while a turn is in flight (037).
        public static let busy = -32040
        /// `presence/report` from a connection with no identity: not a window and not a
        /// device the bridge opened on behalf of. The surface is taken from the
        /// connection and never from the parameters, so there is nothing to report as.
        public static let notASurface = -32022
        /// A new agent asked for while the per-agent limit is zero. Every agent would
        /// be at it before its first word, and a new one has no queue to hold on.
        public static let agentLimitReached = -32023
        /// Text that is not an HTTPS or SSH Git URL, or has no name to give a folder (027).
        public static let notACloneURL = -32024
        /// The folder a clone would become is already there and is not a checkout of
        /// that repository. The message names it; nothing in it is touched.
        public static let folderInTheWay = -32025
        /// Git could not clone it. The message says why in a sentence.
        public static let cloneFailed = -32026
        /// An agent asked to do something to an agent that is not its to touch, or
        /// past its project's limit, or was itself started by an agent (028). The
        /// message is the sentence the agent is shown.
        public static let notYours = -32027
        /// Making a worktree failed, or it could not be made at all (030). The message
        /// is git's own words, and no agent was started.
        public static let worktreeFailed = -32028
        /// The worktree an agent works in is not there any more.
        public static let worktreeMissing = -32029
        /// The folder named is not a worktree of this project's repository, or not one
        /// the app made, where only those will do.
        public static let notAWorktree = -32030
        /// An agent is still working in the worktree to be removed.
        public static let worktreeInUse = -32031
        /// The folder or file asked for is not there, or not any more (034).
        public static let fileGone = -32032
        /// It is there and cannot be opened (034).
        public static let fileNotReadable = -32033
        /// `changes/file` for a path that is not in the agent's list of changes.
        public static let notChanged = -32034
        /// A lease action on something that is not there to act on: an end on a
        /// resource nobody holds, an empty name, a waiter not in that line (036).
        public static let leaseRefused = -32035
        // 038's, from -32040 so that lanes being built alongside it can take the
        // numbers straight after 034's without colliding.
        /// Checking a pull request out: its worktree folder is already there.
        public static let worktreeExists = -32040
        /// Checking a pull request out: its branch is checked out somewhere else, named.
        public static let branchCheckedOut = -32041
        /// Checking a pull request out: git could not fetch its branch.
        public static let fetchFailed = -32042
        /// The project already has a babysitting workflow; the data is its id.
        public static let babysitterExists = -32043
        /// A pull request number that is not in the project's list.
        public static let noSuchPullRequest = -32044
    }

    // MARK: Workflows

    public struct WorkflowsListRequest: Codable, Sendable {
        /// Nil lists every project's.
        public var folder: URL?
        public init(folder: URL? = nil) { self.folder = folder }
    }

    public struct WorkflowRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public init(folder: URL, workflowID: String) {
            self.folder = folder
            self.workflowID = workflowID
        }
    }

    public struct WorkflowRemovedNotification: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public init(folder: URL, workflowID: String) {
            self.folder = folder
            self.workflowID = workflowID
        }
    }

    /// Put a workflow away, or bring it back.
    ///
    /// The counterweight to an agent writing one without asking. Archiving is not
    /// deleting: the file stays in the repository, where it can be read and reviewed
    /// like any other file, and the app simply stops acting on it.
    public struct WorkflowArchiveRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public var archived: Bool
        public init(folder: URL, workflowID: String, archived: Bool) {
            self.folder = folder
            self.workflowID = workflowID
            self.archived = archived
        }
    }

    /// Change what a workflow is allowed to do.
    ///
    /// The whole settings, not a delta: a key the caller leaves `nil` is removed from
    /// the file. The page always sends what it is showing, so there is no third state
    /// between "set this" and "leave this alone" to get wrong.
    public struct WorkflowSettingsRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public var settings: WorkflowSettings
        public init(folder: URL, workflowID: String, settings: WorkflowSettings) {
            self.folder = folder
            self.workflowID = workflowID
            self.settings = settings
        }
    }

    /// What this runtime last advertised for this folder. Starts nothing.
    public struct DiscardDraftRequest: Codable, Sendable {
        public var draftID: UUID
        public init(draftID: UUID) { self.draftID = draftID }
    }

    /// Keyed by runtime id. What `modes/remembered` answers and `modes/changed` carries.
    public typealias RememberedModes = [String: JSONValue]

    public struct ModesImportRequest: Codable, Sendable {
        public var modes: RememberedModes
        public init(modes: RememberedModes) { self.modes = modes }
    }

    public struct RememberedOptionsRequest: Codable, Sendable {
        public var runtimeID: String
        public var cwd: URL
        public init(runtimeID: String, cwd: URL) {
            self.runtimeID = runtimeID
            self.cwd = cwd
        }
    }

    /// What an agent passes to the workflow tool.
    public struct ManageWorkflowsRequest: Codable, Sendable {
        public enum Action: String, Codable, Sendable {
            case list, read, write, remove
        }

        public var token: String
        public var action: Action
        public var workflowID: String?
        public var content: String?

        public init(token: String, action: Action, workflowID: String? = nil,
                    content: String? = nil) {
            self.token = token
            self.action = action
            self.workflowID = workflowID
            self.content = content
        }
    }

    // MARK: Agents started by agents (028)

    /// What an agent passes to `start_agent`. There is no folder: the new agent
    /// always starts in the caller's own project, which the token decides.
    public struct StartHelperRequest: Codable, Sendable {
        public var token: String
        public var prompt: String
        public var runtime: String?
        public var model: String?
        public var permissionMode: String?
        /// `"new"`, or the name of a worktree of the caller's repository, as the agent
        /// wrote it (030). Resolved by the daemon, which alone can say what exists.
        public var worktree: String?

        public init(token: String, prompt: String, runtime: String? = nil,
                    model: String? = nil, permissionMode: String? = nil,
                    worktree: String? = nil) {
            self.worktree = worktree
            self.token = token
            self.prompt = prompt
            self.runtime = runtime
            self.model = model
            self.permissionMode = permissionMode
        }
    }

    /// What an agent passes to `stop_agent` or `archive_agent`. The id is a string
    /// so one that is not a UUID is refused in words rather than failing to decode.
    public struct HelperRequest: Codable, Sendable {
        public var token: String
        public var agentID: String

        public init(token: String, agentID: String) {
            self.token = token
            self.agentID = agentID
        }
    }

    /// What an agent passes to `list_my_agents`: nothing but who it is.
    public struct ListHelpersRequest: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    // MARK: Pull requests (038)

    /// `pullRequests/list`, `pullRequests/refresh` and `pullRequests/addBabysitter`.
    public struct PullRequestsRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    /// `agents/pushPullRequest`: nothing but who is asking. The daemon takes the pull
    /// request, the branch and the repository from the caller's run (R7).
    public struct PushPullRequestRequest: Codable, Sendable {
        public var token: String
        public init(token: String) { self.token = token }
    }

    /// `agents/replyOnPullRequest`.
    public struct ReplyOnPullRequestRequest: Codable, Sendable {
        public var token: String
        public var body: String
        /// A review comment to answer in its thread; nil comments on the pull request.
        public var inReplyTo: Int?

        public init(token: String, body: String, inReplyTo: Int? = nil) {
            self.token = token
            self.body = body
            self.inReplyTo = inReplyTo
        }
    }

    /// `pullRequests/resume` and `pullRequests/checkout`.
    public struct PullRequestRequest: Codable, Sendable {
        public var folder: URL
        public var number: Int
        public init(folder: URL, number: Int) {
            self.folder = folder
            self.number = number
        }
    }

    // MARK: Leases (036)

    /// `lease_resource`: take, extend, or wait in line.
    public struct LeaseRequest: Codable, Sendable {
        public var token: String
        public var name: String
        public var minutes: Int?
        /// Nil is true: wait in line.
        public var wait: Bool?

        public init(token: String, name: String, minutes: Int? = nil, wait: Bool? = nil) {
            self.token = token
            self.name = name
            self.minutes = minutes
            self.wait = wait
        }
    }

    /// `release_resource`: give back, or leave the line.
    public struct LeaseNameRequest: Codable, Sendable {
        public var token: String
        public var name: String

        public init(token: String, name: String) {
            self.token = token
            self.name = name
        }
    }

    /// `list_resources`.
    public struct LeaseTokenRequest: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    /// The person ending whoever holds `name`.
    public struct PersonEndRequest: Codable, Sendable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    /// The person taking one agent out of the line for `name`. The id is a string, so
    /// a malformed one is refused in words rather than failing to decode.
    public struct PersonRemoveRequest: Codable, Sendable {
        public var name: String
        public var agentID: String

        public init(name: String, agentID: String) {
            self.name = name
            self.agentID = agentID
        }
    }

    /// Every resource worth drawing, and the daemon's time when it was read.
    ///
    /// The time is the daemon's so a client counts "minutes left" from the same clock
    /// the lease runs by, not from its own.
    public struct LeaseSnapshot: Codable, Sendable, Hashable {
        public var resources: [ResourceState]
        public var at: Date

        public init(resources: [ResourceState], at: Date) {
            self.resources = resources
            self.at = at
        }

        public static let empty = LeaseSnapshot(resources: [], at: .distantPast)
    }

    /// One resource as the page draws it. A waiter's call id stays in the daemon; what
    /// crosses the wire is only whether its call is open.
    public struct ResourceState: Codable, Sendable, Hashable, Identifiable {
        public var name: ResourceName
        public var kind: ResourceKind
        public var displayName: String
        /// Leased, but no longer found on the Mac (spec, Edge Cases).
        public var isGone: Bool
        public var lease: Lease?
        public var line: [LineMember]
        public var endingSoon: Bool

        public var id: ResourceName { name }

        public init(name: ResourceName, kind: ResourceKind, displayName: String, isGone: Bool = false,
                    lease: Lease? = nil, line: [LineMember] = [], endingSoon: Bool = false) {
            self.name = name
            self.kind = kind
            self.displayName = displayName
            self.isGone = isGone
            self.lease = lease
            self.line = line
            self.endingSoon = endingSoon
        }
    }

    public struct LineMember: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var askedAt: Date
        /// Whether its call is still open ("waiting in its call"), or it will be
        /// started when its turn comes ("will be started").
        public var isCallOpen: Bool

        public init(agentID: UUID, askedAt: Date, isCallOpen: Bool) {
            self.agentID = agentID
            self.askedAt = askedAt
            self.isCallOpen = isCallOpen
        }
    }

    // MARK: Worktrees (030)

    /// `worktrees/list`: everything about a folder's repository the chooser needs.
    public struct WorktreesListRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    public struct WorktreesListResponse: Codable, Hashable, Sendable {
        /// False hides the chooser altogether.
        public var isRepository: Bool
        /// False when the repository has nothing to base a worktree on.
        public var canMakeNew: Bool
        /// Why a new worktree cannot be made, said where the choice is.
        public var whyNot: String?
        public var worktrees: [WorktreeSummary]
        /// Branches a new worktree can be made on: none checked out anywhere, most
        /// recently committed to first.
        public var branches: [BranchSummary]

        public init(isRepository: Bool, canMakeNew: Bool = false, whyNot: String? = nil,
                    worktrees: [WorktreeSummary] = [], branches: [BranchSummary] = []) {
            self.isRepository = isRepository
            self.canMakeNew = canMakeNew
            self.whyNot = whyNot
            self.worktrees = worktrees
            self.branches = branches
        }

        /// The branch the project folder is on, "detached" when it is on none. Nil
        /// when it is in no repository, or not listed yet.
        public var projectFolderBranch: String? {
            worktrees.first(where: \.isProjectFolder).map { $0.branch ?? "detached" }
        }

        /// What the chooser says under "Project folder": its branch first, since the
        /// project folder is not always on main.
        public var projectFolderDescription: String {
            let alongside = "Work alongside anything else here"
            guard let branch = projectFolderBranch else { return alongside }
            return "\(branch) · \(alongside.lowercased())"
        }

        public static let notARepository = WorktreesListResponse(isRepository: false)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isRepository = try c.decodeIfPresent(Bool.self, forKey: .isRepository) ?? false
            canMakeNew = try c.decodeIfPresent(Bool.self, forKey: .canMakeNew) ?? false
            whyNot = try c.decodeIfPresent(String.self, forKey: .whyNot)
            worktrees = try c.decodeIfPresent([WorktreeSummary].self, forKey: .worktrees) ?? []
            branches = try c.decodeIfPresent([BranchSummary].self, forKey: .branches) ?? []
        }
    }

    /// A branch a new worktree can be made on.
    public struct BranchSummary: Codable, Hashable, Sendable, Identifiable {
        /// What git checks out: the local name, even for one only a remote has.
        public var name: String
        /// The remote it comes from, when there is no local branch of that name yet.
        public var remote: String?

        public var id: String { name }

        public init(name: String, remote: String? = nil) {
            self.name = name
            self.remote = remote
        }
    }

    /// One worktree of a repository, as git lists it and as the app knows it.
    public struct WorktreeSummary: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var root: URL
        /// Nil when its HEAD is detached.
        public var branch: String?
        /// The project folder itself, listed so the chooser can leave it out.
        public var isProjectFolder: Bool
        /// False when its folder is gone.
        public var exists: Bool
        public var madeByApp: Bool
        /// Agents not archived whose folder is in it.
        public var agents: [UUID]

        public var id: URL { root }

        public init(name: String, root: URL, branch: String?, isProjectFolder: Bool,
                    exists: Bool, madeByApp: Bool, agents: [UUID]) {
            self.name = name
            self.root = root
            self.branch = branch
            self.isProjectFolder = isProjectFolder
            self.exists = exists
            self.madeByApp = madeByApp
            self.agents = agents
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            root = try c.decode(URL.self, forKey: .root)
            branch = try c.decodeIfPresent(String.self, forKey: .branch)
            isProjectFolder = try c.decodeIfPresent(Bool.self, forKey: .isProjectFolder) ?? false
            exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? true
            madeByApp = try c.decodeIfPresent(Bool.self, forKey: .madeByApp) ?? false
            agents = try c.decodeIfPresent([UUID].self, forKey: .agents) ?? []
        }
    }

    /// `worktrees/check` and `worktrees/remove`.
    public struct WorktreeRemovalRequest: Codable, Sendable {
        public var project: URL
        public var root: URL
        /// The person has seen what would be lost and said yes.
        public var confirmed: Bool

        public init(project: URL, root: URL, confirmed: Bool = false) {
            self.project = project
            self.root = root
            self.confirmed = confirmed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project = try c.decode(URL.self, forKey: .project)
            root = try c.decode(URL.self, forKey: .root)
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        }
    }

    /// What removing a worktree would lose, said before anything is removed.
    public struct RemovalCheck: Codable, Hashable, Sendable {
        /// Agents still working in it. Any at all and it is not removed.
        public var blockedBy: [UUID]
        /// Files changed and not committed.
        public var uncommitted: Int
        /// Commits on its branch that are not in the branch it came from.
        public var unmerged: Bool

        public var losesWork: Bool { uncommitted > 0 || unmerged }

        public init(blockedBy: [UUID] = [], uncommitted: Int = 0, unmerged: Bool = false) {
            self.blockedBy = blockedBy
            self.uncommitted = uncommitted
            self.unmerged = unmerged
        }
    }

    public struct WorktreeRemoved: Codable, Hashable, Sendable {
        public var removedBranch: Bool
        public init(removedBranch: Bool) { self.removedBranch = removedBranch }
    }

    // MARK: Attention (021)

    /// `surface/identify`: which device this connection is.
    public struct SurfaceIdentification: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var kind: Device.Kind

        public init(id: UUID, name: String, kind: Device.Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    /// `devices/announce`: this device, and the public half of its key.
    public struct DeviceAnnouncement: Codable, Sendable {
        public var id: UUID
        public var publicKey: Data
        public var name: String
        public var kind: Device.Kind

        public init(id: UUID, publicKey: Data, name: String, kind: Device.Kind) {
            self.id = id
            self.publicKey = publicKey
            self.name = name
            self.kind = kind
        }
    }

    /// `device/changed`: the whole record.
    public struct DeviceNotification: Codable, Sendable, Hashable {
        public var id: UUID
        public var device: Device

        public init(_ device: Device) {
            self.id = device.id
            self.device = device
        }
    }

    /// `presence/report`. Three small fields, sent on a change and never on a timer.
    /// **No timestamp**: a contract term, not an omission — the daemon's clock stamps it.
    public struct PresenceReport: Codable, Sendable {
        public var watching: UUID?
        public var active: Bool
        /// Whether this surface may show notifications; omitted means unchanged.
        public var mayNotify: Bool?

        public init(watching: UUID?, active: Bool, mayNotify: Bool? = nil) {
            self.watching = watching
            self.active = active
            self.mayNotify = mayNotify
        }
    }

    /// One need and where it is showing, as `attention/pending` lists them.
    public struct AttentionDelivery: Codable, Sendable, Hashable {
        public var needID: NeedID
        public var to: Surface?

        public init(needID: NeedID, to: Surface?) {
            self.needID = needID
            self.to = to
        }
    }

    /// `attention/pending`: what is outstanding, and where each is showing.
    public struct AttentionPending: Codable, Sendable {
        public var needs: [Need]
        public var deliveries: [AttentionDelivery]

        public init(needs: [Need], deliveries: [AttentionDelivery]) {
            self.needs = needs
            self.deliveries = deliveries
        }
    }

    /// `attention/changed`: the whole resolved fact for one need. `need` nil means met,
    /// and every surface withdraws; `to` nil means nowhere reachable, or watched.
    public struct AttentionNotification: Codable, Sendable, Hashable {
        public var needID: NeedID
        public var need: Need?
        public var to: Surface?
        public var alert: Bool

        public init(needID: NeedID, need: Need?, to: Surface?, alert: Bool) {
            self.needID = needID
            self.need = need
            self.to = to
            self.alert = alert
        }
    }
}

public extension DaemonAPI {
    /// `daemon/status` (037).
    struct DaemonStatus: Codable, Hashable, Sendable {
        /// Agents starting, running or waiting on the person: an update waits for zero.
        public var turnsInFlight: Int
        /// Agents holding a runtime: what removing the server would stop.
        public var agentsLive: Int

        public init(turnsInFlight: Int, agentsLive: Int) {
            self.turnsInFlight = turnsInFlight
            self.agentsLive = agentsLive
        }
    }

    /// `daemon/quit` (037).
    struct QuitRequest: Codable, Hashable, Sendable {
        /// Stop every live agent first. Without it, a turn in flight refuses the quit.
        public var stopAgents: Bool

        public init(stopAgents: Bool) { self.stopAgents = stopAgents }
    }
}

public extension DaemonAPI {
    /// `files/browse` (037). An absolute path, or one starting `~`, which is the
    /// daemon's own home. Nil is the home.
    struct FilesBrowseRequest: Codable, Hashable, Sendable {
        public var path: String?
        public init(path: String? = nil) { self.path = path }
    }
}

public extension DaemonAPI {
    /// `files/write` (037). `data` travels as base64 in the JSON.
    struct FilesWriteRequest: Codable, Hashable, Sendable {
        public var agentID: UUID
        public var name: String
        public var data: Data
        public init(agentID: UUID, name: String, data: Data) {
            self.agentID = agentID
            self.name = name
            self.data = data
        }
    }

    struct FilesWriteResponse: Codable, Hashable, Sendable {
        public var path: String
        public init(path: String) { self.path = path }
    }

    /// The most `files/write` takes, and the most the window sends.
    static let attachmentLimit = 25 * 1024 * 1024
}
