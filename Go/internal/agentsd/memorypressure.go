package agentsd

import (
	"context"
	"fmt"
	"log"

	"github.com/shirou/gopsutil/v4/mem"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Memory pressure (#4514): each warm runtime holds 90 to 200 MB (#4504), the wrong trade
// for a faster first reply when the machine already swaps. While swap is more than half
// used, or macOS says its memory pressure is warning or critical, the pool's cap is 0 and
// it ends the runtimes it has; when that clears, the cap is WakeSettings.warmRuntimes again.
// Each change of the cap is logged as "warm pool: cap <n> (<why>)".

// swapHighPercent is the share of swap in use above which the pool keeps none.
const swapHighPercent = 50

// pressureNow is the machine's memory pressure: why the pool keeps none, or "" when it
// may keep its setting. A test puts a fake here.
var pressureNow = machinePressure

// machinePressure reads swap with gopsutil (vm.swapusage on a Mac, /proc/meminfo on
// Linux) and, on a Mac, the kernel's pressure level (pressureLevel). A read that fails
// says no pressure: the setting holds.
func machinePressure() string {
	if why := pressureLevel(); why != "" {
		return why
	}
	if s, err := mem.SwapMemoryWithContext(context.Background()); err == nil && s.Total > 0 && s.UsedPercent > swapHighPercent {
		return fmt.Sprintf("swap %.0f%% used", s.UsedPercent)
	}
	return ""
}

// warmCap is the pool's cap now: 0 under memory pressure, else the setting. why is the
// pressure, "" with none. A change from the last look is logged.
func (d *Daemon) warmCap(s wire.WakeSettings) (capacity int, why string) {
	why = pressureNow()
	d.pressureMu.Lock()
	was := d.pressure
	d.pressure = why
	d.pressureMu.Unlock()
	switch {
	case why != "" && was == "":
		log.Printf("warm pool: cap 0 (%s; the setting is %d)", why, s.WarmRuntimes)
	case why == "" && was != "":
		log.Printf("warm pool: cap %d (memory pressure cleared)", s.WarmRuntimes)
	}
	if why != "" {
		return 0, why
	}
	return int(s.WarmRuntimes), ""
}
