package agentsd

import (
	"context"
	"fmt"
	"log"
	"strings"
	goruntime "runtime"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"

	"github.com/alexec/agents/Go/wire"
)

// Capacity (#4578, epic #4584): the machine's level, ok, near or full, from its load per
// core, its memory pressure and its swap. CPU percent is a bad input: 100% busy with a short
// run queue is a healthy machine, and on 2026-10-04 load 113 to 146 on 10 cores made builds
// 10× slower (#236). The level rises at once, and falls only after two looks under the line
// (as the disk's has a margin, #195), so it does not flap. machine.busy is raised when it
// rises from ok, and machine.ok when it comes back to ok.

// The lines. The spike (#4583) calibrates them.
const (
	capacityNearLoad    = 1.5
	capacityFullLoad    = 2.5
	capacityFullSwap    = 50.0
	capacityEvery       = 15 * time.Second
	capacityLooksToFall = 2
)

// capacitySample is one look at the machine.
type capacitySample struct {
	// load1 and load5 are the load averages per core.
	load1, load5 float64
	// pressure is "" when the kernel does not say.
	pressure wire.MemoryPressure
	swap     float64
}

// capacitySampler is the look; a test puts a fake here.
var capacitySampler = sampleCapacity

// sampleCapacity reads the load with gopsutil (getloadavg on a Mac, /proc/loadavg on
// Linux), swap with gopsutil, and the kernel's pressure (kernelPressure). A read that fails
// reads as nothing there: 0, or no pressure.
func sampleCapacity(ctx context.Context) capacitySample {
	var s capacitySample
	cores := float64(max(1, goruntime.NumCPU()))
	if a, err := load.AvgWithContext(ctx); err == nil {
		s.load1, s.load5 = a.Load1/cores, a.Load5/cores
	}
	if m, err := mem.SwapMemoryWithContext(ctx); err == nil && m.Total > 0 {
		s.swap = m.UsedPercent
	}
	s.pressure = kernelPressure()
	return s
}

// capacityTarget is the level one look gives, and the signal that gave it ("" for ok):
// the worst of the three, and the first of load, memory_pressure and swap at that level.
func capacityTarget(s capacitySample) (wire.CapacityLevel, string) {
	switch {
	case s.load1 > capacityFullLoad:
		return wire.CapacityLevelFull, "load"
	case s.pressure == wire.MemoryPressureCritical:
		return wire.CapacityLevelFull, "memory_pressure"
	case s.swap > capacityFullSwap:
		return wire.CapacityLevelFull, "swap"
	case s.load1 > capacityNearLoad:
		return wire.CapacityLevelNear, "load"
	case s.pressure == wire.MemoryPressureWarn:
		return wire.CapacityLevelNear, "memory_pressure"
	}
	return wire.CapacityLevelOk, ""
}

var capacityRank = map[wire.CapacityLevel]int{"": 0, wire.CapacityLevelOk: 0, wire.CapacityLevelNear: 1, wire.CapacityLevelFull: 2}

// nextCapacity is the level after a look: up to the target at once; down only when this
// look and the one before it were both under the level (below is how many in a row were),
// and then to the higher target of the two.
func nextCapacity(was, target, lastBelow wire.CapacityLevel, below int) (level, nextLastBelow wire.CapacityLevel, nextBelow int) {
	if was == "" {
		was = wire.CapacityLevelOk
	}
	switch {
	case capacityRank[target] >= capacityRank[was]:
		return target, "", 0
	case below+1 >= capacityLooksToFall:
		if capacityRank[lastBelow] > capacityRank[target] {
			target = lastBelow
		}
		return target, "", 0
	}
	return was, target, below + 1
}

// capacityBook is the level and the last look, for machine/usage and for the leases and
// starts that follow it (#4579, #4580).
type capacityBook struct {
	capMu      sync.Mutex
	capLevel   wire.CapacityLevel
	capSample  capacitySample
	capSampled bool
	// capBelow is how many looks in a row were under capLevel, and capLastBelow the
	// higher target of them.
	capBelow     int
	capLastBelow wire.CapacityLevel
}

