package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/shirou/gopsutil/v4/process"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The warm pool (#183, #202, #4044): a finished session keeps its runtime for a while, so
// the person's reply does not wait for a cold start, and agents/prewarm starts one behind
// a chat the person opens or types in. Every runtime costs about 0.3 to 0.5 GB
// (specs/183-warm-pool/measurements.md), so the pool is bounded:
//
//   - a finished runtime is released after WakeSettings.releaseAfterMinutes with no turn
//     (warmIdle by default, 0 turning that off). An agent waiting for an event (#4513)
//     is one: its runtime is ended and the ACP session id kept, and the event's turn
//     continues the conversation with session/load or session/resume. A waiting agent
//     whose runtime can do neither is kept, as a release would lose the conversation;
//     it does not count against the cap;
//   - at most WakeSettings.warmRuntimes stay warm (0 turns the pool off), the least
//     recently used going first, and a prewarm counts against that before it launches;
//   - a runtime whose background processes still run (a dev server, a build, a watcher)
//     does not count against the cap and is not released at warmIdle, but is released
//     WakeSettings.backgroundHours after its last turn ended, its processes with it and a
//     note in the chat that names them. Once its last process ends, warmIdle starts then;
//   - a warm runtime takes the next turn only when its start is what that turn's would be
//     (warmKey);
//   - under memory pressure the cap is 0 (memorypressure.go, #4514).
//
// Archive, delete and move release at once, as before. Each decision is logged as
// "warm pool: <pooled|released|prewarmed> <id> (<why>)".

// warmIdle is how long a finished runtime with no background processes is kept by default
// (WakeSettings.releaseAfterMinutes).
const warmIdle = defaultReleaseAfterMinutes * time.Minute

var (
	// warmEvery is how often the pool looks at its runtimes.
	warmEvery = 30 * time.Second
	// warmAskedAgain is the host's debounce on a prewarm, per session and reason, as the
	// window's own.
	warmAskedAgain = 15 * time.Second
	// warmFailedRetry is how long a runtime that failed a prewarm is not tried again.
	warmFailedRetry = 5 * time.Minute
	// warmNow is the pool's clock; a test moves it.
	warmNow = time.Now
)

// warmStart is what a live runtime started with: its warmKey, and the processes that were
// its own once it was up, which are not background processes.
type warmStart struct {
	key string
	own map[int32]bool
	// groups is the process groups its commands were seen in (backgroundIn).
	groups map[int]bool
}

// warmLive is a live agent's place in the pool, under live.mu.
type warmLive struct {
	// lastUsed is when its last turn ended or its prewarm began.
	lastUsed time.Time
	// quietSince is when its background processes were last seen to have ended; zero
	// while it had none.
	quietSince time.Time
	// background is whether it had background processes at the last look.
	background bool
	// seen is its background processes at the last look that had any, for
	// agent.background_ended (#4577): nil once they ended.
	seen []acp.Command
	// prewarming is a prewarm under way: it counts against the cap.
	prewarming bool
	// failedAt is its last prewarm's failure; asked is each reason's last prewarm.
	failedAt time.Time
	asked    map[wire.PrewarmRequestWhy]time.Time
	// keptWaiting is whether the log has said it is kept for its wait (#4513).
	keptWaiting bool
}

type warmBook struct {
	// warmMu makes one pass at a time.
	warmMu sync.Mutex
	// wakeSettings reads the Mac's settings (wake_darwin.go); unset off a Mac, where the
	// defaults hold.
	wakeSettings atomic.Pointer[func() wire.WakeSettings]
	// pressure is the memory pressure at the last look (warmCap), "" with none.
	pressureMu sync.Mutex
	pressure   string
}

func (d *Daemon) warmSettings() wire.WakeSettings {
	if f := d.wakeSettings.Load(); f != nil {
		return (*f)()
	}
	return defaultWake()
}

