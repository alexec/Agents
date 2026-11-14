package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The host's part of the budgets a pull request keeps (#4784): bytes, which do not change
// with the runner's load, as a time does. The budgets are in scripts/perf-budgets.json.

// perfSeedAgents is how many live sessions the seeded root holds: more than a busy day's
// 24 on the live root (specs/4777-fast/spec.md, "Measured times").
const perfSeedAgents = 50

func perfBudget(t *testing.T, name string) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "scripts", "perf-budgets.json"))
	if err != nil {
		t.Fatal(err)
	}
	var budgets struct {
		PR map[string]int `json:"pr"`
	}
	if err := json.Unmarshal(b, &budgets); err != nil {
		t.Fatal(err)
	}
	n, ok := budgets.PR[name]
	if !ok || n <= 0 {
		t.Fatalf("no budget %q in scripts/perf-budgets.json", name)
	}
	return n
}

// perfSeeded puts perfSeedAgents live sessions in one folder, each with the option and
// command lists a real runtime gives (878 KB of 1 MB on the live root), which lean leaves out.
func perfSeeded(t *testing.T, d *Daemon, dir string) {
	t.Helper()
	for i := range perfSeedAgents {
		seeded(t, d, dir, func(a *wire.Agent) {
			title := fmt.Sprintf("Seeded session %02d: fix the flaky test in the sidebar", i)
			a.Title = &title
			for j := range 60 {
				description := fmt.Sprintf("What /command-%02d does, in a sentence of about this length.", j)
				a.AvailableCommands = append(a.AvailableCommands, wire.SlashCommand{Name: fmt.Sprintf("command-%02d", j), Description: &description})
			}
			for j := range 6 {
				a.AdvertisedOptions = append(a.AdvertisedOptions, wire.ConfigOption{ID: fmt.Sprintf("option-%d", j), Name: fmt.Sprintf("Option %d", j), Type: "boolean"})
			}
		})
	}
}

func TestLeanAgentRecordKeepsItsBudget(t *testing.T) {
	d, c := start(t, t.TempDir())
	dir := folder(t, c, 1)
	perfSeeded(t, d, dir)
	var agents []json.RawMessage
	if err := json.Unmarshal(c.call(t, 2, "agents/list", wire.ListRequest{Lean: true}), &agents); err != nil {
		t.Fatal(err)
	}
	if len(agents) != perfSeedAgents {
		t.Fatalf("%d agents listed", len(agents))
	}
	largest := 0
	for _, a := range agents {
		largest = max(largest, len(a))
	}
	budget := perfBudget(t, "host.leanAgentBytes")
	t.Logf("lean Agent record: %d bytes at most (budget %d)", largest, budget)
	if largest > budget {
		t.Fatalf("a lean Agent record is %d bytes, over its budget of %d (scripts/perf-budgets.json, #4784)", largest, budget)
	}
}

func TestCatchUpKeepsItsBudget(t *testing.T) {
	d, c := start(t, t.TempDir())
	dir := folder(t, c, 1)
	perfSeeded(t, d, dir)
	size := len(c.call(t, 2, "client/catchUp", wire.CatchUpRequest{Parts: []string{"pins"}}))
	budget := perfBudget(t, "host.catchUpBytes")
	t.Logf("client/catchUp, %d live sessions: %d bytes (budget %d)", perfSeedAgents, size, budget)
	if size > budget {
		t.Fatalf("client/catchUp for %d live sessions is %d bytes, over its budget of %d (scripts/perf-budgets.json, #4784)", perfSeedAgents, size, budget)
	}
}
