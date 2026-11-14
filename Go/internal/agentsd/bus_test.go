package agentsd

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// #4729: a machine publishes each new event it records, envelope only; an event the bus
// delivers is recorded once, and never published again.
func TestBusPublishesAndTakesADeliveryOnce(t *testing.T) {
	d, _ := start(t, t.TempDir())
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
	took := func() []wire.BusEvent {
		t.Helper()
		d.publishBus()
		mu.Lock()
		defer mu.Unlock()
		out := sent
		sent = nil
		return out
	}

	e := d.raise(wire.EventDraft{Name: "machine.woke", At: wire.DateOf(nowFunc()), Scope: macScope(), Sentence: "woke",
		Details: map[string]string{}})
	got := took()
	if len(got) != 1 || e.ID == nil || got[0].ID != *e.ID || got[0].Type != "machine.woke" || got[0].Specversion != "1.0" {
		t.Fatalf("published %+v for %+v", got, e)
	}

	subject := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "4702"}
	bus := wire.BusEvent{Specversion: "1.0", ID: subject.String() + "@pr.merged", Type: "pr.merged", Provider: "github",
		Topic: "alexec/agents", Subject: &subject, Source: "github:alexec/agents", Time: "2026-11-11T17:02:11Z",
		Producer: "agents:machine:#linux-b"}
	raw, _ := json.Marshal(wire.BusDelivery{Event: bus, Subscriptions: []string{"w1"}})
	d.Told(wire.NotifyBusDeliver.Name, raw)
	d.Told(wire.NotifyBusDeliver.Name, raw)
	if again := took(); len(again) != 0 {
		t.Fatalf("a delivered event was published again: %+v", again)
	}
	n := 0
	for _, ev := range d.eventsPage(wire.EventsListRequest{Limit: 200}).Events {
		if ev.ID != nil && *ev.ID == bus.ID {
			n++
			if ev.Producer == nil || *ev.Producer != bus.Producer || ev.Details["subject"] != subject.String() {
				t.Fatalf("%+v", ev)
			}
		}
	}
	if n != 1 {
		t.Fatalf("the delivered event is in the log %d times", n)
	}
}
