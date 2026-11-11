package agentsd

import (
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// PSI's lines (#4578): the share of the last 10 s in which some task, or every task
// ("full"), waited for memory. The spike (#4583) calibrates them.
const (
	psiWarnSome     = 10.0
	psiCriticalFull = 10.0
)

// psiPressure reads /proc/pressure/memory's text:
//
//	some avg10=0.00 avg60=0.00 avg300=0.00 total=0
//	full avg10=0.00 avg60=0.00 avg300=0.00 total=0
//
// critical when full avg10 is psiCriticalFull or more, warn when some avg10 is psiWarnSome
// or more, else normal; "" when it has neither line.
func psiPressure(text string) wire.MemoryPressure {
	avg10 := map[string]float64{}
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || (fields[0] != "some" && fields[0] != "full") {
			continue
		}
		for _, f := range fields[1:] {
			if v, ok := strings.CutPrefix(f, "avg10="); ok {
				if n, err := strconv.ParseFloat(v, 64); err == nil {
					avg10[fields[0]] = n
				}
			}
		}
	}
	if len(avg10) == 0 {
		return ""
	}
	switch {
	case avg10["full"] >= psiCriticalFull:
		return wire.MemoryPressureCritical
	case avg10["some"] >= psiWarnSome:
		return wire.MemoryPressureWarn
	}
	return wire.MemoryPressureNormal
}