// capacityLevel is the machine's level now: ok before the first look.
func (d *Daemon) capacityLevel() wire.CapacityLevel {
	d.capMu.Lock()
	defer d.capMu.Unlock()
	if d.capLevel == "" {
		return wire.CapacityLevelOk
	}
	return d.capLevel
}

// withCapacity is u with the last look and the level, when there was a look.
func (d *Daemon) withCapacity(u wire.MachineUsage) wire.MachineUsage {
	d.capMu.Lock()
	defer d.capMu.Unlock()
	if !d.capSampled {
		return u
	}
	s := d.capSample
	level := d.capLevel
	u.LoadPerCore, u.LoadPerCore5, u.SwapUsedPercent, u.Capacity = &s.load1, &s.load5, &s.swap, &level
	if s.pressure != "" {
		p := s.pressure
		u.MemoryPressure = &p
	}
	return u
}

// checkCapacity looks once, moves the level and raises its events.
func (d *Daemon) checkCapacity(ctx context.Context) {
	s := capacitySampler(ctx)
	target, signal := capacityTarget(s)
	d.capMu.Lock()
	was := d.capLevel
	if was == "" {
		was = wire.CapacityLevelOk
	}
	level, lastBelow, below := nextCapacity(was, target, d.capLastBelow, d.capBelow)
	d.capLevel, d.capLastBelow, d.capBelow = level, lastBelow, below
	d.capSample, d.capSampled = s, true
	d.capMu.Unlock()
	// The compute line is served one grant a look while the level is ok (#4579).
	d.serveCapacityLine()
	if level == was {
		return
	}
	log.Printf("capacity: %s (was %s; load %.2f per core, memory pressure %s, swap %.0f%%)",
		level, was, s.load1, pressureWords(s.pressure), s.swap)
	switch {
	case was == wire.CapacityLevelOk:
		d.raiseMachineBusy(level, signal, s)
	case level == wire.CapacityLevelOk:
		d.raiseMachineOK(was, s)
	}
}

func pressureWords(p wire.MemoryPressure) string {
	if p == "" {
		return "unknown"
	}
	return string(p)
}

func capacityDetails(s capacitySample) map[string]string {
	return map[string]string{"load_per_core": fmt.Sprintf("%.2f", s.load1), "memory_pressure": string(s.pressure),
		"swap_used_percent": fmt.Sprintf("%.0f", s.swap)}
}

// signalWords is the signal for a sentence: "load 2.4 per core".
func signalWords(signal string, s capacitySample) string {
	switch signal {
	case "memory_pressure":
		return "memory pressure " + string(s.pressure)
	case "swap":
		return fmt.Sprintf("swap %.0f%% used", s.swap)
	}
	return fmt.Sprintf("load %.1f per core", s.load1)
}

// raiseMachineBusy and raiseMachineOK are machine.busy and machine.ok.
func (d *Daemon) raiseMachineBusy(level wire.CapacityLevel, signal string, s capacitySample) {
	words := "near capacity"
	if level == wire.CapacityLevelFull {
		words = "at capacity"
	}
	details := capacityDetails(s)
	details["level"], details["signal"] = string(level), signal
	d.raise(wire.EventDraft{Name: "machine.busy", At: now(), Scope: macScope(),
		Sentence: sentenceMachine() + " is " + words + ": " + signalWords(signal, s) + ".", Details: details})
}

func (d *Daemon) raiseMachineOK(was wire.CapacityLevel, s capacitySample) {
	details := capacityDetails(s)
	details["was"] = string(was)
	d.raise(wire.EventDraft{Name: "machine.ok", At: now(), Scope: macScope(),
		Sentence: fmt.Sprintf("%s has capacity again: load %.1f per core.", sentenceMachine(), s.load1), Details: details})
}

// sentenceMachine is thisMachine at the start of a sentence: "This Mac" or "This server".
func sentenceMachine() string {
	m := thisMachine()
	return strings.ToUpper(m[:1]) + m[1:]
}

// watchCapacity looks once now and every 15 s after.
func (d *Daemon) watchCapacity() {
	d.checkCapacity(d.ctx)
	d.goLoop("capacity", func(ctx context.Context) {
		t := time.NewTicker(capacityEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				d.checkCapacity(ctx)
			}
		}
	})
}
