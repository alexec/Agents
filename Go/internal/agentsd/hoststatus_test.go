package agentsd

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

type toldStatus struct {
	mu   sync.Mutex
	sent []wire.MachineStatus
}

func (c *toldStatus) tell(method string, params any) {
	if method != wire.CallHostStatus.Name {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, params.(wire.MachineStatus))
}

func (c *toldStatus) all() []wire.MachineStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]wire.MachineStatus(nil), c.sent...)
}

// host/status (#1387), as DaemonCore+MachineStatus: said to the control plane when the uplink
// comes, again only when it changes, and again whole when the uplink comes back; busy while
// an agent works, idle once none does, with the next scheduled workflow.
func TestAHostTellsItsControlPlaneWhetherItIsIdle(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "nightly.md"), []byte("---\nname: Nightly\non:\n  - schedule:\n      at: \":00\"\n---\nTidy up.\n"), 0o644)
	approveAll(t, c, store.FolderURL(dir))
	worker := seeded(t, d, dir, func(a *wire.Agent) {
		title := "Fix login"
		a.State, a.EndedReason, a.Title = wire.AgentStateRunning, nil, &title
	})
	control := &toldStatus{}
	d.SetControl(control.tell)
	sent := control.all()
	if len(sent) != 1 || sent[0].Idle || len(sent[0].Running) != 1 || sent[0].Running[0] != "Claude (Fix login)" ||
		sent[0].Schedule == nil || sent[0].Schedule.Workflow == nil || *sent[0].Schedule.Workflow != "Nightly" || sent[0].Schedule.At == nil {
		t.Fatalf("%+v", sent)
	}
	// Unchanged: not said again.
	d.reviseHostStatus()
	if n := len(control.all()); n != 1 {
		t.Fatalf("%d", n)
	}
	// The agent ends its turn: idle.
	d.change(worker.ID, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn) })
	d.reviseHostStatus()
	sent = control.all()
	if len(sent) != 2 || !sent[1].Idle || len(sent[1].Running) != 0 {
		t.Fatalf("%+v", sent)
	}
	// The uplink comes back: said again, as it is.
	d.ControlUplinkChanged(true)
	sent = control.all()
	if len(sent) != 3 || !sent[2].Idle {
		t.Fatalf("%+v", sent)
	}
}
