package agentsd

import (
	"context"
	"os"
	goruntime "runtime"
	"slices"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// processes/list (#3453): what runs on this machine, for its page. The daemon, each
// session's runtime and the terminals it asked for, and every child of those, with the CPU
// and memory each uses now, and the machine's totals. Only our processes: never another
// app's. Asked while a page is open; between asks, only each process's last CPU time is
// kept, and only for the processes the last ask listed.

// processesMax bounds the list: a runtime that forks without end does not make the answer
// grow without end.
const processesMax = 200

// processesFresh is how old the last ask's CPU times may be and still be the start of
// "now": an ask after a longer gap measures over processesSample instead.
const (
	processesFresh  = time.Minute
	processesSample = 500 * time.Millisecond
)

type processBook struct {
	procMu sync.Mutex
	// procCPU is each listed process's CPU seconds at procAt; machineBusy and machineAll
	// are the machine's.
	procCPU                 map[int32]float64
	procAt                  time.Time
	machineBusy, machineAll float64
	// machineAt is when machineBusy and machineAll were read, by either ask (#3626).
	machineAt time.Time
}

// processNode is a process in the tree: its parent, and the session it is part of.
type processNode struct {
	pid, parent int32
	depth       int
	agent       *wire.UUID
}

// processTree is the daemon's tree, in order: root first, each process followed by its
// children by pid, a session's own processes under the daemon as the daemon started them.
// A process under a session's runtime or terminal is that session's. At most max nodes;
// omitted counts the rest.
func processTree(root int32, parents map[int32]int32, sessions map[int32]wire.UUID, max int) (nodes []processNode, omitted int) {
	children := map[int32][]int32{}
	for pid, parent := range parents {
		if pid != root {
			children[parent] = append(children[parent], pid)
		}
	}
	for _, c := range children {
		slices.Sort(c)
	}
	seen := map[int32]bool{}
	var walk func(pid, parent int32, depth int, agent *wire.UUID)
	walk = func(pid, parent int32, depth int, agent *wire.UUID) {
		if seen[pid] {
			return
		}
		seen[pid] = true
		if id, ok := sessions[pid]; ok {
			agent = &id
		}
		if len(nodes) < max {
			nodes = append(nodes, processNode{pid: pid, parent: parent, depth: depth, agent: agent})
		} else {
			omitted++
		}
		for _, c := range children[pid] {
			walk(c, pid, depth+1, agent)
		}
	}
	walk(root, parents[root], 0, nil)
	return nodes, omitted
}

func (d *Daemon) processesState(ctx context.Context) wire.ProcessesState {
	d.procMu.Lock()
	defer d.procMu.Unlock()

	sessions := map[int32]wire.UUID{}
	for _, l := range d.everyLive() {
		l.mu.Lock()
		if l.session != nil {
			for _, pid := range l.session.Pids() {
				sessions[int32(pid)] = l.id
			}
		}
		l.mu.Unlock()
	}
	titles := map[wire.UUID]string{}
	for _, a := range d.Store.Agents() {
		if a.Title != nil {
			titles[a.ID] = *a.Title
		}
	}

	parents := map[int32]int32{}
	if pids, err := process.PidsWithContext(ctx); err == nil {
		for _, pid := range pids {
			if p, err := process.NewProcessWithContext(ctx, pid); err == nil {
				if parent, err := p.PpidWithContext(ctx); err == nil {
					parents[pid] = parent
				}
			}
		}
	}
	root := int32(os.Getpid())
	if _, ok := parents[root]; !ok {
		parents[root] = int32(os.Getppid())
	}
	nodes, omitted := processTree(root, parents, sessions, processesMax)

	procs := make([]*process.Process, len(nodes))
	for i, n := range nodes {
		procs[i], _ = process.NewProcessWithContext(ctx, n.pid)
	}
	cpuOf := func() map[int32]float64 {
		m := map[int32]float64{}
		for _, p := range procs {
			if p == nil {
				continue
			}
			if t, err := p.TimesWithContext(ctx); err == nil {
				m[p.Pid] = t.User + t.System
			}
		}
		return m
	}
	machineOf := func() (busy, all float64) { return machineCPU(ctx) }

	// The start of "now": the last ask's, when it is fresh, or a sample taken here.
	before, beforeAt := d.procCPU, d.procAt
	beforeBusy, beforeAll := d.machineBusy, d.machineAll
	if before == nil || time.Since(beforeAt) > processesFresh {
		beforeBusy, beforeAll = machineOf()
		before, beforeAt = cpuOf(), time.Now()
		select {
		case <-ctx.Done():
		case <-time.After(processesSample):
		}
	}
	now, nowAt := cpuOf(), time.Now()
	busy, all := machineOf()
	d.procCPU, d.procAt, d.machineBusy, d.machineAll, d.machineAt = now, nowAt, busy, all, nowAt

	out := wire.ProcessesState{Processes: make([]wire.ProcessUsage, 0, len(nodes)), Omitted: int64(omitted)}
	elapsed := nowAt.Sub(beforeAt).Seconds()
	for i, n := range nodes {
		u := wire.ProcessUsage{Pid: int64(n.pid), Parent: int64(n.parent), Depth: int64(n.depth), Name: "?", AgentId: n.agent}
		if n.agent != nil {
			if t, ok := titles[*n.agent]; ok {
				u.Title = &t
			}
		}
		if p := procs[i]; p != nil {
			if name, err := p.NameWithContext(ctx); err == nil && name != "" {
				u.Name = name
			}
			if m, err := p.MemoryInfoWithContext(ctx); err == nil {
				u.Memory = int64(m.RSS)
			}
		}
		if was, ok := before[n.pid]; ok && elapsed > 0 {
			u.CpuPercent = max(0, (now[n.pid]-was)/elapsed*100)
		}
		out.Processes = append(out.Processes, u)
	}

	out.Machine = d.withCapacity(machineUsage(ctx, beforeBusy, beforeAll, busy, all))
	return out
}

// machineCPU is the machine's busy and total CPU seconds, every core together.
func machineCPU(ctx context.Context) (busy, all float64) {
	ts, err := cpu.TimesWithContext(ctx, false)
	if err != nil || len(ts) == 0 {
		return 0, 0
	}
	t := ts[0]
	all = t.User + t.System + t.Idle + t.Nice + t.Iowait + t.Irq + t.Softirq + t.Steal
	return all - t.Idle - t.Iowait, all
}

// machineUsage is the machine's CPU between two reads of machineCPU, and its memory now.
func machineUsage(ctx context.Context, beforeBusy, beforeAll, busy, all float64) wire.MachineUsage {
	u := wire.MachineUsage{CpuCount: int64(goruntime.NumCPU())}
	if all > beforeAll {
		u.CpuPercent = max(0, min(100, (busy-beforeBusy)/(all-beforeAll)*100))
	}
	if v, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		u.MemoryUsed, u.MemoryTotal = int64(v.Used), int64(v.Total)
	}
	return u
}

// machineUsageState is machine/usage (#3626): a machine's page. Its CPU since the last ask
// (of either this or processes/list), or over processesSample when there was none in the last
// minute; its memory now; and every disk the last disk look found, ok ones too.
func (d *Daemon) machineUsageState(ctx context.Context) wire.MachineUsageState {
	d.procMu.Lock()
	beforeBusy, beforeAll := d.machineBusy, d.machineAll
	if d.machineAt.IsZero() || time.Since(d.machineAt) > processesFresh {
		beforeBusy, beforeAll = machineCPU(ctx)
		select {
		case <-ctx.Done():
		case <-time.After(processesSample):
		}
	}
	busy, all := machineCPU(ctx)
	d.machineBusy, d.machineAll, d.machineAt = busy, all, time.Now()
	d.procMu.Unlock()

	out := wire.MachineUsageState{Machine: d.withCapacity(machineUsage(ctx, beforeBusy, beforeAll, busy, all))}
	d.diskMu.Lock()
	out.Disks = append([]wire.DiskAlarm{}, d.diskVolumes...)
	d.diskMu.Unlock()
	return out
}
