package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/machinelock"
	"github.com/agentloops-dev/agents/Go/wire"
)

// #4825: an event's data goes on the bus sealed to each other machine of the person's lock:
// the control plane reads none of it, and the machine it is sealed to opens it.
func TestBusSealsAnEventsDataToThePersonsOtherMachines(t *testing.T) {
	d, phone, peer, state := lockedMachine(t)
	defer d.Shutdown()
	var mu sync.Mutex
	var sent []wire.BusEvent
	d.SetControlCapabilities(func() []string { return []string{wire.CapEventsBus1} })
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallBusPublish.Name {
			mu.Lock()
			sent = append(sent, params.(wire.BusPublish).Events...)
			mu.Unlock()
		}
		return json.RawMessage(`{}`), nil
	}))
	e := d.raise(wire.EventDraft{Name: "machine.woke", At: wire.DateOf(nowFunc()), Scope: macScope(), Sentence: "woke",
		Details: map[string]string{"words": "a customer's words"}})
	d.publishBus()
	mu.Lock()
	got := sent
	mu.Unlock()
	if len(got) != 1 || len(got[0].Sealed) != 1 || got[0].Sealed[0].Machine != "h-2" {
		t.Fatalf("published %+v", got)
	}
	if all, _ := json.Marshal(got); strings.Contains(string(all), "customer") {
		t.Fatalf("the data went in clear: %s", all)
	}
	data, err := openBusData(state, rawKey(peer), "h-2", got[0].ID, got[0].Sealed)
	if err != nil || string(data) != string(e.Data) {
		t.Fatalf("h-2 opened %s, %v; the event has %s", data, err, e.Data)
	}
	// Nobody else opens it: the phone, h-2 for another event, or as another machine.
	if _, err := openBusData(state, rawKey(phone), "h-2", got[0].ID, got[0].Sealed); err == nil {
		t.Fatal("the phone opened the data")
	}
	if _, err := openBusData(state, rawKey(peer), "h-2", got[0].ID+"x", got[0].Sealed); err == nil {
		t.Fatal("the copy opened for another event")
	}
	if data, _ := openBusData(state, rawKey(peer), "h-3", got[0].ID, got[0].Sealed); data != nil {
		t.Fatal("a machine with no copy has data")
	}
}

// #4825: a delivered event is recorded with its data only when its copy is sealed to this
// machine and signed by a machine of its lock; otherwise it is recorded envelope only.
func TestBusDeliveryOpensOnlyItsOwnSignedCopy(t *testing.T) {
	d, phone, peer, state := lockedMachine(t)
	defer d.Shutdown()
	h1 := memberOf(t, state, "h-1")
	data := []byte(`{"comment":"ship it"}`)
	deliver := func(n string, sealed []wire.BusSealedData) *wire.Event {
		t.Helper()
		subject := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: n}
		bus := wire.BusEvent{Specversion: "1.0", ID: subject.String() + "@pr.commented", Type: "pr.commented",
			Provider: "github", Topic: "alexec/agents", Subject: &subject, Source: "github:alexec/agents",
			Time: "2026-11-11T17:02:11Z", Producer: "agents:machine:#h-2", Sealed: sealed}
		raw, _ := json.Marshal(wire.BusDelivery{Event: bus, Subscriptions: []string{"w1"}})
		d.Told(wire.NotifyBusDeliver.Name, raw)
		for _, ev := range d.eventsPage(wire.EventsListRequest{Limit: 200}).Events {
			if ev.ID != nil && *ev.ID == bus.ID {
				return &ev
			}
		}
		t.Fatalf("%s not recorded", bus.ID)
		return nil
	}
	sealFor := func(n string, signer string) []wire.BusSealedData {
		t.Helper()
		id := (&wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: n}).String() + "@pr.commented"
		key := peer
		switch signer {
		case "phone":
			key = phone
		case "stranger":
			key = newLockKey(t)
		}
		sealed, err := sealBusData(key, "sam", id, data, []machinelock.Member{h1})
		if err != nil || len(sealed) != 1 {
			t.Fatalf("%+v %v", sealed, err)
		}
		return sealed
	}
	if e := deliver("1", sealFor("1", "h-2")); string(e.Data) != string(data) {
		t.Fatalf("h-2's copy: %s", e.Data)
	}
	if e := deliver("2", nil); len(e.Data) != 0 {
		t.Fatalf("no copy: %s", e.Data)
	}
	// Made up by a control plane (or a client): sealed to h-1, signed by no machine of the lock.
	for i, signer := range []string{"stranger", "phone"} {
		n := []string{"3", "4"}[i]
		if e := deliver(n, sealFor(n, signer)); len(e.Data) != 0 {
			t.Fatalf("a copy signed by the %s was taken: %s", signer, e.Data)
		}
	}
	// Moved from another event.
	if e := deliver("5", sealFor("1", "h-2")); len(e.Data) != 0 {
		t.Fatalf("another event's copy was taken: %s", e.Data)
	}
}

// #4825: data over 256 KB is not sealed, and a machine with no other machine seals nothing.
func TestBusSealsNoDataTooLargeOrToNobody(t *testing.T) {
	_, _, peer, state := lockedMachine(t)
	h1 := memberOf(t, state, "h-1")
	big := []byte(`"` + strings.Repeat("a", busDataMost) + `"`)
	if s, err := sealBusData(peer, "sam", "x@y", big, []machinelock.Member{h1}); err != nil || s != nil {
		t.Fatalf("%v %v", len(s), err)
	}
	if s, err := sealBusData(peer, "sam", "x@y", []byte(`{}`), nil); err != nil || s != nil {
		t.Fatalf("%v %v", len(s), err)
	}
}
