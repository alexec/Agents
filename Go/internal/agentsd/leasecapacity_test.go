package agentsd

import (
	"context"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// holds is whether agent holds name now.
func holds(d *Daemon, name wire.ResourceName, agent wire.UUID) bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	e := d.book.Entries[name]
	return e != nil && holderIndex(e, agent) >= 0
}

// The built-in capacity lease, and build, follow the machine's level (#4579): granted at ok,
// in line at near and full with the reason, the holders left alone, and the line served one
// grant a look once the level is ok again. The screen and the person's booking are not
// compute and never wait for it.
func TestComputeLeasesFollowTheMachine(t *testing.T) {
	fakeRuntimes(t)
	set := fakeCapacity(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	ctx := context.Background()
	quiet := capacitySample{load1: 0.4}
	look := func(s capacitySample) { t.Helper(); set(s); d.checkCapacity(ctx) }
	dir := t.TempDir()
	early, a, b := seeded(t, d, dir, nil), seeded(t, d, dir, nil), seeded(t, d, dir, nil)
	me, ma, mb := appClient(t, d, early.ID), appClient(t, d, a.ID), appClient(t, d, b.ID)
	for _, m := range []*mcpClient{me, ma, mb} {
		m.post("initialize", map[string]any{}, 1)
	}

	// ok, on a machine with no declared resources: capacity is granted, and list_resources
	// says what it is for.
	look(quiet)
	if text, _ := me.tool(2, "lease_resource", map[string]any{"name": "capacity", "minutes": 10}); !strings.HasPrefix(text, "You hold "+capacityDisplay()+" until ") {
		t.Fatal(text)
	}
	if text, _ := me.tool(3, "list_resources", nil); !strings.Contains(text, "- capacity — "+capacityDisplay()+": lease it before heavy work") ||
		!strings.Contains(text, "granted now: "+thisMachine()+" has capacity; you hold it until ") {
		t.Fatal(text)
	}

	// near: a new grant of capacity or build goes in line with the reason, though places are free.
	look(capacitySample{load1: 2.4})
	inLine := ". You are 1st in line. You will get a lease.granted event when it is yours. End your turn, and you will be started again with it."
	if text, _ := ma.tool(2, "lease_resource", map[string]any{"name": "capacity"}); text != sentenceMachine()+" is near capacity (load 2.4 per core)"+inLine {
		t.Fatal(text)
	}
	if text, _ := mb.tool(2, "lease_resource", map[string]any{"name": "build"}); text != sentenceMachine()+" is near capacity (load 2.4 per core)"+inLine {
		t.Fatal(text)
	}
	// The holder is not disturbed: it extends what it holds.
	if text, _ := me.tool(4, "lease_resource", map[string]any{"name": "capacity", "minutes": 20}); !strings.HasPrefix(text, "You still hold "+capacityDisplay()) {
		t.Fatal(text)
	}
	// Not compute: the screen and the person's booking are granted at any level.
	if text, _ := me.tool(5, "lease_resource", map[string]any{"name": "screen", "minutes": 5}); !strings.HasPrefix(text, "You hold Screen") {
		t.Fatal(text)
	}
	if text, _ := me.tool(6, "lease_resource", map[string]any{"name": "person", "minutes": 5}); !strings.HasPrefix(text, "You hold ") {
		t.Fatal(text)
	}

	// full: a release does not hand capacity on.
	look(capacitySample{load1: 3.5})
	if text, _ := me.tool(7, "release_resource", map[string]any{"name": "capacity"}); text != "Released "+capacityDisplay()+"." {
		t.Fatal(text)
	}
	if text, _ := me.tool(8, "lease_resource", map[string]any{"name": "build", "wait": false}); text != sentenceMachine()+" is at capacity (load 3.5 per core). You are not in line." {
		t.Fatal(text)
	}

	// Two looks under the line take it to ok; the first of them still holds the line.
	look(quiet)
	if holds(d, "capacity", a.ID) || holds(d, "build", b.ID) {
		t.Fatal("served while near")
	}
	// ok: one grant a look, the oldest first.
	look(quiet)
	if !holds(d, "capacity", a.ID) || holds(d, "build", b.ID) {
		t.Fatal("the first look after ok did not serve the oldest alone")
	}
	waitFor(t, "the wake", func() bool {
		for _, u := range userMessages(d, a.ID) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nlease.granted at ") {
				return true
			}
		}
		return false
	})
	// While the line is served, a new compute grant waits behind it.
	if text, _ := me.tool(9, "lease_resource", map[string]any{"name": "capacity", "wait": false}); text != sentenceMachine()+" has capacity again, and its line is served one agent every 15 seconds. You are not in line." {
		t.Fatal(text)
	}
	look(quiet)
	if !holds(d, "build", b.ID) {
		t.Fatal("the second look did not serve the next")
	}
	// The line is empty: the next look ends the serving, and grants are at once again.
	look(quiet)
	if text, _ := me.tool(10, "lease_resource", map[string]any{"name": "capacity"}); !strings.HasPrefix(text, "You hold "+capacityDisplay()+" until ") {
		t.Fatal(text)
	}
}
