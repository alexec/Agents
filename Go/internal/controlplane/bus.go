package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The event bus (#4729, spec 4724-event-bus, "The bus"). Each machine publishes the
// events it records (bus/publish), envelope only. The control plane keeps the first copy
// of each id on its person's bus and drops a later one, from any machine, with a
// create-if-absent write in the store, so several copies agree. It delivers a new event at
// once (bus/deliver) to each machine of the person whose subscriptions (bus/subscribe)
// match it: the copy that took it delivers to the machines it holds, and every other copy,
// told on the mesh, to the ones it holds.
//
// Best effort (Alex, 2026-11-11, #4726): no backfill and no resend. A machine that is not
// connected misses the event, and a rare copy can still be delivered twice (two copies of
// the control plane racing). Consumers read the subject's state now.
//
// The bus log is the last busLogKept envelopes of each person's bus, for dedupe and the
// Events page (#4732), not for redelivery: v1/bus/<bus>/log/<time>-<id hash>.json is the
// envelope, and v1/bus/<bus>/ids/<id hash>.json says it is on the bus. The sweep keeps
// the newest busLogKept and deletes both files of the rest.
//
// The envelope is routing data only: refs, names and times (principle 7). Its data, which
// can be a customer's words, comes only sealed by the machine that raised it to each machine
// of its person's lock (#4825): the control plane checks the copies' sizes, keeps them in
// the bus log, and gives each machine its own copy only. It opens none, and cannot make one
// up: inside each is the raising machine's signature.

const (
	busPrefix = "v1/bus/"
	// busLogKept is how many envelopes each person's bus keeps (#4726).
	busLogKept = 100_000
	// busPublishMost and busSubscriptionsMost bound one call, as the wire says.
	busPublishMost       = 100
	busSubscriptionsMost = 1_000
	// busTopicsMost bounds one subscription's topics; busTextMost each text in it.
	busTopicsMost = 100
	busTextMost   = 1_024
	// busSealedMost bounds an event's sealed copies: one per machine of the person.
	busSealedMost = 64
	// busSealedBytes bounds one copy: 256 KB of data, the raising machine's key and
	// signature, and the seal's tag; busEncapsulatedBytes its encapsulated key (P-256).
	busSealedBytes       = 256<<10 + 65 + 64 + 16
	busEncapsulatedBytes = 65
	// busLogStamp sorts a log file by when the control plane took it.
	busLogStamp = "20060102T150405.000000000Z"
)

// eventBus is what this copy holds of the bus: the subscriptions of the machines it holds,
// and what it dropped.
type eventBus struct {
	mu sync.Mutex
	// subs is each machine's subscriptions, as its last bus/subscribe sent them.
	subs map[string][]wire.BusSubscription
	// standby is the polls each machine stands by on (#4731), and when it last asked.
	standby map[string]map[string]time.Time
	// kept, dropped and delivered count since this copy started.
	kept, dropped, delivered atomic.Int64
}

// busOf is the name of a person's bus in the store: one per person today (#4726).
func busOf(person string) string {
	sum := sha256.Sum256([]byte(person))
	return hex.EncodeToString(sum[:8])
}

func busIDHash(id string) string {
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:16])
}

func busIDKey(bus, hash string) string { return busPrefix + bus + "/ids/" + hash + ".json" }

func busLogKey(bus string, at time.Time, hash string) string {
	return busPrefix + bus + "/log/" + at.UTC().Format(busLogStamp) + "-" + hash + ".json"
}

// busPeer is a new event on the mesh, for the machines other copies hold.
type busPeer struct {
	Person string        `json:"person"`
	Event  wire.BusEvent `json:"event"`
	// PollOnly is a copy that was dropped: only the machines that stand by on its poll get
	// it (#4731), as another poll may have made the copy that was kept.
	PollOnly bool `json:"pollOnly,omitempty"`
}

