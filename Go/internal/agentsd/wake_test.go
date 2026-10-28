package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/mac"
	"github.com/alexec/agents/Go/wire"
)

func percent(n int) *int { return &n }

func TestVerdictFloorIsInclusive(t *testing.T) {
	for _, c := range []struct {
		working bool
		p       mac.Power
		want    verdictKind
	}{
		{false, mac.Power{OnMains: true}, verdictIdle},
		{true, mac.Power{OnMains: true, BatteryPercent: percent(5)}, verdictHold},
		{true, mac.Power{}, verdictHold},
		{true, mac.Power{BatteryPercent: percent(21)}, verdictHold},
		{true, mac.Power{BatteryPercent: percent(20)}, verdictBatteryLow},
	} {
		if got := verdictFor(c.working, c.p); got.kind != c.want {
			t.Errorf("%+v: got %v, want %v", c, got.kind, c.want)
		}
	}
}

type fakeMac struct {
	power   mac.Power
	holds   int
	reads   int
	told    []wire.WakeState
	holding bool
}

func newWaker(t *testing.T, m *fakeMac) *waker {
	return &waker{
		file:  filepath.Join(t.TempDir(), "wake.json"),
		power: func() mac.Power { m.reads++; return m.power },
		hold: func() (func(), error) {
			m.holds++
			m.holding = true
			return func() { m.holding = false }, nil
		},
		tell: func(s wire.WakeState) { m.told = append(m.told, s) },
	}
}

// testClock is the time nowFunc gives while a test holds it. A daemon's
// background loops (its own or another test's) read it while the test moves
// it, so it is read and written under a lock (#2846).
type testClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *testClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *testClock) set(at time.Time) {
	c.mu.Lock()
	c.at = at
	c.mu.Unlock()
}

func (c *testClock) add(d time.Duration) { c.set(c.now().Add(d)) }

// atTime sets nowFunc to a clock that starts at start until the test ends.
func atTime(t *testing.T, start time.Time) *testClock {
	c := &testClock{at: start}
	old := setNowFunc(c.now)
	t.Cleanup(func() { setNowFunc(old) })
	return c
}

func TestNowFuncSwapDoesNotRace(t *testing.T) {
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				_ = nowFunc()
			}
		}
	}()
	old := setNowFunc(func() time.Time { return time.Unix(1, 0).UTC() })
	if got := nowFunc(); !got.Equal(time.Unix(1, 0).UTC()) {
		t.Fatalf("swapped clock: got %v", got)
	}
	setNowFunc(old)
	close(stop)
	wg.Wait()
}

func TestWakeHoldsForWorkThenTheGrace(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 16, 20, 0, 0, 0, time.UTC))
	m := &fakeMac{power: mac.Power{BatteryPercent: percent(80)}}
	w := newWaker(t, m)

	w.Revise(0, true)
	if m.holding || len(m.told) != 1 || m.told[0].IsHolding {
		t.Fatalf("idle: holding %v, told %+v", m.holding, m.told)
	}
	w.Revise(2, false)
	if !m.holding || m.holds != 1 || !w.State().IsHolding || w.State().AgentsInFlight != 2 {
		t.Fatalf("working: %+v", w.State())
	}
	// The same verdict again neither holds twice nor reads the power.
	reads := m.reads
	w.Revise(2, false)
	if m.holds != 1 || m.reads != reads {
		t.Fatalf("revised again: holds %d, reads %d→%d", m.holds, reads, m.reads)
	}
	// A new count is told while the hold goes on.
	w.Revise(1, false)
	if got := m.told[len(m.told)-1]; got.AgentsInFlight != 1 || !got.IsHolding {
		t.Fatalf("count: %+v", got)
	}
	// The work stops: the grace holds for an hour from now.
	w.Revise(0, false)
	s := w.State()
	if !m.holding || s.GraceUntil == nil || s.GraceUntil.Time().Sub(clock.now()) != time.Hour {
		t.Fatalf("grace: %+v", s)
	}
	clock.add(61 * time.Minute)
	w.Revise(0, true)
	if m.holding || w.State().IsHolding {
		t.Fatalf("after the grace: %+v", w.State())
	}
}

func TestWakeLetsALowBatteryGo(t *testing.T) {
	m := &fakeMac{power: mac.Power{BatteryPercent: percent(15)}}
	w := newWaker(t, m)
	w.Revise(1, false)
	s := w.State()
	if m.holding || !s.HeldBackByBattery || s.BatteryPercent == nil || *s.BatteryPercent != 15 {
		t.Fatalf("low battery: %+v", s)
	}
	m.power = mac.Power{OnMains: true, BatteryPercent: percent(16)}
	w.Revise(1, true)
	if !m.holding || w.State().HeldBackByBattery {
		t.Fatalf("plugged in: %+v", w.State())
	}
}

func TestWakeOffHoldsNothingAndOnPowerHoldsIdle(t *testing.T) {
	m := &fakeMac{power: mac.Power{OnMains: true}}
	w := newWaker(t, m)
	w.Revise(1, false)
	if !m.holding {
		t.Fatal("not holding for work")
	}
	got := w.Set(wire.WakeSettings{KeepsAwake: false, GraceHours: 12, WarmRuntimes: -1})
	if m.holding || got.GraceHours != 8 || got.WarmRuntimes != 0 {
		t.Fatalf("off: holding %v, settings %+v", m.holding, got)
	}
	if b, _ := os.ReadFile(w.file); !strings.Contains(string(b), `"graceHours":8`) {
		t.Fatalf("wake.json: %s", b)
	}
	w.Set(wire.WakeSettings{KeepsAwake: true, AwakeOnPower: true})
	w.Revise(0, false)
	if s := w.State(); !m.holding || !s.OnPower {
		t.Fatalf("on power: %+v", s)
	}
	w.Stop()
	if m.holding || w.State().IsHolding {
		t.Fatal("still holding after Stop")
	}
}

func TestReadWakeSettingsForgives(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wake.json")
	if s := readWakeSettings(path); s != defaultWake() {
		t.Fatalf("missing: %+v", s)
	}
	os.WriteFile(path, []byte(`{"keepsAwake":"yes","graceHours":99,"awakeOnPower":true}`), 0o644)
	if s := readWakeSettings(path); !s.KeepsAwake || s.GraceHours != 8 || s.WarmRuntimes != 3 || !s.AwakeOnPower {
		t.Fatalf("forgiven: %+v", s)
	}
	os.WriteFile(path, []byte(`not json`), 0o644)
	if s := readWakeSettings(path); s != defaultWake() {
		t.Fatalf("corrupt: %+v", s)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a corrupt wake.json was not set aside")
	}
}
