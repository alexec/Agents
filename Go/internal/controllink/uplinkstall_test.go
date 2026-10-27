package controllink

import (
	"context"
	"strings"
	"testing"
	"time"
)

// enrolled enrols a host with f and returns its uplink, not yet running.
func enrolled(t *testing.T, f *fakeControl, accept Accept) *Uplink {
	t.Helper()
	root := t.TempDir()
	private, err := HostPrivateKey(root)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	m, err := Enroll(ctx, root, f.code(), private, MachineHello{})
	if err != nil {
		t.Fatal(err)
	}
	return &Uplink{Root: root, Member: m, Private: private, Accept: accept}
}

// stalled is a fake control plane whose first uplink reads nothing once its channel is open.
func stalled(t *testing.T) *fakeControl {
	f := newFakeControl(t)
	f.stall = make(chan struct{})
	// After srv.Close is registered, so it runs first: the stalled handler returns.
	t.Cleanup(func() { close(f.stall) })
	return f
}

func hello(t *testing.T, f *fakeControl, within time.Duration, what string) {
	t.Helper()
	select {
	case <-f.hellos:
	case <-time.After(within):
		t.Fatal(what)
	}
}

// A control plane that stops reading (a stalled TLS link) does not hold Broadcast, nor
// anything else that writes to it: the uplink drops it and dials again (#1403).
func TestAStalledControlPlaneIsDropped(t *testing.T) {
	f := stalled(t)
	opened := make(chan Conn, 4)
	u := enrolled(t, f, func(c Conn) {
		opened <- c
		for range c.In() {
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go u.Run(ctx)
	hello(t, f, 10*time.Second, "no host/hello")
	<-opened
	// More than the queue and the socket's buffers hold, so the writer meets the stall.
	line := `{"jsonrpc":"2.0","method":"agent/changed","params":{"x":"` + strings.Repeat("x", 16<<10) + `"}}`
	start := time.Now()
	for i := 0; i < 4000; i++ {
		t0 := time.Now()
		u.Broadcast(line)
		if took := time.Since(t0); took > 5*time.Second {
			t.Fatalf("Broadcast %d was held %s by a control plane that reads nothing", i, took.Round(time.Millisecond))
		}
	}
	t.Logf("4000 broadcasts in %s", time.Since(start).Round(time.Millisecond))
	hello(t, f, 15*time.Second, "the stalled control plane was not dropped and dialled again")
	// The new link carries what is said now.
	<-opened
	for deadline := time.Now().Add(10 * time.Second); ; {
		u.Broadcast(`{"jsonrpc":"2.0","method":"agent/changed","params":{}}`)
		select {
		case got := <-f.channel:
			if !strings.Contains(got, "agent/changed") {
				t.Fatalf("the new link carried %s", got)
			}
			return
		case <-time.After(100 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			t.Fatal("the new link carried nothing")
		}
	}
}

// A link gone quiet (a half-open TCP one after sleep), with nothing to write that would
// find it, is found by its ping and dialled again (#1403).
func TestAQuietDeadLinkIsFoundByItsPing(t *testing.T) {
	f := stalled(t)
	u := enrolled(t, f, func(c Conn) {
		for range c.In() {
		}
	})
	u.pingEvery = 200 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go u.Run(ctx)
	hello(t, f, 10*time.Second, "no host/hello")
	hello(t, f, 10*time.Second, "a link that answers no ping was kept")
}

// A copy that lets go as soon as the host says hello is dialled less and less often, not
// every firstWait (#1529). Time here is a hundredth of the real one: 600 ms is a minute,
// waits of 10, 20, 40, 80, 160 and 300 ms are 1, 2, 4, 8, 16 and 30 s.
func TestACopyThatLetsGoAtOnceIsDialledLessOften(t *testing.T) {
	f := newFakeControl(t)
	f.letGo = true
	u := enrolled(t, f, func(c Conn) {
		for range c.In() {
		}
	})
	u.firstWait, u.lastWait, u.steadyFor = 10*time.Millisecond, 300*time.Millisecond, 100*time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()
	done := make(chan struct{})
	go func() {
		u.Run(ctx)
		close(done)
	}()
	dials := 0
	for {
		select {
		case <-f.hellos:
			dials++
			continue
		case <-done:
		}
		break
	}
	t.Logf("%d dials in a scaled minute", dials)
	if dials < 2 {
		t.Fatalf("%d dials: the uplink did not dial again", dials)
	}
	// Seven waits fit in a minute (1+2+4+8+16+30 s); the old reset dialled about 50 times.
	if dials > 7 {
		t.Fatalf("%d dials in a scaled minute, want 7 or fewer: the wait did not grow", dials)
	}
}
