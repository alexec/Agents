package agentsd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/shirou/gopsutil/v4/process"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A background command that ends after the turn (#4577). Claude's runtime starts a cycle
// of its own when one ends (#4323, unprompted.go); other runtimes start none, and after an
// Agents restart the runtime that would have is gone. So the daemon raises
// agent.background_ended when every background process of a session has ended:
//
//   - the warm pass sees a live runtime's background processes go from some to none
//     (warmpool.go), at most warmEvery late. Not on a runtime that wakes itself, and not
//     when they ended in a turn, which saw them end, unless the session waits already;
//   - a clean stop writes each session's background processes that outlive it (their own
//     process groups, as Claude's commands are) to <root>/background.json; the next start
//     adopts those still running, and raises the event as the last of a session's ends.
//     A session whose runtime woke itself, with no wait open, is sent a prompt instead
//     of nothing, as its runtime would have.
//
// The event wakes only the session whose processes they were: a wait_for_event on it,
// with nothing else, is what a session that ends its turn on a background command does.

const backgroundEndedEvent = "agent.background_ended"

// wakesItself is whether a runtime starts a turn of its own when its background command
// ends (#4323): the daemon then raises nothing while that runtime is live. A test moves it.
var wakesItself = func(runtimeID string) bool { return runtimeID == "claude" }

// noteBackground is a look at a live runtime's background processes, under l.mu: what had
// been running and has all ended since the last look, or nil.
func (p *warmLive) noteBackground(bg []acp.Command) []acp.Command {
	if len(bg) > 0 {
		p.seen = bg
		return nil
	}
	ended := p.seen
	p.seen = nil
	return ended
}

// commandNames is "`make build`, `npm run dev` and 2 more" style: at most four, each at
// most 60 characters.
func commandNames(cmds []acp.Command) string {
	var names []string
	for i, c := range cmds {
		if i == 4 {
			names = append(names, fmt.Sprintf("and %d more", len(cmds)-4))
			break
		}
		line := strings.TrimSpace(c.Line)
		if r := []rune(line); len(r) > 60 {
			line = string(r[:60]) + "…"
		}
		names = append(names, "`"+line+"`")
	}
	return strings.Join(names, ", ")
}

// raiseBackgroundEnded is agent.background_ended for the session.
func (d *Daemon) raiseBackgroundEnded(id wire.UUID, cmds []acp.Command, afterRestart bool) {
	a := d.Store.Agent(id)
	if a == nil || a.State == wire.AgentStateArchived || len(cmds) == 0 {
		return
	}
	names := commandNames(cmds)
	log.Printf("background: %s's background processes ended (%s)", id, names)
	details := map[string]string{"commands": names, "count": fmt.Sprint(len(cmds))}
	if afterRestart {
		details["after_restart"] = "true"
	}
	d.raiseAbout(a, backgroundEndedEvent, "had its background commands end: "+names+".", details)
}

// backgroundNow is the session's background processes now, from its live runtime (or
// those it had at the last look, whose end the next look raises), and those adopted after
// a restart; nil when it has none.
func (d *Daemon) backgroundNow(id wire.UUID) []acp.Command {
	var out []acp.Command
	if l := d.liveIfAny(id); l != nil {
		table := processTable(d.ctx)
		l.mu.Lock()
		if l.session != nil {
			if l.warm.groups == nil {
				l.warm.groups = map[int]bool{}
			}
			out = backgroundOf(l.session, l.warm.own, l.warm.groups, table)
			if len(out) == 0 {
				// Ended since the last look: the next pass raises the event.
				out = slices.Clone(l.pool.seen)
			}
		}
		l.mu.Unlock()
	}
	d.adoptedMu.Lock()
	for _, p := range d.adopted[id] {
		out = append(out, acp.Command{Pid: p.Pid, Line: p.Line})
	}
	d.adoptedMu.Unlock()
	return out
}

// backgroundWaitWords is why a wait on agent.background_ended alone is refused, or "":
// on a runtime that wakes itself, and with nothing in the background to end.
func (d *Daemon) backgroundWaitWords(a *wire.Agent) string {
	d.adoptedMu.Lock()
	adopted := len(d.adopted[a.ID]) > 0
	d.adoptedMu.Unlock()
	switch {
	case adopted:
		return ""
	case wakesItself(a.RuntimeID):
		return "This runtime starts your session again itself when a background command ends: end your turn. Nothing is waiting."
	case len(d.backgroundNow(a.ID)) == 0:
		return "Nothing you started runs in the background now; it may have ended already, so look at its output. Nothing is waiting."
	}
	return ""
}

// onlyBackgroundEnded is whether a wait's patterns are agent.background_ended alone.
func onlyBackgroundEnded(ps []waitPattern) bool {
	return len(ps) > 0 && !slices.ContainsFunc(ps, func(p waitPattern) bool { return p.name != backgroundEndedEvent })
}

// MARK: over a restart

// adoptedProcess is a background process a session's runtime left running over a stop:
// its pid, its command line, and its start time in ms, so a pid used again is not it.
type adoptedProcess struct {
	Pid     int    `json:"pid"`
	Line    string `json:"line"`
	Started int64  `json:"started"`
}

type backgroundHandover struct {
	Agents map[wire.UUID][]adoptedProcess `json:"agents"`
}

type adoptedBook struct {
	adoptedMu sync.Mutex
	// adopted is the background processes each session's runtime left over the last stop.
	adopted map[wire.UUID][]adoptedProcess
}

