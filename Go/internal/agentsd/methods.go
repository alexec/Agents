package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"sort"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// register is every method this host serves. One it does not answers -32601, which the
// window copes with: a pane that needs it stays empty (#1125, stage 5).
func (d *Daemon) register() {
	On(d, wire.CallDaemonPing, func(context.Context, *Client, wire.Empty) (wire.PingResponse, error) {
		return wire.PingResponse{Ok: true}, nil
	})
	d.registerWarmPool()
	d.registerRequests()
	// No runtime takes a pasted key now that Gemini, the last one that did, is retired
	// (#3043): a window still offers its (always empty) list on every connect.
	Quiet(d, wire.CallCredentialsOffer.Name)
	d.registerFiles()
	d.registerFeatures()
	d.registerMac()
	d.registerAgents()
	d.registerPins()
	d.registerReviews()
	d.registerSuggestions()
	d.registerSettings()
	d.registerHost()
	d.registerProblemReport()
	d.registerBackups()
	d.registerLockHello()
	d.registerFirstBuild()
	d.registerLockReset()
	d.registerReceive()
	d.registerSend()
	d.registerFolderSend()
	d.registerFolderBringBack()
	d.registerExports()
	d.registerBringBack()
	d.registerLeases()
	d.registerAttention()
	d.registerWorktrees()
	d.registerChanges()
	d.registerTurnUndo()
	d.registerBrowserWatch()
	d.registerFolders()
	d.registerGuarded()
	d.registerEvents()
	d.registerEventWaits()
	d.registerCost()
	d.registerLineage()
	d.registerLineageSessions()
	d.registerLineageFigures()
	d.registerBuilds()
	d.registerForge()
	d.registerMessages()
	d.registerWorkTimeline()
	d.registerWorkFeatures()
	d.registerDocs()
	d.registerDevices()
	d.registerAllowances()
	d.registerAccounts()
	d.sweepOrgAccountFolders()
	d.registerContinueWhenBack()
	d.registerMCP()
	d.registerOptions()
	d.registerInstall()
	d.registerSandbox()
	d.registerDesktopControl()
	d.registerBrowserControl()
	d.registerBrowserSettings()
	d.registerSessionSecrets()
	d.registerSealedSecrets()
	d.registerLocalSecrets()
	d.registerSecretUse()
	d.registerSecretTerminal()
	d.registerDesktopControlPause()
	d.registerAuto()
	d.registerMoves()
	d.registerMoveIn()
	d.registerRuntimeSessions()
	d.registerRuntimeAuth()
	d.registerHeadlessSignIn()
	d.registerWorkflows()
	d.registerDailySummary()
	d.registerSummaryPages()
	d.registerShells()
	d.registerSkills()
	d.registerAgentConfigEditor()
	d.registerShared()
	d.registerPlugins()
	d.registerWake()
	d.registerSelfUpdate()
	d.registerMacSignIn()
	d.registerCatalog()
	d.registerPersonaCatalog()
	d.registerSimulators()
	d.registerLanguageServers()
	d.registerMCPCatalog()
	d.registerMCPVerify()
	d.registerMCPSignIn()
	d.registerConnections()
	d.registerGitHubBot()
	d.registerGitHubBotCopies()
	d.registerConnectorSetup()
	d.registerAssess()
	d.registerHostedMCP()
	d.registerViews()
	d.registerPolicy()
	d.registerPolicyYours()
	d.registerPolicyFolder()
	d.registerMCPTools()
	// Person settings sync across machines, but local edits remain allowed (#2410).
	d.registerUserScope()
	On(d, wire.CallPermissionsPending, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.PermissionRequest, error) {
		return d.pendingPermissions(), nil
	})
	On(d, wire.CallPermissionsAnswer, func(ctx context.Context, c *Client, r wire.AnswerRequest) (wire.Empty, error) {
		d.mu.Lock()
		ls := make([]*live, 0, len(d.lives))
		for _, l := range d.lives {
			ls = append(ls, l)
		}
		d.mu.Unlock()
		for _, l := range ls {
			if l.answer(r.PermissionID, r.OptionID) {
				return wire.Empty{}, nil
			}
		}
		return wire.Empty{}, Invalid("no such question is waiting")
	})
	On(d, wire.CallElicitationsPending, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.ElicitationRequest, error) {
		return d.pendingElicitations(), nil
	})
	On(d, wire.CallElicitationsAnswer, func(ctx context.Context, c *Client, r wire.AnswerElicitationRequest) (wire.Empty, error) {
		if !d.once(r.SendID) {
			return wire.Empty{}, nil
		}
		return wire.Empty{}, d.answerElicitation(r)
	})
	On(d, wire.CallRuntimesList, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.RuntimeStatus, error) {
		return d.markRuntimes(d.runtimeStatuses()), nil
	})
	// relay/offer: a sign-in lent by another host (056, T091), from the window's lend.
	On(d, wire.CallRelayOffer, func(ctx context.Context, c *Client, o wire.RelayOffer) (wire.Empty, error) {
		if o.Runtime == "" {
			return wire.Empty{}, Invalid("relay/offer: no runtime")
		}
		return wire.Empty{}, d.offerRelay(o)
	})

	On(d, wire.CallFoldersList, func(ctx context.Context, c *Client, r wire.FoldersListRequest) ([]wire.FolderSummary, error) {
		return d.folders(r.IncludeArchived), nil
	})
	On(d, wire.CallFoldersAdd, func(ctx context.Context, c *Client, r wire.AddFolderRequest) (wire.FolderSummary, error) {
		// The project picked in the Add Folder sheet (#2671), written as the folder is added,
		// so the control plane never adopts a project of the folder's own name first.
		pick := ""
		if r.Project != nil {
			if !wire.ValidProjectID(*r.Project) {
				return wire.FolderSummary{}, Invalid("%q is not a project id.", *r.Project)
			}
			pick = *r.Project
		}
		return d.addFolderOf(r.Folder, true, pick)
	})

	On(d, wire.CallAgentsList, func(ctx context.Context, c *Client, r wire.ListRequest) ([]wire.Agent, error) {
		return d.agentsList(r)
	})
	On(d, wire.CallAgentsStart, func(ctx context.Context, c *Client, r wire.StartRequest) (wire.UUID, error) {
		// An agent on another machine asked for it (#2887): its labels are an agent's.
		if r.StartedFrom != nil {
			id, err := d.startFor(r, startedBy{owner: wire.SessionLabelOwnerAgent, actor: c.actor()})
			if err == nil {
				d.noteStartedHere(id, *r.StartedFrom)
			}
			return id, err
		}
		return d.startAs(r, c.actor())
	})
	// Sessions on another machine (#2927), from the control plane.
	On(d, wire.CallAgentsFromStarter, func(ctx context.Context, c *Client, r wire.SessionCall) (wire.SessionCallReply, error) {
		return d.fromStarter(r)
	})
	On(d, wire.CallAgentsEndedElsewhere, func(ctx context.Context, c *Client, r wire.SessionEnded) (wire.Empty, error) {
		return wire.Empty{}, d.endedElsewhere(r)
	})
	On(d, wire.CallAgentsStop, func(ctx context.Context, c *Client, r wire.AgentStopRequest) (wire.Empty, error) {
		if d.Store.Agent(r.AgentID) == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		d.actedOn(r.AgentID, c.actor())
		d.noteAdminStop(r.AgentID, r.ByAdmin != nil && *r.ByAdmin)
		d.live(r.AgentID).cancel()
		d.cancelContinue(r.AgentID)
		d.dropLeases(r.AgentID, "holderStopped")
		d.endWait(r.AgentID, "stopped", false)
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsArchive, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Empty, error) {
		d.actedOn(r.AgentID, c.actor())
		return wire.Empty{}, d.archive(r.AgentID)
	})
	On(d, wire.CallAgentsSetUnread, func(ctx context.Context, c *Client, r wire.SetUnreadRequest) (wire.Empty, error) {
		if d.change(r.AgentID, func(a *wire.Agent) {
			a.IsUnread = &r.Unread
			if !r.Unread {
				a.FileToSee = nil // Mark as Read clears the file's mark too (#1802)
			}
		}) == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsSetMuted, func(ctx context.Context, c *Client, r wire.SetMutedRequest) (wire.Empty, error) {
		if d.setMuted(r.AgentID, r.Muted) == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsTranscript, func(ctx context.Context, c *Client, r wire.TranscriptRequest) (wire.TranscriptPage, error) {
		return d.transcript(r)
	})
	On(d, wire.CallAgentsTurns, func(ctx context.Context, c *Client, r wire.TurnsRequest) (wire.TurnsPage, error) {
		return d.turns(r)
	})
}

// MARK: folders

// folders is the union of every folder an agent is in and every folder kept in
// folders.json (DaemonCore.allFolders), newest activity first.
// folderPaths is every folders(false) lists, undressed: what a caller holding
// workflowMu may ask for, since dressing a summary reads the workflows (#1322).
func (d *Daemon) folderPaths() []string {
	seen := map[string]bool{}
	var out []string
	add := func(f string) {
		if !seen[f] {
			seen[f] = true
			out = append(out, f)
		}
	}
	archived := map[string]bool{}
	for _, p := range d.Store.Folders() {
		f := store.FolderPath(p.Folder)
		if p.ArchivedAt != nil {
			archived[f] = true
			continue
		}
		add(f)
	}
	for _, f := range d.Store.AgentFolders() {
		if !archived[f] && !seen[f] {
			// As summary names a folder with no record: its links resolved.
			add(store.FolderPath(store.FolderURL(f)))
		}
	}
	return out
}

func (d *Daemon) folders(includeArchived bool) []wire.FolderSummary {
	records := map[string]wire.Folder{}
	for _, p := range d.Store.Folders() {
		records[store.FolderPath(p.Folder)] = p
	}
	folders := map[string]bool{}
	for f := range records {
		folders[f] = true
	}
	for _, f := range d.Store.AgentFolders() {
		folders[f] = true
	}
	var out []wire.FolderSummary
	for f := range folders {
		// Each folder's live records, and its archived ones as the store keeps them summed
		// (#4510), not every record copied.
		agents := d.Store.LiveAgentsIn(f)
		s := summary(f, records, agents, d.Store.ArchivedIn(f))
		if !includeArchived && s.Folder.ArchivedAt != nil {
			continue
		}
		d.dress(&s, agents)
		d.markHelperLimits(&s)
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].Folder.Folder < out[j].Folder.Folder
	})
	if out == nil {
		out = []wire.FolderSummary{}
	}
	return out
}

