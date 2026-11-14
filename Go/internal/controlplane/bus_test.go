package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// busDeliveries is what each host was told on bus/deliver.
type busDeliveries struct {
	mu  sync.Mutex
	got map[string][]wire.BusDelivery
}

func (b *busDeliveries) told(host, method string, params json.RawMessage) {
	if method != wire.NotifyBusDeliver.Name {
		return
	}
	var d wire.BusDelivery
	if json.Unmarshal(params, &d) != nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.got == nil {
		b.got = map[string][]wire.BusDelivery{}
	}
	b.got[host] = append(b.got[host], d)
}

func (b *busDeliveries) of(host string) []wire.BusDelivery {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]wire.BusDelivery(nil), b.got[host]...)
}

func prMerged(n int) wire.BusEvent {
	subject := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: fmt.Sprint(n)}
	return wire.BusEvent{Specversion: "1.0", ID: subject.String() + "@pr.merged", Type: "pr.merged", Provider: "github",
		Topic: "alexec/agents", Subject: &subject, Source: "github:alexec/agents", Time: "2026-11-11T17:02:11Z",
		Producer: "agents:machine:#mac-mini"}
}

func busSay[T any](t *testing.T, p *plane, host, method string, params any) T {
	t.Helper()
	raw, _ := json.Marshal(params)
	answer, err := p.s.methods.HostSaid(host, method, raw)
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}
	var out T
	b, _ := json.Marshal(answer)
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func subscribeTo(t *testing.T, p *plane, host string, subs ...wire.BusSubscription) {
	t.Helper()
	got := busSay[wire.BusSubscribed](t, p, host, wire.CallBusSubscribe.Name, wire.BusSubscribe{Subscriptions: subs})
	if got.Count != int64(len(subs)) {
		t.Fatalf("holds %d subscriptions, not %d", got.Count, len(subs))
	}
}

func str(s string) *string { return &s }

// #4729: two machines publish the same event; it goes on the bus once, a machine that
// subscribed is told once, and the same event published again (a restart) is not told again.
func TestBusDropsACopyAndDeliversOnce(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	var told busDeliveries
	p.told = told.told
	a, b, c := p.host("MAC-A").member.Host, p.host("LINUX-B").member.Host, p.host("MAC-C").member.Host
	p.waitFor(func() bool { return p.s.router.Holds(a) && p.s.router.Holds(b) && p.s.router.Holds(c) }, "the machines held")
	subscribeTo(t, p, c, wire.BusSubscription{ID: "merged", Type: str("pr.*"), Topics: []string{"Alexec/Agents"}},
		wire.BusSubscription{ID: "other", Provider: str("jira")})
	subscribeTo(t, p, a, wire.BusSubscription{ID: "mine", Type: str("pr.merged")})

	e := prMerged(4702)
	first := busSay[wire.BusPublished](t, p, a, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	second := busSay[wire.BusPublished](t, p, b, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	again := busSay[wire.BusPublished](t, p, a, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	if first != (wire.BusPublished{Kept: 1}) || second != (wire.BusPublished{Dropped: 1}) || again != (wire.BusPublished{Dropped: 1}) {
		t.Fatalf("%+v %+v %+v", first, second, again)
	}
	p.waitFor(func() bool { return len(told.of(c)) >= 1 }, "C told")
	time.Sleep(200 * time.Millisecond)
	got := told.of(c)
	if len(got) != 1 || got[0].Event.ID != e.ID || strings.Join(got[0].Subscriptions, ",") != "merged" {
		t.Fatalf("C was told %+v", got)
	}
	// The machine that published it has it, and is not told it.
	if len(told.of(a)) != 0 || len(told.of(b)) != 0 {
		t.Fatalf("A %+v, B %+v", told.of(a), told.of(b))
	}
	if p.s.bus.kept.Load() != 1 || p.s.bus.dropped.Load() != 2 || p.s.bus.delivered.Load() != 1 {
		t.Fatalf("kept %d, dropped %d, delivered %d", p.s.bus.kept.Load(), p.s.bus.dropped.Load(), p.s.bus.delivered.Load())
	}
	// The bus log has it, envelope only.
	keys, _ := mem.List(context.Background(), busPrefix)
	if len(keys) != 2 {
		t.Fatalf("the bus has %v", keys)
	}
	// No subscriptions: none told. A subscription that matches nothing: none told.
	subscribeTo(t, p, c)
	busSay[wire.BusPublished](t, p, a, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{prMerged(4703)}})
	time.Sleep(200 * time.Millisecond)
	if len(told.of(c)) != 1 {
		t.Fatalf("C, with no subscriptions, was told %+v", told.of(c))
	}
}

// #4729: an event published at one copy reaches a machine another copy holds.
func TestBusDeliversAcrossCopies(t *testing.T) {
	t.Parallel()
	a, b := twoCopies(t)
	var told busDeliveries
	b.told = told.told
	publisher := a.host("MAC-A").member.Host
	consumer := b.host("MAC-B").member.Host
	b.waitFor(func() bool { return b.s.router.Holds(consumer) }, "B holding the consumer")
	subscribeTo(t, b, consumer, wire.BusSubscription{ID: "w1", Subject: prMerged(1).Subject})
	busSay[wire.BusPublished](t, a, publisher, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{prMerged(2), prMerged(1)}})
	b.waitFor(func() bool { return len(told.of(consumer)) >= 1 }, "the consumer told")
	time.Sleep(200 * time.Millisecond)
	if got := told.of(consumer); len(got) != 1 || got[0].Event.ID != prMerged(1).ID {
		t.Fatalf("%+v", got)
	}
	// The other copy dedupes against the same store.
	if got := busSay[wire.BusPublished](t, b, consumer, wire.CallBusPublish.Name,
		wire.BusPublish{Events: []wire.BusEvent{prMerged(1)}}); got.Dropped != 1 {
		t.Fatalf("%+v", got)
	}
}

func TestBusRefusesWhatIsNotAnEnvelope(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	host := p.host("MAC-A").member.Host
	bad := prMerged(1)
	bad.Type = "pr.closed"
	for _, e := range []wire.BusEvent{bad, {Specversion: "0.3", ID: "x@y", Type: "y", Provider: "p"}} {
		raw, _ := json.Marshal(wire.BusPublish{Events: []wire.BusEvent{e}})
		if _, err := p.s.methods.HostSaid(host, wire.CallBusPublish.Name, raw); err == nil {
			t.Fatalf("took %+v", e)
		}
	}
	many := make([]wire.BusEvent, busPublishMost+1)
	raw, _ := json.Marshal(wire.BusPublish{Events: many})
	if _, err := p.s.methods.HostSaid(host, wire.CallBusPublish.Name, raw); err == nil {
		t.Fatal("took too many")
	}
}

func TestBusMatches(t *testing.T) {
	t.Parallel()
	e := prMerged(7)
	other := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "8"}
	for _, c := range []struct {
		sub  wire.BusSubscription
		want bool
	}{
		{wire.BusSubscription{ID: "all"}, true},
		{wire.BusSubscription{ID: "p", Provider: str("github")}, true},
		{wire.BusSubscription{ID: "p", Provider: str("gitlab")}, false},
		{wire.BusSubscription{ID: "t", Type: str("pr.merged")}, true},
		{wire.BusSubscription{ID: "t", Type: str("pr.*")}, true},
		{wire.BusSubscription{ID: "t", Type: str("issue.*")}, false},
		{wire.BusSubscription{ID: "t", Type: str("pr.closed")}, false},
		{wire.BusSubscription{ID: "o", Topics: []string{"o/r", "alexec/agents"}}, true},
		{wire.BusSubscription{ID: "o", Topics: []string{"o/r"}}, false},
		{wire.BusSubscription{ID: "s", Subject: e.Subject}, true},
		{wire.BusSubscription{ID: "s", Subject: &other}, false},
	} {
		if got := busMatches(c.sub, e); got != c.want {
			t.Errorf("%+v: %v", c.sub, got)
		}
	}
}

