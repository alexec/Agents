package notices

// RoutingTests.swift, ported, and the desk's own cases.

import (
	"encoding/json"
	"testing"
	"time"
)

var (
	t0     = time.Unix(978307200+1_000_000, 0)
	limits = Thresholds{MacIdle: 120 * time.Second, DeviceStaleness: 600 * time.Second,
		SettlingPause: 20 * time.Second, ReAlertInterval: 300 * time.Second}
	agent = "A0000000-0000-4000-8000-000000000001"
	phone = "B0000000-0000-4000-8000-000000000002"
	pad   = "C0000000-0000-4000-8000-000000000003"
	yes   = true
	no    = false
)

func need() Need { return Need{Agent: agent, RaisedAt: t0.Add(-time.Hour)} }

func device(id, kind string, may *bool, lastSeen time.Time) Device {
	return Device{ID: id, Kind: kind, MayNotify: may, LastSeen: lastSeen}
}

func presence(s Surface, watching string, active bool, ago time.Duration) Presence {
	return Presence{Surface: s, Watching: watching, Active: active, HeardAt: t0.Add(-ago)}
}

func decide(n Need, ps []Presence, ds []Device, d *Delivery, now time.Time) Decision {
	m := map[Surface]Presence{}
	for _, p := range ps {
		m[p.Surface] = p
	}
	return Decide(n, m, ds, d, limits, now)
}

func to(d Decision) string {
	switch {
	case d.To == nil:
		return "nowhere"
	case d.To.IsMac():
		return "mac"
	}
	return d.To.Device
}

var dev = func(id string) Surface { return Surface{Device: id} }

func TestTheLadder(t *testing.T) {
	iphone := device(phone, IPhone, &yes, t0)
	// 1. Watching silences everything, on any surface.
	if d := decide(need(), []Presence{presence(Mac, agent, true, 0)}, []Device{iphone}, nil, t0); d.To != nil || d.Alert || d.Wait {
		t.Fatal(d)
	}
	if d := decide(need(), []Presence{presence(Mac, "", true, 5*time.Second), presence(dev(pad), agent, true, time.Second)},
		[]Device{iphone}, nil, t0); d.To != nil {
		t.Fatal(to(d))
	}
	// 2. At the Mac, active and recent.
	if d := decide(need(), []Presence{presence(Mac, "", true, 30*time.Second), presence(dev(phone), "", true, time.Second)},
		[]Device{iphone}, nil, t0); to(d) != "mac" || !d.Alert || d.Wait {
		t.Fatal(d)
	}
	if d := decide(need(), []Presence{presence(Mac, "", false, 0)}, []Device{iphone}, nil, t0); to(d) != phone {
		t.Fatal(to(d))
	}
	if d := decide(need(), []Presence{presence(Mac, "", true, 121*time.Second)}, []Device{iphone}, nil, t0); to(d) != phone {
		t.Fatal(to(d))
	}
	// 3. The device in hand.
	if d := decide(need(), []Presence{presence(dev(pad), "", true, 10*time.Second), presence(dev(phone), "", true, 100*time.Second)},
		[]Device{iphone, device(pad, IPad, &yes, t0)}, nil, t0); to(d) != pad {
		t.Fatal(to(d))
	}
	// A device that may not notify is skipped, and so is one that never said.
	for _, may := range []*bool{&no, nil} {
		if d := decide(need(), []Presence{presence(dev(phone), "", true, time.Second)},
			[]Device{device(phone, IPhone, may, t0)}, nil, t0); d.To != nil {
			t.Fatal(to(d))
		}
	}
	// 4. The default: the most recently used iPhone; never an unknown.
	older := device("D0000000-0000-4000-8000-000000000004", IPhone, &yes, t0.Add(-9000*time.Second))
	newer := device(phone, IPhone, &yes, t0.Add(-4000*time.Second))
	if d := decide(need(), []Presence{presence(dev(pad), "", true, 601*time.Second)},
		[]Device{older, newer, device(pad, IPad, &yes, t0)}, nil, t0); to(d) != phone {
		t.Fatal(to(d))
	}
	if d := decide(need(), nil, []Device{device(older.ID, Unknown, &yes, t0), device(pad, IPad, &yes, t0)}, nil, t0); d.To != nil {
		t.Fatal(to(d))
	}
	// A tie goes to the iPhone.
	if d := decide(need(), []Presence{presence(dev(pad), "", true, 3*time.Second), presence(dev(phone), "", true, 3*time.Second)},
		[]Device{device(pad, IPad, &yes, t0), iphone}, nil, t0); to(d) != phone {
		t.Fatal(to(d))
	}
}