func backgroundHoursOf(s wire.WakeSettings) int {
	if s.BackgroundHours == nil {
		return defaultBackgroundHours
	}
	return int(min(max(*s.BackgroundHours, 1), 24))
}

// releaseAfterOf is how long an idle runtime is kept; 0 is none released for being idle.
func releaseAfterOf(s wire.WakeSettings) time.Duration {
	if s.ReleaseAfterMinutes == nil {
		return warmIdle
	}
	return time.Duration(min(max(*s.ReleaseAfterMinutes, 0), maxReleaseAfterMinutes)) * time.Minute
}

// MARK: the rules

// warmEntry is a runtime the pool may release: idle, or a prewarm under way.
type warmEntry struct {
	id         wire.UUID
	lastUsed   time.Time
	quietSince time.Time
	background bool
	prewarming bool
	// kept is an agent that waits, on a runtime that cannot continue its conversation.
	kept bool
}

type warmRelease struct {
	id wire.UUID
	// why is for the log and, with background, for the chat's note.
	why        string
	background bool
}

// warmDecide is which runtimes go now: those idle past idle (none when it is 0), then the
// least recently used beyond the cap. A prewarm under way counts against the cap but is
// never released; a runtime with background processes does not count and goes only at
// backgroundHours; a kept one neither counts nor goes.
func warmDecide(es []warmEntry, now time.Time, capacity, backgroundHours int, idle time.Duration) []warmRelease {
	var out []warmRelease
	var counted []warmEntry
	prewarms := 0
	for _, e := range es {
		switch {
		case e.prewarming:
			prewarms++
		case e.kept:
		case e.background:
			if now.Sub(e.lastUsed) >= time.Duration(backgroundHours)*time.Hour {
				out = append(out, warmRelease{id: e.id, why: fmt.Sprintf("%d h idle", backgroundHours), background: true})
			}
		default:
			from := e.lastUsed
			if e.quietSince.After(from) {
				from = e.quietSince
			}
			if idle > 0 && now.Sub(from) >= idle {
				out = append(out, warmRelease{id: e.id, why: fmt.Sprintf("%d min idle", int(idle.Minutes()))})
			} else {
				counted = append(counted, e)
			}
		}
	}
	// The most recently used first; what is past the cap goes.
	slices.SortStableFunc(counted, func(a, b warmEntry) int { return b.lastUsed.Compare(a.lastUsed) })
	room := max(capacity-prewarms, 0)
	for i, e := range counted {
		if i >= room {
			out = append(out, warmRelease{id: e.id, why: fmt.Sprintf("least recently used, over the cap of %d", capacity)})
		}
	}
	return out
}

// MARK: what a runtime started with