// folderSummary is one folder's summary, built from its own record and agents alone:
// dress and markHelperLimits run once for it, not once for every folder as folders(true)
// would, to throw away all but one (#4504, #4506). False when the folder is tracked by
// neither a record nor an agent.
func (d *Daemon) folderSummary(folder string) (wire.FolderSummary, bool) {
	var record wire.Folder
	found := false
	for _, p := range d.Store.Folders() {
		if store.FolderPath(p.Folder) == folder {
			record = p
			found = true
			break
		}
	}
	agents := d.Store.LiveAgentsIn(folder)
	archived := d.Store.ArchivedIn(folder)
	if !found && len(agents) == 0 && archived.Count == 0 {
		return wire.FolderSummary{}, false
	}
	records := map[string]wire.Folder{}
	if found {
		records[folder] = record
	}
	s := summary(folder, records, agents, archived)
	d.dress(&s, agents)
	d.markHelperLimits(&s)
	return s, true
}

func folderPath(a *wire.Agent) string { return store.AgentFolder(a) }

// summary is a folder's summary from its record, its live agents and its archived ones
// summed (store.ArchivedIn, #4510).
func summary(folder string, records map[string]wire.Folder, agents []wire.Agent, archived store.ArchivedTally) wire.FolderSummary {
	p, ok := records[folder]
	if !ok {
		p = wire.Folder{Folder: store.FolderURL(folder)}
		if archived.Count > 0 {
			p.AddedAt = archived.FirstCreatedAt
		}
		for i, a := range agents {
			if i == 0 && archived.Count == 0 || a.CreatedAt < p.AddedAt {
				p.AddedAt = a.CreatedAt
			}
		}
	}
	newest := p.AddedAt
	if archived.LastActivityAt > newest {
		newest = archived.LastActivityAt
	}
	counts := map[string]int64{}
	if archived.Count > 0 {
		counts["archived"] = archived.Count
	}
	cost := map[string]float64{}
	for cur, v := range archived.CostToDate {
		cost[cur] += v
	}
	for _, a := range agents {
		if a.LastActivityAt > newest {
			newest = a.LastActivityAt
		}
		counts[Group(&a)]++
		for cur, v := range a.CostToDate {
			cost[cur] += v
		}
	}
	fi, err := os.Stat(folder)
	return wire.FolderSummary{
		Folder:         p,
		Name:           filepath.Base(folder),
		Exists:         err == nil && fi.IsDir(),
		LastActivityAt: newest,
		Counts:         countsOf(counts),
		CostToDate:     cost,
	}
}

