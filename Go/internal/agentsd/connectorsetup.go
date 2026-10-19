package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// A project's Connectors set-up (#1336): its GitHub repository (from its git remote), the
// person's GitHub connection (#1335), and four slots. Tasks, Code review and CI come with the
// connection, and each proves itself with one real read: the newest issue, the newest pull
// request, the last workflow run. Where agents run is This Mac. A tick is a read: once a slot
// has read, a read that does not reach GitHub keeps the tick, and only GitHub's refusal takes
// it away. Skips are the project's (.agents/project.json "connectors"); the reads are this
// host's (<root>/connector-setup.json, one record per project, only projects kept). Once a slot
// can read, the set-up turns on the github connector's events for the project, once: a person
// who takes the entry out again is not overruled.

var (
	// setupFresh is how long a read is used again before GitHub is asked again.
	setupFresh = 5 * time.Minute
	// setupReadLimit is all of one set-up's reads.
	setupReadLimit = 20 * time.Second
)

// githubSlots is the slots that come with the GitHub connection, in the page's order.
var githubSlots = []wire.ConnectorSlotKind{wire.ConnectorSlotKindTasks, wire.ConnectorSlotKindCodeReview, wire.ConnectorSlotKindCi}

var slotChoice = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "GitHub Issues",
	wire.ConnectorSlotKindCodeReview: "GitHub pull requests",
	wire.ConnectorSlotKindCi:         "GitHub Actions",
	wire.ConnectorSlotKindWorkspace:  "This Mac",
}

var slotThing = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "issues",
	wire.ConnectorSlotKindCodeReview: "pull requests",
	wire.ConnectorSlotKindCi:         "Actions runs",
}

// setupReader is the reads a set-up makes; a test gives a fake GitHub.
type setupReader interface {
	NewestIssue(ctx context.Context, repo string) (*githubmcp.Newest, error)
	NewestPull(ctx context.Context, repo string) (*githubmcp.Newest, error)
	LastRun(ctx context.Context, repo string) (*githubmcp.Newest, error)
	AppReach(ctx context.Context, repo, slug string) (bool, int, error)
}

type setupBook struct {
	setupMu      sync.Mutex
	setupRecords map[string]*setupRecord // by folder; nil until read from disk
	// newSetupReader is GitHub as the token's owner; a test gives a fake.
	newSetupReader func(token string) setupReader
}

// setupRecord is what this host last read for one project.
type setupRecord struct {
	Repo         string                                 `json:"repo"`
	ReadAt       time.Time                              `json:"readAt"`
	Installed    *bool                                  `json:"installed,omitempty"`
	Repositories *int64                                 `json:"repositories,omitempty"`
	Slots        map[wire.ConnectorSlotKind]*slotRecord `json:"slots"`
	// EventsAdded is set once the set-up wrote the github entry, so it is never written again.
	EventsAdded bool `json:"eventsAdded,omitempty"`
}

type slotRecord struct {
	// Read is set once a read worked; Proof is nil when there was nothing to show.
	Read    bool                 `json:"read,omitempty"`
	Proof   *wire.ConnectorProof `json:"proof,omitempty"`
	ReadAt  time.Time            `json:"readAt,omitzero"`
	Refused bool                 `json:"refused,omitempty"`
	Failure string               `json:"failure,omitempty"`
}

func (d *Daemon) registerConnectorSetup() {
	On(d, wire.CallConnectorsSetup, func(ctx context.Context, c *Client, r wire.ConnectorSetupRequest) (wire.ConnectorSetup, error) {
		reading := wire.ConnectorSetupReadingCached
		if r.Reading != nil {
			reading = *r.Reading
		}
		return d.connectorSetup(ctx, r.Folder, reading)
	})
	On(d, wire.CallConnectorsSetupSkip, func(ctx context.Context, c *Client, r wire.ConnectorSkipRequest) (wire.ConnectorSetup, error) {
		return d.skipConnectorSlot(ctx, r)
	})
}

