package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/mac"
	"github.com/alexec/agents/Go/wire"
)

// Keeping the Mac awake while agents work (024, #992), as DaemonCore+Wakefulness: the
// switch and the grace in wake.json, the verdict over the agents and the power, and the
// one hold. Only a Mac host holds (wake_darwin.go); the rules are here so they test
// anywhere.

// batteryFloor is the charge at or below which a Mac on battery is left to sleep.
const batteryFloor = 20

type verdictKind int

const (
	verdictIdle verdictKind = iota
	verdictHold
	verdictBatteryLow
)

type wakeVerdict struct {
	kind    verdictKind
	percent int
}

func (v wakeVerdict) holding() bool { return v.kind == verdictHold }

// verdictFor is Wake.verdict: nothing working holds nothing; mains, or no battery, holds;
// a battery holds only above the floor.
func verdictFor(working bool, p mac.Power) wakeVerdict {
	switch {
	case !working:
		return wakeVerdict{kind: verdictIdle}
	case p.OnMains || p.BatteryPercent == nil:
		return wakeVerdict{kind: verdictHold}
	case *p.BatteryPercent > batteryFloor:
		return wakeVerdict{kind: verdictHold}
	}
	return wakeVerdict{kind: verdictBatteryLow, percent: *p.BatteryPercent}
}

// waker decides and holds. What it remembers is only what it last acted on.
type waker struct {
	mu       sync.Mutex
	file     string
	settings *wire.WakeSettings
	power    func() mac.Power
	hold     func() (release func(), err error)
	tell     func(wire.WakeState)

	inFlight     int
	last         *wakeVerdict
	lastUntil    *time.Time
	lastOnPower  bool
	lastPower    *mac.Power
	graceStarted *time.Time
	since        *time.Time
	release      func()
	// told is the count in the last state told.
	told int
}

func defaultWake() wire.WakeSettings {
	return wire.WakeSettings{KeepsAwake: true, GraceHours: 1, WarmRuntimes: 3}
}