func countsOf(m map[string]int64) wire.FolderSummaryCounts {
	n := func(k string) *int64 {
		if v, ok := m[k]; ok {
			return &v
		}
		return nil
	}
	return wire.FolderSummaryCounts{NeedsAttention: n("needsAttention"), Waiting: n("waiting"), Running: n("running"),
		Finished: n("finished"), Stopped: n("stopped"), Archived: n("archived")}
}

func (d *Daemon) addFolder(folder wire.URL) (wire.FolderSummary, error) {
	return d.addFolderOf(folder, true, "")
}

// addFolderOf adds a folder; with project, one that names no project gets one of its own
// (#2317), or the one picked (#2671). A folder sent from another machine does not: its
// project comes with it.
func (d *Daemon) addFolderOf(folder wire.URL, project bool, pick string) (wire.FolderSummary, error) {
	path := store.FolderPath(folder)
	if r, err := store.Resolve(path); err == nil {
		path = r
	}
	if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
		return wire.FolderSummary{}, &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	ps := d.Store.Folders()
	found := false
	for _, p := range ps {
		if store.FolderPath(p.Folder) == path {
			found = true
		}
	}
	if !found {
		ps = append(ps, wire.Folder{Folder: store.FolderURL(path), AddedAt: wire.DateOf(nowFunc())})
		if err := d.saveFolders(ps); err != nil {
			return wire.FolderSummary{}, err
		}
	}
	if pick != "" {
		d.putInProject(path, pick)
	} else if project {
		d.ensureProject(path)
	}
	d.sendJoinedSoon()
	for _, s := range d.folders(true) {
		if store.FolderPath(s.Folder.Folder) == path {
			Broadcast(d, wire.NotifyFolderChanged, s)
			// A pins.json already in the folder is said now (#1622): a client reads pins/list only
			// when it connects, and the watcher says pins/changed only when the file changes.
			if pp := d.folderPins(path); len(pp.Pins) > 0 || len(pp.Sessions) > 0 || len(pp.Workflows) > 0 {
				Broadcast(d, wire.NotifyPinsChanged, wire.PinsChangedNotification{Folder: pp.Folder, Pins: pp.Pins,
					Sessions: pp.Sessions, Workflows: pp.Workflows})
			}
			return s, nil
		}
	}
	return wire.FolderSummary{}, &Error{Code: CodeNoSuchFolder, Message: path + " could not be added."}
}