// #4729: the sweep keeps the newest of each bus, and deletes the rest with their ids, so an
// id that went can come again.
func TestSweepBusKeepsTheNewest(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	ctx := context.Background()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	host := p.host("MAC-A").member.Host
	events := []wire.BusEvent{prMerged(1), prMerged(2), prMerged(3), prMerged(4)}
	for _, e := range events {
		busSay[wire.BusPublished](t, p, host, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
		time.Sleep(time.Millisecond)
	}
	n, err := sweepBus(ctx, mem, 2, 1)
	if err != nil || n != 1 {
		t.Fatal(n, err)
	}
	n, err = sweepBus(ctx, mem, 2, 10)
	if err != nil || n != 1 {
		t.Fatal(n, err)
	}
	keys, _ := mem.List(ctx, busPrefix)
	if len(keys) != 4 {
		t.Fatalf("%v", keys)
	}
	got := busSay[wire.BusPublished](t, p, host, wire.CallBusPublish.Name, wire.BusPublish{Events: events})
	if got != (wire.BusPublished{Kept: 2, Dropped: 2}) {
		t.Fatalf("%+v", got)
	}
}

// sealedCopy is a copy the control plane cannot open: bytes of the right size only.
func sealedCopy(machine string, fill byte) wire.BusSealedData {
	return wire.BusSealedData{Machine: machine, Sealed: wire.SealedEnvelope{
		Encapsulated: bytes.Repeat([]byte{4}, busEncapsulatedBytes), Ciphertext: bytes.Repeat([]byte{fill}, 200)}}
}

// #4825: an event's sealed data is kept in the bus log, and each machine is given its own
// copy only; a copy too large, or for no machine, is refused.
func TestBusGivesEachMachineItsOwnSealedCopy(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	var told busDeliveries
	p.told = told.told
	a, b, c := p.host("MAC-A").member.Host, p.host("LINUX-B").member.Host, p.host("MAC-C").member.Host
	p.waitFor(func() bool { return p.s.router.Holds(a) && p.s.router.Holds(b) && p.s.router.Holds(c) }, "the machines held")
	subscribeTo(t, p, b, wire.BusSubscription{ID: "all"})
	subscribeTo(t, p, c, wire.BusSubscription{ID: "all"})
	e := prMerged(9)
	e.Sealed = []wire.BusSealedData{sealedCopy(b, 'b'), sealedCopy(c, 'c')}
	busSay[wire.BusPublished](t, p, a, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	p.waitFor(func() bool { return len(told.of(b)) == 1 && len(told.of(c)) == 1 }, "B and C told")
	for host, fill := range map[string]byte{b: 'b', c: 'c'} {
		got := told.of(host)[0].Event.Sealed
		if len(got) != 1 || got[0].Machine != host || got[0].Sealed.Ciphertext[0] != fill {
			t.Fatalf("%s was given %+v", host, got)
		}
	}
	keys, _ := mem.List(context.Background(), busPrefix+busOf(p.s.ownerOf(a))+"/log/")
	if len(keys) != 1 {
		t.Fatalf("the log has %v", keys)
	}
	body, _ := mem.Get(context.Background(), keys[0].Key)
	var kept wire.BusEvent
	if json.Unmarshal(body.Data, &kept) != nil || len(kept.Sealed) != 2 {
		t.Fatalf("the log keeps %s", body.Data)
	}

	big := sealedCopy(b, 'b')
	big.Sealed.Ciphertext = make([]byte, busSealedBytes+1)
	twice := []wire.BusSealedData{sealedCopy(b, 'b'), sealedCopy(b, 'b')}
	for name, sealed := range map[string][]wire.BusSealedData{"too large": {big}, "no machine": {sealedCopy("", 'x')}, "twice": twice} {
		bad := prMerged(10)
		bad.Sealed = sealed
		raw, _ := json.Marshal(wire.BusPublish{Events: []wire.BusEvent{bad}})
		if _, err := p.s.methods.HostSaid(a, wire.CallBusPublish.Name, raw); err == nil {
			t.Fatalf("took a copy %s", name)
		}
	}
}

// #4732: bus/log is the caller's bus, newest first, narrowed by provider, type and topic,
// a page at a time.
func TestBusLogPagesNewestFirstAndNarrows(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	a := p.host("MAC-A").member.Host
	ctx := context.Background()
	at := time.Date(2026, 11, 11, 17, 0, 0, 0, time.UTC)
	jira := wire.BusEvent{Specversion: "1.0", ID: "jira:issue:abc#ABC-9@issue.created", Type: "issue.created", Provider: "jira",
		Topic: "abc", Source: "jira:abc", Time: "2026-11-11T17:00:00Z", Producer: "agents:machine:#linux-b"}
	sealed := prMerged(1)
	sealed.Sealed = []wire.BusSealedData{sealedCopy(a, 'a')}
	for i, e := range []wire.BusEvent{sealed, jira, prMerged(2), prMerged(3)} {
		if _, err := p.s.busPublish(ctx, a, wire.BusPublish{Events: []wire.BusEvent{e}}, at.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	person := p.s.ownerOf(a)
	ids := func(page wire.BusLogPage) string {
		var out []string
		for _, e := range page.Events {
			out = append(out, e.ID[strings.LastIndexByte(e.ID, '#')+1:])
		}
		return strings.Join(out, " ")
	}
	two := int64(2)
	first, err := p.s.busLog(ctx, person, wire.BusLogQuery{Limit: &two})
	if err != nil || ids(first) != "3@pr.merged 2@pr.merged" || !first.HasMore || first.Next == nil {
		t.Fatalf("%v %+v", err, first)
	}
	rest, _ := p.s.busLog(ctx, person, wire.BusLogQuery{Before: first.Next, Limit: &two})
	if ids(rest) != "ABC-9@issue.created 1@pr.merged" || rest.HasMore || rest.Next != nil {
		t.Fatalf("%+v", rest)
	}
	if rest.Events[1].Sealed != nil {
		t.Fatalf("bus/log gave the sealed data: %+v", rest.Events[1])
	}
	for _, c := range []struct {
		q    wire.BusLogQuery
		want string
	}{
		{wire.BusLogQuery{Provider: str("jira")}, "ABC-9@issue.created"},
		{wire.BusLogQuery{Type: str("pr.*")}, "3@pr.merged 2@pr.merged 1@pr.merged"},
		{wire.BusLogQuery{Topic: str("Alexec/Agents"), Type: str("pr.merged")}, "3@pr.merged 2@pr.merged 1@pr.merged"},
		{wire.BusLogQuery{Topic: str("abc"), Provider: str("github")}, ""},
	} {
		got, err := p.s.busLog(ctx, person, c.q)
		if err != nil || ids(got) != c.want {
			t.Errorf("%+v: %v %q, want %q", c.q, err, ids(got), c.want)
		}
	}
	// Another person's bus is empty.
	if other, _ := p.s.busLog(ctx, "someone-else", wire.BusLogQuery{}); len(other.Events) != 0 {
		t.Fatalf("someone else reads %+v", other)
	}
}