func TestThePauseAndTheInterval(t *testing.T) {
	fresh := Need{Agent: agent, RaisedAt: t0.Add(-5 * time.Second)}
	inside := decide(fresh, []Presence{presence(Mac, "", true, 0)}, nil, nil, t0)
	if !inside.Wait || to(inside) != "mac" || inside.Alert {
		t.Fatal(inside)
	}
	outside := decide(fresh, []Presence{presence(Mac, "", true, 0)}, nil, nil, t0.Add(20*time.Second))
	if outside.Wait || !outside.Alert {
		t.Fatal(outside)
	}
	iphone := device(phone, IPhone, &yes, t0)
	if d := decide(Need{Agent: agent, RaisedAt: t0}, []Presence{presence(dev(phone), "", true, 0)}, []Device{iphone}, nil, t0); d.Wait || to(d) != phone {
		t.Fatal(d)
	}
	mac := Mac
	moved := decide(need(), []Presence{presence(dev(phone), "", true, 0)}, []Device{iphone},
		&Delivery{To: &mac, AlertedAt: t0.Add(-100 * time.Second)}, t0)
	if to(moved) != phone || moved.Alert {
		t.Fatal(moved)
	}
	later := decide(need(), []Presence{presence(dev(phone), "", true, 0)}, []Device{iphone},
		&Delivery{To: &mac, AlertedAt: t0.Add(-301 * time.Second)}, t0)
	if !later.Alert {
		t.Fatal(later)
	}
	if d := decide(need(), []Presence{presence(Mac, "", true, 0)}, nil, &Delivery{To: &mac, AlertedAt: t0.Add(-10000 * time.Second)}, t0); d.Alert {
		t.Fatal(d)
	}
}

// The desk posts a need once, moves it with a withdrawal from the old device, and takes
// it back when it is met.
func TestTheDesk(t *testing.T) {
	desk := NewDesk()
	id := json.RawMessage(`{"permission":"E0000000-0000-4000-8000-000000000005"}`)
	headline := json.RawMessage(`{"h1":"work","h2":"Fix the test","h3":"may run a command"}`)
	raised := t0.Add(-600 * time.Second).Sub(referenceDate).Seconds()
	message := AttentionNeed{Need: &NeedOnWire{ID: id, AgentID: &agent, RaisedAt: raised, Headline: headline}}
	devices := []Device{device(phone, IPhone, &yes, t0), device(pad, IPad, &yes, t0)}
	devices[0].PublicKey = []byte{4, 1}

	first := desk.Heard(message, map[Surface]Presence{dev(phone): presence(dev(phone), "", true, 0)}, devices, t0)
	if len(first) != 1 || first[0].Device != phone || !first[0].Alert || string(first[0].Headline) != string(headline) || len(first[0].PublicKey) != 2 {
		t.Fatalf("%+v", first)
	}
	if again := desk.Heard(message, map[Surface]Presence{dev(phone): presence(dev(phone), "", true, 0)}, devices, t0); len(again) != 0 {
		t.Fatalf("posted twice: %+v", again)
	}
	moved := desk.Heard(message, map[Surface]Presence{dev(pad): presence(dev(pad), "", true, 0)}, devices, t0.Add(time.Second))
	if len(moved) != 2 || moved[0].Device != phone || moved[0].Headline != nil || moved[1].Device != pad || moved[1].Alert {
		t.Fatalf("%+v", moved)
	}
	gone := desk.Heard(AttentionNeed{Withdraw: json.RawMessage(`{ "permission" : "E0000000-0000-4000-8000-000000000005" }`)}, nil, devices, t0)
	if len(gone) != 1 || gone[0].Device != pad {
		t.Fatalf("%+v", gone)
	}
	b, _ := json.Marshal(gone[0])
	if string(b) != `{"needID":{"permission":"E0000000-0000-4000-8000-000000000005"},"device":"`+pad+`","alert":false}` {
		t.Fatal(string(b))
	}
}