func (d *Daemon) setupPath() string { return filepath.Join(d.Store.Loc.Root, "connector-setup.json") }

// setupRecordsLocked reads the file once. setupMu is held.
func (d *Daemon) setupRecordsLocked() map[string]*setupRecord {
	if d.setupRecords == nil {
		d.setupRecords = map[string]*setupRecord{}
		if b, err := os.ReadFile(d.setupPath()); err == nil {
			if err := json.Unmarshal(b, &d.setupRecords); err != nil {
				// The reads are only a cache of GitHub's answers: read again from nothing.
				log.Printf("connectors: connector-setup.json could not be read, so the set-up reads again")
				d.setupRecords = map[string]*setupRecord{}
			}
		}
	}
	return d.setupRecords
}

// saveSetupLocked writes the records of projects this host still has. setupMu is held.
func (d *Daemon) saveSetupLocked() {
	for folder := range d.setupRecords {
		if _, ok := d.summaryFor(folder); !ok {
			delete(d.setupRecords, folder)
		}
	}
	b, err := json.Marshal(d.setupRecords)
	if err == nil {
		err = store.WriteAtomically(d.setupPath(), b, 0o600)
	}
	if err != nil {
		log.Printf("connectors: the set-up's reads were not kept: %v", err)
	}
}

// skippedSlots is the project's skips, from .agents/project.json as last approved.
func (d *Daemon) skippedSlots(folder string) map[wire.ConnectorSlotKind]bool {
	out := map[wire.ConnectorSlotKind]bool{}
	m, err := d.approvedConfig(folder)
	if err != nil {
		return out
	}
	c, _ := m["connectors"].(map[string]any)
	list, _ := c["skipped"].([]any)
	for _, v := range list {
		if s, ok := v.(string); ok {
			out[wire.ConnectorSlotKind(s)] = true
		}
	}
	return out
}

func (d *Daemon) setupProject(folder string) (string, error) {
	folder = filepath.Clean(folder)
	if _, ok := d.summaryFor(folder); !ok || !isDir(folder) {
		return "", noSuchProject(folder + " is not a project, or is not there.")
	}
	return folder, nil
}

func (d *Daemon) skipConnectorSlot(ctx context.Context, r wire.ConnectorSkipRequest) (wire.ConnectorSetup, error) {
	folder, err := d.setupProject(r.Folder)
	if err != nil {
		return wire.ConnectorSetup{}, err
	}
	if _, known := slotChoice[r.Slot]; !known || r.Slot == wire.ConnectorSlotKindWorkspace {
		return wire.ConnectorSetup{}, invalid("That slot cannot be skipped.")
	}
	if !d.settled(folder, ".agents/project.json") {
		return wire.ConnectorSetup{}, guardedRefusal(".agents/project.json", "The slot was not changed: ")
	}
	skipped := d.skippedSlots(folder)
	skipped[r.Slot] = r.Skipped
	var list []string
	for _, s := range []wire.ConnectorSlotKind{wire.ConnectorSlotKindTasks, wire.ConnectorSlotKindCodeReview, wire.ConnectorSlotKindCi} {
		if skipped[s] {
			list = append(list, string(s))
		}
	}
	var v any
	if len(list) > 0 {
		v = map[string]any{"skipped": list}
	}
	func() {
		defer d.approveWrite(folder, ".agents/project.json")
		err = setProjectConfig(folder, "connectors", v)
	}()
	if err != nil {
		return wire.ConnectorSetup{}, configWriteError(err)
	}
	log.Printf("connectors: %s %s", r.Slot, map[bool]string{true: "skipped", false: "set up again"}[r.Skipped])
	return d.connectorSetup(ctx, folder, wire.ConnectorSetupReadingCached)
}

