package controlplane

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A client's catch-up keeps the host's list too (#4794): whole when it says all, and what
// changed laid on the list held when it says what changed since.
func TestACatchUpIsKept(t *testing.T) {
	t.Parallel()
	catchUp := wire.CallClientCatchUp.Name
	for params, want := range map[string]bool{
		`{}`: true,
		`{"agents":{"lean":true,"includeArchived":false}}`:                   true,
		`{"agents":{"lean":true,"changedSince":{"epoch":"e","revision":3}}}`: true,
		`{"agents":{"lean":true,"folder":"/x"}}`:                             false,
		`{"agents":{"lean":false}}`:                                          false,
		`{"agents":{"lean":true,"includeArchived":true}}`:                    false,
	} {
		if got := keepsList(catchUp, json.RawMessage(params)); got != want {
			t.Errorf("keepsList(%s) = %v", params, got)
		}
	}
	// agents/list asked what changed since is not the whole list.
	if keepsList("agents/list", json.RawMessage(`{"lean":true,"changedSince":{"epoch":"e","revision":3}}`)) {
		t.Fatal("kept a list of changes as the whole list")
	}

	ids := func(list []json.RawMessage) []string {
		out := []string{}
		for _, raw := range list {
			var r struct{ ID string }
			_ = json.Unmarshal(raw, &r)
			out = append(out, r.ID)
		}
		return out
	}
	whole, ok := caughtUp(json.RawMessage(`{"agents":[{"id":"A"},{"id":"B"}],"agentChanges":{"epoch":"e","revision":1,"removed":[],"all":true}}`), nil)
	if !ok || len(whole) != 2 {
		t.Fatalf("whole: %v %v", ok, ids(whole))
	}
	held, _ := json.Marshal(whole)
	changed, ok := caughtUp(json.RawMessage(`{"agents":[{"id":"C","state":"running"},{"id":"a","state":"archived"}],`+
		`"agentChanges":{"epoch":"e","revision":2,"removed":["B"],"all":false}}`), held)
	if got := ids(changed); !ok || len(got) != 1 || got[0] != "C" {
		t.Fatalf("changed: %v %v", ok, got)
	}
	// Changes with nothing held are not a list to keep.
	if _, ok := caughtUp(json.RawMessage(`{"agents":[],"agentChanges":{"epoch":"e","revision":2,"removed":[],"all":false}}`), nil); ok {
		t.Fatal("kept changes on nothing")
	}
}
