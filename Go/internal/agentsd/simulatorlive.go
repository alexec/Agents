package agentsd

import (
	"context"
	"crypto/sha256"
	"strings"
	"sync/atomic"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A simulator's live tile (#4222): an agent drives a simulator with its own xcrun simctl or
// the device-interaction tools, which agentsd never sees. What it does see is the lease: one
// named simulator:<udid> says which simulator, and that the agent uses it. While the agent
// holds it and a client has its chat in front, the simulator's screen is read every
// simulatorLivePace; the grant and each changed picture count as a drive (d.drove), and a
// changed picture goes as live/frame, source simulator. sendLive keeps the two rules: within
// liveDriveWindow of the last drive, and only to the clients with the chat in front. With no
// client in front nothing is read at all.

const (
	// simulatorLeasePrefix starts a lease name that says a simulator by its UDID.
	simulatorLeasePrefix = "simulator:"
	// simulatorLiveHeight is the tile's picture (320 points) on a 2x screen.
	simulatorLiveHeight = 640
)

// simulatorLivePace is how often a held simulator's screen is read. Atomic, so a test can
// shorten it.
var simulatorLivePace = func() *atomic.Int64 {
	var v atomic.Int64
	v.Store(int64(time.Second))
	return &v
}()

// simulatorLiveShot reads a simulator's screen; a test puts a fake in its place.
var simulatorLiveShot = simulatorScreen

// simulatorNameOf is a simulator's name ("iPhone 17"), or "" when simctl does not list it; a
// test puts a fake in its place.
var simulatorNameOf = func(ctx context.Context, udid string) string {
	for _, s := range listSimulators(ctx).Simulators {
		if strings.EqualFold(s.Udid, udid) {
			return s.Name
		}
	}
	return ""
}

// simulatorLease is the UDID a lease name says (simulator:<udid>, or the UDID alone), in
// capitals as simctl gives it, or "" for any other name.
func simulatorLease(name wire.ResourceName) string {
	udid, _ := strings.CutPrefix(strings.ToLower(string(name)), simulatorLeasePrefix)
	if !simulatorUDID.MatchString(udid) {
		return ""
	}
	return strings.ToUpper(udid)
}

// simulatorDisplay is what a simulator lease is called where a person reads it: its name, or
// "Simulator <udid>" when simctl does not list it. "" for a name that is not a simulator's.
// Not under leaseMu: it runs simctl.
func simulatorDisplay(given string) string {
	name, _ := resourceName(given)
	udid := simulatorLease(name)
	if udid == "" {
		return ""
	}
	if s := simulatorNameOf(context.Background(), udid); s != "" {
		return s
	}
	return "Simulator " + udid
}

// holdsLease is whether agent holds the resource name now.
func (d *Daemon) holdsLease(agent wire.UUID, name wire.ResourceName) bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	d.loadLeases()
	e := d.book.Entries[name]
	return e != nil && holderIndex(e, agent) >= 0
}

// simulatorWatch is a holder's watch on one simulator lease.
type simulatorWatch struct {
	agent wire.UUID
	name  wire.ResourceName
}

// simulatorWatchEnds is whether the watch k stops, its holder having let go: then it is gone
// from the book, under liveMu, so a grant just after starts a new one.
func (d *Daemon) simulatorWatchEnds(k simulatorWatch, holder wire.UUID) bool {
	d.liveMu.Lock()
	defer d.liveMu.Unlock()
	if d.holdsLease(holder, k.name) {
		return false
	}
	delete(d.simulatorWatches, k)
	return true
}

// watchSimulator follows a simulator lease just granted, until its holder lets go of it or
// the host stops. Only one watch runs for each holder and simulator.
func (d *Daemon) watchSimulator(l wire.Lease) {
	udid := simulatorLease(l.Resource)
	if udid == "" {
		return
	}
	k := simulatorWatch{sessionKey(l.Holder), l.Resource}
	d.liveMu.Lock()
	if d.simulatorWatches == nil {
		d.simulatorWatches = map[simulatorWatch]bool{}
	}
	running := d.simulatorWatches[k]
	d.simulatorWatches[k] = true
	d.liveMu.Unlock()
	// The grant is the first drive: the agent took the lease to use the simulator.
	d.drove(l.Holder, wire.LiveSourceSimulator, nil)
	if running {
		return
	}
	d.goLoop("simulator tile", func(ctx context.Context) {
		var last [32]byte
		seen := false
		defer func() {
			if ctx.Err() != nil {
				d.liveMu.Lock()
				delete(d.simulatorWatches, k)
				d.liveMu.Unlock()
			}
		}()
		for {
			if d.simulatorWatchEnds(k, l.Holder) {
				return
			}
			if len(d.inFront(l.Holder)) == 0 {
				// Nobody looks: nothing is read, and the next picture is a new start.
				seen = false
			} else if s, err := simulatorLiveShot(ctx, udid, simulatorLiveHeight); err == nil {
				sum := sha256.Sum256(s.Jpeg)
				if seen && sum != last {
					d.drove(l.Holder, wire.LiveSourceSimulator, nil)
				}
				if !seen || sum != last {
					width, height := s.Width, s.Height
					d.sendLive(wire.LiveFrame{Source: wire.LiveSourceSimulator, AgentID: l.Holder, Image: liveImage(s.Jpeg),
						Width: &width, Height: &height, Title: optional(l.DisplayName)})
				}
				last, seen = sum, true
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Duration(simulatorLivePace.Load())):
			}
		}
	})
}
