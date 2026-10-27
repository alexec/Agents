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
		trigger, _ := json.Marshal(serverTrigger("app/review", []string{"Review-Bot", "linux"}, itoa(i), nil))
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
		due := wire.DateOf(time.Now().Truncate(time.Minute).Add(-time.Duration(i) * time.Minute))
		trigger, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/nightly", Trigger: wire.ScheduleTriggerID(due.Time()), RunsOn: []string{"review-bot"}, DueAt: &due})
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

// serverTrigger is a server's event as a machine sends it: its details as raiseMCPEvent
// makes them, and more, and the trigger id they name.
func serverTrigger(workflow string, runsOn []string, id string, more map[string]string) wire.TeamTrigger {
	details := map[string]string{"server": "github", "event": "pr.opened", "subscription": "s1", "mcp_event_id": id,
		"time": "2026-10-21T09:00:00Z", "payload": `{"n":1}`}
	for k, v := range more {
		details[k] = v
	}
	e := wire.Event{Name: "pr.opened", Details: details}
	return wire.TeamTrigger{Workflow: workflow, Trigger: wire.EventTriggerID(e.Name, e.Details), RunsOn: runsOn, Event: &e}
}

// A trigger sent for a bot carries only what a machine hears: a server's event, cut to its
// details, with the sender the control plane's own links name, or a schedule due about now,
// and the trigger id they name. Anything else is refused, and a trigger no machine took is
// unclaimed, so it may be sent again.
func TestATeamTriggerCarriesOnlyAServerEventOrASchedule(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), nil)
	var mu sync.Mutex
	var got []wire.TeamTrigger
	takes := true
	p.asked = func(host, method string, params json.RawMessage) (any, bool) {
		if method != wire.CallWorkflowsFire.Name {
			return nil, false
		}
		var tr wire.TeamTrigger
		json.Unmarshal(params, &tr)
		mu.Lock()
		defer mu.Unlock()
		got = append(got, tr)
		return wire.TeamTriggerFired{Ran: takes}, true
	}
	sent := func() []wire.TeamTrigger {
		mu.Lock()
		defer mu.Unlock()
		return append([]wire.TeamTrigger(nil), got...)
	}
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)
	var made wire.BotMade
	json.Unmarshal(call(t, admin, "", "bots/make", wire.BotMake{Name: "review-bot", Group: platform.ID}), &made)
	p.botMachine(admin, made.User, "MACHINE-B1")
	samsMac := p.machine(sam, "MACHINE-S")
	runsOn := []string{"review-bot"}
	send := func(tr wire.TeamTrigger) error {
		params, _ := json.Marshal(tr)
		_, err := p.s.methods.HostSaid(samsMac.member.Host, "workflows/trigger", params)
		return err
	}

	appEvent := wire.Event{Name: "lease.granted", Details: map[string]string{"resource": "build"}}
	wrongID := serverTrigger("app/review", runsOn, "e0", nil)
	wrongID.Trigger = "schedule:2026-10-21T09:00:00Z"
	old := wire.DateOf(time.Now().Add(-48 * time.Hour).Truncate(time.Minute))
	both := serverTrigger("app/review", runsOn, "e0", nil)
	both.DueAt = &old
	unlinked := serverTrigger("app/review", runsOn, "e9", map[string]string{"sender_channel": "slack", "sender_identity": "T1/U9"})
	for name, tr := range map[string]wire.TeamTrigger{
		"an app event":       {Workflow: "app/review", Trigger: wire.EventTriggerID(appEvent.Name, appEvent.Details), RunsOn: runsOn, Event: &appEvent},
		"a wrong id":         wrongID,
		"an old schedule":    {Workflow: "app/nightly", Trigger: wire.ScheduleTriggerID(old.Time()), RunsOn: runsOn, DueAt: &old},
		"event + schedule":   both,
		"nothing":            {Workflow: "app/review", Trigger: "event:x", RunsOn: runsOn},
		"an unlinked sender": unlinked,
	} {
		if err := send(tr); err == nil {
			t.Errorf("%s: taken", name)
		}
	}
	time.Sleep(100 * time.Millisecond)
	if n := len(sent()); n != 0 {
		t.Fatalf("sent on %d refused triggers", n)
	}

	// Details a server's event has not, and a sender named with no channel identity, are cut.
	if err := send(serverTrigger("app/review", runsOn, "e1", map[string]string{"resource": "build", "sender_user": "someone-else"})); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(sent()) == 1 }, "the event sent")
	if d := sent()[0].Event.Details; d["resource"] != "" || d["sender_user"] != "" || d["payload"] != `{"n":1}` || d["mcp_event_id"] != "e1" {
		t.Fatalf("%v", d)
	}

	// A linked sender is the person its link names, whoever the machine said.
	giveEmail(t, p, sam.id, "sam@example.com")
	slack := wire.ChannelSender{Channel: "slack", Identity: "T1/U42", Email: new("sam@example.com")}
	checkLink(t, p, samsMac.member.Host, slack)
	note := waitNote(t, sam.window, "control/linkRequested")
	var asked wire.ChannelLinkRequest
	json.Unmarshal(note.Params, &asked)
	call(t, sam.window, "", "links/approve", wire.ChannelLinkDecide{Request: asked.Request})
	if err := send(serverTrigger("app/review", runsOn, "e2", map[string]string{"sender_channel": "slack", "sender_identity": "T1/U42",
		"sender_user": "someone-else", "sender_name": "Alex"})); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(sent()) == 2 }, "the event sent")
	if d := sent()[1].Event.Details; d["sender_user"] != sam.id || d["sender_name"] != "Sam" {
		t.Fatalf("%v", d)
	}

	// A schedule due now is sent.
	due := wire.DateOf(time.Now().Truncate(time.Minute))
	if err := send(wire.TeamTrigger{Workflow: "app/nightly", Trigger: wire.ScheduleTriggerID(due.Time()), RunsOn: runsOn, DueAt: &due}); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(sent()) == 3 }, "the schedule sent")

	// Not taken, and none can be started: unclaimed, so the same trigger is sent again.
	mu.Lock()
	takes = false
	mu.Unlock()
	again := serverTrigger("app/review", runsOn, "e3", nil)
	if err := send(again); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(sent()) == 4 }, "asked once")
	time.Sleep(100 * time.Millisecond)
	if err := send(again); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { return len(sent()) == 5 }, "asked again")
}
