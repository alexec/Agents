package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/wire"
)

// A folder's Connectors set-up (#1336): its GitHub repository (from its git remote), the
// person's GitHub connection (#1335), and four slots. Tasks, Code review and CI come with the
// connection, and each proves itself with one real read: the newest issue, the newest pull
// request, the last workflow run. Where agents run is This Mac. A tick is a read: once a slot
// has read, a read that does not reach GitHub keeps the tick, and only GitHub's refusal takes
// it away. Skips are the folder's (.agents/folder.json "connectors"); the reads are this
// host's (<root>/connector-setup.json, one record per folder, only folders kept). Once a slot
// can read, the set-up turns on the github connector's events for the folder, once: a person
// who takes the entry out again is not overruled.
//
// GitLab (#1632): with no GitHub remote, a GitLab remote (gitlab.com, the connected GitLab, or
// a host named gitlab) picks GitLab, and the GitLab connection fills the three slots, proved by
// the newest issue, the newest merge request and the last pipeline; the gitlab connector's
// events go on. The connection counts only on the GitLab it was made on.

var (
	// setupFresh is how long a read is used again before GitHub is asked again.
	setupFresh = 5 * time.Minute
	// setupReadLimit is all of one set-up's reads.
	setupReadLimit = 20 * time.Second
)

// forgeSlots is the slots that come with the forge's connection, in the page's order.
var forgeSlots = []wire.ConnectorSlotKind{wire.ConnectorSlotKindTasks, wire.ConnectorSlotKindCodeReview, wire.ConnectorSlotKindCi}

var slotChoice = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "GitHub Issues",
	wire.ConnectorSlotKindCodeReview: "GitHub pull requests",
	wire.ConnectorSlotKindCi:         "GitHub Actions",
	wire.ConnectorSlotKindWorkspace:  "This Mac",
}

var gitlabSlotChoice = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "GitLab issues",
	wire.ConnectorSlotKindCodeReview: "GitLab merge requests",
	wire.ConnectorSlotKindCi:         "GitLab pipelines",
}

var slotThing = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "issues",
	wire.ConnectorSlotKindCodeReview: "pull requests",
	wire.ConnectorSlotKindCi:         "Actions runs",
}

var gitlabSlotThing = map[wire.ConnectorSlotKind]string{
	wire.ConnectorSlotKindTasks:      "issues",
	wire.ConnectorSlotKindCodeReview: "merge requests",
	wire.ConnectorSlotKindCi:         "pipelines",
}

// forge is what a folder's remote picked: the provider, its root (GitLab's), the repository
// or folder, and its host as the page says it.
type forge struct {
	provider wire.ConnectionProvider
	root     string
	repo     string
	site     string
}

func (f forge) name() string {
	if f.provider == wire.ConnectionProviderGitlab {
		return "GitLab"
	}
	return "GitHub"
}

func (f forge) choice(kind wire.ConnectorSlotKind) string {
	if c, ok := gitlabSlotChoice[kind]; ok && f.provider == wire.ConnectionProviderGitlab {
		return c
	}
	return slotChoice[kind]
}

func (f forge) thing(kind wire.ConnectorSlotKind) string {
	if f.provider == wire.ConnectionProviderGitlab {
		return gitlabSlotThing[kind]
	}
	return slotThing[kind]
}

// ours is the made-by-Agents connector whose events the forge's set-up turns on.
func (f forge) ours() string {
	if f.provider == wire.ConnectionProviderGitlab {
		return "agents/gitlab"
	}
	return "agents/github"
}

// gitlabSetupReader is the reads a GitLab set-up makes; a test gives a fake GitLab.
type gitlabSetupReader interface {
	NewestIssue(ctx context.Context, folder string) (*gitlabmcp.Newest, error)
	NewestMergeRequest(ctx context.Context, folder string) (*gitlabmcp.Newest, error)
	LastPipeline(ctx context.Context, folder string) (*gitlabmcp.Newest, error)
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
	// newGitLabSetupReader is the GitLab at root as the token's owner; a test gives a fake.
	newGitLabSetupReader func(root, token string) gitlabSetupReader
	// newCodespacesClient reads and changes Codespaces as the GitHub connection owner.
	newCodespacesClient func(token string) codespacesClient
}

// setupRecord is what this host last read for one folder.
type setupRecord struct {
	Repo string `json:"repo"`
	// Forge is gitlab for a GitLab folder; empty is GitHub.
	Forge        string                                 `json:"forge,omitempty"`
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
	// Repo and Forge are what was read when it was not the folder's own (a project's
	// slot, #2669); empty is the record's.
	Repo  string `json:"repo,omitempty"`
	Forge string `json:"forge,omitempty"`
}

