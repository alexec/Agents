package controlplane

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// fires counts the workflows/fire each fake machine was asked, and answers as told.
type fires struct {
	mu    sync.Mutex
	asked map[string]int
	ran   map[string]int
	takes func(host string) bool
}

func (f *fires) answer(host, method string, params json.RawMessage) (any, bool) {
	if method != wire.CallWorkflowsFire.Name {
		return nil, false
	}
	took := f.takes(host)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked[host]++
	if took {
		f.ran[host]++
	}
	return wire.TeamTriggerFired{Ran: took}, true
}

func (f *fires) total() (asked, ran int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, n := range f.asked {
		asked += n
	}
	for _, n := range f.ran {
		ran += n
	}
	return asked, ran
}

// T043 (#2011, FR-035): a server's event or a schedule that a bot's runs-on: workflow
// matches is sent once by the control plane. Each machine that heard it sends it; the
// control plane takes the first and asks the bot's machines in turn until one runs it. A
// machine that cannot run it is passed over; runs-on: with no bot is left to the machine;
// someone outside the bot's group cannot send it a trigger.
func TestATeamTriggerHeardByEveryMachineRunsOnce(t *testing.T) {
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), nil)
	f := &fires{asked: map[string]int{}, ran: map[string]int{}}
	p.asked = f.answer
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	lee := p.invite(admin, "Lee", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)

	machines := []*fakeHost{p.botMachine(admin, made.User, "MACHINE-B1"), p.botMachine(admin, made.User, "MACHINE-B2"),
		p.botMachine(admin, made.User, "MACHINE-B3")}
	// The first in order has no copy of the workflow: it is passed over.
	first := machines[0].member.Host
	for _, m := range machines[1:] {
		if m.member.Host < first {
			first = m.member.Host
		}
	}
	f.takes = func(host string) bool { return host != first }
	samsMac, leesMac := p.machine(sam, "MACHINE-S"), p.machine(lee, "MACHINE-L")
	senders := []string{samsMac.member.Host}
	for _, m := range machines {
		senders = append(senders, m.member.Host)
	}

	const triggers = 50
	for i := range triggers {
		trigger, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/review", Trigger: "event:pr.opened:" + itoa(i),
			RunsOn: []string{"Review-Bot", "linux"}, Event: &wire.Event{Name: "pr.opened", Details: map[string]string{"server": "github"}}})
		var wg sync.WaitGroup
		for _, host := range senders {
			wg.Add(1)
			go func() {
				defer wg.Done()
				out, err := p.s.methods.HostSaid(host, "workflows/trigger", trigger)
				if err != nil {
					t.Error(err)
					return
				}
				if !out.(wire.TeamTriggerSent).Taken {
					t.Errorf("%s: not taken", host)
				}
			}()
		}
		wg.Wait()
	}
	p.waitFor(func() bool { _, ran := f.total(); return ran == triggers }, "every trigger run")
	asked, ran := f.total()
	if ran != triggers || asked != 2*triggers {
		t.Fatalf("%d triggers: asked %d, ran %d", triggers, asked, ran)
	}
	if f.ran[first] != 0 {
		t.Fatalf("%s ran %d", first, f.ran[first])
	}

	// runs-on: with no bot's name is the machine's own.
	plain, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/lint", Trigger: "schedule:x", RunsOn: []string{"linux"}})
	out, err := p.s.methods.HostSaid(samsMac.member.Host, "workflows/trigger", plain)
	if err != nil || out.(wire.TeamTriggerSent).Taken {
		t.Fatalf("%v %v", out, err)
	}
	// Lee is not in the bot's group.
	bots, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/review", Trigger: "schedule:y", RunsOn: []string{"review-bot"}})
	if _, err := p.s.methods.HostSaid(leesMac.member.Host, "workflows/trigger", bots); err == nil || !strings.Contains(err.Error(), "group") {
		t.Fatal(err)
	}
	if asked2, _ := f.total(); asked2 != asked {
		t.Fatalf("asked %d after, %d before", asked2, asked)
	}
}
