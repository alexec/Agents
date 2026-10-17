package notices

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// AttentionNeed is DaemonAPI.AttentionNeed, as a host says it on channel 0: a need to
// offer, or one to withdraw.
type AttentionNeed = wire.AttentionNeed

// RelayDelivery is DaemonAPI.RelayDelivery, a delivery to a relay host: a need posted to
// a device, or (with no headline) taken back from it.
type RelayDelivery = wire.RelayDelivery

type posted struct {
	device string
	alert  bool
	at     time.Time
}

// Desk is NoticeDesk: what this copy has posted for each need, and to which device, so a
// need is posted once, moved when the person moves, and taken back when it is met.
type Desk struct {
	mu     sync.Mutex
	posted map[string]posted
}

func NewDesk() *Desk { return &Desk{posted: map[string]posted{}} }

// key is a NeedID as a map key: its JSON.
func key(id wire.NeedID) string {
	b, _ := json.Marshal(id)
	return string(b)
}

// Heard is NoticeDesk.heard: what to tell the relay host of a need a host raised.
func (d *Desk) Heard(message AttentionNeed, presences map[Surface]Presence, devices []Device, now time.Time) []RelayDelivery {
	d.mu.Lock()
	defer d.mu.Unlock()
	if message.Withdraw != nil {
		return d.withdraw(*message.Withdraw)
	}
	if message.Need == nil {
		return nil
	}
	need := message.Need
	k := key(need.ID)
	var delivery *Delivery
	if p, ok := d.posted[k]; ok {
		to := Surface{Device: p.device}
		delivery = &Delivery{To: &to, AlertedAt: p.at}
	}
	agent := ""
	if need.AgentID != nil {
		agent = string(*need.AgentID)
	}
	decision := Decide(Need{Agent: agent, RaisedAt: need.RaisedAt.Time()}, presences, devices, delivery, Standard, now)
	var chosen *Device
	if !decision.Wait && decision.To != nil && !decision.To.IsMac() {
		for i := range devices {
			if devices[i].ID == decision.To.Device {
				chosen = &devices[i]
			}
		}
	}
	if chosen == nil {
		return d.withdraw(need.ID)
	}
	var out []RelayDelivery
	if previous, ok := d.posted[k]; ok {
		if previous.device == chosen.ID {
			// Same device: a later decision that would show it quietly must not replace
			// the banner, and one that would buzz again is the ladder saying the interval
			// passed.
			if previous.alert || !decision.Alert {
				return nil
			}
		} else {
			out = append(out, RelayDelivery{NeedID: need.ID, Device: wire.UUID(previous.device)})
		}
	}
	d.posted[k] = posted{device: chosen.ID, alert: decision.Alert, at: now}
	headline := message.Headline
	if headline == nil {
		headline = &need.Headline
	}
	return append(out, RelayDelivery{NeedID: need.ID, Device: wire.UUID(chosen.ID), PublicKey: chosen.PublicKey,
		Headline: headline, Alert: decision.Alert})
}

func (d *Desk) withdraw(id wire.NeedID) []RelayDelivery {
	k := key(id)
	previous, ok := d.posted[k]
	if !ok {
		return nil
	}
	delete(d.posted, k)
	return []RelayDelivery{{NeedID: id, Device: wire.UUID(previous.device)}}
}
