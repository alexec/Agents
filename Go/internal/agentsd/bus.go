package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The event bus (#4729, spec 4724-event-bus, "The bus"). This machine publishes each new
// event it records, envelope only (bus/publish), a short time after it, to a control plane
// that takes it (events.bus/1). Best effort: an event that cannot be sent then (no control
// link, a failed send, too many waiting) is not sent later; it stays in events.jsonl, the
// machine's own log.
//
// An event the control plane delivers (bus/deliver) for a subscription of this machine is
// recorded here as for any event, once: one whose id this machine already has (it made it
// too) is dropped. A delivered event is never published again.

const (
	busPublishAfter = time.Second
	// busPublishBatch is one send, as the control plane takes it.
	busPublishBatch = 100
	// busPublishHeld bounds what waits for a send; past it, the newest are dropped.
	busPublishHeld = 1_000
	// busSeenScan is how far back a delivered event's id is looked for in this machine's log.
	busSeenScan = 2_000
)

type busBook struct {
	busMu      sync.Mutex
	busPending []wire.BusEvent
	busTimer   *time.Timer
	// busSending keeps one send at a time.
	busSending sync.Mutex
}

// busEventOf is an event's envelope as the bus takes it; false for one with none.
func busEventOf(e wire.Event) (wire.BusEvent, bool) {
	if e.ID == nil || e.Type == nil || e.Specversion == nil || e.Provider == nil {
		return wire.BusEvent{}, false
	}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	return wire.BusEvent{Specversion: *e.Specversion, ID: *e.ID, Type: *e.Type, Provider: *e.Provider,
		Topic: str(e.Topic), Subject: e.Subject, Source: str(e.Source), Time: str(e.Time), Producer: str(e.Producer)}, true
}

// publishSoon keeps a new event of this machine's for the next bus/publish.
func (d *Daemon) publishSoon(e wire.Event) {
	if d.askControl.Load() == nil || !d.controlHas(wire.CapEventsBus1) {
		return
	}
	b, ok := busEventOf(e)
	if !ok {
		return
	}
	d.busMu.Lock()
	defer d.busMu.Unlock()
	if len(d.busPending) >= busPublishHeld {
		return
	}
	d.busPending = append(d.busPending, b)
	if d.busTimer == nil {
		d.busTimer = time.AfterFunc(busPublishAfter, func() {
			d.busMu.Lock()
			d.busTimer = nil
			d.busMu.Unlock()
			d.publishBus()
		})
	}
}

// publishBus sends what waits, a batch at a time. A batch that fails is dropped with the
// rest: no backfill.
func (d *Daemon) publishBus() {
	d.busSending.Lock()
	defer d.busSending.Unlock()
	d.busMu.Lock()
	pending := d.busPending
	d.busPending = nil
	d.busMu.Unlock()
	ask := d.askControl.Load()
	for len(pending) > 0 && ask != nil && d.ctx.Err() == nil {
		batch := pending[:min(len(pending), busPublishBatch)]
		pending = pending[len(batch):]
		ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
		_, err := (*ask)(ctx, wire.CallBusPublish.Name, wire.BusPublish{Events: batch})
		cancel()
		if err != nil {
			log.Printf("bus/publish: %d events not sent: %v", len(batch)+len(pending), err)
			return
		}
	}
}

// toldBusDelivery is bus/deliver: an event on the bus for this machine's subscriptions.
func (d *Daemon) toldBusDelivery(params json.RawMessage) {
	var del wire.BusDelivery
	if err := json.Unmarshal(params, &del); err != nil {
		log.Printf("bus/deliver: %v", err)
		return
	}
	e := del.Event
	if e.ID == "" || e.Type == "" || d.hasEventID(e.ID) {
		return
	}
	details := map[string]string{"bus_producer": e.Producer, "bus_subscriptions": strings.Join(del.Subscriptions, ",")}
	sentence := e.Type
	if e.Subject != nil {
		details["subject"] = e.Subject.String()
		sentence += " on " + e.Subject.String()
	}
	if e.Producer != "" {
		sentence += ", from " + strings.TrimPrefix(e.Producer, "agents:machine:#")
	}
	at := wire.DateOf(nowFunc())
	if t, err := time.Parse(time.RFC3339Nano, e.Time); err == nil {
		at = wire.DateOf(t)
	}
	d.raiseEnveloped(wire.EventDraft{Name: e.Type, At: at, Scope: macScope(), Sentence: sentence, Details: details},
		nil, &serverEnvelope{bus: &e})
}

// hasEventID says this machine's log has an event with that id among its newest.
func (d *Daemon) hasEventID(id string) bool {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	for i := len(d.eventList) - 1; i >= 0 && i >= len(d.eventList)-busSeenScan; i-- {
		if got := d.eventList[i].ID; got != nil && *got == id {
			return true
		}
	}
	return false
}
