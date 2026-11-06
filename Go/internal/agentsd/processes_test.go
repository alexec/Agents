package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// processes/list (#3453): the daemon first, then what it started, each followed by its
// children; a session's runtime, its terminal and their children carry the session.
func TestTheProcessTreeIsTheDaemonsInOrder(t *testing.T) {
	a := wire.UUID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
	b := wire.UUID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
	parents := map[int32]int32{
		10: 1,  // the daemon
		30: 10, // b's runtime
		20: 10, // a's runtime
		21: 20, // node under it
		22: 21,
		25: 10, // a's terminal
		40: 10, // an MCP server: the daemon's own
		50: 1,  // another app's: never listed
		51: 50,
	}
	sessions := map[int32]wire.UUID{20: a, 25: a, 30: b}
	nodes, omitted := processTree(10, parents, sessions, 100)
	if omitted != 0 {
		t.Fatalf("omitted %d", omitted)
	}
	type row struct {
		pid, depth int
		agent      wire.UUID
	}
	var got []row
	for _, n := range nodes {
		r := row{pid: int(n.pid), depth: n.depth}
		if n.agent != nil {
			r.agent = *n.agent
		}
		got = append(got, r)
	}
	want := []row{{10, 0, ""}, {20, 1, a}, {21, 2, a}, {22, 3, a}, {25, 1, a}, {30, 1, b}, {40, 1, ""}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("row %d: got %v, want %v", i, got[i], want[i])
		}
	}
	if nodes[0].parent != 1 {
		t.Fatalf("the daemon's parent %d", nodes[0].parent)
	}

	// Bounded: the rest are counted, not listed.
	nodes, omitted = processTree(10, parents, sessions, 3)
	if len(nodes) != 3 || omitted != 4 {
		t.Fatalf("bounded to 3: %d listed, %d omitted", len(nodes), omitted)
	}
}

// The handler: the daemon (this test) first, a child it started under it, and the
// machine's totals.
func TestProcessesListsTheDaemonAndItsChildren(t *testing.T) {
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Skip("no sleep:", err)
	}
	defer func() { _ = child.Process.Kill(); _ = child.Wait() }()

	_, c := start(t, t.TempDir())
	var s wire.ProcessesState
	if err := json.Unmarshal(c.call(t, 1, wire.CallProcessesList.Name, map[string]any{}), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Processes) == 0 || s.Processes[0].Pid != int64(os.Getpid()) || s.Processes[0].Depth != 0 {
		t.Fatalf("the daemon is not first: %+v", s.Processes)
	}
	var found *wire.ProcessUsage
	for i, p := range s.Processes {
		if p.Pid == int64(child.Process.Pid) {
			found = &s.Processes[i]
		}
	}
	if found == nil || found.Depth != 1 || found.Parent != int64(os.Getpid()) || found.AgentId != nil {
		t.Fatalf("the child: %+v", found)
	}
	if s.Processes[0].Memory <= 0 {
		t.Fatalf("the daemon's memory %d", s.Processes[0].Memory)
	}
	if s.Machine.CpuCount <= 0 || s.Machine.MemoryTotal <= 0 || s.Machine.MemoryUsed <= 0 || s.Machine.MemoryUsed > s.Machine.MemoryTotal {
		t.Fatalf("the machine: %+v", s.Machine)
	}
}

// machine/usage (#3626): the machine's totals, and every disk the daemon looked at, ok
// ones too, so the page lists the root's volume when nothing is low.
func TestMachineUsageHasTheTotalsAndEveryDisk(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.checkDisk()
	var s wire.MachineUsageState
	if err := json.Unmarshal(c.call(t, 1, wire.CallMachineUsage.Name, map[string]any{}), &s); err != nil {
		t.Fatal(err)
	}
	if s.Machine.CpuCount <= 0 || s.Machine.MemoryTotal <= 0 || s.Machine.MemoryUsed <= 0 || s.Machine.MemoryUsed > s.Machine.MemoryTotal {
		t.Fatalf("the machine: %+v", s.Machine)
	}
	if s.Machine.CpuPercent < 0 || s.Machine.CpuPercent > 100 {
		t.Fatalf("the CPU %v", s.Machine.CpuPercent)
	}
	if len(s.Disks) == 0 {
		t.Fatal("no disk: the root's volume is always looked at")
	}
	for _, disk := range s.Disks {
		if disk.Reading.TotalBytes <= 0 || disk.Reading.FreeBytes > disk.Reading.TotalBytes || disk.Level == "" {
			t.Fatalf("a disk: %+v", disk)
		}
	}
}
