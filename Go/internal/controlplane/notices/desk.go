package notices

import (
	"bytes"
	"encoding/json"
	"sync"
	"time"
)

// AttentionNeed is DaemonAPI.AttentionNeed, as a host says it on channel 0: a need to
// offer, or one to withdraw.
type AttentionNeed struct {
	Need     *NeedOnWire     `json:"need,omitempty"`
	Headline json.RawMessage `json:"headline,omitempty"`
	Buzz     *bool           `json:"buzz,omitempty"`
	Withdraw json.RawMessage `json:"withdraw,omitempty"`
}

// NeedOnWire is Need as the wire carries it. Its id (NeedID) and headline pass through
// as they came.
type NeedOnWire struct {
	ID       json.RawMessage `json:"id"`
	AgentID  *string         `json:"agentID,omitempty"`
	RaisedAt float64         `json:"raisedAt"`
	Headline json.RawMessage `json:"headline"`
}

// Delivery to a relay host is DaemonAPI.RelayDelivery: a need posted to a device, or
// (with no headline) taken back from it.
type RelayDelivery struct {
	NeedID    json.RawMessage `json:"needID"`
	Device    string          `json:"device"`
	PublicKey []byte          `json:"publicKey,omitempty"`
	Headline  json.RawMessage `json:"headline,omitempty"`
	Alert     bool            `json:"alert"`
}

// referenceDate is 2001-01-01, which Swift's dates count from.
var referenceDate = time.Unix(978307200, 0)

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

// key is a NeedID as a map key: its JSON, compacted.
func key(id json.RawMessage) string {
	var b bytes.Buffer
	if json.Compact(&b, id) != nil {
		return string(id)
	}
	return b.String()
}

// Heard is NoticeDesk.heard: what to tell the relay host of a need a host raised.
func (d *Desk) Heard(message AttentionNeed, presences map[Surface]Presence, devices []Device, now time.Time) []RelayDelivery {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(message.Withdraw) > 0 {
		return d.withdraw(message.Withdraw)
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
		agent = *need.AgentID
	}
	raised := referenceDate.Add(time.Duration(need.RaisedAt * float64(time.Second)))
	decision := Decide(Need{Agent: agent, RaisedAt: raised}, presences, devices, delivery, Standard, now)
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
			out = append(out, RelayDelivery{NeedID: need.ID, Device: previous.device})
		}
	}
	d.posted[k] = posted{device: chosen.ID, alert: decision.Alert, at: now}
	headline := message.Headline
	if len(headline) == 0 {
		headline = need.Headline
	}
	return append(out, RelayDelivery{NeedID: need.ID, Device: chosen.ID, PublicKey: chosen.PublicKey,
		Headline: headline, Alert: decision.Alert})
}

func (d *Desk) withdraw(id json.RawMessage) []RelayDelivery {
	k := key(id)
	previous, ok := d.posted[k]
	if !ok {
		return nil
	}
	delete(d.posted, k)
	return []RelayDelivery{{NeedID: id, Device: previous.device}}
}
