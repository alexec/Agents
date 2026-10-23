package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func listedProviders(t *testing.T, s *controllink.Session) []wire.ProviderSummary {
	t.Helper()
	var listed wire.ProviderList
	json.Unmarshal(call(t, s, "", "providers/list", nil), &listed)
	return listed.Providers
}

// US5 AS4 (#1761, FR-027, FR-028): a provider given to a group is shown to and used by
// that group's users only. One with no group is the admins'. Only an admin changes groups.
func TestOnlyAProvidersGroupSeesAndUsesIt(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	record := `{"id":"do-1","name":"DigitalOcean","kind":"http","url":"http://127.0.0.1:9/","secretNames":[],` +
		`"capabilities":["create"],"contract":1,"rev":1}`
	if _, err := st.Put(context.Background(), providers.ProviderKey("do-1"), []byte(record), store.Absent); err != nil {
		t.Fatal(err)
	}
	p := startPlaneWith(t, st, controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	kim := p.invite(owner, "Kim", wire.UserRoleMember)

	// Made before groups: the admins' alone.
	if got := listedProviders(t, owner); len(got) != 1 || got[0].MayUse == nil || !*got[0].MayUse {
		t.Fatalf("%+v", got)
	}
	if got := listedProviders(t, sam.window); len(got) != 0 {
		t.Fatalf("Sam sees %+v", got)
	}
	if e := callError(t, sam.window, "", "groups/set", wire.GroupSet{Name: "Mine", Members: []string{sam.id}}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}

	var platform wire.Group
	json.Unmarshal(call(t, owner, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	if platform.ID == "" || len(platform.Members) != 1 {
		t.Fatalf("%+v", platform)
	}
	if e := callError(t, owner, "", "groups/set", wire.GroupSet{Name: "platform"}); !strings.Contains(e, "already a group") {
		t.Fatal(e)
	}
	call(t, owner, "", "providers/setGroup", wire.ProviderGroup{Provider: "do-1", Group: &platform.ID})
	// Sam is told the provider, now theirs to use; a list from before said none.
	for {
		note := waitNote(t, sam.window, "control/providersChanged")
		var told wire.ProviderList
		json.Unmarshal(note.Params, &told)
		if len(told.Providers) == 1 && *told.Providers[0].Group == platform.ID {
			break
		}
		if len(told.Providers) != 0 {
			t.Fatalf("Sam was told %s", note.Params)
		}
	}

	if got := listedProviders(t, sam.window); len(got) != 1 || !*got[0].MayUse {
		t.Fatalf("Sam: %+v", got)
	}
	if got := listedProviders(t, kim.window); len(got) != 0 {
		t.Fatalf("Kim sees %+v", got)
	}
	// The admin still sees it, to give it to another group, but is not in Platform.
	if got := listedProviders(t, owner); len(got) != 1 || *got[0].MayUse {
		t.Fatalf("owner: %+v", got)
	}
	create := wire.ProviderCreate{ID: "do-1", Name: "box-1"}
	if e := callError(t, kim.window, "", "providers/create", create); !strings.Contains(e, "no such provider") {
		t.Fatal(e)
	}
	if e := callError(t, owner, "", "providers/create", create); !strings.Contains(e, "Only the Platform group") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, "", "providers/remove", map[string]any{"id": "do-1"}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}

	var groups wire.GroupList
	json.Unmarshal(call(t, kim.window, "", "groups/list", nil), &groups)
	if len(groups.Groups) != 0 {
		t.Fatalf("Kim: %+v", groups)
	}
	json.Unmarshal(call(t, sam.window, "", "groups/list", nil), &groups)
	if len(groups.Groups) != 1 {
		t.Fatalf("Sam: %+v", groups)
	}

	// Everyone, then removed: a group a provider has is not removed.
	yes := true
	call(t, owner, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Everyone: &yes})
	if got := listedProviders(t, kim.window); len(got) != 1 {
		t.Fatalf("Kim, with everyone: %+v", got)
	}
	if e := callError(t, owner, "", "groups/remove", wire.GroupRequest{ID: platform.ID}); !strings.Contains(e, "DigitalOcean belongs") {
		t.Fatal(e)
	}
	call(t, owner, "", "providers/setGroup", wire.ProviderGroup{Provider: "do-1"})
	call(t, owner, "", "groups/remove", wire.GroupRequest{ID: platform.ID})
	json.Unmarshal(call(t, owner, "", "groups/list", nil), &groups)
	if len(groups.Groups) != 0 {
		t.Fatalf("after remove: %+v", groups)
	}
	if got := listedProviders(t, sam.window); len(got) != 0 {
		t.Fatalf("Sam, after: %+v", got)
	}
}
