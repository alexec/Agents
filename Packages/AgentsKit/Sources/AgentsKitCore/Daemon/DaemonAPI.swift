import Foundation

/// What the app asks the daemon, and what the daemon tells every window.
///
/// The same JSON-RPC as the runtimes, over a Unix socket instead of a pipe.
public enum DaemonAPI {
    public enum Method {
        public static let runtimesList = "runtimes/list"
        /// Install a missing runtime on this Mac (048). `RuntimeRequest` → `RuntimeStatus`,
        /// answered at once; progress and the result follow on `runtime/changed`. The
        /// Mac's daemon only, and only for the app itself: it runs a vendor's script.
        public static let runtimesInstall = "runtimes/install"
        public static let runtimesAccounts = "runtimes/accounts"
        public static let runtimeAuthenticate = "runtimes/authenticate"
        public static let runtimeLogOut = "runtimes/logout"
        public static let runtimeSetProvider = "runtimes/setProvider"
        /// Takes a `SetProviderRequest`: the provider named is the one turned off.
        public static let runtimeDisableProvider = "runtimes/disableProvider"
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
        /// Where the person is, told by every surface when it comes to the front, goes
        /// behind, changes conversation, or sees input after a quiet spell (021 FR-011).
        /// No timestamp is accepted: the daemon stamps arrival with its own clock.
        public static let presenceReport = "presence/report"
        /// What wants a person and where it is showing, asked once on connect, beside
        /// `permissions/pending` and for the same reason: a surface that was not
        /// listening is put right rather than left guessing.
        public static let attentionPending = "attention/pending"
        /// What a client catching up after a connection needs before anything else, in
        /// one answer (#175): the live projects, the first page of live agents, and what is
        /// waiting on a person. A host from before it answers method-not-found, and the
        /// client asks for each part on its own.
        public static let clientCatchUp = "client/catchUp"
        /// A remote saying which device it is, once, right after it connects. The
        /// server takes the identity from this and then owns it: every later request
        /// on the connection is that device's, and `presence/report` never carries it
        /// (021 T051). A stand-in until pairing verifies it against the device store —
        /// Phase 7 makes the bridge refuse an unpaired device at accept.
        public static let surfaceIdentify = "surface/identify"
        /// The bridge saying the connection it just opened carries a device, not itself
        /// (security review, Phase 3). From then on the connection has the device's
        /// rights, never a window's, and there is no way back. With an id the device is
        /// fixed; without one, the first id the device names is the only one it may use.
        /// Said by the bridge, before a single line of the device's is carried.
        public static let connectionBindDevice = "connection/bindDevice"
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
        /// The Mac's window forgetting a paired device (046, R11): its record goes, and the
        /// bridge stops carrying anything for it through the relay. Refused `notAllowed` on
        /// a device's own connection.
        public static let devicesForget = "devices/forget"
        /// The Mac's window asking for a pairing code to show as a QR code: the Mac's key,
        /// a one-time secret and this Mac's name, good for five minutes or one device,
        /// whichever comes first (security review, Phase 3). Asking again replaces it.
        public static let devicesStartPairing = "devices/startPairing"
        /// The window's pairing sheet closing before anybody scanned it.
        public static let devicesStopPairing = "devices/stopPairing"
        /// The bridge asking for the code's secret, so its listener can take it. A window's
        /// connection only, which the bridge's is; a device's never.
        public static let pairingCurrent = "pairing/current"
        /// The bridge handing the daemon the public half of the Mac's relay key, so a device
        /// announcing on the direct link is given it (046, R4). Said once per connection,
        /// right after `mailbox/carry`.
        public static let relayRegister = "relay/register"
        public static let agentsStart = "agents/start"
        public static let agentsSetLabels = "agents/setLabels"
        public static let agentsLabelVocabulary = "agents/labelVocabulary"
        public static let agentsPrompt = "agents/prompt"
        public static let agentsUnqueue = "agents/unqueue"
        /// Stop one shell or task an agent left running in the background, and nothing
        /// else it is doing (057).
        public static let agentsStopBackground = "agents/stopBackground"
        /// A queued prompt sent into the running turn rather than after it, where the
        /// runtime advertises steering. Takes an `UnqueueRequest`: the same two ids.
        public static let agentsSendNow = "agents/sendNow"
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
        /// Delete one archived agent: its conversation, record and clean worktree (#398).
        /// The person's alone; each client asks first.
        public static let agentsDelete = "agents/delete"
        /// How long archived agents are kept, and how much space they take (051).
        public static let retentionState = "retention/state"
        /// Change that, confirming first when the change deletes agents at once (051).
        public static let retentionSet = "retention/set"
        /// Put a chat down to come back to, or pick it back up (040). The person's
        /// word about their own attention: no agent tool reaches either.
        public static let agentsPark = "agents/park"
        public static let agentsUnpark = "agents/unpark"
        /// The ways on from an agent whose folder has gone (#119): a successor in the
        /// project folder that reads this session, or the worktree made again from its
        /// branch. The person's, from the error and the chat header.
        public static let agentsContinueInProject = "agents/continueInProject"
        public static let agentsRecreateWorktree = "agents/recreateWorktree"
        /// Mark a finished chat unread, or read, from its row (#70). The person's word
        /// about their own attention, as parking is: no agent tool reaches it.
        public static let agentsSetUnread = "agents/setUnread"
        /// Start a finished session's runtime ahead of a prompt, because a window opened it
        /// or somebody is typing in its box (#183). Answers at once; the start goes on
        /// behind, and a runtime nobody prompts goes as the warm pool decides.
        public static let agentsPrewarm = "agents/prewarm"
        public static let agentsTranscript = "agents/transcript"
        public static let agentsTouchedPaths = "agents/touchedPaths"
        /// The conversation's finished turns, each as its ask and its last block.
        public static let agentsTurns = "agents/turns"
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
        /// Not the app's to call. Since 023 the older door for the chips half of
        /// `agentsFinishTurn`; the helper stopped relaying it when the tool names were
        /// retired (09-29). Kept for a helper binary from before then, which is after the
        /// #58 cut-off (051).
        public static let agentsSuggestPrompts = "agents/suggestPrompts"
        /// Nor this one. Another of that MCP server's tools: the agent asking that a
        /// file be put in front of the user.
        public static let agentsShowFile = "agents/showFile"
        /// The helper relaying `ask_form`: the agent asking the person a question and
        /// waiting for the answer. The daemon holds the form as an elicitation.
        public static let agentsAskForm = "agents/askForm"
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
        /// Why this host has a chat project or not (#229), for a New Chat that found no
        /// summary marked `isChat` in the list.
        public static let projectsChatState = "projects/chatState"
        /// The person setting a project's two helper limits (#64), from any window or
        /// paired client (#111). Not in `ConnectionRole.agentMethods`, so no agent and no
        /// workflow can raise a ceiling over agents.
        public static let projectsSetHelperLimits = "projects/setHelperLimits"
        /// The person pinning a project to the top of the sidebar, or unpinning it, from
        /// any client. Not in `ConnectionRole.agentMethods`: the sidebar is the person's.
        public static let projectsSetPinned = "projects/setPinned"
        /// A project's disk space lines (#195), kept in its `.agents/project.json`.
        public static let projectsSetDiskSpace = "projects/setDiskSpace"
        /// A change to an app-owned file in `.agents` made outside the app (#502): what the
        /// file was and is, line by line; and the person's Keep (the change is used from
        /// now on) or Undo (the approved copy is written back). Not in
        /// `ConnectionRole.agentMethods`: an agent cannot approve its own change.
        public static let projectsReadGuardedChange = "projects/readGuardedChange"
        public static let projectsKeepGuardedChange = "projects/keepGuardedChange"
        public static let projectsUndoGuardedChange = "projects/undoGuardedChange"
        /// Every volume that is low on space, for the window's strip (#195).
        public static let diskState = "disk/state"
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
        /// Turn one on or off, keeping its place on the list (#100).
        public static let workflowsEnable = "workflows/enable"
        /// Approve a workflow file as the person was shown it (security review).
        public static let workflowsApprove = "workflows/approve"
        /// Deny one on this host only (#391): it does not run here, and the file is not
        /// touched, so other hosts still see it waiting. Takes a `WorkflowApproveRequest`.
        public static let workflowsDeny = "workflows/deny"
        /// A project's plugins and which are waiting for the person's OK (security review, S2).
        public static let pluginsList = "plugins/list"
        public static let pluginsApprove = "plugins/approve"
        /// Change what a workflow is allowed to do, by writing its own file. The daemon
        /// is the writer for the reason it writes every other workflow change: a second
        /// window — or a phone — must not become a second author of the same file.
        public static let workflowsSettings = "workflows/settings"
        /// Clear a server's event trigger's "events may have been missed" (#383).
        public static let workflowsClearMCPMissed = "workflows/mcpTrigger/clearMissed"
        /// What the MCP helper relays when an agent calls the workflow tool.
        public static let agentsManageWorkflows = "agents/manageWorkflows"
        /// What the MCP helper relays when an agent calls `start_agent`,
        /// `stop_agent`, `park_agent` or `list_my_agents` (028). The
        /// caller is the token, and the token alone decides the project and what it
        /// may touch.
        public static let agentsStartHelper = "agents/startHelper"
        public static let agentsStopHelper = "agents/stopHelper"
        public static let agentsParkHelper = "agents/parkHelper"
        /// `archive_agent` (#120).
        public static let agentsArchiveHelper = "agents/archiveHelper"
        public static let agentsListHelpers = "agents/listHelpers"
        /// `list_sessions` and `read_session` (065): the caller's project, read only.
        public static let agentsListSessions = "agents/listSessions"
        public static let agentsReadSession = "agents/readSession"
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
        /// The person adding or changing a declared resource, and taking one away
        /// (#116). A person's, never an agent's: an agent reads declarations in
        /// `list_resources` and does not write them.
        public static let resourcesDeclare = "resources/declare"
        public static let resourcesRemove = "resources/remove"
        /// A folder's repository and its worktrees, for the start bar's chooser and the
        /// project page (030). Asked for when something is shown, never polled.
        public static let worktreesList = "worktrees/list"
        /// What removing a worktree would lose, asked before it is removed.
        public static let worktreesCheck = "worktrees/check"
        /// Remove a worktree the app made, and its branch when that is safe.
        public static let worktreesRemove = "worktrees/remove"
        /// The person moving an agent into a worktree or back to its project folder, or
        /// taking back a move still waiting for the turn to end (053).
        public static let agentsMove = "agents/move"
        /// What an MCP helper begun before 2026-09-29 relays when its agent calls
        /// `enter_worktree` or `exit_worktree` (053). The caller is the token. Kept for
        /// those sessions: a move is now asked for on `finish_turn`.
        public static let agentsMoveSelf = "agents/moveSelf"
        /// The agent saying how the work actually went, at the end of it. The app
        /// cannot know this any other way — a turn giving itself back says nothing
        /// about whether the work is finished. Since 023 the older door for the
        /// outcome half of `agentsFinishTurn`, kept like `agentsSuggestPrompts` above
        /// for a helper from before 09-29 (#58).
        public static let agentsReportOutcome = "agents/reportOutcome"
        /// Both of those at once (023): the one call that ends a turn, relayed by the
        /// helper when an agent calls `finish_turn`. The two above stay for the older
        /// names the helper still relays.
        public static let agentsFinishTurn = "agents/finishTurn"
        /// `park_agent` or `archive_agent` with no id (#481): the agent asking to be put
        /// away once its own turn ends.
        public static let agentsAfterTurn = "agents/afterTurn"
        /// `set_session_labels` (#481): the agent's own labels on its own session.
        public static let agentsSetOwnLabels = "agents/setOwnLabels"
        /// `wait_for_event` naming agents or only a time (#481): a block, as `blocked`
        /// on `finish_turn` was, which ends the turn.
        public static let agentsWaitOn = "agents/waitOn"

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
        /// Which runtimes this window could lend a credential for, and whether this server
        /// takes lends at all. Names only; sent on every connect to a server (043).
        public static let credentialsOffer = "credentials/offer"
        /// That this window relays a runtime's sign-in from the Mac (047): where the relay's
        /// socket was forwarded to on the server, the certificate it answers with, and the
        /// stand-in sign-in the runtime is given. Nothing secret; sent on every connect.
        public static let relayOffer = "relay/offer"
        /// A credential for one runtime, for this connection only, sent only after the
        /// daemon answered `credentialWanted`. Held in memory and dropped when the
        /// connection closes; a daemon without `--serve` refuses it (043, D5).
        public static let credentialsLend = "credentials/lend"
        /// A window lends this Mac's own file sign-in for one runtime (049: OpenCode's).
        public static let credentialsLendSignIn = "credentials/lendSignIn"
        /// The folders at a path, before there is any project or agent to scope it to:
        /// what the window browses to choose a server folder as a project (037).
        public static let filesBrowse = "files/browse"
        /// A file attached on one machine, for an agent on another (037): written into
        /// the agent's folder so it can read it, and the path handed back.
        public static let filesWrite = "files/write"
        /// A file put into a project's drop box (#231), from any window, phone or page:
        /// written into `<project>/.agents/dropbox/<folder>/`, where the project's watch
        /// hears it arrive like any other.
        public static let dropboxPut = "dropbox/put"