// githubConnection is the person's GitHub connection on this host, if any.
func (d *Daemon) githubConnection() (connections.Connection, bool) {
	s, err := d.connectionStore()
	if err != nil {
		return connections.Connection{}, false
	}
	c, ok, err := s.Get(connections.GitHub)
	return c, ok && err == nil
}

func (d *Daemon) setupReader(token string) setupReader {
	if d.newSetupReader != nil {
		return d.newSetupReader(token)
	}
	return githubmcp.NewRealGitHub("", func() string { return token }, nil)
}

func (d *Daemon) connectorSetup(ctx context.Context, folder string, reading wire.ConnectorSetupReading) (wire.ConnectorSetup, error) {
	folder, err := d.setupProject(folder)
	if err != nil {
		return wire.ConnectorSetup{}, err
	}
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	repo, _ := githubmcp.RepoAt(gitCtx, folder)
	cancel()
	skipped := d.skippedSlots(folder)
	conn, connected := d.githubConnection()
	usable := connected && conn.Usable(time.Now())

	d.setupMu.Lock()
	rec := d.setupRecordsLocked()[folder]
	if rec == nil || rec.Repo != repo {
		rec = &setupRecord{Repo: repo, Slots: map[wire.ConnectorSlotKind]*slotRecord{}}
	}
	due := reading == wire.ConnectorSetupReadingFresh ||
		(reading == wire.ConnectorSetupReadingCached && time.Since(rec.ReadAt) > setupFresh)
	rec = cloneRecord(rec)
	d.setupMu.Unlock()

	if due && usable && repo != "" {
		d.readSetup(ctx, rec, conn.Access, skipped)
		d.setupMu.Lock()
		d.setupRecordsLocked()[folder] = rec
		d.saveSetupLocked()
		d.setupMu.Unlock()
	}

	out := wire.ConnectorSetup{Folder: folder, Slots: []wire.ConnectorSlot{}}
	install := connections.GitHubInstallURL
	out.InstallURL = &install
	if repo != "" {
		out.Repository = &repo
	}
	if connected {
		w := wireConnection(conn)
		out.Connection = &w
		if usable && repo != "" {
			out.Installed, out.Repositories = rec.Installed, rec.Repositories
		}
	}
	for _, s := range githubSlots {
		out.Slots = append(out.Slots, githubSlot(s, repo, connected && usable, skipped[s], rec.Slots[s]))
	}
	out.Slots = append(out.Slots, wire.ConnectorSlot{Slot: wire.ConnectorSlotKindWorkspace,
		Choice: slotChoice[wire.ConnectorSlotKindWorkspace], State: wire.ConnectorSlotStateRead})
	for _, s := range out.Slots {
		if s.State == wire.ConnectorSlotStateRead || s.State == wire.ConnectorSlotStateSkipped {
			out.Done++
		}
	}
	out.Events = d.setupEvents(ctx, folder, rec, out.Slots, reading != wire.ConnectorSetupReadingStored)
	return out, nil
}

func cloneRecord(r *setupRecord) *setupRecord {
	c := *r
	c.Slots = map[wire.ConnectorSlotKind]*slotRecord{}
	for k, v := range r.Slots {
		s := *v
		c.Slots[k] = &s
	}
	return &c
}