// checkBusEvent says what is wrong with an envelope a machine sent, if anything.
func checkBusEvent(e wire.BusEvent) error {
	switch {
	case e.Specversion != "1.0":
		return fmt.Errorf("specversion is %q, not 1.0", e.Specversion)
	case e.ID == "" || len(e.ID) > busTextMost:
		return fmt.Errorf("an id is 1 to %d bytes", busTextMost)
	case e.Type == "" || !strings.Contains(e.ID, "@"+e.Type):
		return fmt.Errorf("the id %q does not say the type %q", e.ID, e.Type)
	case e.Provider == "" || len(e.Provider) > busTextMost || len(e.Topic) > busTextMost:
		return fmt.Errorf("the provider is 1 to %d bytes, the topic at most %d", busTextMost, busTextMost)
	case len(e.Source) > 2*busTextMost || len(e.Producer) > busTextMost || len(e.Time) > 64:
		return fmt.Errorf("the source, the producer or the time is too long")
	case e.Subject != nil && e.Subject.Check() != nil:
		return fmt.Errorf("the subject is not a ref: %v", e.Subject.Check())
	case e.Poll != nil && checkBusPoll(*e.Poll) != nil:
		return checkBusPoll(*e.Poll)
	case len(e.Sealed) > busSealedMost:
		return fmt.Errorf("at most %d sealed copies", busSealedMost)
	}
	to := make(map[string]bool, len(e.Sealed))
	for _, c := range e.Sealed {
		switch {
		case c.Machine == "" || len(c.Machine) > busTextMost || to[c.Machine]:
			return fmt.Errorf("a sealed copy names no machine, or one named before")
		case len(c.Sealed.Encapsulated) != busEncapsulatedBytes || len(c.Sealed.Ciphertext) > busSealedBytes:
			return fmt.Errorf("a sealed copy is more than 256 KB of data")
		}
		to[c.Machine] = true
	}
	return nil
}

// busFor is e as it goes to host: with that machine's own sealed copy only, or none.
func busFor(e wire.BusEvent, host string) wire.BusEvent {
	sealed := e.Sealed
	e.Sealed = nil
	for _, c := range sealed {
		if c.Machine == host {
			e.Sealed = []wire.BusSealedData{c}
			break
		}
	}
	return e
}

