package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The merged copy of lineage (#4273, #4275): this machine stays the system of record for its
// links, and sends the control plane what changed (lineage/sync) a short time after each
// change, so lineage is there while it sleeps: the links started or ended, and its sessions'
// changes of state. Only refs, states and times (principle 7).
//
// A send of its own, not with usage/rollup: the rollup goes hourly and is a costly call,
// and "working" must reach the control plane within seconds (#4265 pulses on it). Changes
// within lineageSyncAfter of each other go as one send.
//
// What is unsent is in <root>/lineage-sync.json. The first send, and the one after a control
// plane says it has no copy (a new or moved one), is every link, the first with reset.

const (
	lineageSyncAfter = 2 * time.Second
	// lineageSyncLinks and lineageSyncStates bound one send, as the control plane does.
	lineageSyncLinks  = 2_000
	lineageSyncStates = 1_000
	// lineageStatesHeld bounds the changes held while the control plane cannot be reached:
	// the oldest go first.
	lineageStatesHeld = 5_000
	// lineageLinksSaved bounds the links saved unsent: past it, the file says to send them
	// all again, which All has.
	lineageLinksSaved = 2_000
)

type lineageSyncFile struct {
	// Full is a whole send to make: every link, the first send with reset.
	Full bool `json:"full,omitempty"`
	// Reset is that the next send starts the control plane's copy again.
	Reset bool `json:"reset,omitempty"`
	// Links is each link to send, by lineageSyncKey, as it is now.
	Links map[string]wire.LineageLink `json:"links,omitempty"`
	// Told is each session's state as last noted; a file without it is a whole send to make.
	Told map[wire.UUID]wire.LineageSessionState `json:"told"`
	// States is the changes to send, oldest first.
	States []wire.LineageStateChange `json:"states,omitempty"`
}

type lineageSyncBook struct {
	syncMu    sync.Mutex
	syncFile  *lineageSyncFile
	syncTimer *time.Timer
	syncOnce  sync.Once
	// syncDropped counts the changes dropped past lineageStatesHeld, so a send's own are
	// taken off States after it.
	syncDropped int
	// syncSending keeps one send at a time.
	syncSending sync.Mutex
}

// notingStore is the lineage store, noting each link it starts or ends for the next send.
type notingStore struct {
	lineage.Store
	note func(wire.LineageLink)
}

func (s notingStore) Link(r wire.LineageLinkRequest, at time.Time) (wire.LineageLink, error) {
	l, err := s.Store.Link(r, at)
	// An active link is the answer unchanged, and was noted when it started.
	if err == nil && l.At == wire.DateOf(at) {
		s.note(l)
	}
	return l, err
}

func (s notingStore) End(r wire.LineageEndRequest, at time.Time) ([]wire.LineageLink, error) {
	ended, err := s.Store.End(r, at)
	for _, l := range ended {
		s.note(l)
	}
	return ended, err
}

func lineageSyncKey(l wire.LineageLink) string {
	return l.From.Kind + "\t" + l.From.Ref + "\t" + l.To.Kind + "\t" + l.To.Ref + "\t" + l.Rel + "\t" +
		strconv.FormatFloat(float64(l.At), 'g', -1, 64)
}

func (d *Daemon) lineageSyncPath() string { return filepath.Join(d.Store.Loc.Root, "lineage-sync.json") }

// syncLocked is the file, read on first use. None, or one that cannot be read, is a whole
// send to make.
func (d *Daemon) syncLocked() *lineageSyncFile {
	if d.syncFile == nil {
		f := &lineageSyncFile{}
		readStore(d.lineageSyncPath(), f, "every link goes to the control plane again")
		if f.Told == nil {
			f.Full = true
			f.Told = map[wire.UUID]wire.LineageSessionState{}
		}
		if f.Links == nil {
			f.Links = map[string]wire.LineageLink{}
		}
		d.syncFile = f
	}
	return d.syncFile
}

// noteLinkChanged keeps l for the next send.
func (d *Daemon) noteLinkChanged(l wire.LineageLink) {
	d.syncMu.Lock()
	f := d.syncLocked()
	if !f.Full {
		f.Links[lineageSyncKey(l)] = l
	}
	d.syncMu.Unlock()
	d.lineageSyncSoon()
}

// sessionStateOf is a session's state in the graph (#4273), from the group the sidebars put
// it in.
func sessionStateOf(a *wire.Agent) wire.LineageSessionState {
	switch Group(a) {
	case "running":
		return wire.LineageSessionStateWorking
	case "waiting":
		return wire.LineageSessionStateWaiting
	case "needsAttention", "blocked":
		return wire.LineageSessionStateNeedsYou
	case "archived":
		return wire.LineageSessionStateArchived
	}
	return wire.LineageSessionStateStopped
}

// noteSessionState keeps a's state for the next send when it moved. A writer agent is in
// no graph.
func (d *Daemon) noteSessionState(a *wire.Agent) {
	if a.Purpose != nil {
		return
	}
	state := sessionStateOf(a)
	d.syncMu.Lock()
	moved := d.noteStateLocked(a.ID, state, nowFunc())
	d.syncMu.Unlock()
	if moved {
		d.lineageSyncSoon()
	}
}

// noteSessionDeleted keeps a deleted session's last change; it is told no more.
func (d *Daemon) noteSessionDeleted(a *wire.Agent) {
	if a.Purpose != nil {
		return
	}
	d.syncMu.Lock()
	d.noteStateLocked(a.ID, wire.LineageSessionStateDeleted, nowFunc())
	delete(d.syncLocked().Told, a.ID)
	d.syncMu.Unlock()
	d.lineageSyncSoon()
}

func (d *Daemon) noteStateLocked(id wire.UUID, state wire.LineageSessionState, at time.Time) bool {
	f := d.syncLocked()
	if told, ok := f.Told[id]; ok && told == state {
		return false
	}
	f.Told[id] = state
	f.States = append(f.States, wire.LineageStateChange{Node: sessionNode(id), State: state, At: wire.DateOf(at)})
	if over := len(f.States) - lineageStatesHeld; over > 0 {
		f.States = append([]wire.LineageStateChange(nil), f.States[over:]...)
		d.syncDropped += over
	}
	return true
}

// noteSessionsNow notes each session's state as it is now, once a run, for what changed
// while this host was not running, and forgets the sessions that are no longer here.
func (d *Daemon) noteSessionsNow() {
	agents := d.Store.Agents()
	here := map[wire.UUID]bool{}
	for i := range agents {
		here[agents[i].ID] = true
		d.noteSessionState(&agents[i])
	}
	d.syncMu.Lock()
	f := d.syncLocked()
	for id := range f.Told {
		if !here[id] {
			delete(f.Told, id)
		}
	}
	d.syncMu.Unlock()
}

// lineageSyncSoon sends within lineageSyncAfter, with what else changes by then.
func (d *Daemon) lineageSyncSoon() {
	if d.askControl.Load() == nil {
		return
	}
	d.syncMu.Lock()
	defer d.syncMu.Unlock()
	if d.syncTimer == nil {
		d.syncTimer = time.AfterFunc(lineageSyncAfter, func() {
			d.syncMu.Lock()
			d.syncTimer = nil
			d.syncMu.Unlock()
			d.sendLineage()
		})
	}
}

// sendLineage sends what is unsent, if this host has a control plane that takes it, until
// none is left or a send fails; a failed send is tried again on the next change, the next
// hour or the next connection.
func (d *Daemon) sendLineage() {
	ask := d.askControl.Load()
	if ask == nil || !d.controlHas(wire.CapLineageGraph1) {
		return
	}
	d.syncSending.Lock()
	defer d.syncSending.Unlock()
	d.syncOnce.Do(d.noteSessionsNow)
	defer d.saveLineageSync()
	for d.ctx.Err() == nil {
		send, dropped, ok := d.unsentLineage()
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
		raw, err := (*ask)(ctx, wire.CallLineageSync.Name, send)
		cancel()
		var answer wire.LineageSyncAnswer
		if err == nil && len(raw) > 0 {
			err = json.Unmarshal(raw, &answer)
		}
		if err != nil {
			log.Printf("lineage/sync: not sent, tried again later: %v", err)
			return
		}
		d.lineageSent(send, dropped, answer.Full != nil && *answer.Full)
	}
}

// unsentLineage is the next send: the oldest links and states first, at most a send's
// bound. A whole send to make takes every link first.
func (d *Daemon) unsentLineage() (wire.LineageSync, int, bool) {
	d.syncMu.Lock()
	f := d.syncLocked()
	if f.Full {
		// A link noted from now is kept as it is then; All, read outside syncMu (the store
		// notes under it), fills in the rest.
		f.Full, f.Reset = false, true
		f.Links = map[string]wire.LineageLink{}
		d.syncMu.Unlock()
		all := d.lineage().All()
		d.syncMu.Lock()
		for _, l := range all {
			if k := lineageSyncKey(l); !hasLink(f.Links, k) {
				f.Links[k] = l
			}
		}
	}
	defer d.syncMu.Unlock()
	if !f.Reset && len(f.Links) == 0 && len(f.States) == 0 {
		return wire.LineageSync{}, 0, false
	}
	var send wire.LineageSync
	if f.Reset {
		t := true
		send.Reset = &t
	}
	links := make([]wire.LineageLink, 0, len(f.Links))
	for _, l := range f.Links {
		links = append(links, l)
	}
	sort.Slice(links, func(i, j int) bool {
		if links[i].At != links[j].At {
			return links[i].At < links[j].At
		}
		return lineageSyncKey(links[i]) < lineageSyncKey(links[j])
	})
	send.Links = links[:min(len(links), lineageSyncLinks)]
	send.States = append([]wire.LineageStateChange(nil), f.States[:min(len(f.States), lineageSyncStates)]...)
	return send, d.syncDropped, true
}

// lineageSent drops what went, but a link that changed on its way. When the control plane
// had no copy of the links, the next send is every link again.
func (d *Daemon) lineageSent(send wire.LineageSync, dropped int, full bool) {
	d.syncMu.Lock()
	defer d.syncMu.Unlock()
	f := d.syncLocked()
	// The ones dropped while it was on its way were the oldest: the send's own.
	sent := max(0, len(send.States)-(d.syncDropped-dropped))
	f.States = f.States[min(sent, len(f.States)):]
	if full {
		f.Full, f.Reset = true, false
		f.Links = map[string]wire.LineageLink{}
		return
	}
	if send.Reset != nil {
		f.Reset = false
	}
	for _, l := range send.Links {
		k := lineageSyncKey(l)
		if now, ok := f.Links[k]; ok && sameLink(now, l) {
			delete(f.Links, k)
		}
	}
}

func hasLink(links map[string]wire.LineageLink, k string) bool {
	_, ok := links[k]
	return ok
}

func sameLink(a, b wire.LineageLink) bool {
	if (a.EndedAt == nil) != (b.EndedAt == nil) || a.EndedAt != nil && *a.EndedAt != *b.EndedAt {
		return false
	}
	return a.From == b.From && a.To == b.To && a.Rel == b.Rel && a.Source == b.Source && a.At == b.At
}

// saveLineageSync writes the file. Past lineageLinksSaved links it says to send them all
// again instead, so it stays small.
func (d *Daemon) saveLineageSync() {
	d.syncMu.Lock()
	defer d.syncMu.Unlock()
	if d.syncFile == nil {
		return
	}
	saved := *d.syncFile
	if len(saved.Links) > lineageLinksSaved {
		saved.Full, saved.Reset, saved.Links = true, false, nil
	}
	if err := writeStore(d.lineageSyncPath(), saved); err != nil {
		log.Printf("lineage-sync.json: could not save: %v", err)
	}
}

// closeLineageSync saves what is unsent at shutdown.
func (d *Daemon) closeLineageSync() {
	d.syncMu.Lock()
	if d.syncTimer != nil {
		d.syncTimer.Stop()
		d.syncTimer = nil
	}
	d.syncMu.Unlock()
	d.saveLineageSync()
}
