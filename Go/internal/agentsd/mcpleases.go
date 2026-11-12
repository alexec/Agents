package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Producer leases (#4731, spec 4724-event-bus, "The bus", step 6). Before each poll of a
// server's events, this machine asks the control plane for the poll's lease (bus/lease),
// or renews it. One machine of the person holds each lease and polls; the others stand by,
// and the control plane delivers them what the holder's poll makes (BusEvent.poll).
//
// A poll is the folder's project, the server's name, the event and its filters, hashed: the
// same on every machine that polls the same thing (#4731, decided). A folder with no
// project, or a control plane without events.leases/1, has no lease: it polls as before.
//
// Only a subscription that waits alone hold stands by: a workflow and Archive when merged
// need the event's data, which the bus does not carry yet (#4825). They poll whoever holds
// the lease, and take it when it is free.
//
// The holder lets its leases go when the Mac goes to sleep, a subscription ends or stops,
// and agentsd stops, so another machine takes over at its next poll. One that takes over
// polls from now: no backfill (#4726).

const (
	// mcpLeaseRenewEvery is how often a holder renews its lease while it waits for its next
	// poll, within the lease's 5 minutes.
	mcpLeaseRenewEvery = 2 * time.Minute
	// mcpStandbyPace is how often a machine that stands by asks again.
	mcpStandbyPace = mcpPollDefault
)

// mcpLeaseBook is which subscriptions hold their poll's lease, and which stand by.
type mcpLeaseBook struct {
	mu sync.Mutex
	// held and standing are by subscription id, each its poll.
	held, standing map[string]string
}

// producerPoll is the key of a subscription's poll, or "" when it has no lease.
func (d *Daemon) producerPoll(folder, key string) string {
	project := d.envelopeProject(folder)
	if project == "" || key == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(project + "\n" + key))
	return hex.EncodeToString(sum[:16])
}

// mayStandBy is whether a subscription can leave its polls to another machine: only waits
// hold it.
func (s *mcpSubscription) mayStandBy() bool {
	return len(s.workflows) == 0 && !s.archives && len(s.waits) > 0
}

func (d *Daemon) leasesOn() bool {
	return d.askControl.Load() != nil && d.controlHas(wire.CapEventsLeases1)
}

// askLease is one bus/lease; nil when it could not be asked.
func (d *Daemon) askLease(ctx context.Context, polls, release []string) *wire.BusLeased {
	ask := d.askControl.Load()
	if ask == nil {
		return nil
	}
	c, cancel := context.WithTimeout(ctx, reportPatience)
	defer cancel()
	raw, err := (*ask)(c, wire.CallBusLease.Name, wire.BusLease{Polls: polls, Release: release})
	if err != nil {
		log.Printf("bus/lease: %v", err)
		return nil
	}
	var got wire.BusLeased
	if json.Unmarshal(raw, &got) != nil {
		return nil
	}
	return &got
}

// mcpMayPoll says whether this machine polls s now: it holds the lease, there is none, or
// s cannot stand by. Asking fails open: the machine polls.
func (d *Daemon) mcpMayPoll(ctx context.Context, s *mcpSubscription) bool {
	b := &d.mcpLeases
	b.mu.Lock()
	wasStanding := b.standing[s.id] != ""
	b.mu.Unlock()
	polls := func(holds string) bool {
		b.mu.Lock()
		defer b.mu.Unlock()
		delete(b.standing, s.id)
		if holds != "" {
			if b.held == nil {
				b.held = map[string]string{}
			}
			b.held[s.id] = holds
		} else {
			delete(b.held, s.id)
		}
		return true
	}
	key := d.producerPoll(s.folder, s.key)
	if key == "" || !d.leasesOn() {
		return polls("")
	}
	got := d.askLease(ctx, []string{key}, nil)
	if got == nil || len(got.Leases) != 1 || got.Leases[0].Poll != key {
		return polls("")
	}
	if l := got.Leases[0]; l.Mine {
		if wasStanding {
			log.Printf("mcp events: %s %s took the lease and polls from now", s.server, s.event)
		}
		return polls(key)
	}
	if !s.mayStandBy() {
		return polls("")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.held, s.id)
	if b.standing == nil {
		b.standing = map[string]string{}
	}
	if !wasStanding {
		log.Printf("mcp events: %s %s stands by: %s polls it", s.server, s.event, got.Leases[0].Holder)
	}
	b.standing[s.id] = key
	return false
}

// mcpHeldPoll is the poll whose lease s holds, or "".
func (d *Daemon) mcpHeldPoll(id string) string {
	d.mcpLeases.mu.Lock()
	defer d.mcpLeases.mu.Unlock()
	return d.mcpLeases.held[id]
}