// warmKey is what a runtime starts with, as a hash: the runtime's program and its version
// (its file's size and time), its sandbox, its account, its folder and arguments, its
// persona, its MCP servers and the session's secrets. A warm runtime takes a turn only when
// that turn's key is the same (#4044); otherwise a new one starts. Read with no side
// effect: no token is made for it.
func (d *Daemon) warmKey(a *wire.Agent) string {
	k := map[string]any{"runtime": a.RuntimeID, "cwd": a.Cwd, "account": a.AccountID, "extra": a.StartOptions.ExtraArguments,
		"persona": a.Persona, "starter": a.StartedByAgent}
	if rt := runtimeByID(a.RuntimeID); rt != nil {
		path, args, _ := locateFor(rt)
		k["path"], k["args"] = path, args
		if fi, err := os.Stat(path); err == nil {
			k["version"] = fmt.Sprint(fi.Size(), fi.ModTime().UnixNano())
		}
	}
	choice, _ := d.resolveSandbox(a.RuntimeID, a.SandboxOverride, a.StartedByAgent)
	k["sandbox"] = choice
	var servers []string
	for _, e := range d.sessionEntries(folderPath(a), a.ID) {
		b, _ := json.Marshal(e.server)
		servers = append(servers, e.name+"="+string(b))
	}
	k["servers"] = servers
	// A tool turned Off is in the runtime's own deny list, which it reads as it starts (#4099).
	k["toolsOff"] = d.offTools(a)
	k["secrets"] = d.sessionSecretEnv(a.ID)
	// A server a person allowed after it was refused connects at a new start (#4120).
	k["secretProxy"] = d.secretProxyStart(a.ID)
	b, _ := json.Marshal(k)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// warmFits is whether the agent's warm runtime may take its next turn. One that started
// differently is released here, and false is the turn starting a new one.
func (d *Daemon) warmFits(l *live, a *wire.Agent) bool {
	l.mu.Lock()
	key := l.warm.key
	l.mu.Unlock()
	if key == d.warmKey(a) {
		return true
	}
	d.releaseWarm(l, "its start changed", nil, true)
	return false
}

// MARK: background processes

// procInfo is a process of the machine's: its parent and its name.
type procInfo struct {
	parent int32
	name   string
}

// processTable is every process's parent and name. A look costs a few milliseconds, so it
// is made once a pass, and only when the pool has a runtime to look at.
func processTable(ctx context.Context) map[int32]procInfo {
	out := map[int32]procInfo{}
	pids, err := process.PidsWithContext(ctx)
	if err != nil {
		return out
	}
	for _, pid := range pids {
		p, err := process.NewProcessWithContext(ctx, pid)
		if err != nil {
			continue
		}
		parent, err := p.PpidWithContext(ctx)
		if err != nil {
			continue
		}
		name, _ := p.NameWithContext(ctx)
		out[pid] = procInfo{parent: parent, name: name}
	}
	return out
}

// descendantsIn is every process under root, not root itself.
func descendantsIn(table map[int32]procInfo, root int32) map[int32]bool {
	children := map[int32][]int32{}
	for pid, p := range table {
		if pid != root {
			children[p.parent] = append(children[p.parent], pid)
		}
	}
	out := map[int32]bool{}
	var walk func(int32)
	walk = func(pid int32) {
		for _, c := range children[pid] {
			if !out[c] {
				out[c] = true
				walk(c)
			}
		}
	}
	walk(root)
	return out
}

// descendants is the runtime's own processes as it starts: its MCP servers and helpers,
// which are not background processes.
func (d *Daemon) descendants(pid int) map[int32]bool {
	if pid <= 0 {
		return map[int32]bool{}
	}
	return descendantsIn(processTable(d.ctx), int32(pid))
}

// backgroundIn is the runtime's background processes. A runtime's own helpers (its CLI,
// its MCP servers) stay in its process group; a command it runs for the agent gets a group
// of its own, as Claude's do, so a process under the runtime in another group, that was not
// there as it started, is one. So is a process of such a group that outlived its shell
// ("cmd &"): the machine's child then, still in the group. groups gathers each group seen
// under the runtime, from every look, in a turn too. Only the topmost of a tree is listed.
func backgroundIn(table map[int32]procInfo, root int32, own map[int32]bool, groups map[int]bool, pgidOf func(int32) int) []int32 {
	if _, ok := table[root]; !ok {
		return nil
	}
	under := descendantsIn(table, root)
	picked := map[int32]bool{}
	for pid := range under {
		g := pgidOf(pid)
		if g <= 0 || g == int(root) {
			continue
		}
		groups[g] = true
		if !own[pid] {
			picked[pid] = true
		}
	}
	for pid, p := range table {
		if pid != root && !under[pid] && !own[pid] && p.parent <= 1 {
			if g := pgidOf(pid); g > 0 && g != int(root) && groups[g] {
				picked[pid] = true
			}
		}
	}
	var out []int32
	for pid := range picked {
		if !picked[table[pid].parent] {
			out = append(out, pid)
		}
	}
	slices.Sort(out)
	return out
}

// backgroundOf is the runtime's background processes, its terminals' first.
func backgroundOf(s *acp.Session, own map[int32]bool, groups map[int]bool, table map[int32]procInfo) []acp.Command {
	out := s.Terminals()
	seen := map[int32]bool{}
	for _, c := range out {
		seen[int32(c.Pid)] = true
	}
	pgid := func(pid int32) int { g, _ := syscall.Getpgid(int(pid)); return g }
	for _, pid := range backgroundIn(table, int32(s.Pid()), own, groups, pgid) {
		if seen[pid] {
			continue
		}
		line := table[pid].name
		if p, err := process.NewProcess(pid); err == nil {
			if c, err := p.Cmdline(); err == nil && c != "" {
				line = c
			}
		}
		out = append(out, acp.Command{Pid: int(pid), Line: line})
	}
	return out
}

// backgroundNote is the chat's line when a release ended background processes.
func backgroundNote(hours int, cmds []acp.Command) string {
	return fmt.Sprintf("Released after %d h idle; ended its background processes: %s", hours, commandNames(cmds))
}

// MARK: the pool

// warmPass looks at every warm runtime and releases those the rules say go. Busy is a
// live agent in a turn: not the pool's.
func (d *Daemon) warmPass() {
	d.warmMu.Lock()
	defer d.warmMu.Unlock()
	if d.going() {
		return
	}
	s := d.warmSettings()
	capacity, pressure := d.warmCap(s)
	hours, idle := backgroundHoursOf(s), releaseAfterOf(s)
	now := warmNow()
	type look struct {
		l       *live
		session *acp.Session
		own     map[int32]bool
		groups  map[int]bool
		busy    bool
	}
	var looks []look
	var es []warmEntry
	idles := 0
	for _, l := range d.everyLive() {
		l.mu.Lock()
		switch {
		case l.pool.prewarming:
			es = append(es, warmEntry{id: l.id, prewarming: true})
		case l.session != nil:
			busy := l.running || l.inTurn
			if !busy {
				idles++
				if l.pool.lastUsed.IsZero() {
					l.pool.lastUsed = now
				}
			}
			if l.warm.groups == nil {
				l.warm.groups = map[int]bool{}
			}
			looks = append(looks, look{l: l, session: l.session, own: l.warm.own, groups: l.warm.groups, busy: busy})
		}
		l.mu.Unlock()
	}
	if len(looks) == 0 {
		return
	}
	table := processTable(d.ctx)
	background := map[wire.UUID][]acp.Command{}
	ended := map[wire.UUID][]acp.Command{}
	for _, i := range looks {
		l := i.l
		a := d.Store.Agent(l.id)
		w := waitOf(a)
		selfWaking := a != nil && wakesItself(a.RuntimeID)
		// A turn's look only gathers the groups its commands run in.
		l.mu.Lock()
		bg := backgroundOf(i.session, i.own, i.groups, table)
		if l.session == i.session {
			// Ended in a turn, the turn saw it end; unless the session waits already.
			busy := i.busy || l.running || l.inTurn
			if e := l.pool.noteBackground(bg); e != nil && !selfWaking && (!busy || w != nil) {
				ended[l.id] = e
			}
		}
		if i.busy || l.session != i.session {
			l.mu.Unlock()
			continue
		}
		if len(bg) > 0 {
			background[l.id] = bg
		} else if l.pool.background {
			// Its last process ended: warmIdle starts now.
			l.pool.quietSince = now
		}
		l.pool.background = len(bg) > 0
		kept := keptForWait(l, i.session, w)
		es = append(es, warmEntry{id: l.id, lastUsed: l.pool.lastUsed, quietSince: l.pool.quietSince, background: l.pool.background, kept: kept})
		l.mu.Unlock()
	}
	for id, cmds := range ended {
		d.raiseBackgroundEnded(id, cmds, false)
	}
	if idles == 0 {
		return
	}
	for _, r := range warmDecide(es, now, capacity, hours, idle) {
		l := d.liveIfAny(r.id)
		if l == nil {
			continue
		}
		if pressure != "" && !r.background {
			r.why += "; " + pressure
		}
		if w := waitOf(d.Store.Agent(r.id)); w != nil {
			r.why += "; it waits for " + waitLabel(w) + ", and its next turn continues the conversation"
		}
		var bg []acp.Command
		if r.background {
			bg = background[r.id]
		}
		if d.releaseWarm(l, r.why, bg, false) && len(bg) > 0 {
			d.record(r.id, runtimeNote(backgroundNote(hours, bg)))
		}
	}
}

// waitOf is the agent's open wait (wait_for_event, a place in a lease's line),
// or nil.
func waitOf(a *wire.Agent) *wire.EventWait {
	if a == nil || a.EventWait == nil || a.EventWait.Ending != nil {
		return nil
	}
	return a.EventWait
}

// keptForWait is whether an idle agent's runtime is kept for its wait (#4513): it waits,
// and its runtime can neither load nor resume a conversation, so a release would lose it.
// The log says so once for each runtime. Under l.mu.
func keptForWait(l *live, s *acp.Session, w *wire.EventWait) bool {
	if w == nil || s.CanContinue() {
		l.pool.keptWaiting = false
		return false
	}
	if !l.pool.keptWaiting {
		l.pool.keptWaiting = true
		log.Printf("warm pool: kept %s (it waits for %s, and its runtime has no session/load or session/resume, so a release would lose the conversation)", l.id, waitLabel(w))
	}
	return true
}

// warmSoon is a pass after a turn ends, on a goroutine of its own.
func (d *Daemon) warmSoon(l *live) {
	l.mu.Lock()
	warm := l.session != nil
	if warm {
		l.pool.lastUsed = warmNow()
	}
	l.mu.Unlock()
	if !warm {
		return
	}
	capacity, _ := d.warmCap(d.warmSettings())
	log.Printf("warm pool: pooled %s (turn ended; cap %d)", l.id, capacity)
	d.goAfterTurn("warm pool", d.warmPass)
}

func (d *Daemon) liveIfAny(id wire.UUID) *live {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.lives[id]
}

// releaseWarm ends an idle agent's runtime, and its background processes with it, and
// is false when it was busy again or had none. inTurn is warmFits' release, from the turn
// that is about to start.
func (d *Daemon) releaseWarm(l *live, why string, background []acp.Command, inTurn bool) bool {
	l.mu.Lock()
	s := l.session
	if s == nil || l.pool.prewarming || !inTurn && (l.running || l.inTurn) {
		l.mu.Unlock()
		return false
	}
	l.session = nil
	l.warm = warmStart{}
	l.pool = warmLive{failedAt: l.pool.failedAt, asked: l.pool.asked}
	l.mu.Unlock()
	log.Printf("warm pool: released %s (%s)", l.id, why)
	s.Stop()
	for _, c := range background {
		endProcess(c.Pid)
	}
	// As the session's watch does for one of its own: it sees the session is not ours.
	d.dropStandIn(l.id)
	d.dropCredentialGrants(l.id)
	d.dropAppTokens(l.id)
	if a := d.Store.Agent(l.id); a != nil && orgRouteOf(a.AccountID) != "" {
		d.sweepOrgAccountFolders()
	}
	return true
}

// endProcess ends a background process: TERM, then KILL if it is still there.
func endProcess(pid int) {
	if pid <= 1 || syscall.Kill(pid, syscall.SIGTERM) != nil {
		return
	}
	safe.Go("end background process", func() {
		time.Sleep(3 * time.Second)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	})
}

// registerWarmPool serves agents/prewarm and looks at the pool, and at the background
// processes adopted over a restart (#4577), every warmEvery.
func (d *Daemon) registerWarmPool() {
	On(d, wire.CallAgentsPrewarm, func(_ context.Context, _ *Client, r wire.PrewarmRequest) (wire.Empty, error) {
		d.prewarm(r)
		return wire.Empty{}, nil
	})
	d.goLoop("warm pool", func(ctx context.Context) {
		t := time.NewTicker(warmEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				d.adoptedPass()
				d.warmPass()
			}
		}
	})
}

