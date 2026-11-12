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
// event it records, its envelope and its data sealed to the person's other machines
// (bus/publish, busdata.go, #4825), a short time after it, to a control plane
// that takes it (events.bus/1). Best effort: an event that cannot be sent then (no control
// link, a failed send, too many waiting) is not sent later; it stays in events.jsonl, the
// machine's own log.
//
// An event the control plane delivers (bus/deliver) for a subscription of this machine is
// recorded here as for any event, once, with its data when it carries a copy sealed to this
// machine: one whose id this machine already has (it made it too) is dropped. A delivered
// event is never published again.

const (
	busPublishAfter = time.Second
	// busPublishBatch is one send, as the control plane takes it.
	busPublishBatch = 100
	// busPublishHeld bounds what waits for a send; past it, the newest are dropped.
	busPublishHeld = 1_000
	// busPublishHeldData bounds the data that waits; past it, the newest go envelope only.
	busPublishHeldData = 16 << 20
	// busPublishBatchBytes bounds the sealed data of one send, well under a message's limit.
	busPublishBatchBytes = 8 << 20
	// busSeenScan is how far back a delivered event's id is looked for in this machine's log.
	busSeenScan = 2_000
)

type busBook struct {
	busMu      sync.Mutex
	busPending []busPending
	// busPendingData is the bytes of data in busPending.
	busPendingData int
	busTimer       *time.Timer
	// busSending keeps one send at a time.
	busSending sync.Mutex
}

// busPending is an event that waits for a send: its envelope, and the data to seal.
type busPending struct {
	event wire.BusEvent
	data  json.RawMessage
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
	data := e.Data
	if len(data) > busDataMost || d.busPendingData+len(data) > busPublishHeldData {
		data = nil
	}
	d.busPendingData += len(data)
	d.busPending = append(d.busPending, busPending{event: b, data: data})
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
	d.busPending, d.busPendingData = nil, 0
	d.busMu.Unlock()
	ask := d.askControl.Load()
	if len(pending) == 0 || ask == nil {
		return
	}
	person, signer, to := d.busDataTo()
	for len(pending) > 0 && d.ctx.Err() == nil {
		var batch []wire.BusEvent
		bytes := 0
		for len(pending) > 0 && len(batch) < busPublishBatch && (len(batch) == 0 || bytes+len(pending[0].data)*len(to) <= busPublishBatchBytes) {
			p := pending[0]
			pending = pending[1:]
			if signer != nil && len(p.data) > 0 {
				sealed, err := sealBusData(signer, person, p.event.ID, p.data, to)
				if err != nil {
					log.Printf("bus/publish: the data of %s not sealed: %v", p.event.ID, err)
				}
				p.event.Sealed = sealed
				bytes += len(p.data) * len(sealed)
			}
			batch = append(batch, p.event)
		}
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
	data := d.openBusDelivery(e)
	e.Sealed = nil
	d.raiseEnveloped(wire.EventDraft{Name: e.Type, At: at, Scope: macScope(), Sentence: sentence, Details: details},
		nil, &serverEnvelope{bus: &e, busData: data})
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
