package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Every MCP server in the host's mcp.json files and how each is doing (#753). A server not
// hosted is checked as a session would reach it (mcpclient.go): as the host starts, when
// its entry changes (the files are read once a minute), every four hours, and on Check
// Now. A folder's server not approved here, and one missing a secret, are never started.
// A hosted server's state is its one copy's; a short check of it only learns what it
// declares, for its levels (#1428), when its entry changes and every four hours.
//
// Logged: the server's name and the outcome in a word. Never a command, argument,
// environment value, header, URL or body (054 FR-023).

const (
	mcpHealthInterval = 4 * time.Hour
	// mcpHealthParallel is the checks at once: a stdio check starts a process.
	mcpHealthParallel = 3
)

type mcpHealthResult struct {
	// digest is the entry as checked, secrets filled: a change checks it again.
	digest string
	check  wire.MCPCheckState
	at     wire.Date
	err    string
	tools  int
	// declared is what the server declared when it answered, for its levels.
	declared mcpcatalog.Declared
	// ours is the catalogue id when Agents made the server.
	ours string
}

type mcpHealthBook struct {
	healthMu sync.Mutex
	results  map[string]mcpHealthResult
	running  map[string]bool
	// forced is what Check Now asked for, until its check starts.
	forced map[string]bool
	// told is what the clients were last told: an unchanged pass tells them nothing.
	told                    *wire.MCPHealthSnapshot
	reconciling, reconcileA bool
	// healthTimeout is how long a check waits for initialize and tools/list.
	healthTimeout time.Duration
}

type mcpDue struct {
	id, cwd, digest string
	name            string
	server          sdk.McpServer
}

// mcpLevels is a row's five levels from what its check found; Tested is known for ours.
func mcpLevels(h *wire.MCPServerHealth, e mcpEntry, kept *mcpHealthResult) {
	ours, made := mcpcatalog.Ours{}, false
	if e.server.Stdio != nil {
		ours, made = mcpcatalog.OursByCommand(e.server.Stdio.Command)
	}
	if kept != nil && kept.check == wire.MCPCheckStateAnswered {
		levels := mcpcatalog.Levels(kept.declared, made && ours.Tested != "")
		h.Levels = &levels
	}
}

func healthID(folder *string, name string) string {
	if folder == nil {
		return "~|" + name
	}
	return *folder + "|" + name
}

// StartMCPHealth checks the servers now, then looks again every minute: once, after the
// host knows its personal home.
func (d *Daemon) StartMCPHealth() { safe.Go("mcp health", d.mcpHealthClock) }

func (d *Daemon) mcpHealthClock() {
	d.reconcileMCPHealth()
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			d.reconcileMCPHealth()
		}
	}
}

// mcpHealthSnapshot is mcp/health: a fresh look at the files, with what each check found
// and the checks under way.
func (d *Daemon) mcpHealthSnapshot() wire.MCPHealthSnapshot {
	snap, _ := d.mcpHealthPass()
	return snap
}

// mcpHealthCheck is mcp/health/check: Check Now on one file's servers.
func (d *Daemon) mcpHealthCheck(folder *string) wire.MCPHealthSnapshot {
	snap, _ := d.mcpHealthPass()
	d.healthMu.Lock()
	for _, s := range snap.Servers {
		if !s.Hosted && ((folder == nil && s.Folder == nil) || (folder != nil && s.Folder != nil && *s.Folder == *folder)) {
			d.forced[healthID(s.Folder, s.Name)] = true
		}
	}
	d.healthMu.Unlock()
	which := "personal"
	if folder != nil {
		which = "folder"
	}
	log.Printf("mcp health: check now (%s)", which)
	d.reconcileMCPHealth()
	d.healthMu.Lock()
	defer d.healthMu.Unlock()
	if d.told != nil {
		return *d.told
	}
	return snap
}

// reconcileMCPHealth starts what is due and tells the clients what changed.
func (d *Daemon) reconcileMCPHealth() {
	d.healthMu.Lock()
	if d.reconciling {
		d.reconcileA = true
		d.healthMu.Unlock()
		return
	}
	d.reconciling = true
	d.healthMu.Unlock()
	for {
		snap, due := d.mcpHealthPass()
		d.healthMu.Lock()
		for _, item := range due {
			if len(d.running) >= mcpHealthParallel {
				break
			}
			d.running[item.id] = true
			delete(d.forced, item.id)
			for i := range snap.Servers {
				if healthID(snap.Servers[i].Folder, snap.Servers[i].Name) == item.id && !snap.Servers[i].Hosted {
					snap.Servers[i].Check = wire.MCPCheckStateChecking
				}
			}
			safe.Go("mcp health check", func() { d.checkMCPServer(item) })
		}
		changed := d.told == nil || !reflect.DeepEqual(d.told.Servers, snap.Servers) || !reflect.DeepEqual(d.told.Problems, snap.Problems)
		d.told = &snap
		again := d.reconcileA
		d.reconcileA = false
		if !again {
			d.reconciling = false
		}
		d.healthMu.Unlock()
		if changed {
			Broadcast(d, wire.NotifyMCPHealthChanged, snap)
		}
		if !again {
			return
		}
	}
}

