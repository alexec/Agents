package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// FR-029 (T036): a removal made at one copy is in force at every copy within 5 s. The
// person's window and machine are both at the other copy: the window is cut off, the
// machine is gone, a code they made pairs nothing, and People no longer lists them.
func TestARemovalIsInForceOnEveryCopyWithinFiveSeconds(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	a, b := twoCopies(t)
	_, ownerAtB := b.client("Owner's Mac at B")
	sam := b.invite(ownerAtB, "Sam", wire.UserRoleMember)
	samMachine := b.machine(sam, "SAM-BOX").member.Host
	var shown wire.ControlCodeShown
	json.Unmarshal(call(t, sam.window, "", "clients/startPairing", nil), &shown)
	call(t, sam.window, samMachine, "daemon/ping", nil)
	_, ownerAtA := a.client("Owner's Mac at A")
	a.waitFor(func() bool { return a.s.records.Person(sam.id) != nil }, "A knowing Sam")

	began := time.Now()
	call(t, ownerAtA, "", "people/remove", wire.PersonRequest{User: sam.id})
	deadline := began.Add(5 * time.Second)
	for {
		_, err := sam.window.Call(context.Background(), samMachine, "daemon/ping", nil)
		person := b.s.records.Person(sam.id)
		if err != nil && b.s.records.Host(samMachine) == nil && !b.s.router.Reaches(samMachine) &&
			person != nil && person.IsRemoved() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("not in force at B after 5 s: call %v, host %v, person %+v", err, b.s.records.Host(samMachine), person)
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("in force at B after %v", time.Since(began).Round(time.Millisecond))
	code, _ := controllink.ParseCode(shown.Text)
	if _, err := controllink.PairClient(context.Background(), code, "Sam's phone"); err == nil {
		t.Fatal("a removed person's code paired")
	}
	var list wire.PeopleList
	json.Unmarshal(call(t, ownerAtB, "", "people/list", nil), &list)
	for _, p := range list.People {
		if p.ID == sam.id {
			t.Fatalf("B still lists Sam: %+v", list.People)
		}
	}
}

// SC-003 (T010) at the spec's scale: 10 users with 3 machines each. Each user lists only
// their own machines; every call passed to a machine, and every control-plane method that
// names one, reaches only the caller's own: another's is not found (FR-018).
func TestNoRequestReachesAnotherUsersMachineAtSpecScale(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("30 machines")
	}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	_, ownerWindow := p.client("Owner's Mac")
	everyone := []*person{{id: p.s.localOwner(), window: ownerWindow}}
	for i := 1; i < 10; i++ {
		everyone = append(everyone, p.invite(ownerWindow, "Person "+itoa(i), wire.UserRoleMember))
	}
	for i, who := range everyone {
		for j := range 3 {
			p.machine(who, "MACHINE-"+itoa(100+3*i+j))
		}
	}
	for _, who := range everyone {
		if got, want := listedHosts(t, who.window), idsOf(who.machines); strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("%s lists %v, owns %v", who.id, got, want)
		}
	}
	// Every method at every machine, as fast as it goes: far past a client's rate (#2150), so
	// each line comes a second after the last, as far as the rates can tell.
	clock := time.Now()
	p.s.router.rates.now = func() time.Time {
		clock = clock.Add(time.Second)
		return clock
	}
	for _, who := range everyone {
		for _, other := range everyone {
			for _, h := range other.machines {
				host := h.member.Host
				if other == who {
					call(t, who.window, host, "daemon/ping", nil)
					continue
				}
				for _, method := range []string{"daemon/ping", "agents/list", "worktrees/all"} {
					if e := callError(t, who.window, host, method, nil); !strings.Contains(e, "-32091") {
						t.Fatalf("%s reached %s's machine with %s: %s", who.id, other.id, method, e)
					}
				}
				for method := range hostNamingMethods {
					for _, field := range []string{"host", "from"} {
						params := hostNamingParams(who.machines[0].member.Host)
						params[field] = host
						if e := callError(t, who.window, "", method, params); !strings.Contains(e, "-32091") {
							t.Fatalf("%s: %s with %s's machine as %s: %s", who.id, method, other.id, field, e)
						}
					}
				}
			}
		}
	}
	// Each machine opened channels for its own user's clients only.
	for _, who := range everyone[1:] {
		who.mu.Lock()
		for _, user := range who.actors {
			if user != who.id {
				t.Fatalf("%s's machine opened a channel for %s", who.id, user)
			}
		}
		who.mu.Unlock()
	}
	for _, who := range everyone {
		if len(who.machines) != 3 || p.s.Records().Host(who.machines[0].member.Host) == nil {
			t.Fatalf("a machine of %s's went", who.id)
		}
	}
}
