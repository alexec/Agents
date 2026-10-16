package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"sort"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// register is every method this host serves. One it does not answers -32601, which the
// window copes with: a pane that needs it stays empty (#1125, stage 5).
func (d *Daemon) register() {
	On(d, wire.CallDaemonPing, func(context.Context, *Client, wire.Empty) (wire.PingResponse, error) {
		return wire.PingResponse{Ok: true}, nil
	})
	// What the window pushes or reports on connecting, which this host has no use for yet.
	Quiet(d, wire.CallPresenceReport.Name, wire.CallCredentialsOffer.Name, wire.CallAgentsPrewarm.Name,
		wire.CallAgentsDiscardDraft.Name)
	d.registerFiles()
	d.registerShells()
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
		return d.runtimeStatuses(), nil
	})
	// relay/offer: a sign-in lent by another host (056, T091), from the window's lend.
	On(d, wire.CallRelayOffer, func(ctx context.Context, c *Client, o wire.RelayOffer) (wire.Empty, error) {
		if o.Runtime == "" {
			return wire.Empty{}, Invalid("relay/offer: no runtime")
		}
		return wire.Empty{}, d.offerRelay(o)
	})

	On(d, wire.CallProjectsList, func(ctx context.Context, c *Client, r wire.ProjectsListRequest) ([]wire.ProjectSummary, error) {
		return d.projects(r.IncludeArchived), nil
	})
	On(d, wire.CallProjectsAdd, func(ctx context.Context, c *Client, r wire.ProjectRequest) (wire.ProjectSummary, error) {
		return d.addProject(r.Folder)
	})

	On(d, wire.CallAgentsList, func(ctx context.Context, c *Client, r wire.ListRequest) ([]wire.Agent, error) {
		return d.listAgents(r), nil
	})
	On(d, wire.CallAgentsStart, func(ctx context.Context, c *Client, r wire.StartRequest) (wire.UUID, error) {
		return d.start(r)
	})
	On(d, wire.CallAgentsPrompt, func(ctx context.Context, c *Client, r wire.PromptRequest) (wire.Empty, error) {
		a := d.Store.Agent(r.AgentID)
		if a == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		if err := d.needsSignIn(a.RuntimeID); err != nil {
			return wire.Empty{}, err
		}
		if d.once(r.SendID) {
			d.live(a.ID).enqueue(r.Text)
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsStop, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Empty, error) {
		if d.Store.Agent(r.AgentID) == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		d.live(r.AgentID).cancel()
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsArchive, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Empty, error) {
		return wire.Empty{}, d.archive(r.AgentID)
	})
	On(d, wire.CallAgentsSetUnread, func(ctx context.Context, c *Client, r wire.SetUnreadRequest) (wire.Empty, error) {
		if d.change(r.AgentID, func(a *wire.Agent) { a.IsUnread = &r.Unread }) == nil {
			return wire.Empty{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsTranscript, func(ctx context.Context, c *Client, r wire.TranscriptRequest) (wire.TranscriptPage, error) {
		return d.transcript(r)
	})
	On(d, wire.CallAgentsTurns, func(ctx context.Context, c *Client, r wire.TurnsRequest) (wire.TurnsPage, error) {
		// No summaries yet: the window then loads the chat as one open turn.
		return wire.TurnsPage{Turns: []wire.TurnSummary{}}, nil
	})
}

// MARK: projects

// projects is the union of every folder an agent is in and every project kept in
// projects.json (DaemonCore.allProjects), newest activity first.
func (d *Daemon) projects(includeArchived bool) []wire.ProjectSummary {
	records := map[string]wire.Project{}
	for _, p := range d.Store.Projects() {
		records[store.FolderPath(p.Folder)] = p
	}
	agents := map[string][]wire.Agent{}
	for _, a := range d.Store.Agents() {
		f := projectFolder(&a)
		agents[f] = append(agents[f], a)
	}
	folders := map[string]bool{}
	for f := range records {
		folders[f] = true
	}
	for f := range agents {
		folders[f] = true
	}
	var out []wire.ProjectSummary
	for f := range folders {
		s := summary(f, records, agents[f])
		if !includeArchived && s.Project.ArchivedAt != nil {
			continue
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].Project.Folder < out[j].Project.Folder
	})
	if out == nil {
		out = []wire.ProjectSummary{}
	}
	return out
}

func projectFolder(a *wire.Agent) string {
	if a.Worktree != nil && a.Worktree.Project != "" {
		return store.FolderPath(a.Worktree.Project)
	}
	return store.FolderPath(a.Cwd)
}

func summary(folder string, records map[string]wire.Project, agents []wire.Agent) wire.ProjectSummary {
	p, ok := records[folder]
	if !ok {
		p = wire.Project{Folder: store.FolderURL(folder)}
		for i, a := range agents {
			if i == 0 || a.CreatedAt < p.AddedAt {
				p.AddedAt = a.CreatedAt
			}
		}
	}
	newest := p.AddedAt
	counts := map[string]int64{}
	cost := map[string]float64{}
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
	return wire.ProjectSummary{
		Project:        p,
		Name:           filepath.Base(folder),
		Exists:         err == nil && fi.IsDir(),
		LastActivityAt: newest,
		Counts:         countsOf(counts),
		CostToDate:     cost,
	}
}

func countsOf(m map[string]int64) wire.ProjectSummaryCounts {
	n := func(k string) *int64 {
		if v, ok := m[k]; ok {
			return &v
		}
		return nil
	}
	return wire.ProjectSummaryCounts{NeedsAttention: n("needsAttention"), Waiting: n("waiting"), Running: n("running"),
		Finished: n("finished"), Stopped: n("stopped"), Archived: n("archived")}
}

func (d *Daemon) addProject(folder wire.URL) (wire.ProjectSummary, error) {
	path := store.FolderPath(folder)
	if r, err := filepath.EvalSymlinks(path); err == nil {
		path = r
	}
	if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
		return wire.ProjectSummary{}, &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	ps := d.Store.Projects()
	found := false
	for _, p := range ps {
		if store.FolderPath(p.Folder) == path {
			found = true
		}
	}
	if !found {
		ps = append(ps, wire.Project{Folder: store.FolderURL(path), AddedAt: wire.DateOf(nowFunc())})
		if err := d.Store.SaveProjects(ps); err != nil {
			return wire.ProjectSummary{}, err
		}
	}
	for _, s := range d.projects(true) {
		if store.FolderPath(s.Project.Folder) == path {
			Broadcast(d, wire.NotifyProjectChanged, s)
			return s, nil
		}
	}
	return wire.ProjectSummary{}, &Error{Code: CodeNoSuchProject, Message: path + " could not be added."}
}

// MARK: agents

// archive puts an agent away: its turn stopped and its runtime ended first.
func (d *Daemon) archive(id wire.UUID) error {
	if d.Store.Agent(id) == nil {
		return &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	l := d.live(id)
	l.cancel()
	l.mu.Lock()
	s := l.session
	l.session = nil
	l.mu.Unlock()
	if s != nil {
		s.Stop()
	}
	t := now()
	byUser := wire.AgentArchivedReasonByUser
	d.change(id, func(a *wire.Agent) {
		a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &t, &byUser
	})
	d.record(id, stateChanged(wire.AgentStateArchived, nil))
	return nil
}

// listAgents is agents/list: newest activity first, a page after a cursor.
func (d *Daemon) listAgents(r wire.ListRequest) []wire.Agent {
	if r.AgentID != nil {
		if a := d.Store.Agent(*r.AgentID); a != nil {
			return []wire.Agent{*a}
		}
		return []wire.Agent{}
	}
	limit := int64(-1)
	if r.Limit != nil && *r.Limit > 0 {
		limit = *r.Limit
	}
	out := []wire.Agent{}
	for _, a := range d.Store.Agents() {
		archived := a.State == wire.AgentStateArchived
		if archived && !r.IncludeArchived && !r.ArchivedOnly || r.ArchivedOnly && !archived {
			continue
		}
		if r.Folder != nil && projectFolder(&a) != store.FolderPath(*r.Folder) {
			continue
		}
		if r.StartedByWorkflow != nil && (a.StartedByWorkflow == nil || *a.StartedByWorkflow != *r.StartedByWorkflow) {
			continue
		}
		if c := r.After; c != nil && (a.LastActivityAt > c.LastActivityAt || a.LastActivityAt == c.LastActivityAt && a.ID <= c.ID) {
			continue
		}
		out = append(out, a)
		if int64(len(out)) == limit {
			break
		}
	}
	return out
}

// maxPage is the most entries one transcript page carries (TranscriptRequest.bounded).
const maxPage = 500

func (d *Daemon) transcript(r wire.TranscriptRequest) (wire.TranscriptPage, error) {
	if d.Store.Agent(r.AgentID) == nil {
		return wire.TranscriptPage{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
	}
	if r.Limit < 0 || r.Before != nil && *r.Before < 0 || r.From != nil && *r.From < 0 {
		return wire.TranscriptPage{}, Invalid("a transcript page is counted from zero")
	}
	limit := min(r.Limit, maxPage)
	entries, at, err := d.Store.Transcript(r.AgentID, 0)
	if err != nil {
		return wire.TranscriptPage{}, err
	}
	total := int64(len(at))
	if total > 0 {
		total = int64(at[len(at)-1] + 1)
	}
	end := total
	if r.Before != nil {
		end = min(*r.Before, total)
	}
	if r.From != nil {
		limit = max(0, min(limit, end-*r.From))
	}
	start := end - min(limit, end)
	page := wire.TranscriptPage{FirstIndex: start, Total: total, Entries: []wire.TranscriptEntry{}}
	for i, e := range entries {
		if int64(at[i]) >= start && int64(at[i]) < end {
			page.Entries = append(page.Entries, e)
		}
	}
	return page, nil
}
