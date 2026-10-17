package agentsd

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Keeping the Mac awake (024, #992), as DaemonCore+Wakefulness.swift: the Mac's idle sleep
// is held while an agent is mid-turn (starting or running, never one waiting on the person),
// for a grace after the last stops so the person can reply, and while on power when asked;
// never below the battery floor. One hold at most, `caffeinate -i -w <this pid>`, which the
// kernel drops with this process however it ends. The display is not held.
type wakeKeeper struct {
	d        *Daemon
	mu       sync.Mutex
	settings wire.WakeSettings
	loaded   bool

	verdict    string // "hold", "idle", "battery"
	percent    *int64
	graceStart *time.Time
	graceUntil *time.Time
	since      *time.Time
	onPower    bool
	lastPower  *powerReading
	inFlight   int64
	caffeinate *exec.Cmd
	stop       chan struct{}
	readPower  func() powerReading
	now        func() time.Time
	startHold  func() *exec.Cmd
}

// batteryFloorPercent is Wake.batteryFloorPercent: at or below it a laptop on battery sleeps.
const batteryFloorPercent = 20

type powerReading struct {
	onMains bool
	percent *int64
}

func (d *Daemon) registerWake() {
	k := &wakeKeeper{d: d, stop: make(chan struct{}), readPower: readPMSet, now: time.Now, startHold: startCaffeinate}
	d.awake = k
	On(d, wire.CallWakeState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.WakeState, error) {
		return k.state(), nil
	})
	On(d, wire.CallWakeSettings, func(ctx context.Context, c *Client, _ wire.Empty) (wire.WakeSettings, error) {
		k.mu.Lock()
		defer k.mu.Unlock()
		k.load()
		return k.settings, nil
	})
	On(d, wire.CallWakeSet, func(ctx context.Context, c *Client, s wire.WakeSettings) (wire.WakeSettings, error) {
		return k.set(s), nil
	})
	safe.Go("wake", k.run)
}

// run revises every two seconds, reading the power every fifteen (FR-004, FR-011).
func (k *wakeKeeper) run() {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for n := 0; ; n++ {
		select {
		case <-k.stop:
			return
		case <-tick.C:
			k.revise(n%8 == 0)
		}
	}
}

func clampInt(v, lo, hi int64) int64 { return min(max(v, lo), hi) }

// load is wake.json in the root, or on for one hour; read once.
func (k *wakeKeeper) load() {
	if k.loaded {
		return
	}
	k.loaded = true
	k.settings = wire.WakeSettings{KeepsAwake: true, GraceHours: 1, WarmRuntimes: 3}
	b, err := os.ReadFile(filepath.Join(k.d.Store.Loc.Root, "wake.json"))
	if err != nil {
		return
	}
	var raw map[string]any
	if diskjson.Unmarshal(b, &raw) != nil {
		return
	}
	if v, ok := raw["keepsAwake"].(bool); ok {
		k.settings.KeepsAwake = v
	}
	if v, ok := raw["graceHours"].(float64); ok {
		k.settings.GraceHours = clampInt(int64(v), 0, 8)
	}
	if v, ok := raw["warmRuntimes"].(float64); ok {
		k.settings.WarmRuntimes = clampInt(int64(v), 0, 8)
	}
	if v, ok := raw["awakeOnPower"].(bool); ok {
		k.settings.AwakeOnPower = v
	}
}

func (k *wakeKeeper) set(s wire.WakeSettings) wire.WakeSettings {
	k.mu.Lock()
	k.load()
	s.GraceHours, s.WarmRuntimes = clampInt(s.GraceHours, 0, 8), clampInt(s.WarmRuntimes, 0, 8)
	k.settings = s
	if b, err := diskjson.Marshal(s); err == nil {
		if err := store.WriteAtomically(filepath.Join(k.d.Store.Loc.Root, "wake.json"), b, 0o644); err != nil {
			log.Printf("wake.json: could not write: %v", err)
		}
	}
	k.mu.Unlock()
	k.revise(true)
	return s
}

// inFlightNow is how many agents are starting or running: the only agent-side reason to
// hold the Mac awake. One waiting on the person is left out on purpose (FR-003).
func (k *wakeKeeper) inFlightNow() int64 {
	return int64(k.d.Store.CountAgents(func(a *wire.Agent) bool {
		return a.State == wire.AgentStateStarting || a.State == wire.AgentStateRunning
	}))
}

// revise takes or lets go of the hold, as reviseWakefulness.
func (k *wakeKeeper) revise(readPower bool) {
	inFlight := k.inFlightNow()
	k.mu.Lock()
	defer k.mu.Unlock()
	k.load()
	countMoved := inFlight != k.inFlight
	k.inFlight = inFlight
	power := func() powerReading {
		if readPower || k.lastPower == nil {
			r := k.readPower()
			k.lastPower = &r
		}
		return *k.lastPower
	}
	if !k.settings.KeepsAwake {
		k.graceStart = nil
		k.apply("idle", nil, nil, false, countMoved)
		return
	}
	if inFlight > 0 {
		k.graceStart = nil
		v, pct := verdictFor(power())
		k.apply(v, pct, nil, false, countMoved)
		return
	}
	var until *time.Time
	if k.settings.GraceHours > 0 {
		if k.graceStart == nil && k.verdict == "hold" && k.graceUntil == nil && !k.onPower {
			now := k.now()
			k.graceStart = &now
		}
		if k.graceStart != nil {
			u := k.graceStart.Add(time.Duration(k.settings.GraceHours) * time.Hour)
			if k.now().Before(u) {
				until = &u
			} else {
				k.graceStart = nil
			}
		}
	} else {
		k.graceStart = nil
	}
	if k.settings.AwakeOnPower && power().onMains {
		k.apply("hold", nil, nil, true, countMoved)
		return
	}
	if until == nil {
		k.apply("idle", nil, nil, false, countMoved)
		return
	}
	if v, _ := verdictFor(power()); v == "hold" {
		k.apply("hold", nil, until, false, countMoved)
	} else {
		k.apply("idle", nil, nil, false, countMoved)
	}
}