// prewarm is agents/prewarm (#183): a finished session's runtime started behind its chat,
// with no word in it. Silent when it does nothing: a session already warm or busy, the
// pool off or full of prewarms, asked again within warmAskedAgain, or failed a short
// time ago.
func (d *Daemon) prewarm(r wire.PrewarmRequest) {
	a := d.Store.Agent(r.AgentID)
	if a == nil || d.going() || a.State != wire.AgentStateFinished && a.State != wire.AgentStateStopped {
		return
	}
	if runtimeByID(a.RuntimeID) == nil || !isDir(store.FolderPath(a.Cwd)) {
		return
	}
	capacity, _ := d.warmCap(d.warmSettings())
	if capacity == 0 {
		return
	}
	now := warmNow()
	l := d.live(a.ID)
	l.mu.Lock()
	if l.pool.asked == nil {
		l.pool.asked = map[wire.PrewarmRequestWhy]time.Time{}
	}
	switch {
	case l.session != nil:
		// Warm already: opened again, so it is the most recently used.
		if !l.running && !l.inTurn {
			l.pool.lastUsed = now
		}
		l.mu.Unlock()
		return
	case l.running || l.pool.prewarming:
		l.mu.Unlock()
		return
	case now.Sub(l.pool.asked[r.Why]) < warmAskedAgain:
		l.mu.Unlock()
		return
	case !l.pool.failedAt.IsZero() && now.Sub(l.pool.failedAt) < warmFailedRetry:
		l.mu.Unlock()
		return
	}
	l.pool.asked[r.Why] = now
	l.mu.Unlock()
	// The cap holds before the launch (#202): prewarms under way count, and the least
	// recently used warm runtime makes room.
	d.warmMu.Lock()
	prewarms := 0
	for _, o := range d.everyLive() {
		o.mu.Lock()
		if o.pool.prewarming {
			prewarms++
		}
		o.mu.Unlock()
	}
	if prewarms >= capacity {
		d.warmMu.Unlock()
		return
	}
	l.mu.Lock()
	if l.running || l.session != nil {
		l.mu.Unlock()
		d.warmMu.Unlock()
		return
	}
	l.pool.prewarming, l.pool.lastUsed = true, now
	l.running = d.goAfterTurn("prewarm "+string(l.id), func() { l.prewarmRun(r.Why) })
	if !l.running {
		l.pool.prewarming = false
	}
	l.mu.Unlock()
	d.warmMu.Unlock()
	d.warmPass()
}

