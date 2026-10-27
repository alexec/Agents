package controlplane

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

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
	t.Parallel()
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

// starter is a fake of the machine providers: which machines may be started, and the
// starts asked for.
type starter struct {
	mu      sync.Mutex
	may     map[string]bool
	started []string
}

func (s *starter) MayStartFor(_, host string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.may[host]
}
func (s *starter) Workspace(string) *wire.MachineWorkspace { return nil }
func (s *starter) StartForUse(host, _ string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.started = append(s.started, host)
}
func (s *starter) starts() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.started...)
}

// T042 (#2011, FR-034): with none of a bot's machines online, a trigger starts one of its
// stopped workspaces and waits for it; many triggers start it once, at most 20 wait, and
// what waited runs when it joins. A machine that joins and does not take a trigger, or a
// start that never joins, starts nothing more for 15 minutes; with no machine that may be
// started, nothing is.
func TestABotsMachineIsStartedOnceForItsTriggers(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), nil)
	f := &fires{asked: map[string]int{}, ran: map[string]int{}, takes: func(string) bool { return true }}
	p.asked = f.answer
	clock := time.Now()
	var clockMu sync.Mutex
	at := func() time.Time { clockMu.Lock(); defer clockMu.Unlock(); return clock }
	later := func(d time.Duration) { clockMu.Lock(); clock = clock.Add(d); clockMu.Unlock() }
	fake := &starter{may: map[string]bool{}}
	p.s.starts.starter, p.s.starts.now = fake, at

	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	b1, b2 := p.botMachine(admin, made.User, "MACHINE-B1"), p.botMachine(admin, made.User, "MACHINE-B2")
	for _, m := range []*fakeHost{b1, b2} {
		fake.may[m.member.Host] = true
		m.stop()
		host := m.member.Host
		p.waitFor(func() bool { s, _ := p.s.Router().State(host); return !s.online() }, "the bot's machine offline")
	}
	first := min(b1.member.Host, b2.member.Host)
	samsMac := p.machine(sam, "MACHINE-S")
	send := func(i int) {
		t.Helper()
		trigger, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/nightly", Trigger: "schedule:" + itoa(i), RunsOn: []string{"review-bot"}})
		out, err := p.s.methods.HostSaid(samsMac.member.Host, "workflows/trigger", trigger)
		if err != nil || !out.(wire.TeamTriggerSent).Taken {
			t.Fatalf("%v %v", out, err)
		}
	}
	waitStarts := func(n int) {
		t.Helper()
		p.waitFor(func() bool { return len(fake.starts()) >= n }, "a start")
		time.Sleep(100 * time.Millisecond)
		if got := fake.starts(); len(got) != n {
			t.Fatalf("started %v, want %d starts", got, n)
		}
	}
	waiting := func() int {
		p.s.starts.mu.Lock()
		defer p.s.starts.mu.Unlock()
		if b := p.s.starts.byBot[made.User]; b != nil {
			return len(b.waiting)
		}
		return 0
	}

	// 30 triggers: one start, of the first machine; 20 wait, the rest are dropped.
	for i := range 30 {
		send(i)
	}
	p.waitFor(func() bool { return waiting() == waitingMost }, "20 waiting")
	waitStarts(1)
	if fake.starts()[0] != first {
		t.Fatalf("started %v", fake.starts())
	}

	// It joins (a machine of the bot's comes online): the 20 run there, once each.
	joined := p.botMachine(admin, made.User, "MACHINE-B3")
	p.waitFor(func() bool { _, ran := f.total(); return ran == waitingMost }, "what waited run")
	if waiting() != 0 || f.ran[joined.member.Host] != waitingMost {
		t.Fatalf("waiting %d, ran %v", waiting(), f.ran)
	}

	// Online and taking: no start.
	send(100)
	p.waitFor(func() bool { _, ran := f.total(); return ran == waitingMost+1 }, "run on the machine online")
	waitStarts(1)

	// Gone again, and within 15 minutes of the start: no second start, nothing kept.
	joined.stop()
	p.waitFor(func() bool { s, _ := p.s.Router().State(joined.member.Host); return !s.online() }, "offline")
	send(101)
	waitStarts(1)

	// Past it: one start again; a start that never joins is not tried again within 15 minutes.
	later(startPatience + time.Minute)
	send(102)
	waitStarts(2)
	later(5 * time.Minute)
	send(103)
	waitStarts(2)
	later(startPatience)
	send(104)
	waitStarts(3)

	// No machine that may be started: nothing is.
	fake.mu.Lock()
	fake.may = map[string]bool{}
	fake.mu.Unlock()
	later(startPatience + time.Minute)
	send(105)
	waitStarts(3)
	if _, ran := f.total(); ran != waitingMost+1 {
		t.Fatalf("ran %d", ran)
	}
}

// #2027: host/user tells a person's machine the bots of their groups, so it hears a bot's
// workflow's server triggers for it, and again when a bot or a group changes; a bot's
// machine and someone outside the group are told none.
func TestAPersonsMachineIsToldTheBotsOfItsGroups(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), nil)
	users := &hostUsers{}
	p.told = users.heard
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	lee := p.invite(admin, "Lee", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	samsMac, leesMac := p.machine(sam, "MACHINE-S"), p.machine(lee, "MACHINE-L")
	botsOf := func(host string) string {
		u, _ := users.of(host)
		return strings.Join(u.Bots, ",")
	}

	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	p.waitFor(func() bool { return botsOf(samsMac.member.Host) == "review-bot" }, "Sam's machine told the bot")
	bot := p.botMachine(admin, made.User, "MACHINE-B1")
	p.waitFor(func() bool { u, ok := users.of(bot.member.Host); return ok && u.Kind == "bot" }, "the bot's machine told")
	if got := botsOf(bot.member.Host); got != "" {
		t.Fatalf("a bot's machine told bots %q", got)
	}
	if got := botsOf(leesMac.member.Host); got != "" {
		t.Fatalf("Lee, outside the group, told %q", got)
	}

	// Lee joins the group, Sam leaves it.
	call(t, admin, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Members: []string{lee.id}})
	p.waitFor(func() bool {
		return botsOf(leesMac.member.Host) == "review-bot" && botsOf(samsMac.member.Host) == ""
	}, "the group's change told")
}