// mcpWaitHolding is mcpSleep for a subscription, renewing the lease it holds every
// mcpLeaseRenewEvery so that a slow pace does not let it lapse.
func (d *Daemon) mcpWaitHolding(ctx context.Context, id string, wait time.Duration) bool {
	for wait > 0 {
		key := d.mcpHeldPoll(id)
		if key == "" {
			return d.mcpSleep(ctx, wait)
		}
		step := min(wait, mcpLeaseRenewEvery)
		if !d.mcpSleep(ctx, step) {
			return false
		}
		wait -= step
		if wait > 0 && d.mcpHeldPoll(id) == key {
			if got := d.askLease(ctx, []string{key}, nil); got != nil && len(got.Leases) == 1 && !got.Leases[0].Mine {
				// Another machine took it while this one waited: the next look decides.
				d.mcpLeases.mu.Lock()
				delete(d.mcpLeases.held, id)
				d.mcpLeases.mu.Unlock()
			}
		}
	}
	return true
}

// mcpLetGo forgets what s held or stood by on, and lets its lease go: it ended or stopped.
func (d *Daemon) mcpLetGo(id string) {
	d.mcpLeases.mu.Lock()
	key := d.mcpLeases.held[id]
	delete(d.mcpLeases.held, id)
	delete(d.mcpLeases.standing, id)
	d.mcpLeases.mu.Unlock()
	if key != "" && d.leasesOn() && d.ctx.Err() == nil {
		go d.askLease(d.ctx, nil, []string{key})
	}
}

// releaseProducerLeases lets every lease this machine holds go: its Mac goes to sleep, or
// agentsd stops. The subscriptions ask again at their next poll.
func (d *Daemon) releaseProducerLeases(ctx context.Context) {
	d.mcpLeases.mu.Lock()
	seen := map[string]bool{}
	var keys []string
	for _, k := range d.mcpLeases.held {
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	d.mcpLeases.held = nil
	d.mcpLeases.mu.Unlock()
	if len(keys) == 0 || !d.leasesOn() {
		return
	}
	sort.Strings(keys)
	for len(keys) > 0 {
		batch := keys[:min(len(keys), 100)]
		keys = keys[len(batch):]
		d.askLease(ctx, []string{}, batch)
	}
}

// busPollOf is the poll of an event this machine's poll raised, for its envelope on the
// bus; "" for any other.
func (d *Daemon) busPollOf(e wire.Event) string {
	if e.Details["mcp_event_id"] == "" || e.Details["subscription"] == "" || e.Scope.Folder == nil || !d.leasesOn() {
		return ""
	}
	return d.producerPoll(store.FolderPath(e.Scope.Folder.Value), e.Details["subscription"])
}

// takeStandbyDelivery raises an event the bus delivered for a poll this machine stands by
// on, as that subscription's own, so the waits that hold it wake as if this machine had
// polled it. False when no subscription here stands by on it.
func (d *Daemon) takeStandbyDelivery(e wire.BusEvent) bool {
	if e.Poll == nil || *e.Poll == "" {
		return false
	}
	d.mcpLeases.mu.Lock()
	var ids []string
	for id, key := range d.mcpLeases.standing {
		if key == *e.Poll {
			ids = append(ids, id)
		}
	}
	d.mcpLeases.mu.Unlock()
	sort.Strings(ids)
	// Its data, when the holder sealed a copy to this machine (#4825).
	data := d.openBusDelivery(e)
	e.Sealed = nil
	took := false
	for _, id := range ids {
		s := d.mcpSubscription(id)
		if s == nil || s.event != e.Type {
			continue
		}
		took = true
		details := map[string]string{"server": s.server, "event": s.event, "subscription": s.key, "time": e.Time,
			"bus_producer": e.Producer}
		if len(data) > 0 {
			details["payload"] = canonicalJSON(data)
		}
		from := strings.TrimPrefix(e.Producer, "agents:machine:#")
		sentence := s.server + " reported " + s.event
		if e.Subject != nil {
			details["subject"] = e.Subject.String()
			sentence += " on " + e.Subject.String()
		}
		if from != "" {
			sentence += ", from " + from
		}
		at := wire.DateOf(nowFunc())
		if t, err := time.Parse(time.RFC3339Nano, e.Time); err == nil {
			at = wire.DateOf(t)
		}
		raised := d.raiseEnveloped(wire.EventDraft{Name: s.event, At: at, Scope: folderScope(s.folder), Sentence: sentence,
			Details: details}, nil, &serverEnvelope{bus: &e, busData: data})
		d.lineageEvent(raised)
		log.Printf("mcp events: %s %s from the bus (position %d), polled by %s", s.server, s.event, raised.Position, from)
	}
	return took
}