        // The user's own shell in an agent's folder. Deliberately not `terminal/*`,
        // which is 003's and belongs to the agent. Different owner, different
        // identifier space, different lifetime, and nothing crosses (FR-025).
        public static let shellAttach = "shell/attach"
        public static let shellDetach = "shell/detach"
        public static let shellInput = "shell/input"
        public static let shellResize = "shell/resize"
        public static let shellSignal = "shell/signal"
        public static let shellRestart = "shell/restart"
        /// The shells an agent has, by number, so a window that opens finds the tabs it
        /// left rather than only the first (055).
        public static let shellList = "shell/list"
        /// End one shell for good and forget it: the tab was closed (055).
        public static let shellClose = "shell/close"
        /// Start a new shell for an agent, numbered by the daemon, so two screens
        /// opening a tab at once never pick the same number (#401).
        public static let shellOpen = "shell/open"

        // What the reader will allow to be spent. All three are window calls: none is
        // advertised to `AppService`, added to the MCP tool surface, or named in any
        // standing instruction given to an agent. A runaway that can raise its own
        // limit is not stopped.
        public static let costState = "cost/state"
        public static let costSetLimits = "cost/setLimits"
        /// Cursor and Grok permission mode (061). Control only.
        public static let clientPermissionsState = "clientPermissions/state"
        public static let clientPermissionsSet = "clientPermissions/set"
        /// What agents call the person, and their pronouns (#121). Kept as given; a
        /// blank name follows the account of the machine that says it.
        public static let personState = "person/state"
        public static let personSet = "person/set"
        /// Each runtime's command sandbox default (064). Reading is also the phone's, for
        /// "Use runtime default (Off)"; setting is the Mac's alone.
        public static let sandboxState = "sandbox/state"
        public static let sandboxSet = "sandbox/set"
        /// One agent's override (nil clears it), and the card's recovery (064).
        public static let agentsSetSandbox = "agents/setSandbox"
        public static let agentsAnswerSandbox = "agents/answerSandbox"
        /// Every runtime's state (065, US4), and the person saying one is back.
        public static let runtimesAllowances = "runtimes/allowances"
        public static let runtimesMarkAvailable = "runtimes/markAvailable"
        /// What another daemon learned about a shared allowance (052, R6): the Mac's
        /// window carries it between the Mac and each server. The name is 052's, kept so
        /// an older server still hears it: renaming it buys nothing (#58).
        public static let poolApplyAllowances = "pool/applyAllowances"

        /// Why the Mac is, or is not, being kept awake (024). A question about state,
        /// which is why it is `wake/state` while the notification below is
        /// `wake/changed` — the same pairing `cost` uses.
        ///
        /// Asked once on connecting: a window opened while a hold is already in place
        /// has heard no broadcast, and for a long turn would otherwise show nothing
        /// for half an hour.
        public static let wakeState = "wake/state"
        /// What this host keeps that could not be read in this run (#205): files set aside
        /// or held, said so a person sees why paired devices or projects "disappeared".
        public static let storeNotes = "store/notes"
        /// The switch and the grace. The window's, like retention: a phone does not set it.
        public static let wakeSettings = "wake/settings"
        public static let wakeSet = "wake/set"
    }

    public enum Notification {
        public static let agentChanged = "agent/changed"
        public static let agentEntry = "agent/entry"
        public static let agentPermission = "agent/permission"
        /// A server's runtime refused the credential it was started with, or found none
        /// (043, FR-016). `CredentialRefused`.
        public static let credentialRefused = "credentials/refused"
        /// A runtime's status moved: installed, installing, or an install failed (048).
        /// Carries the `RuntimeStatus`; a window may just ask `runtimes/list` again.
        public static let runtimeChanged = "runtime/changed"
        public static let runtimeAccountChanged = "runtime/account"
        /// An agent's runtime refused it for want of a sign-in, somewhere the window did
        /// not ask: a turn, a queued prompt, a pick-up after a restart. `SignInNeeded`.
        /// The window answers it with the sign-in sheet rather than an error.
        public static let signInNeeded = "runtime/signInNeeded"
        public static let agentUsage = "agent/usage"
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
        /// A pairing code began, was used or ran out. Carries nothing: whoever needs the
        /// secret asks `pairing/current` on a connection allowed to.
        public static let pairingChanged = "pairing/changed"
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
        /// A write nobody was waiting on was refused: a line of a chat, an agent's record,
        /// the day's spend (#88). Carries `WriteFailure`; a window shows its message.
        /// Sent once in a while per cause, not once per write.
        public static let writeFailed = "storage/writeFailed"

        /// A workflow appeared, changed, ran, was refused, or was archived. Carries the
        /// whole resolved summary rather than a delta, for the reason `project/changed`
        /// does: two windows cannot then disagree, and one that missed a notification
        /// is put right by the next rather than drifting.
        public static let workflowChanged = "workflow/changed"
        /// A project's plugins, sent whole, when one is found waiting or is approved.
        public static let pluginsChanged = "plugins/changed"
        public static let workflowRemoved = "workflow/removed"
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
        /// Cursor and Grok permission mode changed (061).
        public static let clientPermissionsChanged = "clientPermissions/changed"
        /// What agents call the person changed (#121).
        public static let personChanged = "person/changed"
        /// A runtime's sandbox default changed (064).
        public static let sandboxChanged = "sandbox/changed"
        /// `RuntimeAllowances`, whenever a runtime's state changes (065). Debounced to
        /// one a second.
        public static let runtimesAllowancesChanged = "runtimes/allowancesChanged"
        /// The retention settings, or what the archive holds, changed (051). A
        /// `RetentionState`.
        public static let retentionChanged = "retention/changed"
        /// An agent was deleted and is not in any list any more (051, #398). An
        /// `AgentRemovedNotification`. An older window ignores it and drops the agent at
        /// its next `agents/list`.
        public static let agentRemoved = "agent/removed"

        /// A lease was granted, extended, released, ended or expired, or a line moved:
        /// the whole `LeaseSnapshot`, which clients replace rather than merge (036).
        /// Also once a minute while anything is held, so "minutes left" stays true
        /// without each client counting against its own clock.
        public static let leasesChanged = "leases/changed"
        /// A volume went low or came back, or how much a low one has free moved (#195).
        public static let diskChanged = "disk/changed"

        /// The Mac is now being kept awake, or is not. Sent only when the verdict
        /// moves — `reviseWakefulness` is reached on every streamed token, and a
        /// notification per token would be a flood (024 FR-015, FR-016).
        public static let wakeChanged = "wake/changed"
        /// `StoreNotes`, whenever a file is set aside, held, or reads again (#205).
        public static let storeNotesChanged = "store/notesChanged"
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

