package controlplane

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// #4158: a row has when its name was first set, the hint a machine with a copy sent, its
// newest operation, and whether it is backed up. The hint goes to the person's own clients
// only: after a set and a read, the store has none of it.
func TestSecretRowInfoAndNoHintInTheStore(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	told := &deliveries{got: map[string][]wire.MachineUserSettings{}}
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	box := p.machineSaying(alex, takingHello("MACHINE-30"))
	p.waitFor(func() bool { _, ok := told.last(box.member.Host); return ok }, "the machine told at its join")

	setSecret(t, alex, "GITHUB_TOKEN", "ghp_0123456789abcdefQ7zX", 0)
	rows := func() []wire.UserSecretRow {
		var names wire.UserSecretNames
		json.Unmarshal(call(t, window, "", "user/secretNames", nil), &names)
		return names.Secrets
	}
	p.waitFor(func() bool { r := rows(); return len(r) == 1 && len(r[0].Machines) == 1 }, "the machine noted")
	first := rows()[0]
	if first.Created == nil || first.Hint != nil || first.LastOp != nil || first.BackedUp == nil || *first.BackedUp {
		t.Fatalf("%+v", first)
	}

	// Replace… keeps created.
	time.Sleep(1100 * time.Millisecond)
	setSecret(t, alex, "GITHUB_TOKEN", "ghp_0123456789abcdefQ7zX", 1)
	p.waitFor(func() bool { r := rows(); return len(r) == 1 && *r[0].Version == 2 }, "the new version")
	if r := rows()[0]; r.Created == nil || *r.Created != *first.Created || r.Updated == first.Updated {
		t.Fatalf("created %v, updated %v; was %v, %v", r.Created, r.Updated, *first.Created, first.Updated)
	}

	// The machine opens it and says what it holds, then an agent reads it.
	hint, version := "Q7zX", int64(2)
	read := wire.DateOf(time.Now())
	fill, github := wire.SecretOperationUseFill, "github.com"
	for _, c := range []wire.MachineSecretOpsCall{
		{Ops: []wire.SecretOperation{}, Held: []wire.MachineSecretHeld{{Name: "GITHUB_TOKEN", Version: &version, Hint: &hint,
			LastOp: &wire.SecretLastOp{What: wire.SecretOperationWhatAdded, At: read - 60}}}},
		{Ops: []wire.SecretOperation{{Name: "GITHUB_TOKEN", What: wire.SecretOperationWhatRead, Use: &fill, Place: &github, At: read}}},
	} {
		params, _ := json.Marshal(c)
		if _, err := p.s.methods.HostSaid(box.member.Host, "machine/secretOps", params); err != nil {
			t.Fatal(err)
		}
	}
	r := rows()[0]
	if r.Hint == nil || *r.Hint != hint || r.LastOp == nil || r.LastOp.What != wire.SecretOperationWhatRead || r.LastOp.At != read {
		t.Fatalf("%+v", r)
	}

	// A hint for an older version is not the row's.
	setSecret(t, alex, "GITHUB_TOKEN", "short", 2)
	p.waitFor(func() bool { return *rows()[0].Version == 3 }, "the third version")
	if r := rows()[0]; r.Hint != nil {
		t.Fatalf("a stale hint: %+v", r)
	}

	// The store has no hint, nor the last operation's time.
	listed, _ := st.List(t.Context(), "")
	for _, k := range listed {
		if o, _ := st.Get(t.Context(), k.Key); o != nil && strings.Contains(string(o.Data), hint) {
			t.Fatalf("%s holds the hint", k.Key)
		}
	}
}
