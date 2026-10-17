// Package mac is what the Go agentsd asks of the Mac it runs on, through the Mac's own
// commands, so the host needs no cgo (#1138).
package mac

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Power is what the machine says about its own power, as IOKitPowerSource reads it.
// BatteryPercent is nil on a Mac with no battery, which counts as mains.
type Power struct {
	BatteryPercent *int
	OnMains        bool
}

// UnknownPower is what to believe when the Mac will not say: mains, which holds. Holding
// wrongly leaves a Mac awake, which the person can see; releasing wrongly loses a turn
// (024 T005).
var UnknownPower = Power{OnMains: true}

// ReadPower asks `pmset -g batt`.
func ReadPower() Power {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/pmset", "-g", "batt").Output()
	if err != nil {
		return UnknownPower
	}
	return ParseBatt(string(out))
}

var percentRE = regexp.MustCompile(`\t(\d+)%;`)

// ParseBatt reads `pmset -g batt`:
//
//	Now drawing from 'Battery Power'
//	 -InternalBattery-0 (id=4653155)	85%; discharging; 4:12 remaining present: true
//
// A desktop has the first line only. The charge is the first source that gives one.
func ParseBatt(out string) Power {
	lines := strings.Split(out, "\n")
	if len(lines) == 0 || !strings.Contains(lines[0], "drawing from") {
		return UnknownPower
	}
	p := Power{OnMains: !strings.Contains(lines[0], "'Battery Power'")}
	for _, l := range lines[1:] {
		if m := percentRE.FindStringSubmatch(l); m != nil {
			n, _ := strconv.Atoi(m[1])
			n = min(max(n, 0), 100)
			p.BatteryPercent = &n
			break
		}
	}
	return p
}

// Hold keeps the Mac from idle sleep until Release, or until this process ends:
// `caffeinate -i -w <pid>` ends with it, so a host that dies holds nothing.
type Hold struct{ cmd *exec.Cmd }

// HoldAwake starts the hold.
func HoldAwake() (*Hold, error) {
	cmd := exec.Command("/usr/bin/caffeinate", "-i", "-w", strconv.Itoa(os.Getpid()))
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go cmd.Wait()
	return &Hold{cmd: cmd}, nil
}

// Release lets the Mac sleep again.
func (h *Hold) Release() {
	if h != nil && h.cmd.Process != nil {
		h.cmd.Process.Kill()
	}
}
