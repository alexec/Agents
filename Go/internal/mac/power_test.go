package mac

import "testing"

func TestParseBatt(t *testing.T) {
	for _, c := range []struct {
		out     string
		mains   bool
		percent int
	}{
		{"Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t85%; discharging; 4:12 remaining present: true\n", false, 85},
		{"Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t100%; charged; 0:00 remaining present: true\n", true, 100},
		{"Now drawing from 'AC Power'\n", true, -1},
		{"", true, -1},
	} {
		p := ParseBatt(c.out)
		if p.OnMains != c.mains || (c.percent < 0) != (p.BatteryPercent == nil) || p.BatteryPercent != nil && *p.BatteryPercent != c.percent {
			t.Errorf("%q: %+v", c.out, p)
		}
	}
}
