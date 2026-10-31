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

// Console ▸ Machines (#1804, M1): an admin sees every machine with its owner; a member is
// refused the Console.
func TestConsoleFleetIsEveryMachineForAnAdmin(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	var board wire.FleetBoard
	json.Unmarshal(call(t, admin, "", "console/fleet", map[string]any{}), &board)
	if len(board.Machines) != 2 {
		t.Fatalf("%+v", board)
	}
	owners := map[wire.MachineRef]string{}
	for _, m := range board.Machines {
		owners[m.Host.ID] = m.OwnerName
		if m.Bot || m.Host.State == "" {
			t.Fatalf("%+v", m)
		}
	}
	if owners[wire.MachineRef(owner.member.Host)] != "Local owner" || owners[wire.MachineRef(beas.member.Host)] != "Bea" {
		t.Fatalf("%v", owners)
	}

	if e := callError(t, bea.window, "", "console/fleet", map[string]any{}); !strings.Contains(e, "admin") {
		t.Fatal(e)
	}
}

// Every Console method is an admin's and names no machine (as TestEveryClientMethodChecksTheOwner
// has it for the others), and none is in the other lists.
func TestConsoleMethodsAreAdminsOnly(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	for method := range consoleMethods {
		if own[method] || workspaceMethods[method] || hostNamingMethods[method] || !p.s.methods.Handles(method) {
			t.Errorf("%s: a Console method is the Console's alone", method)
		}
		if e := callError(t, bea.window, "", method, map[string]any{}); !strings.Contains(e, "Only an admin") {
			t.Errorf("%s: %s", method, e)
		}
	}
}

// Console ▸ Team Workflows (#1804, M6): each bot with its group, its machines, the
// workflows it ran this week and the agents running on its machines, by id only.
func TestConsoleTeamWorkflowsIsEachBotsRuns(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	box := p.botMachine(admin, made.User, "MACHINE-B1")
	host := box.member.Host

	now := time.Now()
	for _, trigger := range []string{"pr.opened 1", "pr.opened 2"} {
		if _, err := p.s.claimRun(context.Background(), host, wire.WorkflowClaim{Workflow: "review", Trigger: trigger}, now); err != nil {
			t.Fatal(err)
		}
	}
	p.s.claimRun(context.Background(), host, wire.WorkflowClaim{Workflow: "deps", Trigger: "schedule"}, now)
	p.s.copies.take(host, "agents/list", `{"result":[{"id":"A1","state":"running","title":"secret words","startedByWorkflow":"review","createdAt":800000000},{"id":"A2","state":"finished"}]}`)

	var board wire.TeamWorkflows
	raw := call(t, admin, "", "console/teamWorkflows", map[string]any{})
	json.Unmarshal(raw, &board)
	if len(board.Bots) != 1 {
		t.Fatalf("%s", raw)
	}
	bot := board.Bots[0]
	if bot.Name != "review-bot" || deref(bot.GroupName) != "Platform" || bot.Machines != 1 || bot.Capped {
		t.Fatalf("%+v", bot)
	}
	if len(bot.Workflows) != 2 || bot.Workflows[0].Workflow != "review" || bot.Workflows[0].Runs != 2 || bot.Workflows[1].Runs != 1 {
		t.Fatalf("%+v", bot.Workflows)
	}
	if len(bot.Live) != 1 || bot.Live[0].Agent != "A1" || deref(bot.Live[0].Workflow) != "review" || !strings.HasSuffix(bot.Live[0].HostName, "MACHINE-B1") {
		t.Fatalf("%+v", bot.Live)
	}
	if strings.Contains(string(raw), "secret words") {
		t.Fatal("a title left the machine's list")
	}
}

// Console ▸ Live Now (#2019, M9): every agent running now on every machine, a person's and a
// bot's, with its owner, runtime, state and cost so far, the most costly first; no title.
// console/stopAgent reaches any machine for an admin, and no member.
func TestConsoleLiveIsEveryRunningAgent(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")
	p.s.copies.take(owner.member.Host, "agents/list", `{"result":[{"id":"A1","runtimeID":"claude","state":"running","title":"secret words","costToDate":{"USD":0.5},"createdAt":800000000},{"id":"A2","state":"finished","costToDate":{"USD":99}}]}`)
	p.s.copies.take(beas.member.Host, "agents/list", `{"result":[{"id":"B1","runtimeID":"codex","state":"waitingOnUser","costToDate":{"USD":7}},{"id":"B2","runtimeID":"codex","state":"running","eventWait":{"events":["pr.merged"]},"startedByWorkflow":"review"}]}`)

	var board wire.LiveBoard
	raw := call(t, admin, "", "console/live", map[string]any{})
	json.Unmarshal(raw, &board)
	ids := []string{}
	for _, a := range board.Agents {
		ids = append(ids, string(a.Agent))
	}
	if strings.Join(ids, " ") != "B1 A1 B2" {
		t.Fatalf("%s", raw)
	}
	b1, a1, b2 := board.Agents[0], board.Agents[1], board.Agents[2]
	if b1.OwnerName != "Bea" || b1.State != "waitingOnUser" || b1.Runtime != "codex" || b1.HeardAt == nil || b1.Bot {
		t.Fatalf("%+v", b1)
	}
	if a1.OwnerName != "Local owner" || a1.CostToDate["USD"] != 0.5 || a1.Since == nil {
		t.Fatalf("%+v", a1)
	}
	if !deref(b2.WaitsOnOthers) || deref(b2.Workflow) != "review" || deref(a1.WaitsOnOthers) {
		t.Fatalf("%+v %+v", b2, a1)
	}
	if strings.Contains(string(raw), "secret words") {
		t.Fatal("a title left the machine's list")
	}

	stop := wire.ConsoleStopAgent{Host: wire.MachineRef(beas.member.Host), Agent: "B1"}
	if e := callError(t, bea.window, "", "console/stopAgent", stop); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	// The fake machine does not know agents/stop: its refusal is what came back, so it got there.
	if e := callError(t, admin, "", "console/stopAgent", stop); !strings.Contains(e, "agents/stop") {
		t.Fatal(e)
	}
	if e := callError(t, admin, "", "console/stopAgent", wire.ConsoleStopAgent{Host: "NOWHERE", Agent: "B1"}); !strings.Contains(e, "No machine") {
		t.Fatal(e)
	}
}
