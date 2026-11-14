package agentsd

import (
	"os"
	"slices"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agents/Go/wire"
)

// #3686: spend, usage, time and features are bounded by age, in the hourly sweep, not by
// the newest N keys: a quiet machine with only a few old days keeps none of them.

func readBack(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := diskjson.Unmarshal(b, v); err != nil {
		t.Fatal(err)
	}
}

func TestTheHourlySweepBoundsHistoriesByAge(t *testing.T) {
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.Local)
	atTime(t, now)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	day := func(ago int) string { return dayStamp(now.AddDate(0, 0, -ago)) }
	hour := func(ago int) string { return hourStamp(now.Add(-time.Duration(ago) * time.Hour)) }

	// Fewer keys than each store keeps, so only their age can take them away.
	d.costMu.Lock()
	d.spend = &spendFile{
		Days:   map[string]map[string]float64{day(7): {"USD": 1}, day(6): {"USD": 2}, day(0): {"USD": 3}},
		Tokens: map[string]int64{day(7): 10, day(6): 20},
	}
	usage := map[string]wire.UsageBucket{"claude": {Turns: 1}}
	d.usage = &usageFile{
		Hours: map[string]map[string]wire.UsageBucket{hour(168): usage, hour(167): usage},
		Days:  map[string]map[string]wire.UsageBucket{day(90): usage, day(89): usage},
	}
	d.costMu.Unlock()
	d.timeMu.Lock()
	spent := map[string]wire.TimeBucket{"claude": {Agent: 60}}
	d.timeHeld = &wire.TimeHistory{
		Hours: map[string]map[string]wire.TimeBucket{hour(168): spent, hour(167): spent},
		Days:  map[string]map[string]wire.TimeBucket{day(90): spent, day(89): spent},
		Recap: map[string]wire.DayRecap{day(90): {PeakAgents: 1}, day(89): {PeakAgents: 2}},
	}
	d.timeMu.Unlock()
	d.featureMu.Lock()
	d.features = &featuresFile{Days: map[string]map[string]map[string]int64{
		day(90): {"daemon/ping": {"mac": 1}}, day(89): {"daemon/ping": {"mac": 1}},
	}}
	d.featureMu.Unlock()

	d.sweepHistories(now)

	var s spendFile
	readBack(t, d.spendPath(), &s)
	if got := sortedKeys(s.Days); !slices.Equal(got, []string{day(6), day(0)}) {
		t.Errorf("spend days %v", got)
	}
	if got := sortedKeys(s.Tokens); !slices.Equal(got, []string{day(6)}) {
		t.Errorf("spend tokens %v", got)
	}
	var u usageFile
	readBack(t, d.usagePath(), &u)
	if got := sortedKeys(u.Hours); !slices.Equal(got, []string{hour(167)}) {
		t.Errorf("usage hours %v", got)
	}
	if got := sortedKeys(u.Days); !slices.Equal(got, []string{day(89)}) {
		t.Errorf("usage days %v", got)
	}
	var h wire.TimeHistory
	readBack(t, d.timePath(), &h)
	if got := sortedKeys(h.Hours); !slices.Equal(got, []string{hour(167)}) {
		t.Errorf("time hours %v", got)
	}
	if got := sortedKeys(h.Days); !slices.Equal(got, []string{day(89)}) {
		t.Errorf("time days %v", got)
	}
	if got := sortedKeys(h.Recap); !slices.Equal(got, []string{day(89)}) {
		t.Errorf("time recaps %v", got)
	}
	var f featuresFile
	readBack(t, d.featuresPath(), &f)
	if got := sortedKeys(f.Days); !slices.Equal(got, []string{day(89)}) {
		t.Errorf("feature days %v", got)
	}
}

// Keys from a clock that was set ahead are never too old, so the count still bounds them.
func TestKeepSinceStillCountsKeys(t *testing.T) {
	m := map[string]int{"2026-11-01": 1, "2026-11-05": 1, "2026-12-01": 1, "2026-12-02": 1}
	if gone := keepSince(m, "2026-11-02", 2, ""); gone != 2 {
		t.Fatalf("%d gone", gone)
	}
	if got := sortedKeys(m); !slices.Equal(got, []string{"2026-12-01", "2026-12-02"}) {
		t.Fatalf("%v", got)
	}
}

// A sweep that takes nothing writes nothing. (Features are left out: start's own calls
// are counted, and saved when they changed.)
func TestTheHourlySweepWritesNoStoreWithNothingOld(t *testing.T) {
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.Local)
	atTime(t, now)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.sweepHistories(now)
	for _, p := range []string{d.spendPath(), d.usagePath(), d.timePath()} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s: %v", p, err)
		}
	}
}
