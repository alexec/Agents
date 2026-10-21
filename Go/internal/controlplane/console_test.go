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
	owners := map[wire.HostID]string{}
	for _, m := range board.Machines {
		owners[m.Host.ID] = m.OwnerName
		if m.Bot || m.Host.State == "" {
			t.Fatalf("%+v", m)
		}
	}
	if owners[wire.HostID(owner.member.Host)] != "Local owner" || owners[wire.HostID(beas.member.Host)] != "Bea" {
		t.Fatalf("%v", owners)
	}

	if e := callError(t, bea.window, "", "console/fleet", map[string]any{}); !strings.Contains(e, "admin") {
		t.Fatal(e)
	}
}

// Every Console method is an admin's and names no machine (as TestEveryClientMethodChecksTheOwner
// has it for the others), and none is in the other lists.
func TestConsoleMethodsAreAdminsOnly(t *testing.T) {
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