// readWakeSettings is WakeSettings' forgiving decoder: a key missing or of the wrong kind
// takes its default, numbers are clamped, and a file that is not JSON is set aside.
func readWakeSettings(path string) wire.WakeSettings {
	s := defaultWake()
	b, err := os.ReadFile(path)
	if err != nil {
		return s
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(b, &m) != nil {
		os.Rename(path, fmt.Sprintf("%s.corrupt-%d", path, time.Now().Unix()))
		store.TrimSetAsides(path)
		return s
	}
	json.Unmarshal(m["keepsAwake"], &s.KeepsAwake)
	json.Unmarshal(m["graceHours"], &s.GraceHours)
	json.Unmarshal(m["warmRuntimes"], &s.WarmRuntimes)
	json.Unmarshal(m["awakeOnPower"], &s.AwakeOnPower)
	return clampWake(s)
}

func clampWake(s wire.WakeSettings) wire.WakeSettings {
	s.GraceHours = min(max(s.GraceHours, 0), 8)
	s.WarmRuntimes = min(max(s.WarmRuntimes, 0), 8)
	return s
}

func (w *waker) load() wire.WakeSettings {
	if w.settings == nil {
		s := readWakeSettings(w.file)
		w.settings = &s
	}
	return *w.settings
}

func (w *waker) Settings() wire.WakeSettings {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.load()
}

// Set saves the switch and the hours and applies them at once.
func (w *waker) Set(s wire.WakeSettings) wire.WakeSettings {
	s = clampWake(s)
	w.mu.Lock()
	w.settings = &s
	if b, err := storeJSON(s); err == nil {
		err = store.WriteAtomically(w.file, b, 0o644)
		if err != nil {
			log.Printf("wake.json: could not write: %v", err)
		}
	}
	w.mu.Unlock()
	w.Revise(-1, true)
	return s
}

func (w *waker) readPower() mac.Power {
	p := w.power()
	w.lastPower = &p
	return p
}

// Revise takes or lets go of the hold for what is happening now; inFlight -1 keeps the
// last count. Reading the power costs a process, so it is read only when it could change
// the verdict, or when force asks (the 15-second tick, and a change of settings).
func (w *waker) Revise(inFlight int, force bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if inFlight >= 0 {
		w.inFlight = inFlight
	}
	s := w.load()
	if !s.KeepsAwake {
		w.graceStarted = nil
		w.apply(wakeVerdict{kind: verdictIdle}, nil, false)
		return
	}
	if w.inFlight > 0 {
		// Work again cancels a grace.
		dropping := w.graceStarted != nil
		w.graceStarted = nil
		if !dropping && !force && !w.lastOnPower && w.last != nil && w.last.kind != verdictIdle {
			w.tellIfCounted()
			return
		}
		w.apply(verdictFor(true, w.readPower()), nil, false)
		return
	}
	// Nothing working. A grace begins only from a hold kept for work.
	var until *time.Time
	if s.GraceHours > 0 {
		if w.graceStarted == nil && w.last != nil && w.last.holding() && w.lastUntil == nil && !w.lastOnPower {
			t := nowFunc()
			w.graceStarted = &t
		}
		if w.graceStarted != nil {
			u := w.graceStarted.Add(time.Duration(s.GraceHours) * time.Hour)
			if nowFunc().Before(u) {
				until = &u
			} else {
				w.graceStarted = nil
			}
		}
	} else {
		w.graceStarted = nil
	}
	if s.AwakeOnPower {
		var p mac.Power
		if !force && w.lastPower != nil {
			p = *w.lastPower
		} else {
			p = w.readPower()
		}
		if p.OnMains {
			w.apply(wakeVerdict{kind: verdictHold}, nil, true)
			return
		}
	}
	if until == nil {
		w.apply(wakeVerdict{kind: verdictIdle}, nil, false)
		return
	}
	if !force && w.last != nil && w.last.kind == verdictHold && w.lastUntil != nil && w.lastUntil.Equal(*until) && !w.lastOnPower {
		return
	}
	if verdictFor(true, w.readPower()).holding() {
		w.apply(wakeVerdict{kind: verdictHold}, until, false)
	} else {
		// At or below the floor with nothing working: quiet. The clock is kept.
		w.apply(wakeVerdict{kind: verdictIdle}, nil, false)
	}
}

// tellIfCounted tells the windows a new count while a hold goes on, which Swift's host
// left for the next change of verdict.
func (w *waker) tellIfCounted() {
	if w.inFlight != w.told {
		w.tell(w.stateLocked())
	}
}

// apply acts on a verdict only when it, the grace's end or the reason has moved.
func (w *waker) apply(v wakeVerdict, until *time.Time, onPower bool) {
	if !v.holding() {
		until = nil
	}
	forPower := v.holding() && onPower
	if w.last != nil && *w.last == v && sameTime(until, w.lastUntil) && forPower == w.lastOnPower {
		return
	}
	was := w.last != nil && w.last.holding()
	w.last = &v
	w.lastUntil = until
	w.lastOnPower = forPower
	if v.holding() {
		if !was {
			t := nowFunc()
			w.since = &t
			if release, err := w.hold(); err != nil {
				log.Printf("could not hold the Mac awake: %v", err)
			} else {
				w.release = release
			}
		}
		switch {
		case forPower:
			log.Print("holding the Mac awake: on power")
		case until != nil:
			log.Print("holding the Mac awake: staying awake so you can reply")
		default:
			log.Print("holding the Mac awake: a turn is in flight")
		}
	} else {
		w.since = nil
		if was {
			w.letGo()
			log.Printf("letting the Mac sleep: %s", sleepWords(v))
		}
	}
	w.tell(w.stateLocked())
}

func (w *waker) letGo() {
	if w.release != nil {
		w.release()
		w.release = nil
	}
}

// Stop lets the Mac go whatever the agents' records say: the host is going.
func (w *waker) Stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.graceStarted = nil
	if w.last == nil || !w.last.holding() {
		return
	}
	w.letGo()
	w.last, w.lastUntil, w.lastOnPower, w.since = nil, nil, false, nil
	log.Print("letting the Mac sleep: the daemon is going")
	w.tell(w.stateLocked())
}

func (w *waker) State() wire.WakeState {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.stateLocked()
}

func (w *waker) stateLocked() wire.WakeState {
	w.told = w.inFlight
	v := wakeVerdict{kind: verdictIdle}
	if w.last != nil {
		v = *w.last
	}
	s := wire.WakeState{IsHolding: v.holding(), AgentsInFlight: int64(w.inFlight), OnPower: v.holding() && w.lastOnPower}
	if w.lastPower != nil && w.lastPower.BatteryPercent != nil {
		p := int64(*w.lastPower.BatteryPercent)
		s.BatteryPercent = &p
	}
	if v.kind == verdictBatteryLow {
		s.HeldBackByBattery = true
		p := int64(v.percent)
		s.BatteryPercent = &p
	}
	if v.holding() {
		if w.since != nil {
			d := wire.DateOf(*w.since)
			s.Since = &d
		}
		if w.lastUntil != nil {
			d := wire.DateOf(*w.lastUntil)
			s.GraceUntil = &d
		}
	}
	return s
}

func sleepWords(v wakeVerdict) string {
	switch v.kind {
	case verdictHold:
		return "a turn is in flight"
	case verdictBatteryLow:
		return fmt.Sprintf("battery at %d%%, at or below the floor", v.percent)
	}
	return "nothing is mid-turn"
}

func sameTime(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Equal(*b)
}
