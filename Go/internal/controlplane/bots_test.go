package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// botMachine enrols a machine for a bot, with a code an admin's window made for it.
func (p *plane) botMachine(admin *controllink.Session, bot, name string) *fakeHost {
	p.t.Helper()
	var shown wire.ControlCodeShown
	json.Unmarshal(call(p.t, admin, "", "hosts/startEnroll", wire.MachineEnroll{As: &bot}), &shown)
	code, err := controllink.ParseCode(shown.Text)
	if err != nil {
		p.t.Fatal(err)
	}
	root, private, hello := p.t.TempDir(), controllink.NewPrivateKey(), fakeHello(name)
	member, err := controllink.Enroll(context.Background(), root, code, private, hello)
	if err != nil {
		p.t.Fatal(err)
	}
	return p.serveHost(root, member, private, hello, nil)
}

// hostUsers keeps the last host/user each machine was told.
type hostUsers struct {
	mu   sync.Mutex
	last map[string]wire.MachineUser
}

func (h *hostUsers) heard(host, method string, params json.RawMessage) {
	if method != wire.NotifyHostUser.Name {
		return
	}
	var u wire.MachineUser
	json.Unmarshal(params, &u)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.last == nil {
		h.last = map[string]wire.MachineUser{}
	}
	h.last[host] = u
}

func (h *hostUsers) of(host string) (wire.MachineUser, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	u, ok := h.last[host]
	return u, ok
}

// T039 (#1761, US6, FR-030, FR-031, FR-033, FR-034): a bot is made by an admin, its
// machines are enrolled for it and told they are a bot's; a client cannot act on them,
// an admin is told it is a bot's; one trigger claimed by three machines runs once in 100
// tries; and its cap stops it, with a notice to the admins.
func TestABotRunsOncePerTriggerAndStopsAtItsCap(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	users := &hostUsers{}
	p.told = users.heard
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)

	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	if e := callError(t, sam.window, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	if e := callError(t, admin, "", "bots/make", wire.BotMake{Name: "review bot", Group: platform.ID}); !strings.Contains(e, "no spaces") {
		t.Fatal(e)
	}
	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	bot := made.User
	if e := callError(t, sam.window, "", "hosts/startEnroll", wire.MachineEnroll{As: &bot}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	if e := callError(t, admin, "", "groups/remove", wire.GroupRequest{ID: platform.ID}); !strings.Contains(e, "review-bot") {
		t.Fatal(e)
	}

	machines := []*fakeHost{p.botMachine(admin, bot, "MACHINE-B1"), p.botMachine(admin, bot, "MACHINE-B2"), p.botMachine(admin, bot, "MACHINE-B3")}
	for _, m := range machines {
		host := m.member.Host
		if p.s.OwnerOf(host) != bot {
			t.Fatalf("%s is %s's", host, p.s.OwnerOf(host))
		}
		p.waitFor(func() bool { u, ok := users.of(host); return ok && u.Kind == "bot" && u.Name == "review-bot" }, "told it is the bot's")
	}

	var list wire.PeopleList
	json.Unmarshal(call(t, admin, "", "people/list", nil), &list)
	found := false
	for _, row := range list.People {
		if row.ID == bot {
			found = row.Kind == "bot" && row.Role == wire.UserRoleMember && deref(row.Group) == platform.ID && len(row.Machines) == 3
		}
	}
	if !found {
		t.Fatalf("%+v", list.People)
	}

	// No client acts on a bot's machine: an admin is told it is a bot's, a member that
	// there is no such machine. bots/stopRun reaches it.
	host := machines[0].member.Host
	if e := callError(t, admin, host, "daemon/ping", nil); !strings.Contains(e, "-32073") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, host, "daemon/ping", nil); !strings.Contains(e, "-32091") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, "", "bots/stopRun", wire.BotStopRun{Host: wire.MachineRef(host), Agent: "A"}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	// The fake machine does not know agents/stop: its refusal is what came back.
	if e := callError(t, admin, "", "bots/stopRun", wire.BotStopRun{Host: wire.MachineRef(host), Agent: "A"}); !strings.Contains(e, "agents/stop") {
		t.Fatal(e)
	}

	// SC-008: one trigger, three machines, one run, 100 times.
	for i := range 100 {
		claim, _ := json.Marshal(wire.WorkflowClaim{Workflow: "app/review", Trigger: "event:pr.opened:" + itoa(i)})
		won := make(chan bool, len(machines))
		var wg sync.WaitGroup
		for _, m := range machines {
			wg.Add(1)
			go func() {
				defer wg.Done()
				out, err := p.s.methods.HostSaid(m.member.Host, "workflows/claimRun", claim)
				if err != nil {
					t.Error(err)
					return
				}
				won <- out.(wire.WorkflowClaimed).Won
			}()
		}
		wg.Wait()
		close(won)
		n := 0
		for w := range won {
			if w {
				n++
			}
		}
		if n != 1 {
			t.Fatalf("trigger %d ran %d times", i, n)
		}
	}

	// $3 spent of a $2 cap: the bot's machines start no work until the end of the day, and
	// the admin is told.
	cap := 2.0
	call(t, admin, "", "bots/setCaps", wire.BotCaps{User: bot, Caps: wire.SpendCaps{DailyUSD: &cap}})
	today := time.Now().UTC().Format(usageDayLayout)
	rollup, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{},
		Days: []wire.UsageRollupPeriod{{At: today, Rows: []wire.UsageRollupRow{{Folder: "app", Runtime: "claude", Cost: map[string]float64{"USD": 3}}}}}})
	if _, err := p.s.methods.HostSaid(host, "usage/rollup", rollup); err != nil {
		t.Fatal(err)
	}
	note := waitNote(t, admin, "control/capReached")
	var reached wire.CapReached
	json.Unmarshal(note.Params, &reached)
	if reached.User != bot || reached.SpentUSD != 3 || reached.CapUSD != 2 {
		t.Fatalf("%s", note.Params)
	}
	for _, m := range machines {
		host := m.member.Host
		p.waitFor(func() bool {
			u, _ := users.of(host)
			return u.CapReachedUntil != nil && u.CapReachedUntil.Time().After(time.Now())
		},
			"told it is at its cap")
	}
	// A higher cap lets it start again.
	cap = 10
	call(t, admin, "", "bots/setCaps", wire.BotCaps{User: bot, Caps: wire.SpendCaps{DailyUSD: &cap}})
	p.waitFor(func() bool { u, _ := users.of(host); return u.CapReachedUntil == nil }, "told its cap is lifted")
	// A cap of $0 or less is refused, not kept as no cap (#2066).
	zero := 0.0
	if e := callError(t, admin, "", "bots/setCaps", wire.BotCaps{User: bot, Caps: wire.SpendCaps{DailyUSD: &zero}}); !strings.Contains(e, "more than $0") {
		t.Fatalf("a $0 cap: %q", e)
	}
}
