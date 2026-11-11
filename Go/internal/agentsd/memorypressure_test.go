package agentsd

import (
	"bytes"
	"strings"
	"sync"
	"testing"
)

// Under memory pressure the pool keeps none and says why; when it clears, the setting is
// the cap again, with no restart (#4514).
func TestWarmPoolKeepsNoneUnderMemoryPressure(t *testing.T) {
	fakeRuntimes(t)
	var mu sync.Mutex
	pressure := ""
	pressureNow = func() string { mu.Lock(); defer mu.Unlock(); return pressure }
	was := pressureNow
	t.Cleanup(func() { pressureNow = was })
	set := func(p string) { mu.Lock(); pressure = p; mu.Unlock() }
	var b bytes.Buffer
	var bmu sync.Mutex
	defer captureLog(&b, &bmu)()
	text := func() string { bmu.Lock(); defer bmu.Unlock(); return b.String() }

	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	d.warmPass()
	if l := d.live(id); l.session == nil {
		t.Fatal("released with no pressure")
	}

	set("swap 75% used")
	d.warmPass()
	l := d.live(id)
	l.mu.Lock()
	gone := l.session == nil
	l.mu.Unlock()
	if !gone {
		t.Fatal("kept under memory pressure")
	}
	if got := text(); !strings.Contains(got, "warm pool: cap 0 (swap 75% used; the setting is 3)") ||
		!strings.Contains(got, "warm pool: released "+string(id)+" (least recently used, over the cap of 0; swap 75% used)") {
		t.Fatal(got)
	}
	if capacity, why := d.warmCap(d.warmSettings()); capacity != 0 || why == "" {
		t.Fatalf("cap %d (%q)", capacity, why)
	}
	if n := strings.Count(text(), "warm pool: cap 0"); n != 1 {
		t.Fatalf("the change was logged %d times", n)
	}

	set("")
	if capacity, _ := d.warmCap(d.warmSettings()); capacity != 3 {
		t.Fatalf("cap %d once it cleared, want the setting", capacity)
	}
	if !strings.Contains(text(), "warm pool: cap 3 (memory pressure cleared)") {
		t.Fatal(text())
	}
}

// machinePressure reads this machine without failing; what it says depends on the machine.
func TestMachinePressureReads(t *testing.T) {
	t.Log(machinePressure())
}
