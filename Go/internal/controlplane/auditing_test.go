package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Who did what (#996): a client's action through the control plane is kept with the actor
// the control plane knows it by, never the one it names, and the host is told the same
// actor on the channel. Reads are not kept.
func TestTheControlPlaneWritesTheActor(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	actors := make(chan *wire.AuditActor, 4)
	box := p.hostWith("MACHINE-2", func(c controllink.Conn) {
		if a, ok := c.(controllink.Actored); ok {
			actors <- a.Actor()
		}
	})
	member, window := p.client("Test window")

	call(t, window, box.member.Host, "agents/list", nil)
	callError(t, window, box.member.Host, "agents/stop", map[string]any{"id": "A1", "actor": map[string]any{"user": "mallory"}})
	if e := callError(t, window, "", "control/setAuditDays", wire.AuditDays{Days: 0}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	call(t, window, "", "control/setAuditDays", wire.AuditDays{Days: 30})

	opened := <-actors
	owner := p.s.localOwner()
	if opened == nil || opened.User != owner || opened.Client == nil || string(*opened.Client) != member.Client {
		t.Fatalf("%+v", opened)
	}

	var list wire.AuditList
	p.waitFor(func() bool {
		// A new list each time: decoding into the last one keeps its fields a reply leaves out.
		list = wire.AuditList{}
		json.Unmarshal(call(t, window, "", "audit/list", wire.AuditQuery{}), &list)
		return len(list.Entries) == 2
	}, "two entries")
	if !list.Admin || list.Days != 30 || list.More {
		t.Fatalf("%+v", list)
	}
	setDays, stop := list.Entries[0], list.Entries[1]
	if setDays.Method == "agents/stop" {
		setDays, stop = stop, setDays
	}
	if stop.Action != "Stopped an agent" || string(*stop.Host) != box.member.Host || *stop.Target != "A1" ||
		stop.Actor.User != owner || string(*stop.Actor.Client) != member.Client || *stop.Actor.ClientName != "Test window" ||
		*stop.Actor.UserName != "Local owner" {
		t.Fatalf("%+v", stop)
	}
	if setDays.Method != "control/setAuditDays" || setDays.Host != nil {
		t.Fatalf("%+v", setDays)
	}

	var export wire.AuditExport
	json.Unmarshal(call(t, window, "", "audit/export", wire.AuditQuery{}), &export)
	if export.Count != 2 || strings.Count(export.Lines, "\n") != 2 || strings.Contains(export.Lines, "mallory") {
		t.Fatalf("%+v", export)
	}
}

// #2058: what an audited call named is read off the router's lock. While the read of a
// start's target is held up, as a multi-MB attachment would hold it, the machine still
// answers and other calls still pass; the entry is kept once the read ends.
func TestTheAuditTargetIsReadOffTheRoutersLock(t *testing.T) {
	// Not parallel (#2512): it sets the package's audit target.
	reading, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	was := auditTarget
	auditTarget = func(params json.RawMessage) *string {
		once.Do(func() { close(reading) })
		<-release
		return was(params)
	}
	t.Cleanup(func() { auditTarget = was })
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.hostWith("MACHINE-2", nil)
	_, window := p.client("Test window")

	answered := make(chan error, 1)
	go func() {
		_, err := window.Call(context.Background(), box.member.Host, "agents/stop", map[string]any{"id": "A1"})
		answered <- err
	}()
	<-reading
	select {
	case <-answered:
	case <-time.After(10 * time.Second):
		t.Fatal("the machine's answer waited for the audit's read")
	}
	call(t, window, box.member.Host, "agents/list", nil)
	close(release)
	p.waitFor(func() bool {
		var list wire.AuditList
		json.Unmarshal(call(t, window, "", "audit/list", wire.AuditQuery{}), &list)
		return len(list.Entries) == 1 && list.Entries[0].Target != nil && *list.Entries[0].Target == "A1"
	}, "the stop kept")
}