// readSetup makes the reads, side by side, into rec.
func (d *Daemon) readSetup(ctx context.Context, rec *setupRecord, token string, skipped map[wire.ConnectorSlotKind]bool) {
	ctx, cancel := context.WithTimeout(ctx, setupReadLimit)
	defer cancel()
	gh := d.setupReader(token)
	type answer struct {
		slot   wire.ConnectorSlotKind
		newest *githubmcp.Newest
		err    error
	}
	reads := map[wire.ConnectorSlotKind]func(context.Context, string) (*githubmcp.Newest, error){
		wire.ConnectorSlotKindTasks: gh.NewestIssue, wire.ConnectorSlotKindCodeReview: gh.NewestPull, wire.ConnectorSlotKindCi: gh.LastRun,
	}
	answers := make(chan answer, len(reads))
	n := 0
	for slot, read := range reads {
		if skipped[slot] {
			continue
		}
		n++
		go func() {
			newest, err := read(ctx, rec.Repo)
			answers <- answer{slot, newest, err}
		}()
	}
	installed, repositories, reachErr := gh.AppReach(ctx, rec.Repo, connections.GitHubAppSlug)
	if reachErr == nil {
		count := int64(repositories)
		rec.Installed, rec.Repositories = &installed, &count
	}
	now := time.Now()
	for range n {
		a := <-answers
		s := rec.Slots[a.slot]
		if s == nil {
			s = &slotRecord{}
			rec.Slots[a.slot] = s
		}
		var gh *githubmcp.GitHubError
		switch {
		case a.err == nil:
			*s = slotRecord{Read: true, Proof: proofOf(a.newest), ReadAt: now}
		case errors.As(a.err, &gh) && gh.Refused:
			*s = slotRecord{Refused: true, ReadAt: now}
			log.Printf("connectors: GitHub refused the %s read", a.slot)
		default:
			// Not reached, or the connection was not taken: a slot that read keeps its tick.
			s.Failure = "Connected, but github.com can't be reached for the first read."
			if errors.As(a.err, &gh) && gh.Kind == githubmcp.NotSignedIn {
				s.Failure = "GitHub did not take the connection. Connect GitHub again."
			} else if errors.As(a.err, &gh) && gh.Kind == githubmcp.RateLimited {
				s.Failure = "GitHub's rate limit was reached. Try again in a minute."
			}
			log.Printf("connectors: the %s read failed", a.slot)
		}
	}
	rec.ReadAt = now
}

func proofOf(n *githubmcp.Newest) *wire.ConnectorProof {
	if n == nil {
		return nil
	}
	p := &wire.ConnectorProof{Title: n.Title}
	if n.Number > 0 {
		number := int64(n.Number)
		p.Number = &number
	}
	if n.URL != "" {
		p.URL = &n.URL
	}
	if n.Outcome != "" {
		p.Outcome = &n.Outcome
	}
	if t, err := time.Parse(time.RFC3339, n.At); err == nil {
		at := wire.DateOf(t)
		p.At = &at
	}
	return p
}

func githubSlot(kind wire.ConnectorSlotKind, repo string, connected, skipped bool, rec *slotRecord) wire.ConnectorSlot {
	s := wire.ConnectorSlot{Slot: kind, Choice: slotChoice[kind]}
	say := func(m string) { s.Message = &m }
	switch {
	case skipped:
		s.State = wire.ConnectorSlotStateSkipped
	case repo == "":
		s.State = wire.ConnectorSlotStateNoRemote
	case !connected:
		s.State = wire.ConnectorSlotStateNotConnected
	case rec == nil:
		s.State = wire.ConnectorSlotStateNotRead
	case rec.Refused:
		s.State = wire.ConnectorSlotStateRefused
		say("GitHub refused: Agents can't see " + slotThing[kind] + " in " + repo + ".")
	case rec.Read:
		s.State, s.Proof = wire.ConnectorSlotStateRead, rec.Proof
		at := wire.DateOf(rec.ReadAt)
		s.ReadAt = &at
	case rec.Failure != "":
		s.State = wire.ConnectorSlotStateFailed
		say(rec.Failure)
	default:
		s.State = wire.ConnectorSlotStateNotRead
	}
	return s
}

