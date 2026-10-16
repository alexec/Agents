// Package notices chooses where a need for the person shows, and keeps what was posted
// where (058, R6, T097): Routing.swift's ladder and NoticeDesk in ControlNotices.swift.
// The control plane hands each delivery to the relay host, which seals it to the device.
package notices

import (
	"sort"
	"time"
)

// Surface is Surface: the Mac's screen ("" device) or one paired device.
type Surface struct {
	Device string
}

// Mac is the Mac's screen.
var Mac = Surface{}

func (s Surface) IsMac() bool { return s.Device == "" }

// Presence is Presence: where a surface last said the person was.
type Presence struct {
	Surface  Surface
	Watching string
	Active   bool
	HeardAt  time.Time
}

func (p Presence) isRecent(now time.Time, t Thresholds) bool {
	return now.Sub(p.HeardAt) < t.DeviceStaleness
}

func (p Presence) isHere(now time.Time, t Thresholds) bool {
	return p.Active && now.Sub(p.HeardAt) < t.MacIdle
}

func (p Presence) isWatching(agent string) bool { return p.Active && p.Watching == agent }

// Device kinds, as Device.Kind says them.
const (
	IPhone  = "iPhone"
	IPad    = "iPad"
	Unknown = "unknown"
)

// Device is Device: a paired phone or iPad, as routing needs it.
type Device struct {
	ID        string
	PublicKey []byte
	Kind      string
	LastSeen  time.Time
	MayNotify *bool
}

func (d Device) eligible() bool { return d.MayNotify != nil && *d.MayNotify }

// Thresholds is AttentionThresholds.
type Thresholds struct {
	MacIdle, DeviceStaleness, SettlingPause, ReAlertInterval time.Duration
}

// Standard is AttentionThresholds.standard.
var Standard = Thresholds{MacIdle: 120 * time.Second, DeviceStaleness: 600 * time.Second,
	SettlingPause: 20 * time.Second, ReAlertInterval: 300 * time.Second}

// Need is what Routing reads of a Need.
type Need struct {
	Agent    string
	RaisedAt time.Time
}

// Delivery is Delivery: where a need was last shown, and when it last alerted.
type Delivery struct {
	To        *Surface
	AlertedAt time.Time
}

// Decision is Decision: where a need should be showing (nil: nowhere, or silence because
// it is being watched), whether the person may be alerted afresh, and whether to hold.
type Decision struct {
	To    *Surface
	Alert bool
	Wait  bool
}

// Decide is Routing.decide: the ladder, one pure function. The first rung that applies
// wins: being watched anywhere, at the Mac (with the settling pause), the device in
// hand, the default iPhone, nowhere.
func Decide(need Need, presences map[Surface]Presence, devices []Device, delivery *Delivery, t Thresholds, now time.Time) Decision {
	// 1. Being watched, anywhere.
	if need.Agent != "" {
		for _, p := range presences {
			if p.isWatching(need.Agent) {
				return Decision{}
			}
		}
	}
	// 2. At the Mac, with the pause, which applies only here.
	if mac, ok := presences[Mac]; ok && mac.isHere(now, t) {
		to := Mac
		if now.Sub(need.RaisedAt) < t.SettlingPause {
			return Decision{To: &to, Wait: true}
		}
		return Decision{To: &to, Alert: alert(to, delivery, t, now)}
	}
	var eligible []Device
	for _, d := range devices {
		if d.eligible() {
			eligible = append(eligible, d)
		}
	}
	// 3. The device in hand: heard from most recently, and recently enough. A tie goes to
	// the iPhone, then to the id.
	var inHand []pair
	for _, p := range presences {
		if !p.isRecent(now, t) || p.Surface.IsMac() {
			continue
		}
		for _, d := range eligible {
			if d.ID == p.Surface.Device {
				inHand = append(inHand, pair{p, d})
			}
		}
	}
	if len(inHand) > 0 {
		best := inHand[0]
		for _, c := range inHand[1:] {
			if later(best, c) {
				best = c
			}
		}
		to := best.p.Surface
		return Decision{To: &to, Alert: alert(to, delivery, t, now)}
	}
	// 4. The default: the most recently used eligible iPhone. An unknown kind never is.
	var phones []Device
	for _, d := range eligible {
		if d.Kind == IPhone {
			phones = append(phones, d)
		}
	}
	if len(phones) > 0 {
		sort.Slice(phones, func(i, j int) bool {
			if !phones[i].LastSeen.Equal(phones[j].LastSeen) {
				return phones[i].LastSeen.Before(phones[j].LastSeen)
			}
			return phones[i].ID < phones[j].ID
		})
		to := Surface{Device: phones[len(phones)-1].ID}
		return Decision{To: &to, Alert: alert(to, delivery, t, now)}
	}
	// 5. Nowhere.
	return Decision{}
}

// later says whether b beats a: heard later, or at the same instant an iPhone, or the id.
type pair struct {
	p Presence
	d Device
}

func later(a, b pair) bool {
	if !a.p.HeardAt.Equal(b.p.HeardAt) {
		return a.p.HeardAt.Before(b.p.HeardAt)
	}
	aPhone, bPhone := a.d.Kind == IPhone, b.d.Kind == IPhone
	if aPhone != bPhone {
		return bPhone
	}
	return a.d.ID < b.d.ID
}

// alert is Routing.alert: whether the person may be buzzed. A move inside the interval
// still moves the notification, silently.
func alert(to Surface, delivery *Delivery, t Thresholds, now time.Time) bool {
	if delivery == nil {
		return true
	}
	if delivery.To != nil && *delivery.To == to {
		return false
	}
	return now.Sub(delivery.AlertedAt) >= t.ReAlertInterval
}
