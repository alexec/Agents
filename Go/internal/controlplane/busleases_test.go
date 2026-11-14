package controlplane

import (
	"context"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

func leaseOf(t *testing.T, p *plane, host string, polls []string, release ...string) []wire.BusProducerLease {
	t.Helper()
	got := busSay[wire.BusLeased](t, p, host, wire.CallBusLease.Name, wire.BusLease{Polls: polls, Release: release})
	if len(got.Leases) != len(polls) {
		t.Fatalf("%d leases for %d polls", len(got.Leases), len(polls))
	}
	return got.Leases
}

// #4731: one machine holds a poll's lease and polls; another stands by and is delivered
// what the holder's poll made, once. The holder sleeps (lets it go): the other takes it at
// its next ask, and the first then stands by. A lease not renewed for 5 minutes goes too.
func TestProducerLeaseHolderSleepsAndAnotherTakesOver(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	var told busDeliveries
	p.told = told.told
	a, b, c := p.host("MAC-A").member.Host, p.host("LINUX-B").member.Host, p.host("MAC-C").member.Host
	p.waitFor(func() bool { return p.s.router.Holds(a) && p.s.router.Holds(b) && p.s.router.Holds(c) }, "the machines held")
	const poll = "0123456789abcdef0123456789abcdef"

	if l := leaseOf(t, p, a, []string{poll}); !l[0].Mine || l[0].Holder != a {
		t.Fatalf("A asked first and got %+v", l[0])
	}
	if l := leaseOf(t, p, a, []string{poll}); !l[0].Mine {
		t.Fatalf("A renews and got %+v", l[0])
	}
	if l := leaseOf(t, p, b, []string{poll}); l[0].Mine || l[0].Holder != a {
		t.Fatalf("B should stand by on A, got %+v", l[0])
	}

	// A's poll makes an event: B, standing by, is told it once; C, which is not, is not.
	e := prMerged(4702)
	e.Poll = str(poll)
	busSay[wire.BusPublished](t, p, a, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	p.waitFor(func() bool { return len(told.of(b)) >= 1 }, "B told")
	// The same event from another poll that is a copy goes to that poll's standbys only.
	busSay[wire.BusPublished](t, p, c, wire.CallBusPublish.Name, wire.BusPublish{Events: []wire.BusEvent{e}})
	time.Sleep(200 * time.Millisecond)
	got := told.of(b)
	if len(got) < 1 || got[0].Event.ID != e.ID || got[0].Event.Poll == nil || *got[0].Event.Poll != poll || len(got[0].Subscriptions) != 0 {
		t.Fatalf("B was told %+v", got)
	}
	if len(told.of(c)) != 0 || len(told.of(a)) != 0 {
		t.Fatalf("A %+v, C %+v", told.of(a), told.of(c))
	}

	// A sleeps: it lets the lease go. B takes it at its next ask; A then stands by.
	leaseOf(t, p, a, []string{}, poll)
	if l := leaseOf(t, p, b, []string{poll}); !l[0].Mine {
		t.Fatalf("B should take over, got %+v", l[0])
	}
	if l := leaseOf(t, p, a, []string{poll}); l[0].Mine || l[0].Holder != b {
		t.Fatalf("A woke and should stand by on B, got %+v", l[0])
	}
	// Letting go of a lease another holds leaves it.
	leaseOf(t, p, a, []string{}, poll)
	if l := leaseOf(t, p, c, []string{poll}); l[0].Mine || l[0].Holder != b {
		t.Fatalf("A let go of B's lease: %+v", l[0])
	}

	// B goes offline and stops renewing: after 5 minutes, the next to ask takes it.
	later := time.Now().Add(busLeaseFor + time.Second)
	out, err := p.s.busLeaseCall(context.Background(), c, wire.BusLease{Polls: []string{poll}}, later)
	if err != nil || len(out.Leases) != 1 || !out.Leases[0].Mine {
		t.Fatalf("C after the lease ended: %+v %v", out, err)
	}

	// A day after it ended, the sweep deletes it.
	if n, err := sweepBusLeases(context.Background(), mem, later.Add(busLeaseFor+busLeaseKept+time.Minute), 10); err != nil || n != 1 {
		t.Fatalf("swept %d, %v", n, err)
	}
}

func TestProducerLeaseRefusesABadPoll(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	a := p.host("MAC-A").member.Host
	p.waitFor(func() bool { return p.s.router.Holds(a) }, "the machine held")
	for _, bad := range []string{"", "a/b", string(make([]byte, busPollMost+1))} {
		if _, err := p.s.busLeaseCall(context.Background(), a, wire.BusLease{Polls: []string{bad}}, time.Now()); err == nil {
			t.Fatalf("%q was taken", bad)
		}
	}
}