// forgeName is the record's name for f's forge: gitlab, or empty for GitHub.
func forgeName(f forge) string {
	if f.provider == wire.ConnectionProviderGitlab {
		return string(f.provider)
	}
	return ""
}

// readOf is what s read, when it read f's repository: a slot's source can change (#2669).
func (r *setupRecord) readOf(kind wire.ConnectorSlotKind, f forge) *slotRecord {
	s := r.Slots[kind]
	if s == nil {
		return nil
	}
	repo, name := s.Repo, s.Forge
	if repo == "" {
		repo, name = r.Repo, r.Forge
	}
	if repo != f.repo || name != forgeName(f) {
		return nil
	}
	return s
}

// slotSource is what fills one slot: the folder's own forge, or its project's (#2669).
type slotSource struct {
	f           forge
	conn        connections.Connection
	usable      bool
	fromProject bool
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
	On(d, wire.CallConnectorsCodespaces, func(ctx context.Context, c *Client, r wire.ConnectorCodespacesRequest) (wire.ConnectorCodespaces, error) {
		return d.connectorCodespaces(ctx, r)
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

// saveSetupLocked writes the records of folders this host still has. setupMu is held.
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

// skippedSlots is the folder's skips, from .agents/folder.json as last approved.
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

func (d *Daemon) setupFolder(folder string) (string, error) {
	folder = filepath.Clean(folder)
	if _, ok := d.summaryFor(folder); !ok || !isDir(folder) {
		return "", noSuchFolder(folder + " is not a folder, or is not there.")
	}
	return folder, nil
}

func (d *Daemon) skipConnectorSlot(ctx context.Context, r wire.ConnectorSkipRequest) (wire.ConnectorSetup, error) {
	folder, err := d.setupFolder(r.Folder)
	if err != nil {
		return wire.ConnectorSetup{}, err
	}
	if _, known := slotChoice[r.Slot]; !known || r.Slot == wire.ConnectorSlotKindWorkspace {
		return wire.ConnectorSetup{}, invalid("That slot cannot be skipped.")
	}
	if _, set := d.projectSlot(folder, r.Slot); set {
		return wire.ConnectorSetup{}, &Error{Code: wire.FailureNotPermitted, Message: "The folder's project sets this slot for every folder in it. Its owner or an admin changes it."}
	}
	if !d.settled(folder, ".agents/folder.json") {
		return wire.ConnectorSetup{}, guardedRefusal(".agents/folder.json", "The slot was not changed: ")
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
		defer d.approveWrite(folder, ".agents/folder.json")
		err = setFolderConfig(folder, "connectors", v)
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

func (d *Daemon) gitlabSetupReader(root, token string) gitlabSetupReader {
	if d.newGitLabSetupReader != nil {
		return d.newGitLabSetupReader(root, token)
	}
	return gitlabmcp.NewRealGitLab(root, func() string { return token }, nil)
}

// gitlabConnection is the person's GitLab connection on this host, if any.
func (d *Daemon) gitlabConnection() (connections.Connection, bool) {
	s, err := d.connectionStore()
	if err != nil {
		return connections.Connection{}, false
	}
	c, ok, err := s.Get(connections.GitLab)
	return c, ok && err == nil
}

// connectionFor is the person's connection to f's forge, and whether it counts there: a
// GitLab connection counts only on its own GitLab.
func (d *Daemon) connectionFor(f forge) (connections.Connection, bool) {
	if f.provider != wire.ConnectionProviderGitlab {
		return d.githubConnection()
	}
	c, connected := d.gitlabConnection()
	if !connected || gitlabmcp.BaseURL(c.URL) != f.root {
		return connections.Connection{}, false
	}
	return c, true
}

// slotSources is what fills each of the forge's slots: the project's setting where its
// project sets one (#2669), else the folder's own forge. A project's skip is the folder's
// skip; a slot the project fills is not skipped by the folder's own.
func (d *Daemon) slotSources(folder string, own forge, conn connections.Connection, connected bool, skipped map[wire.ConnectorSlotKind]bool) map[wire.ConnectorSlotKind]slotSource {
	now := time.Now()
	out := map[wire.ConnectorSlotKind]slotSource{}
	for _, kind := range forgeSlots {
		src := slotSource{f: own, conn: conn, usable: connected && conn.Usable(now)}
		if ps, set := d.projectSlot(folder, kind); set {
			src.fromProject = true
			skipped[kind] = ps.Skipped != nil && *ps.Skipped
			if !skipped[kind] {
				src.f = projectForge(ps)
				c, ok := d.connectionFor(src.f)
				src.conn, src.usable = c, ok && c.Usable(now)
			}
		}
		out[kind] = src
	}
	return out
}

// forgeAt is what the folder's git remote names: a GitHub repository first, else a GitLab
// folder on the connected GitLab, gitlab.com, or a host named gitlab. Its connection, and
// whether there is one, come with it: a GitLab connection counts only on its own GitLab.
func (d *Daemon) forgeAt(ctx context.Context, folder string) (forge, connections.Connection, bool) {
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	github := forge{provider: wire.ConnectionProviderGithub, site: "github.com"}
	if repo, ok := githubmcp.RepoAt(gitCtx, folder); ok {
		github.repo = repo
		c, connected := d.githubConnection()
		return github, c, connected
	}
	c, connected := d.gitlabConnection()
	roots := []string{connections.GitLabCom}
	if connected && c.URL != "" {
		roots = append([]string{c.URL}, roots...)
	}
	root, project, ok := gitlabmcp.ProjectAt(gitCtx, folder, roots)
	if !ok {
		c, connected := d.githubConnection()
		return github, c, connected
	}
	f := forge{provider: wire.ConnectionProviderGitlab, root: root, repo: project, site: "gitlab.com"}
	if u, err := url.Parse(root); err == nil && u.Host != "" {
		f.site = u.Host
	}
	if connected && gitlabmcp.BaseURL(c.URL) != root {
		// Connected to another GitLab: its token is not sent here.
		return f, connections.Connection{}, false
	}
	return f, c, connected
}

func (d *Daemon) connectorSetup(ctx context.Context, folder string, reading wire.ConnectorSetupReading) (wire.ConnectorSetup, error) {
	folder, err := d.setupFolder(folder)
	if err != nil {
		return wire.ConnectorSetup{}, err
	}
	f, conn, connected := d.forgeAt(ctx, folder)
	repo := f.repo
	recForge := ""
	if f.provider == wire.ConnectionProviderGitlab {
		recForge = string(f.provider)
	}
	skipped := d.skippedSlots(folder)
	usable := connected && conn.Usable(time.Now())
	sources := d.slotSources(folder, f, conn, connected, skipped)
	readable := false
	for kind, src := range sources {
		readable = readable || (src.usable && src.f.repo != "" && !skipped[kind])
	}

	d.setupMu.Lock()
	rec := d.setupRecordsLocked()[folder]
	if rec == nil || rec.Repo != repo || rec.Forge != recForge {
		rec = &setupRecord{Repo: repo, Forge: recForge, Slots: map[wire.ConnectorSlotKind]*slotRecord{}}
	}
	due := reading == wire.ConnectorSetupReadingFresh ||
		(reading == wire.ConnectorSetupReadingCached && time.Since(rec.ReadAt) > setupFresh)
	rec = cloneRecord(rec)
	d.setupMu.Unlock()

	if due && readable {
		d.readSetup(ctx, f, usable, conn.Access, rec, sources, skipped)
		d.setupMu.Lock()
		d.setupRecordsLocked()[folder] = rec
		d.saveSetupLocked()
		d.setupMu.Unlock()
	}

	out := wire.ConnectorSetup{Folder: folder, Slots: []wire.ConnectorSlot{}, Forge: &f.provider, Site: &f.site}
	if f.provider == wire.ConnectionProviderGithub {
		install := connections.GitHubInstallURL
		out.InstallURL = &install
	}
	if repo != "" {
		out.Repository = &repo
		page := "https://github.com/" + repo
		if f.provider == wire.ConnectionProviderGitlab {
			page = f.root + repo
		}
		out.RepositoryURL = &page
	}
	if connected {
		w := wireConnection(conn)
		out.Connection = &w
		if usable && repo != "" {
			out.Installed, out.Repositories = rec.Installed, rec.Repositories
		}
	}
	for _, s := range forgeSlots {
		src := sources[s]
		slot := forgeSlot(src.f, s, src.usable, skipped[s], rec.readOf(s, src.f))
		if src.f.repo != "" && !skipped[s] {
			r := src.f.repo
			slot.Repository = &r
		}
		if src.fromProject {
			yes := true
			slot.FromProject = &yes
		}
		out.Slots = append(out.Slots, slot)
	}
	if id, tools, known := d.folderProject(folder); id != "" {
		out.Project = &id
		if known {
			out.ProjectName = &tools.Name
		}
	}
	out.Slots = append(out.Slots, wire.ConnectorSlot{Slot: wire.ConnectorSlotKindWorkspace,
		Choice: slotChoice[wire.ConnectorSlotKindWorkspace], State: wire.ConnectorSlotStateRead})
	for _, s := range out.Slots {
		if s.State == wire.ConnectorSlotStateRead || s.State == wire.ConnectorSlotStateSkipped {
			out.Done++
		}
	}
	out.Events = d.setupEvents(ctx, f, folder, rec, out.Slots, reading != wire.ConnectorSetupReadingStored)
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

// slotRead is one slot's read, whichever the forge.
type slotRead func(ctx context.Context, repo string) (*githubmcp.Newest, error)

// readSetup makes the reads, side by side, into rec: each slot from its own source, and
// whether the Agents App is on the folder's own GitHub repository.
func (d *Daemon) readSetup(ctx context.Context, own forge, ownUsable bool, ownToken string, rec *setupRecord, sources map[wire.ConnectorSlotKind]slotSource, skipped map[wire.ConnectorSlotKind]bool) {
	ctx, cancel := context.WithTimeout(ctx, setupReadLimit)
	defer cancel()
	type answer struct {
		slot   wire.ConnectorSlotKind
		f      forge
		newest *githubmcp.Newest
		err    error
	}
	answers := make(chan answer, len(sources))
	n := 0
	for slot, src := range sources {
		if skipped[slot] || !src.usable || src.f.repo == "" {
			continue
		}
		read := d.slotReader(src.f, src.conn.Access, slot)
		n++
		go func() {
			newest, err := read(ctx, src.f.repo)
			answers <- answer{slot, src.f, newest, err}
		}()
	}
	if ownUsable && own.provider == wire.ConnectionProviderGithub && own.repo != "" {
		installed, repositories, reachErr := d.setupReader(ownToken).AppReach(ctx, own.repo, connections.GitHubAppSlug)
		if reachErr == nil {
			count := int64(repositories)
			rec.Installed, rec.Repositories = &installed, &count
		}
	}
	now := time.Now()
	for range n {
		a := <-answers
		s := &slotRecord{}
		if had := rec.readOf(a.slot, a.f); had != nil {
			s = had
		}
		switch refused, failure := readFailure(a.f, a.err); {
		case a.err == nil:
			*s = slotRecord{Read: true, Proof: proofOf(a.newest), ReadAt: now}
		case refused:
			*s = slotRecord{Refused: true, ReadAt: now}
			log.Printf("connectors: %s refused the %s read", a.f.name(), a.slot)
		default:
			// Not reached, or the connection was not taken: a slot that read keeps its tick.
			s.Failure = failure
			log.Printf("connectors: the %s read failed", a.slot)
		}
		if a.f.repo != rec.Repo || forgeName(a.f) != rec.Forge {
			s.Repo, s.Forge = a.f.repo, forgeName(a.f)
		} else {
			s.Repo, s.Forge = "", ""
		}
		rec.Slots[a.slot] = s
	}
	rec.ReadAt = now
}

// slotReader is the read that proves one slot on f's forge.
func (d *Daemon) slotReader(f forge, token string, slot wire.ConnectorSlotKind) slotRead {
	if f.provider == wire.ConnectionProviderGitlab {
		gl := d.gitlabSetupReader(f.root, token)
		return map[wire.ConnectorSlotKind]slotRead{
			wire.ConnectorSlotKindTasks: fromGitLab(gl.NewestIssue), wire.ConnectorSlotKindCodeReview: fromGitLab(gl.NewestMergeRequest),
			wire.ConnectorSlotKindCi: fromGitLab(gl.LastPipeline),
		}[slot]
	}
	gh := d.setupReader(token)
	return map[wire.ConnectorSlotKind]slotRead{
		wire.ConnectorSlotKindTasks: gh.NewestIssue, wire.ConnectorSlotKindCodeReview: gh.NewestPull, wire.ConnectorSlotKindCi: gh.LastRun,
	}[slot]
}

// fromGitLab is a GitLab read as a slot's read.
func fromGitLab(read func(context.Context, string) (*gitlabmcp.Newest, error)) slotRead {
	return func(ctx context.Context, folder string) (*githubmcp.Newest, error) {
		n, err := read(ctx, folder)
		if n == nil || err != nil {
			return nil, err
		}
		return &githubmcp.Newest{Number: n.Number, Title: n.Title, URL: n.URL, At: n.At, Outcome: n.Outcome}, nil
	}
}

// readFailure is whether the forge refused the read, and else what the slot says.
func readFailure(f forge, err error) (refused bool, words string) {
	if err == nil {
		return false, ""
	}
	if f.provider == wire.ConnectionProviderGitlab {
		var gl *gitlabmcp.GitLabError
		switch {
		case errors.As(err, &gl) && gl.Refused:
			return true, ""
		case errors.As(err, &gl) && gl.Kind == gitlabmcp.NotSignedIn:
			return false, "GitLab did not take the connection. Connect GitLab again."
		case errors.As(err, &gl) && gl.Kind == gitlabmcp.RateLimited:
			return false, "GitLab's rate limit was reached. Try again in a minute."
		}
		return false, "Connected, but " + f.site + " can't be reached for the first read."
	}
	var gh *githubmcp.GitHubError
	switch {
	case errors.As(err, &gh) && gh.Refused:
		return true, ""
	case errors.As(err, &gh) && gh.Kind == githubmcp.NotSignedIn:
		return false, "GitHub did not take the connection. Connect GitHub again."
	case errors.As(err, &gh) && gh.Kind == githubmcp.RateLimited:
		return false, "GitHub's rate limit was reached. Try again in a minute."
	}
	return false, "Connected, but github.com can't be reached for the first read."
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

func forgeSlot(f forge, kind wire.ConnectorSlotKind, connected, skipped bool, rec *slotRecord) wire.ConnectorSlot {
	repo := f.repo
	s := wire.ConnectorSlot{Slot: kind, Choice: f.choice(kind)}
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
		say(f.name() + " refused: Agents can't see " + f.thing(kind) + " in " + repo + ".")
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

// setupEvents is the forge's connector's events for the folder (github's or gitlab's). With
// turnOn, a set-up that can read turns them on: the made-by-Agents entry goes in the
// folder's .agents/mcp.json, approved, once.
func (d *Daemon) setupEvents(ctx context.Context, f forge, folder string, rec *setupRecord, slots []wire.ConnectorSlot, turnOn bool) wire.ConnectorEvents {
	ours, _ := mcpcatalog.OursByID(f.ours())
	ev := wire.ConnectorEvents{State: wire.ConnectorEventsStateOff, Names: ours.Declares.Events, Workflows: []wire.ConnectorWorkflow{}}
	server, taken := d.ourServerFor(folder, ours)
	reads := false
	for _, s := range slots {
		reads = reads || (s.Slot != wire.ConnectorSlotKindWorkspace && s.State == wire.ConnectorSlotStateRead)
	}
	switch {
	case server != "":
		ev.State = wire.ConnectorEventsStateOn
	case taken:
		ev.State = wire.ConnectorEventsStateTaken
		m := "A connector not made by Agents is already called " + ours.NameHere() + " in .agents/mcp.json, so it was left as it is."
		ev.Message = &m
	case turnOn && reads && !rec.EventsAdded:
		if err := d.addOurConnector(ctx, folder, ours); err != nil {
			ev.State = wire.ConnectorEventsStateFailed
			// The words alone: a person reads this, not the wire's error code.
			why := err.Error()
			var rpcErr *Error
			if errors.As(err, &rpcErr) {
				why = rpcErr.Message
			}
			m := "The " + ours.NameHere() + " connector could not be added: " + why
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
		server, _ = d.ourServerFor(folder, ours)
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

// ourServerFor is the name of the made-by-Agents connector ours (github's, gitlab's) that
// reaches the folder (its own, then the person's), and whether its name is taken by another.
func (d *Daemon) ourServerFor(folder string, ours mcpcatalog.Ours) (server string, taken bool) {
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	var personal []mcpEntry
	if home := d.personalHome(); home != "" {
		personal, _ = readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
	}
	for _, list := range [][]mcpEntry{entries, personal} {
		for _, e := range list {
			if e.server.Stdio == nil {
				continue
			}
			if o, ok := mcpcatalog.OursByCommand(e.server.Stdio.Command); ok && o.ID == ours.ID {
				return e.name, false
			}
		}
	}
	for _, e := range entries {
		taken = taken || e.name == ours.NameHere()
	}
	return "", taken
}

// addOurConnector adds the made-by-Agents connector ours to the folder, as Add Connector…
// does: previewed, then added and approved as written.
func (d *Daemon) addOurConnector(ctx context.Context, folder string, ours mcpcatalog.Ours) error {
	dest := wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &folder}
	result := mcpcatalog.OursResult(ours, d.declaredBy(ours))
	preview := d.mcpPreview(ctx, wire.MCPPreviewRequest{Result: result, Destination: dest})
	if preview.Preview == nil {
		return errors.New("its entry could not be prepared")
	}
	if _, err := d.mcpAdd(wire.MCPAddRequest{PreviewID: preview.Preview.PreviewID, Destination: dest}); err != nil {
		return err
	}
	log.Printf("connectors: the %s connector was added to a folder for its events", ours.NameHere())
	return nil
}
