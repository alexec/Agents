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
// links and its sessions' states (#4274), and sends the control plane what changed
// (lineage/sync) a short time after each change, so lineage is there while it sleeps: the
// links started or ended, and the changes of state the store recorded. Only refs, states and
// times (principle 7).
//
// A send of its own, not with usage/rollup: the rollup goes hourly and is a costly call,
// and "working" must reach the control plane within seconds (#4265 pulses on it). Changes
// within lineageSyncAfter of each other go as one send.
//
// What is unsent is in <root>/lineage-sync.json. The first send, and the one after a control
// plane says it has no copy (a new or moved one), is every link and every change of state
// the store keeps, the first with reset.

const (
	lineageSyncAfter = 2 * time.Second
	// lineageSyncLinks and lineageSyncStates bound one send, as the control plane does.
	lineageSyncLinks  = 2_000
	lineageSyncStates = 1_000
	// lineageStatesHeld and lineageLinksSaved bound what is held unsent: past them, a whole
	// send is to make instead, from what the store keeps.
	lineageStatesHeld = 5_000
	lineageLinksSaved = 2_000
)

type lineageSyncFile struct {
	// Kept is true in every file written; a file without it is a whole send to make.
	Kept bool `json:"kept"`
	// Full is a whole send to make: every link and state, the first send with reset.
	Full bool `json:"full,omitempty"`
	// Reset is that the next send starts the control plane's copy again.
	Reset bool `json:"reset,omitempty"`
	// Links is each link to send, by lineageSyncKey, as it is now.
	Links map[string]wire.LineageLink `json:"links,omitempty"`
	// States is the changes of state to send, oldest first.
	States []wire.LineageStateChange `json:"states,omitempty"`
}

type lineageSyncBook struct {
	syncMu    sync.Mutex
	syncFile  *lineageSyncFile
	syncTimer *time.Timer
	// syncStatesGen moves each time States is made again, so a send's own are taken off
	// it only when it is the same list.
	syncStatesGen int
	// syncSending keeps one send at a time.
	syncSending sync.Mutex
}

// notingStore is the lineage store, noting each link it starts or ends, and each change of
// state it records, for the next send.
type notingStore struct {
	lineage.Store
	link  func(wire.LineageLink)
	state func(wire.LineageStateChange)
}

func (s notingStore) Link(r wire.LineageLinkRequest, at time.Time) (wire.LineageLink, error) {
	l, err := s.Store.Link(r, at)
	// An active link is the answer unchanged, and was noted when it started.
	if err == nil && l.At == wire.DateOf(at) {
		s.link(l)
	}
	return l, err
}

func (s notingStore) End(r wire.LineageEndRequest, at time.Time) ([]wire.LineageLink, error) {
	ended, err := s.Store.End(r, at)
	for _, l := range ended {
		s.link(l)
	}
	return ended, err
}

func (s notingStore) SetState(n wire.LineageNode, state wire.LineageSessionStateName, at time.Time) (bool, error) {
	moved, err := s.Store.SetState(n, state, at)
	if err == nil && moved {
		s.state(wire.LineageStateChange{Node: n, State: state, At: wire.DateOf(at)})
	}
	return moved, err
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
		readStore(d.lineageSyncPath(), f, "all of lineage goes to the control plane again")
		if !f.Kept {
			*f = lineageSyncFile{Kept: true, Full: true}
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
	if f := d.syncLocked(); !f.Full {
		f.Links[lineageSyncKey(l)] = l
	}
	d.syncMu.Unlock()
	d.lineageSyncSoon()
}

// noteStateChanged keeps c for the next send; past lineageStatesHeld, a whole send is to
// make instead.
func (d *Daemon) noteStateChanged(c wire.LineageStateChange) {
	d.syncMu.Lock()
	if f := d.syncLocked(); !f.Full {
		f.States = append(f.States, c)
		// A whole send holds every state the store keeps, so the bound is past that.
		if len(f.States) > lineage.MostStates+lineageStatesHeld {
			f.Full, f.Reset, f.States, f.Links = true, false, nil, map[string]wire.LineageLink{}
			d.syncStatesGen++
		}
	}
	d.syncMu.Unlock()
	d.lineageSyncSoon()
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
	defer d.saveLineageSync()
	for d.ctx.Err() == nil {
		send, gen, ok := d.unsentLineage()
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
		d.lineageSent(send, gen, answer.Full != nil && *answer.Full)
	}
}

// unsentLineage is the next send: the oldest links and states first, at most a send's
// bound, and the generation of States it took from. A whole send to make takes every link
// and every change of state the store keeps first.
func (d *Daemon) unsentLineage() (wire.LineageSync, int, bool) {
	d.syncMu.Lock()
	f := d.syncLocked()
	if f.Full {
		// What is noted from now is kept as it is then; All, read outside syncMu (the store
		// notes under it), fills in what came before.
		f.Full, f.Reset, f.States = false, true, nil
		f.Links = map[string]wire.LineageLink{}
		d.syncStatesGen++
		d.syncMu.Unlock()
		links, states := d.lineage().All()
		d.syncMu.Lock()
		for _, l := range links {
			if k := lineageSyncKey(l); !hasLink(f.Links, k) {
				f.Links[k] = l
			}
		}
		f.States = append(states, f.States...)
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
	return send, d.syncStatesGen, true
}

// lineageSent drops what went, but a link that changed on its way. When the control plane
// had no copy of the links, the next send is every link again.
func (d *Daemon) lineageSent(send wire.LineageSync, gen int, full bool) {
	d.syncMu.Lock()
	defer d.syncMu.Unlock()
	f := d.syncLocked()
	if gen == d.syncStatesGen {
		f.States = f.States[min(len(send.States), len(f.States)):]
	}
	if full {
		// The states were kept; the links come again with every state, as a whole send is.
		f.Full, f.Reset, f.States = true, false, nil
		f.Links = map[string]wire.LineageLink{}
		d.syncStatesGen++
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

// saveLineageSync writes the file. Past its bounds it says to make a whole send instead,
// so it stays small.
func (d *Daemon) saveLineageSync() {
	d.syncMu.Lock()
	defer d.syncMu.Unlock()
	if d.syncFile == nil {
		return
	}
	saved := *d.syncFile
	if len(saved.Links) > lineageLinksSaved || len(saved.States) > lineageStatesHeld {
		saved.Full, saved.Reset, saved.Links, saved.States = true, false, nil, nil
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