// verdictFor is Wake.verdict with work in flight: on mains or with no battery, hold;
// above the floor, hold; at or below it, held back.
func verdictFor(p powerReading) (string, *int64) {
	if p.onMains || p.percent == nil || *p.percent > batteryFloorPercent {
		return "hold", nil
	}
	return "battery", p.percent
}

// apply acts on a verdict only when it, the grace clock or the power reason moved, and
// says so to every window; a count that moved alone is said too.
func (k *wakeKeeper) apply(verdict string, percent *int64, until *time.Time, onPower, countMoved bool) {
	holding := verdict == "hold"
	if !holding {
		until, onPower = nil, false
	}
	same := verdict == k.verdict && sameTime(until, k.graceUntil) && onPower == k.onPower
	if same && !countMoved {
		return
	}
	if !same {
		wasHolding := k.verdict == "hold"
		k.verdict, k.percent, k.graceUntil, k.onPower = verdict, percent, until, onPower
		if holding {
			if !wasHolding {
				now := k.now()
				k.since = &now
			}
			if k.caffeinate == nil {
				k.caffeinate = k.startHold()
			}
			switch {
			case onPower:
				log.Printf("holding the Mac awake: on power")
			case until != nil:
				log.Printf("holding the Mac awake: staying awake so you can reply")
			default:
				log.Printf("holding the Mac awake: a turn is in flight")
			}
		} else {
			k.since = nil
			if wasHolding {
				k.letGo()
				log.Printf("letting the Mac sleep: %s", sleepWords(verdict, percent))
			}
		}
	}
	state := k.stateLocked()
	safe.Go("wake changed", func() { Broadcast(k.d, wire.NotifyWakeChanged, state) })
}

func sameTime(a, b *time.Time) bool {
	return a == nil && b == nil || a != nil && b != nil && a.Equal(*b)
}

func sleepWords(verdict string, percent *int64) string {
	if verdict == "battery" && percent != nil {
		return "battery at " + strconv.FormatInt(*percent, 10) + "%, at or below the floor"
	}
	return "nothing is mid-turn"
}

func (k *wakeKeeper) letGo() {
	if k.caffeinate != nil {
		k.caffeinate.Process.Kill()
		k.caffeinate.Wait()
		k.caffeinate = nil
	}
}

func (k *wakeKeeper) state() wire.WakeState {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.stateLocked()
}

// stateLocked is WakeState, made fresh: what wake/state answers and windows are told.
func (k *wakeKeeper) stateLocked() wire.WakeState {
	holding := k.verdict == "hold"
	s := wire.WakeState{IsHolding: holding, AgentsInFlight: k.inFlight, HeldBackByBattery: k.verdict == "battery",
		OnPower: holding && k.onPower}
	if k.lastPower != nil {
		s.BatteryPercent = k.lastPower.percent
	}
	if k.verdict == "battery" {
		s.BatteryPercent = k.percent
	}
	if holding && k.since != nil {
		d := wire.DateOf(*k.since)
		s.Since = &d
	}
	if holding && k.graceUntil != nil {
		d := wire.DateOf(*k.graceUntil)
		s.GraceUntil = &d
	}
	return s
}

// shutDown lets the Mac go whatever the records say, as letGoOfTheMac.
func (k *wakeKeeper) shutDown() {
	close(k.stop)
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.verdict == "hold" {
		k.letGo()
		log.Printf("letting the Mac sleep: the daemon is going")
	}
	k.verdict = ""
}

// startCaffeinate holds idle system sleep (not the display) until this process ends.
func startCaffeinate() *exec.Cmd {
	cmd := exec.Command("/usr/bin/caffeinate", "-i", "-w", strconv.Itoa(os.Getpid()))
	if err := cmd.Start(); err != nil {
		log.Printf("wake: could not hold the Mac awake: %v", err)
		return nil
	}
	return cmd
}

var battPercent = regexp.MustCompile(`(\d+)%`)

// readPMSet is PowerSource.read: `pmset -g batt` says the source, and the charge when
// there is a battery. Anything unreadable is mains: a Mac with no battery holds.
func readPMSet() powerReading {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/pmset", "-g", "batt").Output()
	if err != nil {
		return powerReading{onMains: true}
	}
	return parsePMSet(string(out))
}

func parsePMSet(out string) powerReading {
	r := powerReading{onMains: !strings.Contains(out, "'Battery Power'")}
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "InternalBattery") {
			if m := battPercent.FindStringSubmatch(line); m != nil {
				p, _ := strconv.ParseInt(m[1], 10, 64)
				r.percent = &p
			}
		}
	}
	return r
}
