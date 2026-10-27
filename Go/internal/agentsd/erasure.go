package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Erasure (#1001, T8 slice b1): Delete removes an agent's folder, then the runtime's own
// copy of its conversation, and the agent never comes back from a backup.
//
//   - erasures.json is the queue of runtime copies still to erase, kept across a restart.
//     The eraser takes them one at a time: it starts the runtime as the agent ran (its
//     account), asks it to delete the session (ACP session/delete), and for Claude and
//     Codex also removes the files it knows in the home that launch names. A copy that
//     could not be erased is tried again at the next start, erasureTries times at most.
//   - erased.json is every agent this machine deleted, so a restore skips it. Backups carry
//     it, and a restore adds the backup's to this machine's.
//
// A sweep of many agents costs one runtime start per runtime and account, none for an
// adapter that said it cannot delete, and one rewrite of each file per batch (#2427).
const (
	erasuresFile = "erasures.json"
	erasedFile   = "erased.json"
	erasuresMost = 1000
	erasureTries = 3
	erasureKeep  = 7 * 24 * time.Hour
	erasureWait  = 60 * time.Second
	erasedMost   = 10000
	erasedKeep   = 400 * 24 * time.Hour
)

// erasure is one runtime copy to erase.
type erasure struct {
	AgentID   wire.UUID `json:"agentID"`
	RuntimeID string    `json:"runtimeID"`
	SessionID string    `json:"sessionID"`
	AccountID *string   `json:"accountID,omitempty"`
	QueuedAt  time.Time `json:"queuedAt"`
	Tries     int       `json:"tries"`
}

// eraser is the Daemon's queue state. mu guards both files; busy is whether the eraser is
// taking an entry, for a test to wait on. cannotDelete is each adapter install that said it
// cannot delete a session, by adapterKey; only eraseLoop reads and writes it.
type eraser struct {
	mu           sync.Mutex
	kick         chan struct{}
	busy         bool
	cannotDelete map[string]bool
}

// writeErasureFile writes erasures.json and erased.json; a test counts the writes.
var writeErasureFile = store.WriteAtomically

// adapterKey names a runtime's adapter as installed: its path and when it last changed, so
// an update is asked again. It is "" when the adapter is not found.
func adapterKey(rt *runtimeDef) string {
	path, _, _ := locateFor(rt)
	if path == "" {
		return ""
	}
	at := ""
	if st, err := os.Stat(path); err == nil {
		at = st.ModTime().UTC().Format(time.RFC3339Nano) + "/" + strconv.FormatInt(st.Size(), 10)
	}
	return rt.ID + "\x00" + path + "\x00" + at
}

// erasing is whether the eraser runs. A test turns it on when it says so, so that no test
// starts a runtime or looks in the person's home to erase a copy.
var erasing = true

// sessionIDShape is what a session ID may be before it goes into a file pattern: no
// separator, no dot, no pattern character.
var sessionIDShape = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func (d *Daemon) erasuresPath() string { return filepath.Join(d.Store.Loc.Root, erasuresFile) }
func (d *Daemon) erasedPath() string   { return filepath.Join(d.Store.Loc.Root, erasedFile) }

// startErasures drops the entries that are too old or tried too often, and starts the
// eraser on the rest.
func (d *Daemon) startErasures() {
	d.erasures.kick = make(chan struct{}, 1)
	d.erasures.mu.Lock()
	q := d.readErasures()
	kept := q[:0]
	for _, e := range q {
		switch {
		case e.Tries >= erasureTries:
			log.Printf("erasure: gave up on %s's copy of agent %s after %d tries", e.RuntimeID, e.AgentID, e.Tries)
		case nowFunc().Sub(e.QueuedAt) > erasureKeep:
			log.Printf("erasure: gave up on %s's copy of agent %s, queued %s", e.RuntimeID, e.AgentID, e.QueuedAt.Format(time.RFC3339))
		default:
			kept = append(kept, e)
		}
	}
	if len(kept) != len(q) {
		d.writeErasures(kept)
	}
	d.erasures.mu.Unlock()
	if !erasing {
		return
	}
	safe.Go("erasures", d.eraseLoop)
	d.erasures.kick <- struct{}{}
}

// hasRuntimeCopy is whether the runtime holds a copy of an agent's conversation to erase.
func hasRuntimeCopy(a *wire.Agent) bool {
	return a.RuntimeSessionID != nil && *a.RuntimeSessionID != ""
}

// heldSessions is the runtime sessions of the agents this set-up still keeps, when any of
// agents has a copy: those copies are never erased.
func (d *Daemon) heldSessions(agents []*wire.Agent) map[string]bool {
	if !slices.ContainsFunc(agents, hasRuntimeCopy) {
		return nil
	}
	held := map[string]bool{}
	for _, a := range d.Store.Agents() {
		if hasRuntimeCopy(&a) {
			held[a.RuntimeID+"\x00"+*a.RuntimeSessionID] = true
		}
	}
	return held
}

// mayErase is whether a deleted agent's runtime copy is erased: one made under another
// set-up, or that an agent still kept holds, belongs to someone else.
func (d *Daemon) mayErase(a *wire.Agent, held map[string]bool) bool {
	if !hasRuntimeCopy(a) || held[a.RuntimeID+"\x00"+*a.RuntimeSessionID] {
		return false
	}
	return a.MadeInRoot == nil || *a.MadeInRoot == d.Store.RootID
}

// queueErasure adds the runtime's copy of a deleted agent, and puts it on the erased list.
func (d *Daemon) queueErasure(a *wire.Agent) {
	d.queueErasures([]*wire.Agent{a})
}

// queueErasures is queueErasure for many deleted agents, with one rewrite of each file.
// Only a copy this set-up made, and that no agent it still keeps holds, is queued.
func (d *Daemon) queueErasures(agents []*wire.Agent) {
	if len(agents) == 0 {
		return
	}
	held := d.heldSessions(agents)
	d.erasures.mu.Lock()
	defer d.erasures.mu.Unlock()
	erased := map[wire.UUID]time.Time{}
	var add []erasure
	for _, a := range agents {
		erased[a.ID] = nowFunc()
		if d.mayErase(a, held) {
			add = append(add, erasure{AgentID: a.ID, RuntimeID: a.RuntimeID, SessionID: *a.RuntimeSessionID,
				AccountID: a.AccountID, QueuedAt: nowFunc()})
		}
	}
	d.noteErasedLocked(erased)
	if len(add) == 0 {
		return
	}
	q := append(d.readErasures(), add...)
	if over := len(q) - erasuresMost; over > 0 {
		log.Printf("erasure: the queue is full; %d older copies will not be erased", over)
		q = q[over:]
	}
	d.writeErasures(q)
	select {
	case d.erasures.kick <- struct{}{}:
	default:
	}
}

// eraseLoop takes the queue's entries in turn each time it is kicked. An entry that fails
// stays, with one more try, for the next start: it is not tried again in this run. The
// entries of one pass share a runtime session per runtime and account, and what they came
// to is written once, at the end of the pass, or every eraseBatch entries.
func (d *Daemon) eraseLoop() {
	tried := map[erasure]bool{}
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-d.erasures.kick:
		}
		d.erasures.mu.Lock()
		todo := d.readErasures()
		d.erasures.busy = len(todo) > 0
		d.erasures.mu.Unlock()
		p := &erasePass{d: d, sessions: map[string]*passSession{}}
		results := map[erasure]bool{}
		for _, e := range todo {
			if d.ctx.Err() != nil {
				break
			}
			key := erasure{AgentID: e.AgentID, SessionID: e.SessionID}
			if tried[key] {
				continue
			}
			tried[key] = true
			results[key] = d.erase(p, e)
			if len(results) >= eraseBatch {
				d.noteErasures(results)
				results = map[erasure]bool{}
			}
		}
		p.stop()
		d.erasures.mu.Lock()
		d.noteErasuresLocked(results)
		d.erasures.busy = false
		d.erasures.mu.Unlock()
	}
}

