package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// getCounting counts the reads of a store.
type getCounting struct {
	store.Store
	gets atomic.Int64
}

func (g *getCounting) Get(ctx context.Context, key string) (*store.Object, error) {
	g.gets.Add(1)
	return g.Store.Get(ctx, key)
}

// #2054, #2056: a key is read from the store once until its tag moves, and a key the
// store no longer lists is let go.
func TestStoreReadsAreReadOnceByTag(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	st := &getCounting{Store: store.NewMemory()}
	for i := range 30 {
		st.Put(ctx, fmt.Sprintf("v1/x/%02d.json", i), []byte(fmt.Sprint(i)), store.Always)
	}
	var c readCache
	readAll := func() [][]byte {
		keys, _ := st.List(ctx, "v1/x/")
		out, err := c.read(ctx, st, "v1/x/", keys, keys)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	if got := readAll(); len(got) != 30 || string(got[7]) != "7" || st.gets.Load() != 30 {
		t.Fatalf("%d reads", st.gets.Load())
	}
	readAll()
	if st.gets.Load() != 30 {
		t.Fatalf("read again: %d", st.gets.Load())
	}
	st.Put(ctx, "v1/x/07.json", []byte("seven"), store.Always)
	st.Delete(ctx, "v1/x/08.json")
	if got := readAll(); string(got[7]) != "seven" || st.gets.Load() != 31 {
		t.Fatalf("%q, %d reads", got[7], st.gets.Load())
	}
	if len(c.held) != 29 {
		t.Fatalf("%d held", len(c.held))
	}
}

// #2056: past mostRunsRead claims in a week, the newest are counted, not the oldest.
func TestTeamWorkflowsCountsTheNewestRuns(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	_, admin := p.client("Alex's Mac")
	var made wire.BotMade
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform"}), &platform)
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	host := p.botMachine(admin, made.User, "MACHINE-B1").member.Host

	ctx := context.Background()
	now := time.Now()
	old := now.Add(-3 * 24 * time.Hour)
	for i := range mostRunsRead {
		p.s.claimRun(ctx, host, wire.WorkflowClaim{Workflow: "old", Trigger: fmt.Sprint(i)}, old)
	}
	for i := range 3 {
		p.s.claimRun(ctx, host, wire.WorkflowClaim{Workflow: "new", Trigger: fmt.Sprint(i)}, now)
	}
	var board wire.TeamWorkflows
	raw := call(t, admin, "", "console/teamWorkflows", map[string]any{})
	json.Unmarshal(raw, &board)
	runs := map[string]int64{}
	for _, b := range board.Bots {
		for _, w := range b.Workflows {
			runs[w.Workflow] = w.Runs
		}
	}
	if runs["new"] != 3 || runs["old"] != mostRunsRead-3 {
		t.Fatalf("%v", runs)
	}
}