    /// Whether this host has a chat project, and why not (#229). `projects/list` is a
    /// bare array, so the reason travels on its own call, asked only when New Chat finds
    /// no summary marked `isChat`.
    public enum ChatProjectState: Codable, Hashable, Sendable {
        /// Laid out and live: New Chat starts in `folder`.
        case ready(folder: URL)
        /// The person archived it; the daemon leaves it so. Unarchive brings it back.
        case archived(folder: URL)
        /// A root with no personal home (a scratch root, a test) makes none.
        case noPersonalHome
        /// Something is in the way, in a sentence: the path is a file, or making it failed.
        case failed(message: String)
    }

    /// One project, named by its folder, because the folder is the identity.
    public struct ProjectRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    /// A project's helper limits as the person set them (#64). A nil limit is its
    /// default; both nil puts the project back to the defaults.
    public struct SetHelperLimitsRequest: Codable, Sendable {
        public var folder: URL
        public var limits: HelperLimits
        public init(folder: URL, limits: HelperLimits) {
            self.folder = folder
            self.limits = limits
        }
    }

    /// A project pinned to the top of the sidebar, or not.
    public struct SetPinnedRequest: Codable, Sendable {
        public var folder: URL
        public var pinned: Bool
        public init(folder: URL, pinned: Bool) {
            self.folder = folder
            self.pinned = pinned
        }
    }

    /// A project's disk space lines as the person set them (#195). A nil field is its
    /// default; all nil puts the project back to the defaults.
    public struct SetDiskSpaceRequest: Codable, Sendable {
        public var folder: URL
        public var diskSpace: DiskThresholds
        public init(folder: URL, diskSpace: DiskThresholds) {
            self.folder = folder
            self.diskSpace = diskSpace
        }
    }

    /// One guarded file's waiting change (#502): to read, keep or undo. `digest` is the
    /// change as the person was shown it; Keep and Undo refuse a file that has changed
    /// again since. nil is a file that was removed.
    public struct GuardedChangeRequest: Codable, Sendable {
        public var folder: URL
        public var path: String
        public var digest: String?
        public init(folder: URL, path: String, digest: String? = nil) {
            self.folder = folder
            self.path = path
            self.digest = digest
        }
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
        /// Always none since #398, which dropped retiring: sent for a Remote older than
        /// that, whose summary cannot be read without it.
        private var retiredCount: Int = 0
        /// True on the one project this host made for chats (#229), `~/.agents/chat`;
        /// absent on every other, so an older reader sees an ordinary project.
        public var isChat: Bool?
        /// The app-owned files in `.agents` changed outside the app and waiting for the
        /// person's Keep or Undo (#502); absent when none is, so an older reader sees
        /// nothing new. Until then the app goes on using the copy last approved.
        public var guardedChanges: [GuardedChange]?
        /// Which machine the project is on, stamped by the window that heard of it and
        /// never sent (037). Not in `CodingKeys`.
        public var host: HostID = .mac

        public var id: URL { project.folder }
        public var folder: URL { project.folder }
        public var key: ProjectKey { ProjectKey(host: host, folder: project.folder) }
        /// The helper limits enforced here (#64): the person's, or the defaults.
        public var helperLimits: (running: Int, notArchived: Int) {
            (project.helperLimits ?? HelperLimits()).effective
        }

        enum CodingKeys: String, CodingKey {
            case project, name, exists, lastActivityAt, counts, costToDate, unmeasuredAgents
            case retiredCount, isChat, guardedChanges
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

        /// Written by hand for `counts` alone, which a newer daemon may key by a group
        /// this build has not heard of.
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
            costToDate = try c.decode([String: Decimal].self, forKey: .costToDate)
            unmeasuredAgents = try c.decode(Int.self, forKey: .unmeasuredAgents)
            isChat = try c.decodeIfPresent(Bool.self, forKey: .isChat)
            guardedChanges = try? c.decodeIfPresent([GuardedChange].self, forKey: .guardedChanges)
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
        /// The new agent's own sandbox choice (064). Nil follows the runtime's default.
        public var sandbox: SandboxChoice?
        /// Labels chosen by the person on the new-session form.
        public var labels: [String]