// checkMCPServer is one check: connect, initialize, tools/list, end.
func (d *Daemon) checkMCPServer(item mcpDue) {
	d.healthMu.Lock()
	timeout := d.healthTimeout
	d.healthMu.Unlock()
	if timeout == 0 {
		timeout = time.Minute
	}
	r := mcpHealthResult{digest: item.digest, check: wire.MCPCheckStateFailed}
	if item.server.Stdio != nil {
		if o, ok := mcpcatalog.OursByCommand(item.server.Stdio.Command); ok {
			r.ours = o.ID
		}
	}
	tools, declared, err := checkMCP(d.ctx, item.server, item.cwd, timeout)
	switch f := mcpFailureOf(err); {
	case err == nil:
		r.check, r.tools, r.declared = wire.MCPCheckStateAnswered, tools, declared
	case f.kind == "authRequired" && bringsOwnAuthorization(item.server):
		r.err = "It refused the Authorization header it was sent (HTTP 401)."
	case f.kind == "authRequired":
		r.check = wire.MCPCheckStateSignIn
	default:
		r.err = f.sentence(timeout)
	}
	r.at = now()
	log.Printf("mcp health: %s → %s", item.name, r.check)
	d.healthMu.Lock()
	delete(d.running, item.id)
	d.results[item.id] = r
	d.healthMu.Unlock()
	d.reconcileMCPHealth()
}

func bringsOwnAuthorization(s sdk.McpServer) bool {
	if s.Http == nil {
		return false
	}
	for _, h := range s.Http.Headers {
		if strings.EqualFold(h.Name, "Authorization") {
			return true
		}
	}
	return false
}

func serverDigest(s sdk.McpServer) string {
	b, _ := json.Marshal(s)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// mcpHealthPass is one look at every file: the person's servers, then each folder's, by
// path; with what each last check found, and the checks that are due.
func (d *Daemon) mcpHealthPass() (wire.MCPHealthSnapshot, []mcpDue) {
	snap := wire.MCPHealthSnapshot{Servers: []wire.MCPServerHealth{}, Problems: []wire.MCPHealthFileProblem{}, At: now()}
	secrets := d.secrets()
	at := time.Now()
	var due []mcpDue
	d.healthMu.Lock()
	defer d.healthMu.Unlock()
	if d.results == nil {
		d.results, d.running, d.forced = map[string]mcpHealthResult{}, map[string]bool{}, map[string]bool{}
	}
	listed := map[string]bool{}
	row := func(e mcpEntry, folder *string, cwd string, waiting bool) {
		h := wire.MCPServerHealth{Name: e.name, Folder: folder, Transport: e.kind, Hosted: e.hosted, Check: wire.MCPCheckStateUnchecked}
		id := healthID(folder, e.name)
		listed[id] = true
		mcpLevels(&h, e, nil)
		filled, gone := filledServer(e.server, secrets)
		switch {
		case e.hosted:
			h.Live = d.hostedStatus(folder, e.name)
			if waiting || len(gone) > 0 {
				break
			}
			digest := serverDigest(filled)
			kept, ok := d.results[id]
			if ok && kept.digest == digest {
				mcpLevels(&h, e, &kept)
			} else {
				ok = false
			}
			if !d.running[id] && (!ok || at.Sub(kept.at.Time()) >= mcpHealthInterval) {
				due = append(due, mcpDue{id: id, cwd: cwd, digest: digest, name: e.name, server: filled})
			}
		case e.kind == wire.MCPTransportNameSse:
			h.Check = wire.MCPCheckStateOldTransport
		case waiting:
			h.Check = wire.MCPCheckStateWaiting
		case len(gone) > 0:
			h.Check = wire.MCPCheckStateMissingSecret
		default:
			digest := serverDigest(filled)
			kept, ok := d.results[id]
			if ok && kept.digest == digest {
				h.Check, h.CheckedAt = kept.check, &kept.at
				if kept.err != "" {
					h.LastError = &kept.err
				}
				if kept.check == wire.MCPCheckStateAnswered {
					n := int64(kept.tools)
					h.Tools = &n
				}
				mcpLevels(&h, e, &kept)
			} else {
				ok = false
			}
			switch {
			case d.running[id]:
				h.Check = wire.MCPCheckStateChecking
			case d.forced[id] || !ok || at.Sub(kept.at.Time()) >= mcpHealthInterval:
				due = append(due, mcpDue{id: id, cwd: cwd, digest: digest, name: e.name, server: filled})
			}
		}
		snap.Servers = append(snap.Servers, h)
	}
	if home := d.personalHome(); home != "" {
		entries, problem := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		if problem != "" {
			snap.Problems = append(snap.Problems, wire.MCPHealthFileProblem{Message: problem})
		}
		for _, e := range entries {
			row(e, nil, home, false)
		}
	}
	var folders []string
	for _, p := range d.folders(false) {
		if p.Folder.ArchivedAt == nil {
			folders = append(folders, store.FolderPath(p.Folder.Folder))
		}
	}
	sort.Strings(folders)
	d.mcpMu.Lock()
	approved, _, _ := d.mcpApprovalsLocked()
	d.mcpMu.Unlock()
	for _, folder := range folders {
		entries, problem := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
		f := folder
		if problem != "" {
			snap.Problems = append(snap.Problems, wire.MCPHealthFileProblem{Folder: &f, Message: problem})
		}
		for _, e := range entries {
			row(e, &f, folder, approved == nil || approved[mcpApprovalKey(folder, e.name)] != entryDigest(e.raw))
		}
	}
	// What is no longer listed is forgotten.
	for id := range d.results {
		if !listed[id] {
			delete(d.results, id)
		}
	}
	for id := range d.forced {
		if !listed[id] {
			delete(d.forced, id)
		}
	}
	return snap, due
}

func (d *Daemon) registerMCP() {
	d.handlers[wire.CallMCPHealth.Name] = func(ctx context.Context, c *Client, raw json.RawMessage) (any, error) {
		return d.mcpHealthSnapshot(), nil
	}
	On(d, wire.CallMCPHealthCheck, func(ctx context.Context, c *Client, r wire.MCPHealthCheckRequest) (wire.MCPHealthSnapshot, error) {
		return d.mcpHealthCheck(r.Folder), nil
	})
}