// MARK: agents

// archive puts an agent away, then stops its turn and ends its runtime.
func (d *Daemon) archive(id wire.UUID) error {
	return d.archiveBy(id, wire.AgentArchivedReasonByUser)
}

// archiveBy archives an agent, by the person or by an agent (Agent.ArchivedReason).
func (d *Daemon) archiveBy(id wire.UUID, by wire.AgentArchivedReason) error {
	return d.archiveSweeping(id, by, sweepArchived)
}

// archiveSweeping is archiveBy, with its worktree then removed on the terms of sweep
// (#3726).
func (d *Daemon) archiveSweeping(id wire.UUID, by wire.AgentArchivedReason, sweep worktreeSweep) error {
	if d.Store.Agent(id) == nil {
		return &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	t := now()
	d.change(id, func(a *wire.Agent) {
		a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &t, &by
		a.ArchiveRequest, a.AfterTurn, a.ContinueWhenBack, a.RunningTool = nil, nil, nil, nil
	})
	d.record(id, stateChanged(wire.AgentStateArchived, nil))
	// Its secrets for this session only go now (#3548): its agent is told they expired.
	d.expireSessionSecrets(id)
	// Archived first, then its turn and runtime ended: the turn's ending finds it archived
	// and leaves it so (#1611).
	d.live(id).halt()
	d.dropRequestsOf(id, wire.RequestDroppedWhyAskerEnded) // a lost form too (#4990)
	if a := d.Store.Agent(id); a != nil {
		details := map[string]string{"by": "you"}
		if by == wire.AgentArchivedReasonByAgent {
			details["by"] = "agent"
		}
		if a.Report != nil {
			details["outcome"] = string(a.Report.Outcome)
		}
		d.raiseAgentEvent("agent.archived", id, "was archived.", details)
	}
	d.dropLeases(id, "holderArchived")
	d.endWait(id, "archived", false)
	if a := d.Store.Agent(id); a != nil {
		d.checkQueueSoon(folderPath(a))
	}
	d.agentEnded(id)
	d.forgetAgentInMemory(id)
	// An archived session is not kept pinned (unpinArchived).
	if a := d.Store.Agent(id); a != nil {
		d.unpinSession(folderPath(a), id)
		d.sweepWorktreeSoon(*a, sweep)
	}
	return nil
}

// listed is one agent as agents/list gives it: lean when asked, and an archived agent's
// commands left out unless asked for.
func (d *Daemon) listed(a wire.Agent, r wire.ListRequest) wire.Agent {
	if r.Lean {
		return leaned(a)
	}
	// The store holds an archived agent without its commands (#4653): read when asked for.
	if a.State == wire.AgentStateArchived {
		a.AvailableCommands = []wire.SlashCommand{}
		if r.ArchivedCommands {
			a.AvailableCommands = d.Store.Commands(a.ID)
		}
	}
	return a
}

// archivedOrder is what an archived-only list is in order of (#2153): when the agent was
// archived, or its last activity for a record from before archivedAt.
func archivedOrder(a *wire.Agent) wire.Date {
	if a.ArchivedAt != nil {
		return *a.ArchivedAt
	}
	return a.LastActivityAt
}

// agentsList is agents/list: a point the store cannot vouch for is refused (#4785), and the
// client asks for the whole list.
func (d *Daemon) agentsList(r wire.ListRequest) ([]wire.Agent, error) {
	if r.ChangedSince != nil && !d.Store.Vouches(*r.ChangedSince) {
		return nil, &Error{Code: wire.FailureRevisionGone, Message: "This host cannot say what changed since then. Ask for the whole list."}
	}
	return d.listAgents(r), nil
}

// listAgents is agents/list: newest activity first, a page after a cursor. An archived-only
// list is newest archived first (#2153), as the Archive shows it, so the page holds the ones
// put away last.
func (d *Daemon) listAgents(r wire.ListRequest) []wire.Agent {
	if r.AgentID != nil {
		if a := d.Store.Agent(*r.AgentID); a != nil {
			return []wire.Agent{withProject(d.listed(*a, r), projectOfFolder(folderPath(a)))}
		}
		return []wire.Agent{}
	}
	limit := int64(-1)
	if r.Limit != nil && *r.Limit > 0 && r.ChangedSince == nil {
		limit = *r.Limit
	}
	after := r.After
	if r.ChangedSince != nil {
		after = nil
	}
	out := []wire.Agent{}
	query := ""
	if r.Query != nil {
		query = *r.Query
	}
	read := 0
	issue := d.issueSearchOf(query)
	projects := projectsOfFolders{}
	var agents []wire.Agent
	switch {
	// Only what changed since (#4785), every one and archived ones too, whatever the list
	// asked: a client sees a session archived or brought back. No page.
	case r.ChangedSince != nil:
		agents = d.Store.AgentsChangedSince(r.ChangedSince.Revision)
	case r.IncludeArchived || r.ArchivedOnly:
		agents = d.Store.Agents()
	// A list with no archived agent in it reads only the live records (#4510).
	default:
		agents = d.Store.LiveAgents()
	}
	if r.ArchivedOnly && r.ChangedSince == nil {
		sort.SliceStable(agents, func(i, j int) bool {
			if a, b := archivedOrder(&agents[i]), archivedOrder(&agents[j]); a != b {
				return a > b
			}
			return agents[i].ID < agents[j].ID
		})
	}
	for _, a := range agents {
		archived := a.State == wire.AgentStateArchived
		if r.ChangedSince == nil && (archived && !r.IncludeArchived && !r.ArchivedOnly || r.ArchivedOnly && !archived) {
			continue
		}
		if r.Folder != nil && folderPath(&a) != store.FolderPath(*r.Folder) {
			continue
		}
		if r.StartedByWorkflow != nil && (a.StartedByWorkflow == nil || *a.StartedByWorkflow != *r.StartedByWorkflow) {
			continue
		}
		// The project's sessions on this machine (#3276): those whose folder names it.
		if r.Project != nil && projects.of(&a) != *r.Project {
			continue
		}
		if c := after; c != nil && !r.ArchivedOnly && (a.LastActivityAt > c.LastActivityAt || a.LastActivityAt == c.LastActivityAt && a.ID <= c.ID) {
			continue
		}
		if c := after; c != nil && r.ArchivedOnly {
			at := c.LastActivityAt
			if c.ArchivedAt != nil {
				at = *c.ArchivedAt
			}
			if o := archivedOrder(&a); o > at || o == at && a.ID <= c.ID {
				continue
			}
		}
		// A search (#165) asks for the sessions it matches; what was said is read for the
		// most recently active saidSessions only (#1585).
		if issue != nil {
			if !issue.matches(a) {
				continue
			}
		} else if query != "" {
			if read++; read > saidSessions && !d.titleMatches(a, query) || read <= saidSessions && !d.queryMatches(a, query) {
				continue
			}
		}
		out = append(out, withProject(d.listed(a, r), projects.of(&a)))
		if int64(len(out)) == limit {
			break
		}
	}
	return out
}

// maxPage is the most entries one transcript page carries (TranscriptRequest.bounded).
const maxPage = 500

func (d *Daemon) transcript(r wire.TranscriptRequest) (wire.TranscriptPage, error) {
	if !d.Store.Has(r.AgentID) {
		return wire.TranscriptPage{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
	}
	if r.Limit < 0 || r.Before != nil && *r.Before < 0 || r.From != nil && *r.From < 0 {
		return wire.TranscriptPage{}, Invalid("a transcript page is counted from zero")
	}
	limit := min(r.Limit, maxPage)
	// Only the page's lines are read and decoded (#91): a long chat costs no more.
	ends, err := d.Store.LineEnds(r.AgentID)
	if err != nil {
		return wire.TranscriptPage{}, err
	}
	total := int64(len(ends))
	end := total
	if r.Before != nil {
		end = min(*r.Before, total)
	}
	if r.From != nil {
		limit = max(0, min(limit, end-*r.From))
	}
	start := end - min(limit, end)
	page := wire.TranscriptPage{FirstIndex: start, Total: total, Entries: []wire.TranscriptEntry{}}
	entries, _, err := d.Store.Entries(r.AgentID, ends, int(start), int(end))
	if err != nil {
		return wire.TranscriptPage{}, err
	}
	page.Entries = append(page.Entries, entries...)
	return page, nil
}
