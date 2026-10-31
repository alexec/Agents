package controlplane

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// startCopy is one copy of a control plane of several over st, with the same key: its
// own address is where the others reach it.
func startCopy(t *testing.T, st store.Store, private []byte) *plane {
	return startCopyWith(t, st, private, nil)
}

// startCopyWith is startCopy with something of its Config changed first.
func startCopyWith(t *testing.T, st store.Store, private []byte, change func(*Config)) *plane {
	port := freePort(t)
	p := &plane{t: t, url: "http://127.0.0.1:" + itoa(port), store: st, private: private, lines: make(chan string, 1000)}
	cfg := Config{Store: st, PrivateKey: private, URL: p.url, PeerURL: p.url, Bind: "127.0.0.1", Port: port,
		Name: "Copies", MachineID: "MACHINE-1", CopyBeat: 200 * time.Millisecond, Log: func(l string) {
			select {
			case p.lines <- l:
			default:
			}
		}}
	if change != nil {
		change(&cfg)
	}
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	p.s = s
	return p
}

func twoCopies(t *testing.T) (*plane, *plane) {
	st, key := store.NewMemory(), controllink.NewPrivateKey()
	a, b := startCopy(t, st, key), startCopy(t, st, key)
	a.waitFor(func() bool { return len(a.s.mesh.peers()) == 1 && len(b.s.mesh.peers()) == 1 }, "the copies linked")
	return a, b
}

// A host held by copy A, a window at copy B: B reaches the host through A, and the
// reply comes back the same way (T065).
func TestAWindowAtOneCopyReachesAHostAtAnother(t *testing.T) {
	t.Parallel()
	a, b := twoCopies(t)
	box := a.host("MACHINE-2")
	host := box.member.Host
	b.waitFor(func() bool { return b.s.router.Reaches(host) && !b.s.router.Holds(host) }, "B reaching the host through A")
	_, window := b.client("Window")
	call(t, window, host, "daemon/ping", nil)
	// The host held at A sees B's window as a channel of its own.
	a.waitFor(func() bool { return a.s.router.Channels(host) >= 1 }, "a channel for B's window")

	// The host goes: B shows it offline, and answers its calls so.
	box.stop()
	b.waitFor(func() bool { s, _ := b.s.router.State(host); return !s.online() }, "B showing the host offline")
	if e := callError(t, window, host, "daemon/ping", nil); !strings.Contains(e, "-32090") {
		t.Fatal(e)
	}
}

// A client paired at one copy is known at the other at once, and forgotten at both.
func TestAForgetReachesEveryCopy(t *testing.T) {
	t.Parallel()
	a, b := twoCopies(t)
	member, _ := a.client("Window")
	phone, phoneAtB := b.client("Phone")
	a.waitFor(func() bool { return a.s.records.Client(phone.Client) != nil }, "A knowing B's phone")
	_, window := a.client("Another")
	call(t, window, "", "clients/forget", map[string]string{"client": phone.Client})
	b.waitFor(func() bool { return b.s.router.Sessions() == 0 }, "B closing the phone's session")
	if _, err := phoneAtB.Call(context.Background(), "", "control/status", nil); err == nil {
		t.Fatal("a forgotten client was answered at B")
	}
	// How a client connects is known at every copy (T080).
	var links []wire.ClientConnection
	b.waitFor(func() bool {
		raw, err := b.s.methods.Handle("clients/connections", nil, Caller{})
		if err != nil {
			return false
		}
		links = raw.([]wire.ClientConnection)
		for _, l := range links {
			if string(l.Client) == member.Client {
				return true
			}
		}
		return false
	}, "B knowing A's window is connected")
}

// The store holds whose each host is, and each live copy.
func TestLeasesAndCopiesAreInTheStore(t *testing.T) {
	t.Parallel()
	a, b := twoCopies(t)
	box := a.host("MACHINE-2")
	lease := a.s.mesh.leases.holder(context.Background(), box.member.Host)
	if lease == nil || lease.Copy != a.s.copyID || lease.Epoch != 1 {
		t.Fatalf("%+v", lease)
	}
	for _, p := range []*plane{a, b} {
		if o, _ := p.store.Get(context.Background(), copyRecordKey(p.s.copyID)); o == nil {
			t.Fatal("no copy record")
		}
	}
	// A single copy refuses a copy's key.
	single := startPlane(t, store.NewMemory(), a.private)
	if _, err := controllink.Dial(context.Background(), single.url, ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := controllink.Join(context.Background(), single.url, "", controllink.Credentials{Identity: "x:other",
		Key: controllink.CopyKey(a.private), Kind: "copy"}); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatal(err)
	}
}