// setupEvents is the github connector's events for the project. With turnOn, a set-up that
// can read turns them on: the made-by-Agents entry goes in the project's .agents/mcp.json,
// approved, once.
func (d *Daemon) setupEvents(ctx context.Context, folder string, rec *setupRecord, slots []wire.ConnectorSlot, turnOn bool) wire.ConnectorEvents {
	ours, _ := mcpcatalog.OursByID("agents/github")
	ev := wire.ConnectorEvents{State: wire.ConnectorEventsStateOff, Names: ours.Declares.Events, Workflows: []wire.ConnectorWorkflow{}}
	server, taken := d.githubServerFor(folder)
	reads := false
	for _, s := range slots {
		reads = reads || (s.Slot != wire.ConnectorSlotKindWorkspace && s.State == wire.ConnectorSlotStateRead)
	}
	switch {
	case server != "":
		ev.State = wire.ConnectorEventsStateOn
	case taken:
		ev.State = wire.ConnectorEventsStateTaken
		m := "A connector not made by Agents is already called github in .agents/mcp.json, so it was left as it is."
		ev.Message = &m
	case turnOn && reads && !rec.EventsAdded:
		if err := d.addGitHubConnector(ctx, folder); err != nil {
			ev.State = wire.ConnectorEventsStateFailed
			// The words alone: a person reads this, not the wire's error code.
			why := err.Error()
			var rpcErr *Error
			if errors.As(err, &rpcErr) {
				why = rpcErr.Message
			}
			m := "The github connector could not be added: " + why
			ev.Message = &m
			break
		}
		d.setupMu.Lock()
		if r := d.setupRecordsLocked()[folder]; r != nil {
			r.EventsAdded = true
		} else {
			rec.EventsAdded = true
			d.setupRecords[folder] = rec
		}
		d.saveSetupLocked()
		d.setupMu.Unlock()
		server, _ = d.githubServerFor(folder)
		if server != "" {
			ev.State = wire.ConnectorEventsStateOn
		}
	}
	if server != "" {
		ev.Server = &server
	}
	for _, w := range d.workflowSummaries(folder) {
		if w.IsArchived || !hearsAny(w.Workflow, server, ev.Names) {
			continue
		}
		ev.Workflows = append(ev.Workflows, wire.ConnectorWorkflow{ID: w.Workflow.WorkflowID, Name: w.Workflow.Name})
	}
	return ev
}

// hearsAny is whether one of the workflow's server-event triggers hears one of names from
// server ("" for any).
func hearsAny(w wire.Workflow, server string, names []string) bool {
	for _, t := range w.Triggers {
		mt, ok := serverTrigger(t)
		if !ok || (server != "" && !mt.hears(server)) {
			continue
		}
		for _, n := range names {
			if mt.covers(n) {
				return true
			}
		}
	}
	return false
}

// githubServerFor is the name of the made-by-Agents github connector that reaches the
// project (its own, then the person's), and whether the name github is taken by another.
func (d *Daemon) githubServerFor(folder string) (server string, taken bool) {
	project, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	var personal []mcpEntry
	if home := d.personalHome(); home != "" {
		personal, _ = readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
	}
	for _, list := range [][]mcpEntry{project, personal} {
		for _, e := range list {
			if e.server.Stdio == nil {
				continue
			}
			if o, ok := mcpcatalog.OursByCommand(e.server.Stdio.Command); ok && o.ID == "agents/github" {
				return e.name, false
			}
		}
	}
	for _, e := range project {
		taken = taken || e.name == "github"
	}
	return "", taken
}

// addGitHubConnector adds the made-by-Agents github connector to the project, as Add
// Connector… does: previewed, then added and approved as written.
func (d *Daemon) addGitHubConnector(ctx context.Context, folder string) error {
	ours, _ := mcpcatalog.OursByID("agents/github")
	dest := wire.SkillDestination{Kind: wire.SkillDestinationKindProject, Folder: &folder}
	result := mcpcatalog.OursResult(ours, d.declaredBy(ours))
	preview := d.mcpPreview(ctx, wire.MCPPreviewRequest{Result: result, Destination: dest})
	if preview.Preview == nil {
		return errors.New("its entry could not be prepared")
	}
	if _, err := d.mcpAdd(wire.MCPAddRequest{PreviewID: preview.Preview.PreviewID, Destination: dest}); err != nil {
		return err
	}
	log.Printf("connectors: the github connector was added to a project for its events")
	return nil
}