        public init(runtimeID: String, cwd: URL, prompt: String,
                    attachments: [Attachment] = [],
                    startOptions: StartOptions = .none, draftID: UUID? = nil,
                    additionalDirectories: [URL] = [], mcpServers: [MCPServer] = [],
                    worktree: WorktreeChoice? = nil, requestID: UUID? = nil,
                    sandbox: SandboxChoice? = nil, labels: [String] = []) {
            self.sandbox = sandbox
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
            self.labels = labels
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
            sandbox = try c.decodeIfPresent(SandboxChoice.self, forKey: .sandbox)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
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

    /// `agents/continueInProject` (#119): start a successor of an agent whose folder has
    /// gone, in its project folder, on the same runtime and choices, told to read this
    /// session and carry on. `text` is whatever was in the prompt bar, said after that.
    /// Answered with the new agent's id.
    public struct ContinueInProjectRequest: Codable, Sendable {
        public var agentID: UUID
        public var text: String
        public var attachments: [Attachment]
        /// As `StartRequest.requestID`: a retry answers with the first try's agent.
        public var requestID: UUID?

        public init(agentID: UUID, text: String = "", attachments: [Attachment] = [], requestID: UUID? = nil) {
            self.agentID = agentID
            self.text = text
            self.attachments = attachments
            self.requestID = requestID
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
            requestID = try c.decodeIfPresent(UUID.self, forKey: .requestID)
        }
    }

    /// `agents/prewarm`: why a window thinks a prompt is coming (#183).
    public struct PrewarmRequest: Codable, Sendable {
        public enum Why: String, Codable, Sendable {
            case opened
            case typing
        }
        public var agentID: UUID
        public var why: Why
        public init(agentID: UUID, why: Why) {
            self.agentID = agentID
            self.why = why
        }

        /// How long a chat is on screen before a window says `opened` (#202): arrowing
        /// past a dozen chats starts none, and the one settled on starts one.
        public static let openedAfter: Duration = .milliseconds(1500)
    }

    /// `agents/setUnread`: put the unread mark on a finished chat, or take it off.
    public struct SetUnreadRequest: Codable, Sendable {
        public var agentID: UUID
        public var unread: Bool
        public init(agentID: UUID, unread: Bool) {
            self.agentID = agentID
            self.unread = unread
        }
    }

    /// A person changes one session's labels. Ownership is assigned by the daemon.
    public struct SetLabelsRequest: Codable, Sendable {
        public var agentID: UUID
        public var add: [String]
        public var remove: [String]

        public init(agentID: UUID, add: [String] = [], remove: [String] = []) {
            self.agentID = agentID
            self.add = add
            self.remove = remove
        }
    }

    public struct LabelVocabularyRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
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

        /// Attachments and origin are optional on the way in: a caller that sends only the
        /// text means a prompt of the person's with nothing attached.
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

    /// `agents/stopBackground` (057): which agent, and the runtime's id for the task.
    public struct StopBackgroundRequest: Codable, Sendable {
        public var agentID: UUID
        public var itemID: String
        public init(agentID: UUID, itemID: String) {
            self.agentID = agentID
            self.itemID = itemID
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
        /// Only with `blocked` (039). See `ReportOutcomeRequest`.
        public var waitingOn: [String]?
        public var checkAgainInMinutes: Int?
        /// `any` or `all` (#152): whether the first of `waitingOn` to finish resumes it.
        /// A string, checked at the daemon; left out is `all`.
        public var wakeOn: String?
        /// `park` or `archive`: where the agent asked to be put once the turn is over.
        /// A string, checked at the daemon, and optional: an agent's MCP helper is
        /// started from whatever binary was on disk when its session began, so one
        /// begun before this field existed relays a call without it.
        public var afterwards: String?
        public var addLabels: [String]
        public var removeLabels: [String]
        /// Where the agent asked to move once the turn ends (053). None clears a move
        /// the agent asked for earlier in the same turn: the last call is the whole
        /// account of it.
        public var move: MoveAsk?

        public init(token: String, outcome: String, message: String,
                    prompts: [SuggestedPrompt],
                    waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil,
                    wakeOn: String? = nil, afterwards: String? = nil,
                    addLabels: [String] = [], removeLabels: [String] = [],
                    move: MoveAsk? = nil) {
            self.token = token
            self.outcome = outcome
            self.message = message
            self.prompts = prompts
            self.waitingOn = waitingOn
            self.checkAgainInMinutes = checkAgainInMinutes
            self.wakeOn = wakeOn
            self.afterwards = afterwards
            self.addLabels = addLabels
            self.removeLabels = removeLabels
            self.move = move
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            outcome = try c.decode(String.self, forKey: .outcome)
            message = try c.decode(String.self, forKey: .message)
            prompts = try c.decode([SuggestedPrompt].self, forKey: .prompts)
            waitingOn = try c.decodeIfPresent([String].self, forKey: .waitingOn)
            checkAgainInMinutes = try c.decodeIfPresent(Int.self, forKey: .checkAgainInMinutes)
            wakeOn = try c.decodeIfPresent(String.self, forKey: .wakeOn)
            afterwards = try c.decodeIfPresent(String.self, forKey: .afterwards)
            addLabels = try c.decodeIfPresent([String].self, forKey: .addLabels) ?? []
            removeLabels = try c.decodeIfPresent([String].self, forKey: .removeLabels) ?? []
            move = try c.decodeIfPresent(MoveAsk.self, forKey: .move)
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
        /// More folders changed than `folders` names (#216): at most `folderLimit` are
        /// sent, and a client treats every folder it shows for the agent as changed.
        /// Absent from a host before it, which always sent them all.
        public var many: Bool?

        /// The most folders one notice names; a build in a lane changes thousands.
        public static let folderLimit = 64

        public init(agentID: UUID, folders: [String], many: Bool? = nil) {
            self.agentID = agentID
            self.folders = folders
            self.many = many
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

    /// What the MCP helper sends when an agent calls `ask_form`. The token does the
    /// same work it does for a suggestion, and the questions become a form
    /// elicitation the daemon holds until the person answers — including on the phone.
    public struct AskFormRequest: Codable, Sendable {
        public var token: String
        public var title: String?
        public var questions: [Question]

        public struct Question: Codable, Sendable {
            public var id: String
            public var prompt: String
            public var options: [Option]?
            public var allowMultiple: Bool?

            public struct Option: Codable, Sendable {
                public var id: String
                public var label: String?

                public init(id: String, label: String? = nil) {
                    self.id = id
                    self.label = label
                }
            }

            public init(id: String, prompt: String, options: [Option]? = nil,
                        allowMultiple: Bool? = nil) {
                self.id = id
                self.prompt = prompt
                self.options = options
                self.allowMultiple = allowMultiple
            }
        }

        public init(token: String, title: String? = nil, questions: [Question]) {
            self.token = token
            self.title = title
            self.questions = questions
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
        /// The most entries one page carries, whatever is asked for (#200). A turn longer
        /// than this is read a page at a time.
        public static let limitCeiling = 1_000

        public var agentID: UUID
        public var before: Int?
        public var limit: Int
        /// Nothing before this entry: the turn in progress starts here, and the turns
        /// before it come from `agents/turns`.
        public var from: Int?

        public init(agentID: UUID, before: Int? = nil, limit: Int = 200, from: Int? = nil) {
            self.agentID = agentID
            self.before = before
            self.limit = limit
            self.from = from
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            before = try c.decodeIfPresent(Int.self, forKey: .before)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 200
            from = try c.decodeIfPresent(Int.self, forKey: .from)
        }

        /// The few entries around `index`, to find an entry sent as a stub among them by its
        /// id (#203); the last page when where it is was not said.
        public static func around(_ index: Int?, of agentID: UUID) -> TranscriptRequest {
            guard let index else { return TranscriptRequest(agentID: agentID, limit: 50) }
            return TranscriptRequest(agentID: agentID, before: index + 4, limit: 8)
        }

        /// The request as a host answers it (#200): a negative limit or position is
        /// refused, and a limit past the ceiling is cut to it. A limit of zero is an
        /// empty page.
        public func bounded() throws -> TranscriptRequest {
            var bounded = self
            bounded.limit = try DaemonAPI.boundedLimit(limit, ceiling: Self.limitCeiling)
            try DaemonAPI.requireNotNegative(before, named: "before")
            try DaemonAPI.requireNotNegative(from, named: "from")
            return bounded
        }
    }

    public struct TurnsRequest: Codable, Sendable {
        /// The most turns one page carries, whatever is asked for (#200).
        public static let limitCeiling = 200
        /// How many finished turns a chat opens with, on the window and the Remote alike
        /// (#90, #242); the page keeps the same number (`openingTurns`). A screen holds two
        /// or three, and the rest come as the reader nears the top.
        public static let openingTurns = 12

        /// The first page of a chat's turns, as every client asks for it.
        public static func opening(_ agentID: UUID) -> TurnsRequest {
            TurnsRequest(agentID: agentID, limit: openingTurns)
        }

        public var agentID: UUID
        /// Turns before this one, by its position among the finished turns.
        public var before: Int?
        public var limit: Int

        public init(agentID: UUID, before: Int? = nil, limit: Int = 50) {
            self.agentID = agentID
            self.before = before
            self.limit = limit
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            before = try c.decodeIfPresent(Int.self, forKey: .before)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        }

        /// The request as a host answers it (#200), as `TranscriptRequest.bounded()`.
        public func bounded() throws -> TurnsRequest {
            var bounded = self
            bounded.limit = try DaemonAPI.boundedLimit(limit, ceiling: Self.limitCeiling)
            try DaemonAPI.requireNotNegative(before, named: "before")
            return bounded
        }
    }

    /// A page's limit as a host takes it (#200): never negative, never past `ceiling`.
    static func boundedLimit(_ limit: Int, ceiling: Int) throws -> Int {
        try requireNotNegative(limit, named: "limit")
        return min(limit, ceiling)
    }

    /// One position or limit in a request, refused in words when it is below zero (#200).
    static func requireNotNegative(_ value: Int?, named name: String) throws {
        guard let value, value < 0 else { return }
        throw JSONRPCError(code: JSONRPCError.invalidParams,
                           message: "\(name) must be 0 or more, not \(value).")
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
        /// The day's ledger could not be read and was set aside in this run (#171), so
        /// `today` may be short; said beside the limits. Nil when it read.
        public var note: String?

        public init(limits: CostLimits, today: [String: Decimal], day: String, note: String? = nil) {
            self.limits = limits
            self.today = today
            self.day = day
            self.note = note
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
    public struct ApplyAllowances: Codable, Sendable {
        public var states: [AllowanceState]
        public init(states: [AllowanceState]) { self.states = states }
    }

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

    /// What comes with `sandboxWillNotStart` (064).
    public struct SandboxWillNotStart: Codable, Sendable, Hashable {
        public var runtimeID: String
        public var detail: String
        public var offOffered: Bool
        public init(runtimeID: String, detail: String, offOffered: Bool) {
            self.runtimeID = runtimeID
            self.detail = detail
            self.offOffered = offOffered
        }
    }

    /// One agent's sandbox override (064). `choice: nil` clears it (FR-003b).
    public struct SetSandboxRequest: Codable, Sendable {
        public var agentID: UUID
        public var choice: SandboxChoice?
        public init(agentID: UUID, choice: SandboxChoice?) {
            self.agentID = agentID
            self.choice = choice
        }
    }

    /// The sandbox card's answer (064): carry on without the sandbox, or keep stopped.
    public struct AnswerSandboxRequest: Codable, Sendable {
        public var agentID: UUID
        public var carryOn: Bool
        public init(agentID: UUID, carryOn: Bool) {
            self.agentID = agentID
            self.carryOn = carryOn
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
        /// Every agent without its option and command lists and its plans (`Agent.leaned`),
        /// which is what a sessions column needs. Those lists were 20 KB of a record's 21:
        /// 4.2 MB for 200 agents (#107). The chat that is open asks for its own record
        /// whole, with `agentID`. A client that does not ask gets the whole record, as before.
        public var lean: Bool
        /// Only this agent, whole: the record of the chat that is open, whose menus and
        /// plan the lean list leaves out. An archived agent is read back from disk first.
        /// A host from before #107 ignores it and lists everything, so ask with `limit: 1`
        /// as well and look for the id in what comes back.
        public var agentID: UUID?
        /// Where the last page ended: the next page starts after this agent (#164).
        public var after: ListCursor?
        /// Only agents whose title or labels match, as the sidebar's search reads it
        /// (`SessionLabelQuery`), archived ones included when `includeArchived` is.
        /// What a search asks the host for, rather than filtering what it holds (#165).
        public var query: String?

        /// How many come back when `limit` is not said, and the most that ever do (#164).
        /// A whole list is pages: ask again `after` the last until fewer than asked come.
        public static let defaultLimit = 500
        public static let maximumLimit = 1_000

        public init(includeArchived: Bool = true, archivedCommands: Bool = true,
                    archivedOnly: Bool = false, folder: URL? = nil,
                    startedByWorkflow: String? = nil, limit: Int? = nil,
                    lean: Bool = false, agentID: UUID? = nil,
                    after: ListCursor? = nil, query: String? = nil) {
            self.includeArchived = includeArchived
            self.archivedCommands = archivedCommands
            self.archivedOnly = archivedOnly
            self.folder = folder
            self.startedByWorkflow = startedByWorkflow
            self.limit = limit
            self.lean = lean
            self.agentID = agentID
            self.after = after
            self.query = query
        }

        /// One agent's whole record, archived or not (#107).
        public static func whole(_ agentID: UUID) -> ListRequest {
            ListRequest(includeArchived: true, limit: 1, agentID: agentID)
        }

        /// How many this asks for, as the host will answer it.
        public var pageSize: Int { min(max(0, limit ?? Self.defaultLimit), Self.maximumLimit) }

        /// The same request for the page after `page`, or nil when `page` was the last. A
        /// page longer than asked is a host from before pages, which sent everything.
        public func next(after page: [Agent]) -> ListRequest? {
            guard page.count == pageSize, pageSize > 0, let last = page.last else { return nil }
            var next = self
            next.after = ListCursor(last)
            return next
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? true
            archivedCommands = try c.decodeIfPresent(Bool.self, forKey: .archivedCommands) ?? true
            archivedOnly = try c.decodeIfPresent(Bool.self, forKey: .archivedOnly) ?? false
            folder = try c.decodeIfPresent(URL.self, forKey: .folder)
            startedByWorkflow = try c.decodeIfPresent(String.self, forKey: .startedByWorkflow)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit)
            lean = try c.decodeIfPresent(Bool.self, forKey: .lean) ?? false
            agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
            after = try c.decodeIfPresent(ListCursor.self, forKey: .after)
            query = try c.decodeIfPresent(String.self, forKey: .query)
        }
    }

    /// Where a page of `agents/list` ended (#164): its last agent's activity and id. The
    /// list is newest activity first, and by id among equals, so the next page is
    /// everything after this point. An agent that moves between pages may be listed
    /// twice or not at all; `agent/changed` carries it either way.
    public struct ListCursor: Codable, Hashable, Sendable {
        public var lastActivityAt: Date
        public var id: UUID

        public init(lastActivityAt: Date, id: UUID) {
            self.lastActivityAt = lastActivityAt
            self.id = id
        }

        public init(_ agent: Agent) {
            self.init(lastActivityAt: agent.lastActivityAt, id: agent.id)
        }

        /// The list's order: newest activity first, then by id.
        public static func listOrder(_ a: Agent, _ b: Agent) -> Bool {
            listOrder(a, ListCursor(b))
        }

        /// Whether `a` comes before the point `b` in the list's order.
        public static func listOrder(_ a: Agent, _ b: ListCursor) -> Bool {
            if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    // MARK: Notifications

    /// `agent/entry`: sent only to the connections showing the agent (#203).
    public struct EntryNotification: Codable, Sendable {
        /// The most an entry may weigh on the wire, encoded (#203). A tool call's diff or a
        /// file read whole can be megabytes; past this, a stub goes and the open chat reads
        /// the entry with `agents/transcript`.
        public static let entryByteLimit = 32 * 1024

        public var agentID: UUID
        public var entry: TranscriptEntry
        /// Where the entry is in the transcript, as `agents/transcript` counts. Sent with a
        /// stub, so the chat can read it; nil on everything else.
        public var index: Int?
        /// Set when the entry was too big to send: its encoded size. `entry` is then a stub
        /// with only its id and time, of a kind every build skips when drawing.
        public var oversized: Int?

        public init(agentID: UUID, entry: TranscriptEntry, index: Int? = nil, oversized: Int? = nil) {
            self.agentID = agentID
            self.entry = entry
            self.index = index
            self.oversized = oversized
        }

        /// The stub sent in place of an entry of `bytes` (#203).
        public static func stub(agentID: UUID, for entry: TranscriptEntry, bytes: Int, index: Int?) -> EntryNotification {
            let stub = TranscriptEntry(id: entry.id, at: entry.at,
                                       kind: .unrecognised(.object(["oversized": .int(bytes)])),
                                       subagentID: entry.subagentID)
            return EntryNotification(agentID: agentID, entry: stub, index: index, oversized: bytes)
        }
    }

    public struct PermissionNotification: Codable, Sendable {
        public var agentID: UUID
        /// Nil when the question has been answered and is no longer waiting.
        public var request: PermissionRequest?
        /// Identifies a single withdrawn question. Every withdrawal this daemon sends
        /// carries one; nil is a daemon from before 09-27 withdrawing them all, kept
        /// because that is after the #58 cut-off (051).
        public var requestID: UUID?
        public init(agentID: UUID, request: PermissionRequest?, requestID: UUID? = nil) {
            self.agentID = agentID
            self.requestID = requestID ?? request?.id
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

    /// `agent/terminalOutput`: sent only to the connections showing the agent (#203).
    public struct TerminalOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var terminalID: String
        public var chunk: String
        /// `chunk` is everything the terminal still holds, not the next piece of it: sent to
        /// a connection that has just started showing the agent, in place of what it was not
        /// sent while it showed something else (#203).
        public var whole: Bool?

        public init(agentID: UUID, terminalID: String, chunk: String, whole: Bool? = nil) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.chunk = chunk
            self.whole = whole
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

    // An agent may have several shells (055), told apart by `shell`: a small number,
    // unique for the agent while the shell is held. Zero is the one every agent had
    // before there could be more, and what a message without the field means, so a
    // phone or a server that has never heard of the field is talking about that one.

    public struct ShellAttachRequest: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        public var rows: Int
        public var cols: Int
        /// How far into the shell's output this screen already is, and when the shell
        /// it has was started. Given both, and the same shell is still there, the
        /// replay is only what came after: a screen coming back is not sent four
        /// megabytes it already shows (#401).
        public var since: Int?
        public var startedAt: Date?
        /// The project whose own shell this is (#418), when it is not an agent's: the
        /// daemon starts it in this folder, and `agentID` is `ProjectShell.id(for:)` it.
        /// A daemon from before #418 knows no such agent and says so.
        public var folder: URL?

        public init(agentID: UUID, shell: Int = 0, rows: Int = 24, cols: Int = 80,
                    since: Int? = nil, startedAt: Date? = nil, folder: URL? = nil) {
            self.agentID = agentID
            self.shell = shell
            self.rows = rows
            self.cols = cols
            self.since = since
            self.startedAt = startedAt
            self.folder = folder
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 24
            cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 80
            since = try c.decodeIfPresent(Int.self, forKey: .since)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            folder = try c.decodeIfPresent(URL.self, forKey: .folder)
        }
    }

    /// One of an agent's shells, for detaching and closing.
    public struct ShellRequest: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int

        public init(agentID: UUID, shell: Int = 0) {
            self.agentID = agentID
            self.shell = shell
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
        }
    }

    /// The shells the daemon holds for an agent, in the order they were opened.
    public struct ShellListResponse: Codable, Sendable {
        public var shells: [Int]
        public init(shells: [Int]) { self.shells = shells }
    }

    /// The number the daemon gave a shell it opened (#401).
    public struct ShellOpenResponse: Codable, Sendable {
        public var shell: Int
        public init(shell: Int) { self.shell = shell }
    }

    /// What a window gets on attach: the state, and the bytes to replay.
    ///
    /// Bytes, not a screen. The daemon parses nothing; the window feeds these to its
    /// own emulator and arrives at the screen it would have had if it had been watching
    /// all along (plan decision 2).
    public struct ShellAttachResponse: Codable, Sendable {
        public var state: ShellState
        public var scrollback: Data
        /// Bytes dropped off the front of the buffer, which is also the offset of the
        /// replay's first byte: the replay ends where the next `shell/output` starts.
        public var dropped: Int
        public var startedAt: Date
        /// Where the shell was started. Nil from a daemon before 053, which is after the
        /// #58 cut-off (051), so it stays optional.
        public var folder: URL?
        /// The offset of the replay's first byte, when it is not the whole buffer: an
        /// attach that said `since` gets only what came after. Nil means `dropped`.
        public var offset: Int?

        public init(state: ShellState, scrollback: Data, dropped: Int, startedAt: Date, folder: URL? = nil,
                    offset: Int? = nil) {
            self.state = state
            self.scrollback = scrollback
            self.dropped = dropped
            self.startedAt = startedAt
            self.folder = folder
            self.offset = offset
        }
    }

    public struct ShellInputRequest: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        /// What the user typed, as bytes. Never a `String`: a keystroke is not always a
        /// character, and an escape sequence is not text.
        public var bytes: Data
        /// The typist's screen, when it says (034). The shell takes the size of whoever
        /// typed last, and the daemon is the one place that knows who that was. Older
        /// clients send neither and nothing is resized.
        public var rows: Int?
        public var cols: Int?

        public init(agentID: UUID, shell: Int = 0, bytes: Data, rows: Int? = nil, cols: Int? = nil) {
            self.agentID = agentID
            self.shell = shell
            self.bytes = bytes
            self.rows = rows
            self.cols = cols
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            bytes = try c.decode(Data.self, forKey: .bytes)
            rows = try c.decodeIfPresent(Int.self, forKey: .rows)
            cols = try c.decodeIfPresent(Int.self, forKey: .cols)
        }
    }

    public struct ShellResizeRequest: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        public var rows: Int
        public var cols: Int

        public init(agentID: UUID, shell: Int = 0, rows: Int, cols: Int) {
            self.agentID = agentID
            self.shell = shell
            self.rows = rows
            self.cols = cols
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            rows = try c.decode(Int.self, forKey: .rows)
            cols = try c.decode(Int.self, forKey: .cols)
        }
    }

    public struct ShellSignalRequest: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        public var signal: Int32

        public init(agentID: UUID, shell: Int = 0, signal: Int32) {
            self.agentID = agentID
            self.shell = shell
            self.signal = signal
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            signal = try c.decode(Int32.self, forKey: .signal)
        }
    }

    public struct ShellOutputNotification: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        public var bytes: Data
        /// Where the first of these bytes falls in everything the shell has printed. A
        /// screen whose replay already holds them drops them, rather than printing them
        /// twice (#401). Nil from a host before #401, whose output is shown as it comes.
        public var offset: Int?

        public init(agentID: UUID, shell: Int = 0, bytes: Data, offset: Int? = nil) {
            self.agentID = agentID
            self.shell = shell
            self.bytes = bytes
            self.offset = offset
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            bytes = try c.decode(Data.self, forKey: .bytes)
            offset = try c.decodeIfPresent(Int.self, forKey: .offset)
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
            self.shell = params["shell"]?.intValue ?? 0
            self.bytes = bytes
            self.offset = params["offset"]?.intValue
        }
    }

    public struct ShellStateNotification: Codable, Sendable {
        public var agentID: UUID
        public var shell: Int
        public var state: ShellState

        public init(agentID: UUID, shell: Int = 0, state: ShellState) {
            self.agentID = agentID
            self.shell = shell
            self.state = state
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            shell = try c.decodeIfPresent(Int.self, forKey: .shell) ?? 0
            state = try c.decode(ShellState.self, forKey: .state)
        }
    }

    public enum Failure {
        // Retired: nothing raises these any more, and they are not to be given out again:
        // -32006 (a prompt to a working agent), -32019 (already answered), -32020 (no
        // such device), -32021 (no such need), -32037 (credential refused, now a
        // notification), -32046 (stop the turn first, 052).
        public static let runtimeNotFound = -32001
        public static let runtimeWillNotStart = -32002
        /// The runtime would not start because its command sandbox could not be set up
        /// (064). Its data is `SandboxWillNotStart`: the form keeps the prompt and offers
        /// **Start without sandbox** when `offOffered`.
        public static let sandboxWillNotStart = -32061
        public static let sessionGone = -32003
        public static let folderGone = -32004
        public static let noSuchAgent = -32005
        /// Delete on an agent that is not archived, or that something still holds (#398).
        /// The message is the reason. -32050 was a retired agent's tombstone (051), gone
        /// with tombstones, and is not to be given out again.
        public static let deleteRefused = -32051
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
        /// Something only the Mac's own window may do, asked on a device's connection:
        /// forgetting a device (046).
        public static let notAllowed = -32060
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
        /// An agent turning back on a workflow the person turned off (#100). Only an
        /// agent's own off can be undone by an agent.
        public static let workflowTurnedOffByPerson = -32041
        /// A new agent asked for while the day's spending limit is reached. Raised by
        /// `agents/start` only: a prompt to an agent that already exists succeeds and
        /// waits on that agent's queue, because losing what somebody typed because a
        /// budget was reached would be the worst possible reading of "control cost".
        public static let dayLimitReached = -32018
        /// A daemon asked to quit while a turn is in flight (037).
        public static let busy = -32040
        /// A server daemon had to start a runtime for this request and has no sign-in to
        /// start it with. Nothing was started, so the same request (same `sendID`) can be
        /// sent again after `credentials/lend` (043). `data`: `runtime`, `offered`.
        public static let credentialWanted = -32036
        /// `credentials/lend` to a daemon that is not a server's (043, D5).
        public static let notAServer = -32038
        /// `credentials/lend` for a runtime this connection did not offer, or on a
        /// connection that said the server uses its own sign-in only (043, FR-014).
        public static let notOffered = -32039
        /// A server daemon had to start a runtime whose sign-in the Mac relays (056: Claude),
        /// and there was no relay, the server is not "own sign-in only", and it has no
        /// sign-in of its own. Nothing was started. `data`: `SignInWanted`.
        public static let signInWanted = -32070
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
        /// A method this connection's role may not call: an agent's helper asking for
        /// something only a window may, or a process that is neither (security review).
        public static let notPermitted = -32045
        /// A call for a host the control plane knows but cannot reach right now (058).
        /// Answered by the control plane at once, rather than left to time out.
        /// (-32070 is `signInWanted` and -32080 `catalogRefused`: the control plane's own start at -32090.)
        public static let hostOffline = -32090
        /// A call naming a host the control plane has never enrolled, or has removed.
        public static let noSuchHost = -32091
        /// Was demoting or forgetting the last operator (058, FR-016). Never said since
        /// grants were retired (#111); kept so the number is not given to anything else
        /// an older build would read as this.
        public static let lastOperator = -32092
        /// A change another copy of the control plane made first: the store refused this
        /// one's write, and nothing was changed. Try again (058, contracts/store.md).
        public static let changedElsewhere = -32093
        /// The control plane's store cannot be reached. Live connections carry on;
        /// nothing new can be remembered until it is back.
        public static let storeUnavailable = -32094
        /// A write the disk refused: full, or a folder this may not write to (#88). The
        /// message says what was not kept and what to do; the data is `WriteFailure`.
        public static let couldNotSave = -32095
        /// An agent copied in from another root (#228): its session and folder are that
        /// root's live work, so this daemon will not start a runtime for it.
        public static let importedAgent = -32096
        /// The runtime session is live under another daemon on this Mac (#228), which
        /// holds its lock. Two daemons driving one conversation is two agents doing one
        /// agent's work in the same folder.
        public static let sessionLiveElsewhere = -32097
        /// A scratch daemon asked to run an agent in a folder outside its own root
        /// (#228), without `--allow-outside-root`.
        public static let outsideScratchRoot = -32098
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

    /// Turn a workflow on or off (#100). The app's own state, like archiving, and never
    /// written into the file.
    public struct WorkflowEnableRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public var enabled: Bool
        public init(folder: URL, workflowID: String, enabled: Bool) {
            self.folder = folder
            self.workflowID = workflowID
            self.enabled = enabled
        }
    }

    /// Clear the missed-events mark on one line under a server's event trigger (#383):
    /// the event's name and the server whose line it is.
    public struct WorkflowMCPClearMissedRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public var name: String
        public var server: String?
        public init(folder: URL, workflowID: String, name: String, server: String?) {
            self.folder = folder
            self.workflowID = workflowID
            self.name = name
            self.server = server
        }
    }

    /// A project's plugins.
    public struct PluginsListRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    /// Every plugin in one project, for `plugins/list` and `plugins/changed`.
    public struct PluginsList: Codable, Sendable {
        public var folder: URL
        public var plugins: [ProjectPlugin]
        public init(folder: URL, plugins: [ProjectPlugin]) {
            self.folder = folder
            self.plugins = plugins
        }
    }

    /// Approve a plugin's folder as the row showed it.
    public struct PluginApproveRequest: Codable, Sendable {
        public var plugin: URL
        public var digest: String
        public init(plugin: URL, digest: String) {
            self.plugin = plugin
            self.digest = digest
        }
    }

    /// Approve a workflow's file: `digest` is the one the row carried, so only the file
    /// the person was shown is approved. Deny (#391) sends the same, for the same reason.
    public struct WorkflowApproveRequest: Codable, Sendable {
        public var folder: URL
        public var workflowID: String
        public var digest: String
        public init(folder: URL, workflowID: String, digest: String) {
            self.folder = folder
            self.workflowID = workflowID
            self.digest = digest
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
        /// The `cooldown:` to write, as the file writes it (#103): `15m`, or empty to take
        /// the line out. Unlike the settings, left out means left alone, so a phone or
        /// page that does not show the cooldown cannot remove it by saving a mode.
        public var cooldown: String?
        /// The `labels:` to write (#142), or empty to take the line out. Left out means
        /// left alone, as the cooldown is, so a phone or page from before the labels
        /// field cannot remove them by saving a mode.
        public var labels: [String]?
        /// The `hosts:` to write (#317): machine ids, or empty to take the line out so
        /// every host runs it. Left out means left alone, as the labels are.
        public var hosts: [String]?
        /// The `when-done:` to write (#433): `park`, `archive-allowed` or `archive`, and
        /// `park` or empty takes the line out. Left out means left alone, as the hosts are.
        public var whenDone: String?
        public init(folder: URL, workflowID: String, settings: WorkflowSettings, cooldown: String? = nil,
                    labels: [String]? = nil, hosts: [String]? = nil, whenDone: String? = nil) {
            self.whenDone = whenDone
            self.folder = folder
            self.workflowID = workflowID
            self.settings = settings
            self.cooldown = cooldown
            self.labels = labels
            self.hosts = hosts
        }
    }

    /// What this runtime last advertised for this folder. Starts nothing.
    public struct DiscardDraftRequest: Codable, Sendable {
        public var draftID: UUID
        public init(draftID: UUID) { self.draftID = draftID }
    }

    /// Keyed by runtime id. What `modes/remembered` answers and `modes/changed` carries.
    public typealias RememberedModes = [String: JSONValue]

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
            /// Turn one on or off (#100).
            case enable, disable
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
        public var labels: [String]

        public init(token: String, prompt: String, runtime: String? = nil,
                    model: String? = nil, permissionMode: String? = nil,
                    worktree: String? = nil, labels: [String] = []) {
            self.worktree = worktree
            self.token = token
            self.prompt = prompt
            self.runtime = runtime
            self.model = model
            self.permissionMode = permissionMode
            self.labels = labels
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            prompt = try c.decode(String.self, forKey: .prompt)
            runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
            worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        }
    }

    /// What an agent passes to `stop_agent` or `park_agent`. The id
    /// is a string so one that is not a UUID is refused in words rather than failing
    /// to decode.
    public struct HelperRequest: Codable, Sendable {
        public var token: String
        public var agentID: String

        public init(token: String, agentID: String) {
            self.token = token
            self.agentID = agentID
        }
    }

    /// `park_agent` or `archive_agent` on itself (#481): `park` or `archive`, checked at
    /// the daemon.
    public struct AfterTurnRequest: Codable, Sendable {
        public var token: String
        public var afterwards: String

        public init(token: String, afterwards: String) {
            self.token = token
            self.afterwards = afterwards
        }
    }

    /// `set_session_labels` (#481).
    public struct OwnLabelsRequest: Codable, Sendable {
        public var token: String
        public var add: [String]
        public var remove: [String]

        public init(token: String, add: [String] = [], remove: [String] = []) {
            self.token = token
            self.add = add
            self.remove = remove
        }
    }

    /// `wait_for_event` on agents or a time (#481): the block `finish_turn` used to carry.
    public struct WaitOnRequest: Codable, Sendable {
        public var token: String
        /// By id or exact title, as `waiting_on` took them.
        public var agents: [String]
        /// `any` or `all`; left out is `all`.
        public var wakeOn: String?
        public var untilMinutes: Int?
        /// What the person reads on the row while it waits. Left out, the app says it.
        public var message: String?

        public init(token: String, agents: [String] = [], wakeOn: String? = nil,
                    untilMinutes: Int? = nil, message: String? = nil) {
            self.token = token
            self.agents = agents
            self.wakeOn = wakeOn
            self.untilMinutes = untilMinutes
            self.message = message
        }
    }

    /// What an agent passes to `list_my_agents`: nothing but who it is.
    public struct ListHelpersRequest: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    /// `runtimes/markAvailable` (065): a runtime is back, by its credential key.
    public struct MarkRuntimeAvailable: Codable, Sendable {
        public var credentialKey: String
        public init(credentialKey: String) { self.credentialKey = credentialKey }
    }

    /// What an agent passes to `list_sessions` (065): who it is, and which page. Its
    /// project is its own, never a parameter.
    public struct ListSessionsRequest: Codable, Sendable {
        public var token: String
        /// How many sessions; nil is `SessionLookup.pageSize` (#210).
        public var limit: Int?
        /// The id of the last session the previous page listed; nil is the first page.
        public var after: String?

        public init(token: String, limit: Int? = nil, after: String? = nil) {
            self.token = token
            self.limit = limit
            self.after = after
        }
    }

    /// What an agent passes to `read_session` (065): a session id or exact title.
    public struct ReadSessionRequest: Codable, Sendable {
        public var token: String
        public var session: String

        public init(token: String, session: String) {
            self.token = token
            self.session = session
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

    /// The person ending a lease on `name`: the one `agentID` holds, or with none
    /// named, every one (#116; before it there was only ever one).
    public struct PersonEndRequest: Codable, Sendable {
        public var name: String
        public var agentID: String?

        public init(name: String, agentID: String? = nil) {
            self.name = name
            self.agentID = agentID
        }
    }

    /// The person adding a declared resource, or changing one. `replacing` is the
    /// name it had, when the change renames it.
    public struct DeclareResourceRequest: Codable, Sendable {
        public var resource: DeclaredResource
        public var replacing: String?

        public init(resource: DeclaredResource, replacing: String? = nil) {
            self.resource = resource
            self.replacing = replacing
        }
    }

    /// The person taking a declared resource away. Anyone holding it keeps the lease.
    public struct RemoveResourceRequest: Codable, Sendable {
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
        /// Everyone holding it, in the order they got it (#116).
        public var holds: [Lease]
        /// How many may hold it at once.
        public var places: Int
        /// Set when the person declared it: its description and rules.
        public var declared: DeclaredResource?
        public var line: [LineMember]
        /// Whether any holder's lease is inside its warning window.
        public var endingSoon: Bool

        /// The first holder. Still sent, so a client from before #116 draws the one.
        public var lease: Lease? { holds.first }

        public var id: ResourceName { name }

        public init(name: ResourceName, kind: ResourceKind, displayName: String, isGone: Bool = false,
                    holds: [Lease] = [], places: Int = 1, declared: DeclaredResource? = nil,
                    line: [LineMember] = [], endingSoon: Bool = false) {
            self.name = name
            self.kind = kind
            self.displayName = displayName
            self.isGone = isGone
            self.holds = holds
            self.places = places
            self.declared = declared
            self.line = line
            self.endingSoon = endingSoon
        }

        public init(name: ResourceName, kind: ResourceKind, displayName: String, isGone: Bool = false,
                    lease: Lease?, line: [LineMember] = [], endingSoon: Bool = false) {
            self.init(name: name, kind: kind, displayName: displayName, isGone: isGone,
                      holds: lease.map { [$0] } ?? [], line: line, endingSoon: endingSoon)
        }

        /// "2 of 3 held", for a resource more than one may hold; nil for one only one may.
        public var heldCount: String? {
            places > 1 ? "\(holds.count) of \(places) held" : nil
        }

        private enum CodingKeys: String, CodingKey {
            case name, kind, displayName, isGone, holds, lease, places, declared, line, endingSoon
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(ResourceName.self, forKey: .name)
            kind = try container.decode(ResourceKind.self, forKey: .kind)
            displayName = try container.decode(String.self, forKey: .displayName)
            isGone = try container.decodeIfPresent(Bool.self, forKey: .isGone) ?? false
            if let holds = try container.decodeIfPresent([Lease].self, forKey: .holds) {
                self.holds = holds
            } else {
                holds = try container.decodeIfPresent(Lease.self, forKey: .lease).map { [$0] } ?? []
            }
            places = try container.decodeIfPresent(Int.self, forKey: .places) ?? 1
            declared = try container.decodeIfPresent(DeclaredResource.self, forKey: .declared)
            line = try container.decodeIfPresent([LineMember].self, forKey: .line) ?? []
            endingSoon = try container.decodeIfPresent(Bool.self, forKey: .endingSoon) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(kind, forKey: .kind)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(isGone, forKey: .isGone)
            try container.encode(holds, forKey: .holds)
            try container.encodeIfPresent(lease, forKey: .lease)
            try container.encode(places, forKey: .places)
            try container.encodeIfPresent(declared, forKey: .declared)
            try container.encode(line, forKey: .line)
            try container.encode(endingSoon, forKey: .endingSoon)
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
        /// What git says about it. Nil when its folder is gone, or from an older daemon.
        public var status: WorktreeStatus?

        public var id: URL { root }

        public init(name: String, root: URL, branch: String?, isProjectFolder: Bool,
                    exists: Bool, madeByApp: Bool, agents: [UUID], status: WorktreeStatus? = nil) {
            self.name = name
            self.root = root
            self.branch = branch
            self.isProjectFolder = isProjectFolder
            self.exists = exists
            self.madeByApp = madeByApp
            self.agents = agents
            self.status = status
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
            status = try c.decodeIfPresent(WorktreeStatus.self, forKey: .status)
        }
    }

    /// A worktree's git status, as its row on the project page says it.
    public struct WorktreeStatus: Codable, Hashable, Sendable {
        /// Lines of `git status --porcelain`.
        public var uncommitted: Int
        /// Against what its branch tracks; nil when it tracks nothing.
        public var ahead: Int?
        public var behind: Int?
        /// Commits on its branch the project folder's branch doesn't have. Nil for the
        /// project folder itself, and when its HEAD is detached.
        public var unmerged: Int?

        public init(uncommitted: Int, ahead: Int? = nil, behind: Int? = nil, unmerged: Int? = nil) {
            self.uncommitted = uncommitted
            self.ahead = ahead
            self.behind = behind
            self.unmerged = unmerged
        }

        /// Work that would be lost, or not yet merged: the part worth drawing the eye to.
        public var hasPendingWork: Bool { uncommitted > 0 || (unmerged ?? 0) > 0 }

        /// "3 uncommitted · 2 unmerged · ↑1 ↓2", or "clean" when nothing is pending.
        public var summary: String {
            var parts: [String] = []
            if uncommitted > 0 { parts.append("\(uncommitted) uncommitted") }
            if let unmerged, unmerged > 0 { parts.append("\(unmerged) unmerged") }
            let arrows = [(ahead ?? 0) > 0 ? "↑\(ahead!)" : nil, (behind ?? 0) > 0 ? "↓\(behind!)" : nil]
                .compactMap { $0 }
            if !arrows.isEmpty { parts.append(arrows.joined(separator: " ")) }
            return parts.isEmpty ? "clean" : parts.joined(separator: " · ")
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

    /// A move asked for on `finish_turn` (053).
    public struct MoveAsk: Codable, Sendable, Equatable {
        public var target: MoveTarget
        public var removeLeft: Bool
        public var discardChanges: Bool

        public init(target: MoveTarget, removeLeft: Bool = false, discardChanges: Bool = false) {
            self.target = target
            self.removeLeft = removeLeft
            self.discardChanges = discardChanges
        }
    }

    /// An agent moving itself (053), from a helper begun before the move rode on
    /// `finish_turn`: what it passed to the `enter_worktree` or `exit_worktree` it had.
    public struct MoveSelfRequest: Codable, Sendable {
        public var token: String
        /// None takes back a move the agent asked for earlier in the turn (#481).
        public var target: MoveTarget?
        public var removeLeft: Bool
        public var discardChanges: Bool

        public init(token: String, target: MoveTarget?, removeLeft: Bool = false, discardChanges: Bool = false) {
            self.token = token
            self.target = target
            self.removeLeft = removeLeft
            self.discardChanges = discardChanges
        }
    }

    /// The person moving an agent (053). No target takes back the move that is waiting.
    public struct MoveRequest: Codable, Sendable {
        public var agentID: UUID
        public var target: MoveTarget?
        public var removeLeft: Bool
        public var discardChanges: Bool

        public init(agentID: UUID, target: MoveTarget?, removeLeft: Bool = false, discardChanges: Bool = false) {
            self.agentID = agentID
            self.target = target
            self.removeLeft = removeLeft
            self.discardChanges = discardChanges
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentID = try c.decode(UUID.self, forKey: .agentID)
            target = try c.decodeIfPresent(MoveTarget.self, forKey: .target)
            removeLeft = try c.decodeIfPresent(Bool.self, forKey: .removeLeft) ?? false
            discardChanges = try c.decodeIfPresent(Bool.self, forKey: .discardChanges) ?? false
        }
    }

    /// What a move request came to: made now, waiting for the turn to end, or nothing to
    /// do. The message is what the agent's tool returns and what a window may show.
    public struct MoveAnswer: Codable, Sendable {
        public enum When: String, Codable, Sendable { case now, afterTurn, nothing }
        public var when: When
        public var message: String
        public var agent: Agent?

        public init(when: When, message: String, agent: Agent? = nil) {
            self.when = when
            self.message = message
            self.agent = agent
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

    /// `connection/bindDevice`: which device a bridge connection carries. The relay knows
    /// from the key that opened the frame, the direct link from the key its TLS was
    /// locked with. `pairing` is a connection locked with a pairing code instead: nobody
    /// yet, allowed only to announce itself.
    public struct DeviceBinding: Codable, Sendable {
        public var id: UUID?
        public var pairing: Bool?

        public init(id: UUID?, pairing: Bool = false) {
            self.id = id
            self.pairing = pairing ? true : nil
        }
    }

    /// What the Mac shows as a QR code, and what the phone reads from it.
    public struct PairingCode: Codable, Sendable, Hashable {
        /// The Mac's relay key, X9.63. The phone keeps this one and no other.
        public var macKey: Data
        /// Thirty-two random bytes, good once.
        public var secret: Data
        /// This Mac's name, as the bridge advertises it on Bonjour.
        public var name: String
        public var expires: Date

        public init(macKey: Data, secret: Data, name: String, expires: Date) {
            self.macKey = macKey
            self.secret = secret
            self.name = name
            self.expires = expires
        }

        /// The text in the QR code: `agents-pair:1:<key>:<secret>:<name>`, the key and the
        /// secret in base64url and the name percent-encoded.
        public var text: String {
            let name = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "agents-pair:1:\(Self.base64url(macKey)):\(Self.base64url(secret)):\(name)"
        }

        /// A code read back from a QR code's text, without its expiry: the phone does not
        /// know it and does not need to, the Mac refuses a code it has let go.
        public init?(text: String) {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0] == "agents-pair", parts[1] == "1",
                  let key = Self.data(base64url: parts[2]), key.count == 65, key.first == 0x04,
                  let secret = Self.data(base64url: parts[3]), secret.count == 32,
                  let name = parts[4].removingPercentEncoding
            else { return nil }
            self.init(macKey: key, secret: secret, name: name, expires: .distantFuture)
        }

        static func base64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }

        static func data(base64url text: String) -> Data? {
            var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base.count % 4 != 0 { base += "=" }
            return Data(base64Encoded: base)
        }
    }

    /// `pairing/current`: the secret the bridge's listener should take, if any.
    public struct PairingSecret: Codable, Sendable, Hashable {
        public var secret: Data?
        public var expires: Date?

        public init(secret: Data?, expires: Date?) {
            self.secret = secret
            self.expires = expires
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

    /// `device/changed`: the whole record, or that it was forgotten (046).
    public struct DeviceNotification: Codable, Sendable, Hashable {
        public var id: UUID
        public var device: Device?
        public var removed: Bool?

        public init(_ device: Device) {
            self.id = device.id
            self.device = device
        }

        public init(removed id: UUID) {
            self.id = id
            self.removed = true
        }
    }

    /// `devices/forget`.
    public struct DeviceForget: Codable, Sendable {
        public var id: UUID
        public init(id: UUID) { self.id = id }
    }

    /// `relay/register`: the public half of the Mac's relay key, X9.63.
    public struct RelayRegistration: Codable, Sendable {
        public var publicKey: Data
        public init(publicKey: Data) { self.publicKey = publicKey }
    }

    /// What `devices/announce` answers: the device's record, as it always was, with the
    /// Mac's relay key beside its fields when a bridge has registered one (046). The one
    /// object is both, so a phone from before 046 decodes the record and keeps `macKey`
    /// among the fields it does not know. Kept past the #58 cut-off: the flat shape is
    /// the protocol now, and the bridge path it travels is 058 T106/T042's to replace.
    public struct AnnounceReply: Codable, Sendable, Hashable {
        public var device: Device
        public var macKey: Data?

        public init(device: Device, macKey: Data?) {
            self.device = device
            self.macKey = macKey
        }

        private enum CodingKeys: String, CodingKey { case macKey }

        public init(from decoder: any Decoder) throws {
            var device = try Device(from: decoder)
            device.unknownFields.removeValue(forKey: CodingKeys.macKey.stringValue)
            self.device = device
            macKey = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Data.self, forKey: .macKey)
        }

        public func encode(to encoder: any Encoder) throws {
            try device.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(macKey, forKey: .macKey)
        }
    }

    /// `presence/report`. Three small fields, sent on a change and never on a timer.
    /// **No timestamp**: a contract term, not an omission — the daemon's clock stamps it.
    public struct PresenceReport: Codable, Sendable {
        public var watching: UUID?
        public var active: Bool
        /// Whether this surface may show notifications; omitted means unchanged.
        public var mayNotify: Bool?
        /// The conversation this connection has open, whether or not anybody is looking at
        /// it: a window behind another app still shows its chat. What decides where that
        /// agent's entries and terminal output go (#203). Omitted, `watching` stands in, as
        /// it did for a client from before.
        public var showing: UUID?

        public init(watching: UUID?, active: Bool, mayNotify: Bool? = nil, showing: UUID? = nil) {
            self.watching = watching
            self.active = active
            self.mayNotify = mayNotify
            self.showing = showing
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
    /// What this host keeps that could not be read in this run (#205), one sentence a
    /// file: set aside and started afresh, held and not written, or kept in part. Empty
    /// when everything read.
    struct StoreNotes: Codable, Hashable, Sendable {
        public var notes: [String]

        public init(notes: [String]) {
            self.notes = notes
        }
    }

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
    /// `credentials/offer` (043).
    struct CredentialsOffer: Codable, Hashable, Sendable {
        public var runtimes: [String]
        public var ownSignInOnly: Bool
        /// Runtimes whose sign-in this window would relay but cannot now, and why (056), so
        /// a server can say "not signed in" or "couldn't read it". Absent from older windows.
        public var notRelayed: [String: SignInWanted.Reason]?
        /// Runtimes whose file sign-in this window can lend from its Mac (049: OpenCode), so a
        /// start there asks for it first. Absent from older windows.
        public var signIns: [String]?

        public init(runtimes: [String], ownSignInOnly: Bool, notRelayed: [String: SignInWanted.Reason]? = nil,
                    signIns: [String]? = nil) {
            self.runtimes = runtimes
            self.ownSignInOnly = ownSignInOnly
            self.notRelayed = notRelayed
            self.signIns = signIns
        }
    }

    /// The `data` of a `signInWanted` failure (056, contracts/relay.md).
    struct SignInWanted: Codable, Hashable, Sendable {
        public enum Reason: String, Codable, Hashable, Sendable {
            /// No sign-in on the Mac the relay can lend: none, or not a Claude account's.
            case notSignedIn
            /// There is one, and the Mac could not read it.
            case unreadable
        }
        public var runtime: String
        public var reason: Reason

        public init(runtime: String, reason: Reason) {
            self.runtime = runtime
            self.reason = reason
        }
    }

    /// `relay/offer` (047): the Mac lends a runtime its own sign-in through a relay, without
    /// the sign-in ever reaching the server. `socketPath` is the server end of the window's
    /// reverse forward to the relay (made owner-only by sshd); `caCertificate` is the PEM the
    /// runtime is told to trust for it; `standIn` is a sign-in file with no secret in it.
    struct RelayOffer: Codable, Hashable, Sendable {
        public var runtime: String
        public var socketPath: String
        public var caCertificate: String
        public var standIn: String

        public init(runtime: String, socketPath: String, caCertificate: String, standIn: String) {
            self.runtime = runtime
            self.socketPath = socketPath
            self.caCertificate = caCertificate
            self.standIn = standIn
        }
    }

    /// `credentials/lend` (043). The one message that carries a credential's text. It is
    /// never logged: the server prints only the method's name for it.
    struct CredentialsLend: Codable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
        public var runtime: String
        public var kind: CredentialKind
        public var secret: String

        public var description: String { "CredentialsLend(\(runtime), \(kind.rawValue))" }
        public var customMirror: Mirror { Mirror(self, children: ["runtime": runtime, "kind": kind]) }

        public init(runtime: String, secret: Secret) {
            self.runtime = runtime
            self.kind = secret.kind
            self.secret = secret.reveal()
        }
    }

    /// `credentials/lendSignIn` (049): the lendable part of this Mac's file sign-in for one
    /// runtime, as the text of the file. Empty for nothing to lend, so a start that asked goes
    /// on without. Prints as a provider count only.
    struct SignInLend: Codable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
        public var runtime: String
        public var content: String
        public var providers: Int

        public var description: String { "SignInLend(\(runtime), \(providers) providers)" }
        public var customMirror: Mirror { Mirror(self, children: ["runtime": runtime, "providers": providers]) }

        public init(runtime: String, content: LentSignInContent?) {
            self.runtime = runtime
            self.content = content?.reveal() ?? ""
            self.providers = content?.providers ?? 0
        }
    }

    /// `credentials/refused` (043): which agent stopped, and whether it was the token this
    /// window lent (`lent`) or the server's own sign-in that was refused.
    struct CredentialRefused: Codable, Hashable, Sendable {
        public var agentID: UUID
        public var runtime: String
        public var lent: Bool
        /// The refused sign-in was this Mac's own, relayed (056): signing in on the Mac is
        /// the remedy, not Settings. Absent from older daemons.
        public var relayed: Bool?
        /// The refused key was one this Mac's sign-in file lent (049: OpenCode's): replacing
        /// it on the Mac is the remedy. Absent from older daemons.
        public var borrowed: Bool?

        public init(agentID: UUID, runtime: String, lent: Bool, relayed: Bool? = nil, borrowed: Bool? = nil) {
            self.agentID = agentID
            self.runtime = runtime
            self.lent = lent
            self.relayed = relayed
            self.borrowed = borrowed
        }
    }

    /// `runtime/signInNeeded`: which runtime wants signing in, and the agent it stopped.
    struct SignInNeeded: Codable, Hashable, Sendable {
        public var runtimeID: String
        public var agentID: UUID?

        public init(runtimeID: String, agentID: UUID?) {
            self.runtimeID = runtimeID
            self.agentID = agentID
        }
    }

    /// The `data` of a `credentialWanted` failure (043).
    struct CredentialWanted: Codable, Hashable, Sendable {
        public var runtime: String
        /// The connection offered a credential for this runtime: the window has one and
        /// can lend it without asking. False means it has none to lend.
        public var offered: Bool

        public init(runtime: String, offered: Bool) {
            self.runtime = runtime
            self.offered = offered
        }
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

    /// `dropbox/put` (#231). `folder` is the project's main folder, never a worktree;
    /// `subfolder` a path inside the drop box, empty or nil for its top. `data` travels as
    /// base64 in the JSON, so it is held to `dropboxPutLimit`; a file copied into the
    /// folder by any other means has no limit.
    struct DropboxPutRequest: Codable, Hashable, Sendable {
        public var folder: URL
        public var subfolder: String?
        public var name: String
        public var data: Data
        public init(folder: URL, subfolder: String? = nil, name: String, data: Data) {
            self.folder = folder
            self.subfolder = subfolder
            self.name = name
            self.data = data
        }
    }

    struct DropboxPutResponse: Codable, Hashable, Sendable {
        /// Where the file now is, absolute, on the project's host.
        public var path: String
        public init(path: String) { self.path = path }
    }

    /// The most `dropbox/put` carries: what one message over the phone's link takes.
    static let dropboxPutLimit = attachmentLimit

    // MARK: Deleting archived agents (051, #398)

    /// `retention/state`, and what `retention/changed` carries.
    struct RetentionState: Codable, Hashable, Sendable {
        public var settings: RetentionSettings
        public var archivedCount: Int
        public var archivedBytes: Int

        public init(settings: RetentionSettings, archivedCount: Int, archivedBytes: Int) {
            self.settings = settings
            self.archivedCount = archivedCount
            self.archivedBytes = archivedBytes
        }
    }

    struct RetentionSetRequest: Codable, Sendable {
        public var settings: RetentionSettings
        /// Without it, a change that would delete agents at once is only described.
        public var confirmed: Bool

        public init(settings: RetentionSettings, confirmed: Bool) {
            self.settings = settings
            self.confirmed = confirmed
        }
    }

    /// How many agents a change of setting would delete at once, and what that frees.
    struct DeletePreview: Codable, Hashable, Sendable {
        public var count: Int
        public var bytes: Int

        public init(count: Int, bytes: Int) {
            self.count = count
            self.bytes = bytes
        }
    }

    struct RetentionSetResult: Codable, Sendable {
        public var applied: Bool
        /// When not applied: what it would delete.
        public var wouldDelete: DeletePreview?
        /// When applied: the state after.
        public var state: RetentionState?

        public init(applied: Bool, wouldDelete: DeletePreview? = nil, state: RetentionState? = nil) {
            self.applied = applied
            self.wouldDelete = wouldDelete
            self.state = state
        }
    }

    struct AgentRemovedNotification: Codable, Sendable {
        public var agentID: UUID
        public init(agentID: UUID) { self.agentID = agentID }
    }
}