// eraseBatch is how many erased entries a pass takes before it writes erasures.json.
const eraseBatch = 50

func (d *Daemon) noteErasures(results map[erasure]bool) {
	d.erasures.mu.Lock()
	defer d.erasures.mu.Unlock()
	d.noteErasuresLocked(results)
}

// noteErasuresLocked drops the queue's entries that were erased and counts a try on the rest.
func (d *Daemon) noteErasuresLocked(results map[erasure]bool) {
	if len(results) == 0 {
		return
	}
	q := d.readErasures()
	kept := q[:0]
	for _, e := range q {
		done, ok := results[erasure{AgentID: e.AgentID, SessionID: e.SessionID}]
		switch {
		case !ok:
		case done:
			continue
		default:
			e.Tries++
		}
		kept = append(kept, e)
	}
	d.writeErasures(kept)
}

// erasePass is one pass of the eraser: the runtime sessions it started, one per runtime and
// account, kept for the pass's other entries and stopped at its end.
type erasePass struct {
	d        *Daemon
	sessions map[string]*passSession
}

// passSession is a runtime started for a pass, or why it could not be.
type passSession struct {
	s   *acp.Session
	err error
}

// session is the pass's runtime session for an entry, started the first time it is asked
// for. It is nil, with no error, when the adapter is known not to delete.
func (p *erasePass) session(e erasure, account *wire.AccountProfile) (*acp.Session, error) {
	if e.AccountID != nil && account == nil {
		return nil, errors.New("its account was removed")
	}
	key := e.RuntimeID
	if e.AccountID != nil {
		key += "\x00" + *e.AccountID
	}
	if ps, ok := p.sessions[key]; ok {
		return ps.s, ps.err
	}
	rt := runtimeByID(e.RuntimeID)
	adapter := ""
	if rt != nil {
		adapter = adapterKey(rt)
	}
	if adapter != "" && p.d.erasures.cannotDelete[adapter] {
		p.sessions[key] = &passSession{}
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(p.d.ctx, erasureWait)
	defer cancel()
	s, _, err := p.d.handshakeAs(ctx, e.RuntimeID, account, &probe{commands: make(chan []wire.SlashCommand, 1)})
	ps := &passSession{s: s, err: err}
	if err == nil && !s.CanDelete() {
		s.Stop()
		ps.s = nil
		if adapter != "" {
			if p.d.erasures.cannotDelete == nil {
				p.d.erasures.cannotDelete = map[string]bool{}
			}
			p.d.erasures.cannotDelete[adapter] = true
		}
	}
	p.sessions[key] = ps
	return ps.s, ps.err
}

func (p *erasePass) stop() {
	for _, ps := range p.sessions {
		if ps.s != nil {
			ps.s.Stop()
		}
	}
}

// erase asks the runtime to delete its copy, then removes the files known for it. It is
// done when the runtime deleted it, or when the runtime's files are known and removed.
func (d *Daemon) erase(p *erasePass, e erasure) bool {
	ctx, cancel := context.WithTimeout(d.ctx, erasureWait)
	defer cancel()
	var account *wire.AccountProfile
	if e.AccountID != nil {
		account = d.accountProfile(e.RuntimeID, *e.AccountID)
	}
	env := os.Environ()
	if rt := runtimeByID(e.RuntimeID); rt != nil {
		if l, err := d.launchAs(rt, d.Store.Loc.Root, account); err == nil {
			env = l.Env
		}
	}
	asked := d.eraseInRuntime(ctx, p, e, account)
	if asked != nil {
		log.Printf("erasure: %s did not delete agent %s's conversation: %v", e.RuntimeID, e.AgentID, asked)
	}
	known, removed := eraseRuntimeFiles(e.RuntimeID, e.SessionID, env)
	if removed > 0 {
		log.Printf("erasure: removed %d of %s's files of agent %s", removed, e.RuntimeID, e.AgentID)
	}
	return asked == nil || known
}

// eraseInRuntime is session/delete on the runtime, started as the agent ran. A runtime
// that cannot delete a conversation is not an error: nothing more can be asked of it.
func (d *Daemon) eraseInRuntime(ctx context.Context, p *erasePass, e erasure, account *wire.AccountProfile) error {
	s, err := p.session(e, account)
	if err != nil || s == nil {
		return err
	}
	return s.DeleteSession(ctx, e.SessionID)
}

// eraseRuntimeFiles removes a session's files where the runtime is known to keep them, in
// the home its launch names. known is whether the runtime's layout is known.
func eraseRuntimeFiles(runtimeID, sessionID string, env []string) (known bool, removed int) {
	if !sessionIDShape.MatchString(sessionID) {
		return false, 0
	}
	var patterns []string
	switch runtimeID {
	case "claude":
		home := envHome(env, "CLAUDE_CONFIG_DIR", ".claude")
		patterns = []string{
			filepath.Join(home, "folders", "*", sessionID+".jsonl"),
			filepath.Join(home, "folders", "*", sessionID),
			filepath.Join(home, "todos", sessionID+"-*.json"),
			filepath.Join(home, "file-history", sessionID),
			filepath.Join(home, "session-env", sessionID),
			filepath.Join(home, "debug", sessionID+".txt"),
		}
	case "codex":
		home := envHome(env, "CODEX_HOME", ".codex")
		patterns = []string{
			filepath.Join(home, "sessions", "*", "*", "*", "rollout-*-"+sessionID+".jsonl"),
			filepath.Join(home, "archived_sessions", "rollout-*-"+sessionID+".jsonl"),
		}
	default:
		return false, 0
	}
	for _, p := range patterns {
		matches, _ := filepath.Glob(p)
		for _, m := range matches {
			if err := os.RemoveAll(m); err != nil {
				log.Printf("erasure: %v", err)
				continue
			}
			removed++
		}
	}
	return true, removed
}

// envHome is the folder a variable of env names, or the folder under HOME.
func envHome(env []string, variable, under string) string {
	value := func(name string) string {
		for _, kv := range slices.Backward(env) {
			if v, ok := strings.CutPrefix(kv, name+"="); ok {
				return v
			}
		}
		return ""
	}
	if v := value(variable); v != "" {
		return v
	}
	home := value("HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	return filepath.Join(home, under)
}

func (d *Daemon) readErasures() []erasure {
	var q []erasure
	if b, err := os.ReadFile(d.erasuresPath()); err == nil {
		if err := json.Unmarshal(b, &q); err != nil {
			log.Printf("erasures.json: %v; starting with none", err)
		}
	}
	return q
}

func (d *Daemon) writeErasures(q []erasure) {
	if len(q) == 0 {
		if err := os.Remove(d.erasuresPath()); err != nil && !os.IsNotExist(err) {
			log.Printf("erasures.json: %v", err)
		}
		return
	}
	b, _ := json.Marshal(q)
	if err := writeErasureFile(d.erasuresPath(), b, 0o600); err != nil {
		log.Printf("erasures.json: %v", err)
	}
}

// MARK: The erased list

func (d *Daemon) readErasedLocked() map[wire.UUID]time.Time {
	list := map[wire.UUID]time.Time{}
	if b, err := os.ReadFile(d.erasedPath()); err == nil {
		if err := json.Unmarshal(b, &list); err != nil {
			log.Printf("erased.json: %v; starting with none", err)
		}
	}
	return list
}

// noteErasedLocked adds IDs to the erased list, keeping it to erasedMost IDs of the last
// erasedKeep, the newest.
func (d *Daemon) noteErasedLocked(add map[wire.UUID]time.Time) {
	list := d.readErasedLocked()
	for id, at := range add {
		id = wire.UUID(strings.ToUpper(string(id)))
		if old, ok := list[id]; !ok || at.Before(old) {
			list[id] = at
		}
	}
	cutoff := nowFunc().Add(-erasedKeep)
	maps.DeleteFunc(list, func(_ wire.UUID, at time.Time) bool { return at.Before(cutoff) })
	if over := len(list) - erasedMost; over > 0 {
		ids := slices.SortedFunc(maps.Keys(list), func(a, b wire.UUID) int { return list[a].Compare(list[b]) })
		for _, id := range ids[:over] {
			delete(list, id)
		}
	}
	b, _ := json.Marshal(list)
	if err := writeErasureFile(d.erasedPath(), b, 0o600); err != nil {
		log.Printf("erased.json: %v", err)
	}
}

// takeErasedList adds a backup's erased list to this machine's.
func (d *Daemon) takeErasedList(b []byte) {
	var add map[wire.UUID]time.Time
	if json.Unmarshal(b, &add) != nil || len(add) == 0 {
		return
	}
	d.erasures.mu.Lock()
	defer d.erasures.mu.Unlock()
	d.noteErasedLocked(add)
}