// prewarmRun starts the runtime quietly, then runs what was queued while it started.
func (l *live) prewarmRun(why wire.PrewarmRequestWhy) {
	d := l.d
	ok := false
	if a := d.Store.Agent(l.id); a != nil && a.State != wire.AgentStateArchived && !d.going() {
		ctx, cancel := context.WithCancel(d.ctx)
		l.mu.Lock()
		l.stop = cancel
		l.mu.Unlock()
		ok = l.open(ctx, a, true)
		// Archived or stopped while it started: what it started goes.
		if ok && ctx.Err() != nil {
			l.mu.Lock()
			s := l.session
			l.session = nil
			l.mu.Unlock()
			if s != nil {
				s.Stop()
			}
			ok = false
		}
		cancel()
		l.mu.Lock()
		l.stop = nil
		l.mu.Unlock()
	}
	l.mu.Lock()
	l.pool.prewarming = false
	if ok {
		l.pool.lastUsed = warmNow()
	} else {
		l.pool.failedAt = warmNow()
	}
	l.mu.Unlock()
	if ok {
		log.Printf("warm pool: prewarmed %s (%s)", l.id, why)
	} else {
		log.Printf("warm pool: released %s (prewarm failed; not tried again for %s)", l.id, warmFailedRetry)
	}
	// What was queued while it started goes now; run ends the running.
	l.run()
}
