package agentsd

import (
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// What a restart owes the events (#1219), as DaemonCore+Restarts does it on the Swift host:
// `system.restarted`, how long nothing was running, and every wait that was open over the
// gap told so when it next wakes.
//
// A running host writes <root>/alive.json once a minute, and a clean stop writes its time.
// The next start reads it: the stop time, or the last alive time after a crash, is when the
// gap began. Events only the host sees (`agent.*`, `lease.*`) cannot be had again for that
// time; a wait on one is told it may have missed something, at its next wake and not
// before, since waking it only to say so would use a turn for nothing.

const aliveInterval = time.Minute

// restartGap is RestartGap: when this host started, why the last one went, and since when
// nothing was running, when that is known.
type restartGap struct {
	At     wire.Date `json:"at"`
	Reason string    `json:"reason"` // stopped, crashed, first_start
	// DownSince is the last host's clean stop, or the last time it said it was alive.
	DownSince *wire.Date `json:"downSince,omitempty"`
}

// daemonAlive is DaemonAlive: alive.json.
type daemonAlive struct {
	LastAlive wire.Date  `json:"lastAlive"`
	StoppedAt *wire.Date `json:"stoppedAt,omitempty"`
	// CutOff is the agents a clean stop cut off in a turn, with their state before (#1605).
	CutOff map[wire.UUID]wire.AgentState `json:"cutOff,omitempty"`
}

type restartBook struct {
	restartMu   sync.Mutex
	lastRestart *restartGap
	aliveStop   chan struct{}
	// diskAfterRestart marks the first look at the disk after a restart: a crossing it
	// finds happened in the gap.
	diskAfterRestart bool
}

func (d *Daemon) alivePath() string { return filepath.Join(d.Store.Loc.Root, "alive.json") }

func gapOf(at wire.Date, alive *daemonAlive) restartGap {
	switch {
	case alive == nil:
		return restartGap{At: at, Reason: "first_start"}
	case alive.StoppedAt != nil:
		since := *alive.StoppedAt
		return restartGap{At: at, Reason: "stopped", DownSince: &since}
	}
	since := alive.LastAlive
	return restartGap{At: at, Reason: "crashed", DownSince: &since}
}

// downFor is the seconds nothing was running, when known: never less than nothing, since
// a clock set back is not a gap.
func (g restartGap) downFor() (float64, bool) {
	if g.DownSince == nil {
		return 0, false
	}
	return math.Max(0, g.At.Time().Sub(g.DownSince.Time()).Seconds()), true
}

// downForWords is "3 min", "2 h 5 min", "40 s"; "unknown" when nothing says.
func (g restartGap) downForWords() string {
	f, ok := g.downFor()
	if !ok {
		return "unknown"
	}
	seconds := int(math.Round(f))
	if seconds < 60 {
		return fmt.Sprintf("%d s", seconds)
	}
	minutes := (seconds + 30) / 60
	if minutes < 60 {
		return fmt.Sprintf("%d min", minutes)
	}
	hours, rest := minutes/60, minutes%60
	if hours < 48 {
		if rest == 0 {
			return fmt.Sprintf("%d h", hours)
		}
		return fmt.Sprintf("%d h %d min", hours, rest)
	}
	return fmt.Sprintf("%d days", hours/24)
}

// details are what system.restarted carries.
func (g restartGap) details() map[string]string {
	details := map[string]string{"reason": g.Reason, "down_for_text": g.downForWords()}
	if g.DownSince != nil {
		details["down_since"] = g.DownSince.Time().UTC().Format(time.RFC3339)
	}
	if f, ok := g.downFor(); ok {
		details["down_for"] = fmt.Sprint(int(math.Round(f)))
	}
	return details
}

func restartedSentence(g restartGap) string {
	switch g.Reason {
	case "stopped":
		return "Agents restarted after a clean stop. It was down for " + g.downForWords() + "."
	case "crashed":
		return "Agents restarted after it stopped unexpectedly. It was down for about " + g.downForWords() + "."
	}
	return "Agents started."
}

// caughtUpAfterRestart is whether what a pattern names is had again after a restart: a
// server's events replay from their cursor, branch.moved compares the saved tips, and the
// disk and the person are looked at again. Anything else that happened in the gap is gone.
func caughtUpAfterRestart(name string) bool {
	if isServerPattern(name) || name == "branch.moved" || name == "branch.*" {
		return true
	}
	subject, _, _ := strings.Cut(name, ".")
	return isSubject(subject) && (subject == "system" || subject == "machine" || subject == "person")
}

// restartNoticeWords is EventWords.restartNotice: added to a wake, or a time-out, of a wait
// that was open over a restart: when, for how long, and what may be missing.
func restartNoticeWords(gaps []restartGap, w *wire.EventWait) string {
	if len(gaps) == 0 {
		return ""
	}
	lines := []string{""}
	for _, g := range gaps {
		down := "How long it was down is unknown: nothing was recorded before it went."
		if g.DownSince != nil {
			down = "It was down for about " + g.downForWords() + " (from " + clock(*g.DownSince) + ")."
		}
		lines = append(lines, "Agents restarted at "+clock(g.At)+" while you waited. "+down)
	}
	var names, missing []string
	for _, p := range w.Patterns {
		names = append(names, p.Name)
		if !caughtUpAfterRestart(p.Name) {
			missing = append(missing, p.Name)
		}
	}
	if len(missing) == 0 {
		lines = append(lines, "What you wait on was caught up after it: "+strings.Join(names, ", ")+".")
	} else {
		lines = append(lines, "Events in that time may be missing: "+strings.Join(missing, ", ")+
			". Check the state yourself (for example the branch or the PR).")
	}
	return "\n" + strings.Join(lines, "\n")
}

// restartNotice is what to add to a wait's wake or time-out: the restarts it was open over.
func (d *Daemon) restartNotice(w *wire.EventWait) string {
	d.eventMu.Lock()
	gaps := d.eventStateNow.WaitRestarts[string(w.ID)]
	d.eventMu.Unlock()
	return restartNoticeWords(gaps, w)
}

func (d *Daemon) readAlive() *daemonAlive {
	b, err := os.ReadFile(d.alivePath())
	if err != nil {
		return nil
	}
	var a daemonAlive
	if diskjson.Unmarshal(b, &a) != nil {
		return nil
	}
	return &a
}

func (d *Daemon) writeAlive(a daemonAlive) {
	b, err := diskjson.Marshal(a)
	if err == nil {
		err = store.WriteAtomically(d.alivePath(), b, 0o644)
	}
	if err != nil {
		log.Printf("alive.json: could not write: %v", err)
	}
}

// noteRestart works out the gap, on start, after the agents are read and before anything
// could wake a wait, and marks every open wait as having been open over it.
func (d *Daemon) noteRestart() restartGap {
	at := now()
	gap := gapOf(at, d.readAlive())
	d.restartMu.Lock()
	d.lastRestart = &gap
	d.diskAfterRestart = gap.Reason != "first_start"
	d.restartMu.Unlock()
	d.machineMu.Lock()
	d.machineAfterRestart = gap.Reason != "first_start"
	d.machineMu.Unlock()
	kept := map[string]bool{}
	var open []string
	for _, a := range d.Store.Agents() {
		if w := a.EventWait; w != nil {
			kept[string(w.ID)] = true
			if w.Ending == nil {
				open = append(open, string(w.ID))
			}
		}
	}
	d.eventMu.Lock()
	restarts := map[string][]restartGap{}
	for id, gaps := range d.eventStateNow.WaitRestarts {
		if kept[id] {
			restarts[id] = gaps
		}
	}
	for _, id := range open {
		restarts[id] = append(restarts[id], gap)
	}
	if len(restarts) == 0 {
		restarts = nil
	}
	d.eventStateNow.WaitRestarts = restarts
	d.saveEventStateLocked()
	d.eventMu.Unlock()
	d.writeAlive(daemonAlive{LastAlive: at})
	log.Printf("restart: %s, down for %s", gap.Reason, gap.downForWords())
	return gap
}

// SayRestarted raises system.restarted, once, after the waits are resumed, so a wait that
// names it is woken by it and a workflow on it runs; then says once a minute that the host
// is alive.
func (d *Daemon) SayRestarted() {
	d.restartMu.Lock()
	gap := d.lastRestart
	if d.aliveStop == nil {
		d.aliveStop = make(chan struct{})
		stop := d.aliveStop
		safe.Go("alive", func() {
			t := time.NewTicker(aliveInterval)
			defer t.Stop()
			for {
				select {
				case <-stop:
					return
				case <-d.ctx.Done():
					return
				case <-t.C:
					d.writeAlive(daemonAlive{LastAlive: now()})
				}
			}
		})
	}
	d.restartMu.Unlock()
	if gap != nil {
		d.raise(wire.EventDraft{Name: "system.restarted", At: now(), Scope: macScope(), Sentence: restartedSentence(*gap), Details: gap.details()})
	}
}

// noteCleanStop writes the stop's time, so the next start says stopped rather than crashed.
func (d *Daemon) noteCleanStop() wire.Date {
	d.restartMu.Lock()
	if d.aliveStop != nil {
		close(d.aliveStop)
		d.aliveStop = nil
	}
	d.restartMu.Unlock()
	at := now()
	d.writeAlive(daemonAlive{LastAlive: at, StoppedAt: &at})
	return at
}

// noteCutOffAgents writes again, after the turns the stop cut off have ended, the stop's
// time with those agents, so the next start picks them up (#1605).
func (d *Daemon) noteCutOffAgents(at wire.Date) {
	d.resumeMu.Lock()
	cut := make(map[wire.UUID]wire.AgentState, len(d.cutOff))
	for id, was := range d.cutOff {
		cut[id] = was
	}
	d.resumeMu.Unlock()
	if len(cut) == 0 {
		return
	}
	d.writeAlive(daemonAlive{LastAlive: at, StoppedAt: &at, CutOff: cut})
}

// noticedAfterRestart is the details a crossing found at the first disk look after a
// restart carries, once.
func (d *Daemon) noticedAfterRestart() map[string]string {
	d.restartMu.Lock()
	defer d.restartMu.Unlock()
	if !d.diskAfterRestart {
		return nil
	}
	d.diskAfterRestart = false
	return map[string]string{"noticed": "after_restart"}
}