func (d *Daemon) backgroundPath() string {
	return filepath.Join(d.Store.Loc.Root, "background.json")
}

// startedAt is a process's start time in ms, 0 when it is gone.
func startedAt(pid int) int64 {
	p, err := process.NewProcess(int32(pid))
	if err != nil {
		return 0
	}
	t, err := p.CreateTime()
	if err != nil {
		return 0
	}
	return t
}

// stillRunning is whether the process is the one adopted: there, and started when it was.
func (p adoptedProcess) stillRunning() bool {
	return p.Started != 0 && startedAt(p.Pid) == p.Started
}

// handBackgroundOver writes background.json as a clean stop begins, before the runtimes
// are stopped: each live session's background processes that outlive its runtime (not its
// terminals, which the stop ends), and those adopted at the last start still running.
func (d *Daemon) handBackgroundOver() {
	out := backgroundHandover{Agents: map[wire.UUID][]adoptedProcess{}}
	lives := d.everyLive()
	table := map[int32]procInfo{}
	if len(lives) > 0 {
		table = processTable(d.ctx)
	}
	for _, l := range lives {
		l.mu.Lock()
		s := l.session
		var bg []acp.Command
		if s != nil && !l.pool.prewarming {
			if l.warm.groups == nil {
				l.warm.groups = map[int]bool{}
			}
			bg = backgroundOf(s, l.warm.own, l.warm.groups, table)
		}
		l.mu.Unlock()
		if s == nil {
			continue
		}
		terminals := map[int]bool{}
		for _, t := range s.Terminals() {
			terminals[t.Pid] = true
		}
		for _, c := range bg {
			if terminals[c.Pid] {
				continue
			}
			if t := startedAt(c.Pid); t != 0 {
				out.Agents[l.id] = append(out.Agents[l.id], adoptedProcess{Pid: c.Pid, Line: c.Line, Started: t})
			}
		}
	}
	d.adoptedMu.Lock()
	for id, ps := range d.adopted {
		for _, p := range ps {
			if p.stillRunning() {
				out.Agents[id] = append(out.Agents[id], p)
			}
		}
	}
	d.adoptedMu.Unlock()
	path := d.backgroundPath()
	if len(out.Agents) == 0 {
		_ = os.Remove(path)
		return
	}
	b, err := diskjson.Marshal(out)
	if err == nil {
		err = store.WriteAtomically(path, b, 0o644)
	}
	if err != nil {
		log.Printf("background.json: could not write: %v", err)
		return
	}
	log.Printf("background: handed over the background processes of %d sessions", len(out.Agents))
}

// adoptBackground reads background.json as the host starts, and keeps the processes still
// running for the sessions still here; the file goes.
func (d *Daemon) adoptBackground() {
	path := d.backgroundPath()
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	_ = os.Remove(path)
	var h backgroundHandover
	if diskjson.Unmarshal(b, &h) != nil {
		log.Printf("background.json: could not read it; nothing adopted")
		return
	}
	adopted := map[wire.UUID][]adoptedProcess{}
	for id, ps := range h.Agents {
		if a := d.Store.Agent(id); a == nil || a.State == wire.AgentStateArchived {
			continue
		}
		var alive []adoptedProcess
		for _, p := range ps {
			if p.stillRunning() {
				alive = append(alive, p)
			}
		}
		if len(alive) > 0 {
			adopted[id] = alive
		} else {
			// Ended in the gap: the next pass says so.
			adopted[id] = []adoptedProcess{}
			for _, p := range ps {
				adopted[id] = append(adopted[id], adoptedProcess{Pid: p.Pid, Line: p.Line})
			}
		}
	}
	d.adoptedMu.Lock()
	d.adopted = adopted
	d.adoptedMu.Unlock()
	if len(adopted) > 0 {
		log.Printf("background: adopted the background processes of %d sessions over the restart", len(adopted))
	}
}

// adoptedPass looks at the adopted processes, every warmEvery: a session whose last one
// ended gets agent.background_ended, and, when its runtime would have woken itself and
// nothing else wakes it, a prompt.
func (d *Daemon) adoptedPass() {
	if d.going() {
		return
	}
	type ended struct {
		id   wire.UUID
		cmds []acp.Command
	}
	var done []ended
	d.adoptedMu.Lock()
	for id, ps := range d.adopted {
		var alive []adoptedProcess
		for _, p := range ps {
			if p.stillRunning() {
				alive = append(alive, p)
			}
		}
		if len(alive) > 0 {
			d.adopted[id] = alive
			continue
		}
		delete(d.adopted, id)
		var cmds []acp.Command
		for _, p := range ps {
			cmds = append(cmds, acp.Command{Pid: p.Pid, Line: p.Line})
		}
		done = append(done, ended{id: id, cmds: cmds})
	}
	d.adoptedMu.Unlock()
	for _, e := range done {
		a := d.Store.Agent(e.id)
		if a == nil || a.State == wire.AgentStateArchived {
			continue
		}
		wasWaiting := waitOf(a) != nil
		d.raiseBackgroundEnded(e.id, e.cmds, true)
		if wasWaiting || !wakesItself(a.RuntimeID) {
			continue
		}
		text := "Your background commands ended while Agent Loops restarted, so your runtime could not start you again itself: " +
			commandNames(e.cmds) + ". Read their output and carry on."
		_ = d.enqueue(e.id, wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(), From: wire.PromptOriginApp}, false)
	}
}
