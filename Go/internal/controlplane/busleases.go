package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Producer leases (#4731, spec 4724-event-bus, "The bus", step 6). Before each poll of a
// server's events a machine asks for the poll's lease (bus/lease), or renews it. One machine
// of the person holds each lease and polls; the others stand by, and an event the holder's
// poll makes (BusEvent.poll) is delivered to them. A lease not renewed for busLeaseFor goes
// to the next machine that asks, which polls from now (no backfill, #4726). The holder lets
// it go when its Mac sleeps or the subscription ends, so the next takes over at its next
// poll.
//
// A lease is v1/bus/<bus>/leases/<poll>.json, written with If-None-Match or If-Match, so
// several copies of the control plane give it to one machine. Which machines stand by is
// kept by the copy that holds them, as their subscriptions are.

const (
	// busLeaseFor is how long a lease lasts from its last renewal.
	busLeaseFor = 5 * time.Minute
	// busLeasesMost bounds one call; busPollMost each key.
	busLeasesMost = 100
	busPollMost   = 128
	// busStandbyFor is how long a machine that asked stands by without asking again: past
	// its slowest pace (5 minutes) with room.
	busStandbyFor = 10 * time.Minute
	// busLeaseKept is how long a lease file stays after it ended, for the sweep.
	busLeaseKept = 24 * time.Hour
)

// busLease is a lease file.
type busLease struct {
	Holder string    `json:"holder"`
	Until  time.Time `json:"until"`
}

func busLeaseKey(bus, poll string) string { return busPrefix + bus + "/leases/" + poll + ".json" }

func checkBusPoll(poll string) error {
	if poll == "" || len(poll) > busPollMost || strings.ContainsAny(poll, "/\\ ") {
		return fmt.Errorf("a poll is 1 to %d bytes with no / or space", busPollMost)
	}
	return nil
}

// busLeaseCall is bus/lease: each poll's lease taken, renewed or said to be another's, and
// the ones let go.
func (s *Service) busLeaseCall(ctx context.Context, host string, p wire.BusLease, now time.Time) (wire.BusLeased, error) {
	if s.records.Host(host) == nil {
		return wire.BusLeased{}, fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(p.Polls) > busLeasesMost || len(p.Release) > busLeasesMost {
		return wire.BusLeased{}, fail(invalidParams, "Send at most %d polls and %d to let go.", busLeasesMost, busLeasesMost)
	}
	for _, poll := range append(append([]string(nil), p.Polls...), p.Release...) {
		if err := checkBusPoll(poll); err != nil {
			return wire.BusLeased{}, fail(invalidParams, "A poll: %v.", err)
		}
	}
	bus := busOf(s.ownerOf(host))
	for _, poll := range p.Release {
		if err := s.busLetGo(ctx, bus, host, poll, now); err != nil {
			return wire.BusLeased{}, fail(storeUnavailable, "The lease could not be written: %v", err)
		}
	}
	out := wire.BusLeased{Leases: []wire.BusProducerLease{}}
	var standing []string
	for _, poll := range p.Polls {
		l, err := s.busTake(ctx, bus, host, poll, now)
		if err != nil {
			return wire.BusLeased{}, fail(storeUnavailable, "The lease could not be written: %v", err)
		}
		mine := l.Holder == host
		if !mine {
			standing = append(standing, poll)
		}
		out.Leases = append(out.Leases, wire.BusProducerLease{Poll: poll, Holder: l.Holder, Mine: mine,
			Until: l.Until.UTC().Format(time.RFC3339)})
	}
	s.busStandBy(host, p.Polls, standing, p.Release, now)
	return out, nil
}

// busTake gives host the lease when nobody holds it, it is host's, or it ended; otherwise
// it says who holds it. A race lost to another copy reads it again, once.
func (s *Service) busTake(ctx context.Context, bus, host, poll string, now time.Time) (busLease, error) {
	key := busLeaseKey(bus, poll)
	for attempt := 0; ; attempt++ {
		obj, err := s.cfg.Store.Get(ctx, key)
		if err != nil {
			return busLease{}, err
		}
		when := store.Absent
		if obj != nil {
			var l busLease
			if json.Unmarshal(obj.Data, &l) == nil && l.Holder != host && now.Before(l.Until) {
				return l, nil
			}
			when = store.Matching(obj.ETag)
		}
		l := busLease{Holder: host, Until: now.Add(busLeaseFor)}
		body, _ := json.Marshal(l)
		if _, err := s.cfg.Store.Put(ctx, key, body, when); err == nil {
			return l, nil
		} else if !store.IsConflict(err) || attempt > 0 {
			return busLease{}, err
		}
	}
}

// busLetGo ends host's lease on poll now; one another machine holds is left.
func (s *Service) busLetGo(ctx context.Context, bus, host, poll string, now time.Time) error {
	key := busLeaseKey(bus, poll)
	obj, err := s.cfg.Store.Get(ctx, key)
	if err != nil || obj == nil {
		return err
	}
	var l busLease
	if json.Unmarshal(obj.Data, &l) != nil || l.Holder != host || !now.Before(l.Until) {
		return nil
	}
	body, _ := json.Marshal(busLease{Holder: host, Until: now})
	if _, err := s.cfg.Store.Put(ctx, key, body, store.Matching(obj.ETag)); err != nil && !store.IsConflict(err) {
		return err
	}
	return nil
}

// busStandBy keeps which polls host stands by on: those another machine holds. A poll it
// holds, or lets go, it no longer stands by on.
func (s *Service) busStandBy(host string, asked, standing, released []string, now time.Time) {
	s.bus.mu.Lock()
	defer s.bus.mu.Unlock()
	if s.bus.standby == nil {
		s.bus.standby = map[string]map[string]time.Time{}
	}
	mine := s.bus.standby[host]
	if mine == nil {
		mine = map[string]time.Time{}
	}
	for _, poll := range append(append([]string(nil), asked...), released...) {
		delete(mine, poll)
	}
	for _, poll := range standing {
		mine[poll] = now
	}
	for poll, at := range mine {
		if now.Sub(at) > busStandbyFor {
			delete(mine, poll)
		}
	}
	if len(mine) == 0 {
		delete(s.bus.standby, host)
	} else {
		s.bus.standby[host] = mine
	}
}

// standsBy is whether host stands by on poll now. With s.bus.mu held.
func (b *eventBus) standsBy(host, poll string, now time.Time) bool {
	at, ok := b.standby[host][poll]
	return ok && now.Sub(at) <= busStandbyFor
}

// sweepBusLeases deletes at most most lease files that ended more than busLeaseKept ago.
func sweepBusLeases(ctx context.Context, st store.Store, now time.Time, most int) (int, error) {
	if most <= 0 {
		return 0, nil
	}
	keys, err := st.List(ctx, busPrefix)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, k := range keys {
		_, rest, ok := strings.Cut(strings.TrimPrefix(k.Key, busPrefix), "/")
		if !ok || !strings.HasPrefix(rest, "leases/") {
			continue
		}
		if n >= most {
			return n, nil
		}
		obj, err := st.Get(ctx, k.Key)
		if err != nil {
			return n, err
		}
		var l busLease
		if obj == nil || (json.Unmarshal(obj.Data, &l) == nil && now.Sub(l.Until) < busLeaseKept) {
			continue
		}
		if err := st.Delete(ctx, k.Key); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}