// busPublish is bus/publish: each new id goes on the machine's person's bus, into the
// bus log, and to the machines whose subscriptions match it; a copy of an id already on
// the bus is dropped and counted.
func (s *Service) busPublish(ctx context.Context, host string, p wire.BusPublish, now time.Time) (wire.BusPublished, error) {
	if s.records.Host(host) == nil {
		return wire.BusPublished{}, fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(p.Events) > busPublishMost {
		return wire.BusPublished{}, fail(invalidParams, "Send at most %d events at a time.", busPublishMost)
	}
	for _, e := range p.Events {
		if err := checkBusEvent(e); err != nil {
			return wire.BusPublished{}, fail(invalidParams, "An event: %v.", err)
		}
	}
	person := s.ownerOf(host)
	bus := busOf(person)
	out := wire.BusPublished{}
	for _, e := range p.Events {
		isNew, err := s.busKeep(ctx, bus, e, now)
		if err != nil {
			return out, fail(storeUnavailable, "The bus could not be written: %v", err)
		}
		if !isNew {
			out.Dropped++
			s.bus.dropped.Add(1)
			s.metrics.Bus("dropped")
			// The kept copy may have come from another poll: the machines that stand by on
			// this one get it still (#4731). They drop one they have.
			if e.Poll != nil {
				s.busDeliverTo(person, host, e, true)
				if s.mesh != nil {
					s.mesh.broadcast(encodePeer("bus", busPeer{Person: person, Event: e, PollOnly: true}))
				}
			}
			continue
		}
		out.Kept++
		s.bus.kept.Add(1)
		s.metrics.Bus("kept")
		s.busDeliver(person, host, e)
		if s.mesh != nil {
			s.mesh.broadcast(encodePeer("bus", busPeer{Person: person, Event: e}))
		}
	}
	return out, nil
}

// busKeep writes e on the bus, true when its id was not there: the id's file with a
// create-if-absent write, then its place in the log, which no one else writes.
func (s *Service) busKeep(ctx context.Context, bus string, e wire.BusEvent, now time.Time) (bool, error) {
	hash := busIDHash(e.ID)
	logKey := busLogKey(bus, now, hash)
	mark, err := records.Encode(map[string]any{"id": e.ID, "log": logKey, "at": records.At(now)})
	if err != nil {
		return false, err
	}
	if _, err := s.cfg.Store.Put(ctx, busIDKey(bus, hash), mark, store.Absent); err != nil {
		if store.IsConflict(err) {
			return false, nil
		}
		return false, err
	}
	body, err := json.Marshal(e)
	if err != nil {
		return true, err
	}
	if _, err := s.cfg.Store.Put(ctx, logKey, body, store.Always); err != nil {
		// The id is on the bus; only the Events page misses it.
		s.log(fmt.Sprintf("the bus log missed %s: %v", e.ID, err))
	}
	return true, nil
}

// busSubscribe is bus/subscribe: the machine's subscriptions, in place of the ones before.
func (s *Service) busSubscribe(host string, sub wire.BusSubscribe) (wire.BusSubscribed, error) {
	if s.records.Host(host) == nil {
		return wire.BusSubscribed{}, fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(sub.Subscriptions) > busSubscriptionsMost {
		return wire.BusSubscribed{}, fail(invalidParams, "Send at most %d subscriptions.", busSubscriptionsMost)
	}
	list := make([]wire.BusSubscription, 0, len(sub.Subscriptions))
	for _, one := range sub.Subscriptions {
		if err := checkBusSubscription(one); err != nil {
			return wire.BusSubscribed{}, fail(invalidParams, "A subscription: %v.", err)
		}
		for i, t := range one.Topics {
			one.Topics[i] = strings.ToLower(t)
		}
		list = append(list, one)
	}
	s.bus.mu.Lock()
	defer s.bus.mu.Unlock()
	if s.bus.subs == nil {
		s.bus.subs = map[string][]wire.BusSubscription{}
	}
	if len(list) == 0 {
		delete(s.bus.subs, host)
	} else {
		s.bus.subs[host] = list
	}
	return wire.BusSubscribed{Count: int64(len(list))}, nil
}

func checkBusSubscription(sub wire.BusSubscription) error {
	text := func(p *string) bool { return p == nil || len(*p) <= busTextMost }
	switch {
	case sub.ID == "" || len(sub.ID) > busTextMost:
		return fmt.Errorf("an id is 1 to %d bytes", busTextMost)
	case !text(sub.Provider) || !text(sub.Type):
		return fmt.Errorf("the provider or the type is more than %d bytes", busTextMost)
	case len(sub.Topics) > busTopicsMost:
		return fmt.Errorf("at most %d topics", busTopicsMost)
	case sub.Subject != nil && sub.Subject.Check() != nil:
		return fmt.Errorf("the subject is not a ref: %v", sub.Subject.Check())
	}
	for _, t := range sub.Topics {
		if len(t) > busTextMost {
			return fmt.Errorf("a topic is more than %d bytes", busTextMost)
		}
	}
	return nil
}

// busMatches says whether a subscription takes an event: every field it has matches the
// envelope.
func busMatches(sub wire.BusSubscription, e wire.BusEvent) bool {
	if sub.Provider != nil && *sub.Provider != "" && *sub.Provider != e.Provider {
		return false
	}
	if sub.Type != nil && *sub.Type != "" {
		if noun, ok := strings.CutSuffix(*sub.Type, ".*"); ok {
			if !strings.HasPrefix(e.Type, noun+".") {
				return false
			}
		} else if *sub.Type != e.Type {
			return false
		}
	}
	if len(sub.Topics) > 0 && !slices.Contains(sub.Topics, strings.ToLower(e.Topic)) {
		return false
	}
	if sub.Subject != nil && (e.Subject == nil || sub.Subject.String() != e.Subject.String()) {
		return false
	}
	return true
}

// busDeliver sends e to each machine of person held here whose subscriptions match it,
// once, with the ones that do, or that stands by on the poll that made it (#4731), but the
// machine that published it, which has it. A machine no longer held here loses its
// subscriptions: it sends them again where it connects.
func (s *Service) busDeliver(person, publisher string, e wire.BusEvent) {
	s.busDeliverTo(person, publisher, e, false)
}

// busDeliverTo is busDeliver; pollOnly sends e only to the machines that stand by on its
// poll.
func (s *Service) busDeliverTo(person, publisher string, e wire.BusEvent, pollOnly bool) {
	type delivery struct {
		host string
		subs []string
	}
	var out []delivery
	now := time.Now()
	s.bus.mu.Lock()
	hosts := map[string]bool{}
	for host := range s.bus.subs {
		hosts[host] = true
	}
	for host := range s.bus.standby {
		hosts[host] = true
	}
	for host := range hosts {
		if !s.router.Holds(host) {
			delete(s.bus.subs, host)
			delete(s.bus.standby, host)
			continue
		}
		if host == publisher || s.ownerOf(host) != person {
			continue
		}
		matched := []string{}
		if !pollOnly {
			for _, sub := range s.bus.subs[host] {
				if busMatches(sub, e) {
					matched = append(matched, sub.ID)
				}
			}
		}
		standing := e.Poll != nil && s.bus.standsBy(host, *e.Poll, now)
		if len(matched) > 0 || standing {
			out = append(out, delivery{host, matched})
		}
	}
	s.bus.mu.Unlock()
	for _, d := range out {
		if s.router.Tell(d.host, wire.NotifyBusDeliver.Name, wire.BusDelivery{Event: busFor(e, d.host), Subscriptions: d.subs}) {
			s.bus.delivered.Add(1)
			s.metrics.Bus("delivered")
		}
	}
}

// busFromPeer is a new event another copy took: for the machines held here.
func (s *Service) busFromPeer(raw json.RawMessage) {
	var p busPeer
	if json.Unmarshal(raw, &p) != nil || p.Person == "" || checkBusEvent(p.Event) != nil {
		return
	}
	s.busDeliverTo(p.Person, "", p.Event, p.PollOnly)
}

// sweepBus keeps the newest kept envelopes of each bus, and deletes at most most
// of the rest, the oldest first, each with its id's file.
func sweepBus(ctx context.Context, st store.Store, kept, most int) (int, error) {
	if most <= 0 {
		return 0, nil
	}
	keys, err := st.List(ctx, busPrefix)
	if err != nil {
		return 0, err
	}
	logs := map[string][]string{}
	for _, k := range keys {
		bus, rest, ok := strings.Cut(strings.TrimPrefix(k.Key, busPrefix), "/")
		if ok && strings.HasPrefix(rest, "log/") {
			logs[bus] = append(logs[bus], k.Key)
		}
	}
	n := 0
	for bus, list := range logs {
		// List gives them sorted by key, so by time.
		for _, key := range list[:max(0, len(list)-kept)] {
			if n >= most {
				return n, nil
			}
			name := strings.TrimSuffix(key[strings.LastIndexByte(key, '-')+1:], ".json")
			if err := st.Delete(ctx, busIDKey(bus, name)); err != nil {
				return n, err
			}
			if err := st.Delete(ctx, key); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}

const (
	// busLogPage and busLogPageMost are bus/log's page, as the wire says.
	busLogPage     = 100
	busLogPageMost = 500
	// busLogReadMost bounds the envelopes one bus/log call reads; a narrow filter that
	// finds too few in them says next, and the client reads on from there.
	busLogReadMost = 2_000
)

// busLogMethod is bus/log (#4732): a page of the caller's bus log, newest first, narrowed
// by the envelope's provider, type (a name or noun.*) and topic, for the Events page.
func (m *Methods) busLogMethod(ctx context.Context, params json.RawMessage, from Caller) (any, error) {
	q, err := require[wire.BusLogQuery](params, "BusLogQuery")
	if err != nil {
		return nil, err
	}
	return m.s.busLog(ctx, m.callerPerson(from), q)
}

func (s *Service) busLog(ctx context.Context, person string, q wire.BusLogQuery) (wire.BusLogPage, error) {
	limit := busLogPage
	if q.Limit != nil {
		limit = max(1, min(int(*q.Limit), busLogPageMost))
	}
	match := wire.BusSubscription{ID: "bus/log", Provider: q.Provider, Type: q.Type}
	if q.Topic != nil && *q.Topic != "" {
		match.Topics = []string{strings.ToLower(*q.Topic)}
	}
	prefix := busPrefix + busOf(person) + "/log/"
	keys, err := s.cfg.Store.List(ctx, prefix)
	if err != nil {
		return wire.BusLogPage{}, fail(storeUnavailable, "The bus log could not be read: %v", err)
	}
	out := wire.BusLogPage{Events: []wire.BusEvent{}}
	i := len(keys) - 1
	if q.Before != nil && *q.Before != "" {
		before := prefix + *q.Before
		for i >= 0 && keys[i].Key >= before {
			i--
		}
	}
	read := 0
	for ; i >= 0 && len(out.Events) < limit && read < busLogReadMost; i-- {
		read++
		name := strings.TrimPrefix(keys[i].Key, prefix)
		out.Next = &name
		obj, err := s.cfg.Store.Get(ctx, keys[i].Key)
		if err != nil {
			return wire.BusLogPage{}, fail(storeUnavailable, "The bus log could not be read: %v", err)
		}
		var e wire.BusEvent
		if obj == nil || json.Unmarshal(obj.Data, &e) != nil || !busMatches(match, e) {
			continue
		}
		// The envelope only: the sealed data is each machine's to open, not the page's.
		e.Sealed = nil
		out.Events = append(out.Events, e)
	}
	out.HasMore = i >= 0
	if !out.HasMore {
		out.Next = nil
	}
	return out, nil
}
