package providers

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Write It for Me (#858): a draft of a tool map or commands, written by an agent on the
// control plane's own host. The agent is a stand-in: the test calls its tools as the daemon
// would relay them, and sees what the sheet is told. Ports ProviderDraftsTests.swift.

// world is DraftWorld: what the stand-in server and CLI did, and what the sheet was told.
type world struct {
	mu           sync.Mutex
	tools        []any
	workspaces   []MachineInfo
	checkFails   string
	helps        map[string]string
	notInstalled bool
	unread       []any
	firstItem    any
	sshConfig    *string
	sshAsked     []string
	checks       int
	starts       int
	stops        int
	helpRuns     [][]string
	updates      []DraftUpdate
	started      []StartRequest
	stopped      []string
	logs         []string
	ownerHere    bool
	ownerAsked   int
	agent        string
}

func newWorld(tools []string, descriptions map[string]string) *world {
	config := "hostname cws.devstack-1\nuser coder\nport 22\nproxycommand ssh -W %h:%p bastion.cws.example\nproxyjump none\n"
	w := &world{workspaces: []MachineInfo{{ID: "101", Name: "agents-devbox", State: "running", Cost: new("$0.03/hour")},
		{ID: "102", Name: "scratch-1", State: "stopped"}}, helps: map[string]string{}, sshConfig: &config, ownerHere: true,
		agent: records.NewUUID()}
	for _, name := range tools {
		description := "Does " + name + "."
		if d, ok := descriptions[name]; ok {
			description = d
		}
		w.tools = append(w.tools, map[string]any{"name": name, "description": description, "inputSchema": map[string]any{"type": "object"}})
	}
	return w
}

func (w *world) last() *DraftUpdate {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.updates) == 0 {
		return nil
	}
	u := w.updates[len(w.updates)-1]
	return &u
}

func (w *world) read(f func()) {
	w.mu.Lock()
	defer w.mu.Unlock()
	f()
}

// draftServer is DraftServer: one connection to the stand-in server, as a record says.
type draftServer struct {
	CannotMake
	w      *world
	record ProviderRecord
}

func (s draftServer) Tools() ([]any, error) { return s.w.tools, nil }

func (s draftServer) Check() (Checked, error) {
	s.w.mu.Lock()
	defer s.w.mu.Unlock()
	s.w.checks++
	if s.w.checkFails != "" {
		return Checked{}, &ProviderFailure{s.w.checkFails}
	}
	if s.record.Map != nil {
		m, err := MapFrom(s.record.Map)
		if err != nil {
			return Checked{}, err
		}
		var names []string
		for _, t := range s.w.tools {
			names = append(names, strOr(get(t, "name")))
		}
		if missing := m.Missing(names); missing != "" {
			return Checked{}, providerFailure("The tool map names %s, which the server doesn’t have.", missing)
		}
	}
	if s.w.unread != nil {
		return Checked{Workspaces: []MachineInfo{}, Items: len(s.w.unread), FirstItem: s.w.unread[0]}, nil
	}
	items := -1
	if s.w.firstItem != nil {
		items = len(s.w.workspaces)
	}
	return Checked{Workspaces: s.w.workspaces, Items: items, FirstItem: s.w.firstItem}, nil
}

func (s draftServer) List() ([]MachineInfo, error) { return s.w.workspaces, nil }

func (s draftServer) Start(id string) (*MachineInfo, error) {
	s.w.mu.Lock()
	defer s.w.mu.Unlock()
	s.w.starts++
	for _, w := range s.w.workspaces {
		if w.ID == id {
			w.State = "running"
			return &w, nil
		}
	}
	return nil, nil
}

func (s draftServer) Stop(string) (*MachineInfo, error) {
	s.w.mu.Lock()
	s.w.stops++
	s.w.mu.Unlock()
	return nil, nil
}

func (s draftServer) End() {}

// clock is DraftClock: the drafts' clock, which moves only when the test moves it (#891).
type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) read() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type draftHarness struct {
	w      *world
	drafts *Drafts
	host   string
	owner  Caller
}

func quickDraftTiming() DraftTiming {
	return DraftTiming{Total: 300 * time.Second, Answer: 120 * time.Second, LastWord: 60 * time.Second, OwnerGone: 30 * time.Second,
		KeptAfter: 600 * time.Second, Tick: 20 * time.Millisecond, Help: 25 * time.Second}
}

func newDraftHarness(w *world, timing DraftTiming, localHost bool, busy string, c *clock) *draftHarness {
	h := &draftHarness{w: w, host: "thismac1", owner: Caller{Session: records.NewUUID(), Client: records.NewUUID(), Kind: "mac"}}
	var now func() time.Time
	if c != nil {
		now = c.read
	}
	h.drafts = NewDrafts(timing, DraftHooks{
		Connect: func(record ProviderRecord, _ map[string]string) (Provider, error) {
			return draftServer{w: w, record: record}, nil
		},
		Help: func(_ string, words []string, _ map[string]string) Help {
			w.mu.Lock()
			defer w.mu.Unlock()
			w.helpRuns = append(w.helpRuns, words)
			if w.notInstalled {
				return Help{Status: 127, Text: "env: cws: No such file or directory"}
			}
			return Help{Text: w.helps[strings.Join(words, " ")]}
		},
		LocalHost: func() *LocalHost {
			if localHost {
				return &LocalHost{ID: h.host, Name: "This Mac"}
			}
			return nil
		},
		StartAgent: func(_ string, request StartRequest, _ Caller) (string, error) {
			w.mu.Lock()
			defer w.mu.Unlock()
			w.started = append(w.started, request)
			return w.agent, nil
		},
		StopAgent: func(_, agent string, _ Caller) {
			w.mu.Lock()
			w.stopped = append(w.stopped, agent)
			w.mu.Unlock()
		},
		Notify: func(_ Caller, update DraftUpdate) bool {
			w.mu.Lock()
			w.updates = append(w.updates, update)
			w.mu.Unlock()
			return true
		},
		OwnerHere: func(Caller) bool {
			w.mu.Lock()
			defer w.mu.Unlock()
			w.ownerAsked++
			return w.ownerHere
		},
		BusyHost: func(string, string) string { return busy },
		SSHConfig: func(destination string) *Help {
			w.mu.Lock()
			defer w.mu.Unlock()
			w.sshAsked = append(w.sshAsked, destination)
			if w.sshConfig == nil {
				return &Help{Status: 255, Text: "ssh: Could not resolve hostname"}
			}
			return &Help{Text: *w.sshConfig}
		},
	}, func(line string) {
		w.mu.Lock()
		w.logs = append(w.logs, line)
		w.mu.Unlock()
	}, now)
	return h
}

var mapForm = ProviderAdd{Name: "DigitalOcean", Kind: KindStdio, Command: ptr("npx"), Args: []string{"-y", "@digitalocean/mcp"}}

func ptr(s string) *string { return &s }

const secretValue = "dop_v1_supersecretvalue"

func (h *draftHarness) start(form ProviderAdd, secrets map[string]string, runtime string) (ProviderDraftStarted, error) {
	return h.drafts.Start(ProviderDraftStart{Form: form, Secrets: secrets, RuntimeID: runtime}, h.owner, nil)
}

func (h *draftHarness) startMap(t *testing.T) string {
	t.Helper()
	started, err := h.start(mapForm, map[string]string{"DIGITALOCEAN_API_TOKEN": secretValue}, "claude")
	if err != nil {
		t.Fatal(err)
	}
	return string(started.Draft)
}

func (h *draftHarness) tool(draft, name string, arguments any) (string, error) {
	out, err := h.drafts.Call(h.host, MachineProviderDraftCall{AgentID: wire.UUID(h.w.agent), Draft: wire.UUID(draft), Tool: name, Arguments: jsonValue(arguments)})
	if err != nil {
		return "", err
	}
	return strOr(out.(map[string]any)["note"]), nil
}

func (h *draftHarness) mustTool(t *testing.T, draft, name string, arguments any) string {
	t.Helper()
	note, err := h.tool(draft, name, arguments)
	if err != nil {
		t.Fatal(err)
	}
	return note
}

var goodMap = mustParse(`{"list": {"tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "status"},
	"start": {"tool": "droplet-power-on", "arguments": {"droplet_id": "{id}"}},
	"stop": {"tool": "droplet-power-off", "arguments": {"droplet_id": "{id}"}}}`)

func mapWithSSH(ssh string) any {
	m := toValue(goodMap).(map[string]any)
	m["list"].(map[string]any)["ssh"] = ssh
	return m
}

var dropletTools = []string{"droplet-list", "droplet-power-on", "droplet-power-off"}

func (w *world) question(t *testing.T) DraftQuestion {
	t.Helper()
	for range 300 {
		if u := w.last(); u != nil && u.Question != nil {
			return *u.Question
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("No question was asked.")
	return DraftQuestion{}
}

func TestAServerThatDoesNotFollowTheContractStartsAWriter(t *testing.T) {
	w := newWorld(dropletTools, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	started, err := h.start(mapForm, map[string]string{"DIGITALOCEAN_API_TOKEN": secretValue}, "claude")
	if err != nil || started.Answered != nil {
		t.Fatalf("%v %+v", err, started)
	}
	r := w.started[0]
	if PurposeDraft(r) != string(started.Draft) || r.RuntimeID != "claude" || r.Sandbox == nil || *r.Sandbox != "on" || !strings.Contains(r.Prompt, "droplet-power-on") ||
		!strings.Contains(r.Prompt, "DIGITALOCEAN_API_TOKEN") {
		t.Errorf("%+v", r)
	}
	if string(rawOf(r.Purpose)) != `{"providerDraft":{"id":"`+string(started.Draft)+`"}}` {
		t.Errorf("%s", rawOf(r.Purpose))
	}
	if u := w.last(); u.State != "writing" || u.Steps[0].Text != "read 3 tools" {
		t.Errorf("%+v", u)
	}
}

func TestAContractServerOrTheShippedMapNeedsNoAgent(t *testing.T) {
	contract := newWorld(RequiredTools, nil)
	answered, _ := newDraftHarness(contract, quickDraftTiming(), true, "", nil).start(mapForm, nil, "claude")
	if answered.Answered == nil || answered.Answered.Note != "It follows the contract: it needs no map." || len(contract.started) != 0 {
		t.Errorf("%+v", answered)
	}
	do := newWorld([]string{"droplet-list", "power-on-droplet", "power-off-droplet", "droplet-delete"}, nil)
	shipped, _ := newDraftHarness(do, quickDraftTiming(), true, "", nil).start(mapForm, nil, "claude")
	if shipped.Answered == nil || shipped.Answered.Note != "Agents ships this map." || !jsonEqual(shipped.Answered.Map, ShippedDigitalOceanMap) {
		t.Errorf("%+v", shipped)
	}
}

func TestNoHostOnThisMachineRefusesWithTheReason(t *testing.T) {
	w := newWorld([]string{"droplet-list"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), false, "", nil)
	if _, err := h.start(mapForm, nil, "claude"); failureOf(err) == nil {
		t.Error("started")
	}
	if r := h.drafts.Runtimes(); len(r.Runtimes) != 0 || deref(r.Why) != "No host runs where the control plane runs, so no agent can write here." {
		t.Errorf("%+v", r)
	}
}

func TestOnlyWriterRuntimesAreOffered(t *testing.T) {
	w := newWorld([]string{"droplet-list"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	r := h.drafts.Runtimes()
	if len(r.Runtimes) != 1 || r.Runtimes[0].ID != "claude" || !r.Runtimes[0].IsDefault || deref(r.Host) != "This Mac" {
		t.Errorf("%+v", r)
	}
	_, err := h.start(mapForm, nil, "copilot")
	if f := failureOf(err); f == nil || f.Message != "Copilot can’t write here: its own tools can’t be turned off for one session." || len(w.started) != 0 {
		t.Errorf("%v", err)
	}
}

func TestCheckAndSend(t *testing.T) {
	w := newWorld(dropletTools, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	wrong := mustParse(`{"list": {"tool": "list-droplets", "items": "", "id": "id", "name": "name", "state": "status"},
		"start": {"tool": "x"}, "stop": {"tool": "y"}}`)
	if note := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": wrong}); !strings.HasPrefix(note, "Failed: The tool map names list-droplets") {
		t.Errorf("%q", note)
	}
	passed := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	if !strings.HasPrefix(passed, "Passed: listed 2.") || !strings.Contains(passed, "agents-devbox (id 101): running") {
		t.Errorf("%q", passed)
	}
	if !w.last().Check.Passed || w.checks != 2 {
		t.Error("check")
	}
	if note := h.mustTool(t, id, ToolSendDraft, map[string]any{"draft": goodMap, "note": "I didn't try start."}); note != "Sent. End your turn now." {
		t.Errorf("%q", note)
	}
	u := w.last()
	if u.State != "done" || !jsonEqual(u.DraftJSON, goodMap) || deref(u.Note) != "I didn't try start." {
		t.Errorf("%+v", u)
	}
	if runtime, result, ok := h.drafts.Result(id); !ok || runtime != "claude" || !jsonEqual(result, goodMap) {
		t.Error("result")
	}
	if !eventually(t, func() bool { var n int; w.read(func() { n = len(w.stopped) }); return n == 1 }) {
		t.Error("agent not stopped")
	}
	if note := h.mustTool(t, id, ToolReadTools, nil); note != "This draft has ended." {
		t.Errorf("%q", note)
	}
}

func TestACheckThatReadsNoneOfTheItemsShowsTheFirstRedacted(t *testing.T) {
	w := newWorld(dropletTools, nil)
	w.unread = []any{map[string]any{"uid": "m-101", "label": "devbox", "token": secretValue}, map[string]any{"uid": "m-102", "label": "scratch-1"}}
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	answer := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	if !strings.HasPrefix(answer, "Passed: listed 0.") || !strings.Contains(answer, "2 of the 2 items at list.items have no id or name by this map. The first item:") ||
		!strings.Contains(answer, `"label":"devbox"`) || strings.Contains(answer, secretValue) || !strings.Contains(answer, "${DIGITALOCEAN_API_TOKEN}") {
		t.Errorf("%q", answer)
	}
}

func TestACheckOfAMapWithNoSSHSaysSo(t *testing.T) {
	w := newWorld(dropletTools, nil)
	w.firstItem = map[string]any{"name": "devstack-1", "tools": map[string]any{"IDEs": []any{map[string]any{"accessUrl": "vscode://vscode-remote/ssh-remote+coder@cws.devstack-1/home"}}}}
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	answer := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	if !strings.Contains(answer, "No workspace has an ssh destination, so none can be added as a host.") ||
		!strings.Contains(answer, "ssh-remote+") || !strings.Contains(answer, "coder@cws.devstack-1/home") {
		t.Errorf("%q", answer)
	}
	u := w.last()
	if u.Check.NoSSH == nil || !*u.Check.NoSSH || deref(u.Check.SSH) != "" || len(w.sshAsked) != 0 || u.Steps[len(u.Steps)-1].Text != "no ssh destination" {
		t.Errorf("%+v", u.Check)
	}
}

func TestACheckOfAMapWithSSHTestsItWithSSHG(t *testing.T) {
	w := newWorld(dropletTools, nil)
	w.workspaces = []MachineInfo{{ID: "d1", Name: "devstack-1", State: "running", SSH: new("coder@cws.devstack-1")},
		{ID: "d2", Name: "devstack-2", State: "stopped", SSH: new("coder@cws.devstack-2")}}
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	m := mapWithSSH("coder@cws.{name}")
	answer := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": m})
	words := "ssh -G coder@cws.devstack-1: hostname cws.devstack-1, user coder, port 22, ProxyCommand ssh -W %h:%p bastion.cws.example"
	if !strings.Contains(answer, words) || strings.Contains(answer, "No workspace has an ssh destination") ||
		!reflect.DeepEqual(w.sshAsked, []string{"coder@cws.devstack-1"}) || deref(w.last().Check.SSH) != words || w.last().Check.NoSSH != nil {
		t.Errorf("%q", answer)
	}
	w.read(func() { w.sshConfig = nil })
	failed := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": m})
	if !strings.Contains(failed, "ssh -G coder@cws.devstack-1 failed: ssh: Could not resolve hostname. Check the destination.") {
		t.Errorf("%q", failed)
	}
}

func TestThePromptSaysWhereSSHHidesAndAPortIsOneWord(t *testing.T) {
	w := newWorld(dropletTools, nil)
	w.workspaces = []MachineInfo{{ID: "d1", Name: "box", State: "running", SSH: new("alex@127.0.0.1 -p 2222")}}
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	p := w.started[0].Prompt
	for _, s := range []string{"ssh-remote+coder@host", "program=ssh", "ssh -G", "At most 8 checks and 40 calls; about 5 minutes."} {
		if !strings.Contains(p, s) {
			t.Errorf("prompt lacks %q", s)
		}
	}
	h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": mapWithSSH("alex@127.0.0.1 -p 2222")})
	if !reflect.DeepEqual(w.sshAsked, []string{"ssh://alex@127.0.0.1:2222"}) {
		t.Errorf("%v", w.sshAsked)
	}
}

func TestWhetherADraftNamesSSH(t *testing.T) {
	cases := []struct {
		draft    string
		commands bool
		want     bool
	}{
		{string(rawOf(goodMap)), false, false},
		{`{"list": {"ssh": "coder@cws.{name}"}}`, false, true},
		{`{"list": "cws list", "columns": ["id"]}`, true, false},
		{`{"list": "cws list", "columns": ["id"], "ssh": "root@${ip}"}`, true, true},
		{`{"workspaces": [{"id": "a"}, {"id": "b", "ssh": "b.cws"}]}`, true, true},
		{`{"preset": "coder"}`, true, true},
	}
	for _, c := range cases {
		if hasSSH(mustParse(c.draft), c.commands) != c.want {
			t.Errorf("%s", c.draft)
		}
	}
}

func TestAnotherAgentsCallIsRefused(t *testing.T) {
	w := newWorld([]string{"droplet-list"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	if _, err := h.drafts.Call(h.host, MachineProviderDraftCall{AgentID: wire.UUID(records.NewUUID()), Draft: wire.UUID(id), Tool: ToolReadTools}); failureOf(err) == nil {
		t.Error("another agent")
	}
	if _, err := h.drafts.Call("otherhost", MachineProviderDraftCall{AgentID: wire.UUID(w.agent), Draft: wire.UUID(id), Tool: ToolReadTools}); failureOf(err) == nil {
		t.Error("another host")
	}
	if _, err := h.tool(records.NewUUID(), ToolReadTools, nil); failureOf(err) == nil || failureOf(err).Message != NotYoursWords {
		t.Error("another draft")
	}
	if note := h.mustTool(t, id, ToolReadTools, nil); !strings.Contains(note, "droplet-list") {
		t.Errorf("%q", note)
	}
}

func TestAfterEightChecksTheTimeIsOver(t *testing.T) {
	w := newWorld(dropletTools, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	for range MaxChecks {
		if note := h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap}); !strings.HasPrefix(note, "Passed") {
			t.Fatalf("%q", note)
		}
	}
	if h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap}) != OverWords || h.mustTool(t, id, ToolReadTools, nil) != OverWords {
		t.Error("not over")
	}
	if w.checks != MaxChecks {
		t.Errorf("checks %d", w.checks)
	}
	if h.mustTool(t, id, ToolGiveUp, map[string]any{"reason": "It has no list."}) != "Ended." || w.last().State != "failed" || deref(w.last().Note) != "It has no list." {
		t.Errorf("%+v", w.last())
	}
}

func TestOutOfTimeWithAPassedDraftThatDraftIsTheResult(t *testing.T) {
	w := newWorld(dropletTools, nil)
	c := &clock{now: time.Now()}
	timing := quickDraftTiming()
	timing.Total, timing.Answer, timing.LastWord, timing.Tick = 150*time.Millisecond, 5*time.Second, 100*time.Millisecond, 10*time.Millisecond
	h := newDraftHarness(w, timing, true, "", c)
	id := h.startMap(t)
	h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	for range 500 {
		if u := w.last(); Ended(*u) {
			break
		}
		c.advance(50 * time.Millisecond)
		time.Sleep(10 * time.Millisecond)
	}
	if u := w.last(); u.State != "done" || !jsonEqual(u.DraftJSON, goodMap) {
		t.Errorf("%+v", u)
	}
}

func TestCancelOrTheSheetGoingStopsTheAgent(t *testing.T) {
	w := newWorld([]string{"droplet-list"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	h.drafts.Cancel(id, h.owner)
	if w.last().State != "cancelled" {
		t.Error("not cancelled")
	}
	eventually(t, func() bool { var n int; w.read(func() { n = len(w.stopped) }); return n == 1 })
	if _, _, ok := h.drafts.Result(id); ok {
		t.Error("a result")
	}

	gone := newWorld([]string{"droplet-list"}, nil)
	c := &clock{now: time.Now()}
	timing := quickDraftTiming()
	timing.Tick = 10 * time.Millisecond
	quick := newDraftHarness(gone, timing, true, "", c)
	quick.startMap(t)
	var asked int
	gone.read(func() { gone.ownerHere = false; asked = gone.ownerAsked })
	eventually(t, func() bool { var n int; gone.read(func() { n = gone.ownerAsked }); return n > asked })
	if gone.last().State == "cancelled" {
		t.Error("cancelled at once")
	}
	c.advance(31 * time.Second)
	if !eventually(t, func() bool { return gone.last().State == "cancelled" }) {
		t.Error("not cancelled")
	}
}

func TestATurnThatEndsWithNoDraftFails(t *testing.T) {
	w := newWorld([]string{"droplet-list"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	h.mustTool(t, id, "turn_ended", nil)
	if u := w.last(); u.State != "failed" || deref(u.Note) != "It ended without sending a map." {
		t.Errorf("%+v", u)
	}
}

func TestNoSecretsValueReachesTheAgentAStepAnUpdateOrTheLog(t *testing.T) {
	w := newWorld(dropletTools, map[string]string{"droplet-list": "Lists droplets. Token: " + secretValue})
	encoded := base64.StdEncoding.EncodeToString([]byte(secretValue))
	w.checkFails = "401 Unauthorized for token " + secretValue + " (" + encoded + ")"
	w.workspaces = []MachineInfo{{ID: "1", Name: "box-" + secretValue, State: "running"}}
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	seen := []string{w.started[0].Prompt, h.mustTool(t, id, ToolReadTools, nil), h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})}
	w.read(func() { w.checkFails = "" })
	seen = append(seen, h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap}))
	w.read(func() {
		seen = append(seen, string(rawOf(w.updates)))
		seen = append(seen, w.logs...)
	})
	for _, text := range seen {
		if strings.Contains(text, secretValue) || strings.Contains(text, encoded) {
			t.Errorf("a secret in %q", text)
		}
	}
	if !strings.Contains(seen[1], "${DIGITALOCEAN_API_TOKEN}") || !strings.Contains(seen[2], "${DIGITALOCEAN_API_TOKEN}") {
		t.Error("not redacted by name")
	}
}

func TestAListThatMayChangeSomethingIsAskedFirst(t *testing.T) {
	w := newWorld([]string{"droplet-power-on", "droplet-power-off"}, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	id := h.startMap(t)
	unsafe := mustParse(`{"list": {"tool": "droplet-power-on", "items": "", "id": "id", "name": "name", "state": "s"},
		"start": {"tool": "droplet-power-on"}, "stop": {"tool": "droplet-power-off"}}`)
	answer := make(chan string)
	go func() { answer <- h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": unsafe}) }()
	q := w.question(t)
	if q.Kind != "check" || q.Yes != "Run Check" {
		t.Errorf("%+v", q)
	}
	if err := h.drafts.Answer(ProviderDraftAnswer{Draft: wire.UUID(id), Question: q.ID, Yes: false}, h.owner); err != nil {
		t.Fatal(err)
	}
	if note := <-answer; !strings.HasPrefix(note, "The person said no to this check") || w.checks != 0 {
		t.Errorf("%q", note)
	}
}

func TestProveStartAsksAndNoAnswerIsANo(t *testing.T) {
	w := newWorld(dropletTools, nil)
	timing := quickDraftTiming()
	timing.Answer, timing.LastWord, timing.Tick = 100*time.Millisecond, 5*time.Second, 10*time.Millisecond
	h := newDraftHarness(w, timing, true, "", nil)
	id := h.startMap(t)
	if note := h.mustTool(t, id, ToolProveStart, map[string]any{"draft": goodMap, "workspace": "scratch-1"}); !strings.Contains(note, "isn’t in the last list") {
		t.Errorf("%q", note)
	}
	h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	if note := h.mustTool(t, id, ToolProveStart, map[string]any{"draft": goodMap, "workspace": "scratch-1"}); note != "The person said no." || w.starts != 0 {
		t.Errorf("%q", note)
	}
	started := make(chan string)
	go func() {
		started <- h.mustTool(t, id, ToolProveStart, map[string]any{"draft": goodMap, "workspace": "agents-devbox"})
	}()
	q := w.question(t)
	for deref(q.Workspace) != "agents-devbox" {
		time.Sleep(10 * time.Millisecond)
		q = w.question(t)
	}
	if q.Text != "Claude wants to start agents-devbox on DigitalOcean to prove the map. $0.03/hour while running. It stays running until you stop it." || q.Yes != "Start It" {
		t.Errorf("%+v", q)
	}
	if err := h.drafts.Answer(ProviderDraftAnswer{Draft: wire.UUID(id), Question: q.ID, Yes: true}, h.owner); err != nil {
		t.Fatal(err)
	}
	if note := <-started; note != "Started agents-devbox: running" || w.starts != 1 {
		t.Errorf("%q", note)
	}
}

func TestAStopOfABusyWorkspaceIsNotAsked(t *testing.T) {
	w := newWorld(dropletTools, nil)
	h := newDraftHarness(w, quickDraftTiming(), true, "devbox", nil)
	id := h.startMap(t)
	h.mustTool(t, id, ToolCheckDraft, map[string]any{"draft": goodMap})
	if note := h.mustTool(t, id, ToolProveStop, map[string]any{"draft": goodMap, "workspace": "101"}); note != "Not asked: agents are working on devbox." || w.stops != 0 {
		t.Errorf("%q", note)
	}
}

// Commands for a CLI (#858 US2).

var commandsForm = ProviderAdd{Name: "Company workspaces", Kind: KindCommands, CLI: ptr("cws")}

func cliWorld() *world {
	w := newWorld(nil, nil)
	w.helps = map[string]string{"": "Usage: cws <command>\n  list    List workspaces\n  start   Start one\n  stop    Stop one\n  destroy Delete one",
		"list": "Usage: cws list [--no-header]"}
	return w
}

func TestAPresetsCLIOrOneNotInstalledStartsNoAgent(t *testing.T) {
	w := cliWorld()
	preset, err := newDraftHarness(w, quickDraftTiming(), true, "", nil).start(ProviderAdd{Name: "D", Kind: KindCommands, CLI: ptr("doctl")}, nil, "claude")
	if err != nil || preset.Answered == nil || deref(preset.Answered.Preset) != "doctl" || preset.Answered.Note != "Agents has a preset for doctl: use DigitalOcean Droplets." {
		t.Errorf("%v %+v", err, preset)
	}
	w.notInstalled = true
	if _, err := newDraftHarness(w, quickDraftTiming(), true, "", nil).start(commandsForm, nil, "claude"); failureOf(err) == nil || len(w.started) != 0 {
		t.Errorf("%v", err)
	}
}

func TestReadHelpRunsOnlyWordsTheHelpPrinted(t *testing.T) {
	w := cliWorld()
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	started, err := h.start(commandsForm, nil, "claude")
	if err != nil {
		t.Fatal(err)
	}
	id := started.Draft
	if !strings.Contains(w.started[0].Prompt, "list    List workspaces") {
		t.Error("prompt")
	}
	if note := h.mustTool(t, string(id), ToolReadHelp, map[string]any{"words": []string{"list"}}); note != "Usage: cws list [--no-header]" {
		t.Errorf("%q", note)
	}
	for words, prefix := range map[string]string{"-y list": "Not run: “-y” is a flag", "destroy": "Not run: “destroy” may change",
		"list; rm": "Not run:", "reboot-all": "Not run:"} {
		given := strings.Split(words, " ")
		if words == "list; rm" {
			given = []string{words}
		}
		if note := h.mustTool(t, string(id), ToolReadHelp, map[string]any{"words": given}); !strings.HasPrefix(note, prefix) {
			t.Errorf("%s: %q", words, note)
		}
	}
	if !reflect.DeepEqual(w.helpRuns, [][]string{{}, {"list"}}) {
		t.Errorf("%v", w.helpRuns)
	}
}

func TestASafeListIsCheckedAtOnceOneThatIsntIsAsked(t *testing.T) {
	w := cliWorld()
	h := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	started, _ := h.start(commandsForm, nil, "claude")
	id := started.Draft
	safe := mustParse(`{"list": "cws list --no-header", "columns": ["id", "name", "state"], "start": "cws start ${id}", "stop": "cws stop ${id}"}`)
	if note := h.mustTool(t, string(id), ToolCheckDraft, map[string]any{"draft": safe}); !strings.HasPrefix(note, "Passed: listed 2.") {
		t.Errorf("%q", note)
	}
	unsafe := mustParse(`{"list": "cws list | sh", "columns": ["id", "name", "state"], "start": "x", "stop": "y"}`)
	answer := make(chan string)
	go func() { answer <- h.mustTool(t, string(id), ToolCheckDraft, map[string]any{"draft": unsafe}) }()
	q := w.question(t)
	if !strings.Contains(q.Text, "It isn’t on the safe list because `cws list | sh` has “|”") {
		t.Errorf("%q", q.Text)
	}
	h.drafts.Answer(ProviderDraftAnswer{Draft: id, Question: q.ID, Yes: true}, h.owner)
	if note := <-answer; !strings.HasPrefix(note, "Passed") || w.checks != 2 {
		t.Errorf("%q", note)
	}
}

// What Add keeps (#858 FR-005) and Write the Map Again (US4), through the providers.

func (h *harness) withDrafts(w *world) *draftHarness {
	dh := newDraftHarness(w, quickDraftTiming(), true, "", nil)
	h.providers.DraftWith(dh.drafts)
	h.providers.hooks.Connect = func(ProviderRecord, map[string]string) (Provider, error) { return h.provider, nil }
	return dh
}

func storedRecord(t *testing.T, h *harness, id string) ProviderRecord {
	t.Helper()
	object, _ := h.store.Get(context.Background(), ProviderKey(id))
	var r ProviderRecord
	if object == nil || json.Unmarshal(object.Data, &r) != nil {
		t.Fatal("no record")
	}
	return r
}

func TestAddWithTheDraftsOwnMapMarksItWrittenByTheRuntime(t *testing.T) {
	h := newHarness(t)
	dh := h.withDrafts(newWorld(dropletTools, nil))
	id := dh.startMap(t)
	dh.mustTool(t, id, ToolSendDraft, map[string]any{"draft": goodMap})
	// Written again by the sheet: the same JSON, so the same map.
	same := mustParse(string(rawOf(goodMap)))
	kept := h.must(MethodProvidersAdd, ProviderAdd{Name: "Droplets", Kind: KindStdio, Command: ptr("npx"), Map: jsonValue(same), Draft: new(wire.UUID(id))}).(ProviderSummary)
	r := storedRecord(t, h, string(kept.ID))
	if r.WrittenBy == nil || r.WrittenBy.RuntimeID != "claude" || !jsonEqual(r.Map, goodMap) {
		t.Errorf("%+v", r)
	}
	changed := toValue(goodMap).(map[string]any)
	changed["list"] = map[string]any{"tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "state"}
	other := h.must(MethodProvidersAdd, ProviderAdd{Name: "Droplets 2", Kind: KindStdio, Command: ptr("npx"), Map: jsonValue(changed), Draft: new(wire.UUID(id))}).(ProviderSummary)
	if storedRecord(t, h, string(other.ID)).WrittenBy != nil {
		t.Error("a changed map marked written")
	}
}

func TestWritingAgainStartsFromTheKeptRecordAndSaveKeepsTheServer(t *testing.T) {
	h := newHarness(t)
	w := newWorld(dropletTools, nil)
	dh := h.withDrafts(w)
	kept := h.must(MethodProvidersAdd, ProviderAdd{Name: "Droplets", Kind: KindStdio, Command: ptr("npx"), Args: []string{"-y", "@do/mcp"},
		Map: jsonValue(goodMap), Secrets: map[string]string{"TOKEN": "dop_v1_keptsecretvalue"}}).(ProviderSummary)
	// The sheet knows only the name and kind, and types no secret.
	started := h.must(MethodDraftStart, ProviderDraftStart{Form: ProviderAdd{Name: "Droplets", Kind: KindStdio}, Provider: new(wire.ProviderID(kept.ID)),
		RuntimeID: "claude"}).(ProviderDraftStarted)
	p := w.started[0].Prompt
	if !strings.Contains(p, "It has this map now") || !strings.Contains(p, "droplet-power-on") || !strings.Contains(p, "TOKEN") ||
		strings.Contains(p, "dop_v1_keptsecretvalue") {
		t.Errorf("%q", p)
	}
	newMap := toValue(goodMap).(map[string]any)
	newMap["list"] = map[string]any{"tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "state"}
	dh.mustTool(t, string(started.Draft), ToolSendDraft, map[string]any{"draft": newMap})
	h.must(MethodProvidersUpdate, ProviderAdd{ID: new(wire.ProviderID(kept.ID)), Name: "Droplets", Kind: KindStdio, Map: jsonValue(newMap), Draft: new(wire.UUID(started.Draft))})
	r := storedRecord(t, h, string(kept.ID))
	if *r.Command != "npx" || !reflect.DeepEqual(r.Args, []string{"-y", "@do/mcp"}) || !jsonEqual(r.Map, newMap) ||
		r.WrittenBy == nil || r.WrittenBy.RuntimeID != "claude" || !reflect.DeepEqual(r.SecretNames, []string{"TOKEN"}) || r.Rev != 2 {
		t.Errorf("%+v", r)
	}
}

func TestACommandProvidersCLIIsFoundFromItsCommands(t *testing.T) {
	r := ProviderRecord{Kind: KindCommands, Commands: mustParse(`{"workspaces": [{"name": "a", "start": "cws start a", "stop": "cws stop a"}]}`)}
	if cliOf(r) != "cws" {
		t.Errorf("%q", cliOf(r))
	}
}

func TestAnUpdateWhoseSecretIsAWordIsStillSentRedacted(t *testing.T) {
	// A secret that is also one of the update's own words ("writing"): what cannot be read
	// back redacted is not sent, and the rest is.
	update := DraftUpdate{Draft: wire.UUID(records.NewUUID()), State: "writing", RuntimeName: "Claude", Steps: []DraftStep{}, Note: new("x")}
	if _, ok := redactUpdate(update, NewRedaction(map[string]string{"S": "runtimeName"})); ok {
		t.Error("read back without its runtimeName")
	}
	if out, ok := redactUpdate(update, NewRedaction(map[string]string{"S": "Claude"})); !ok || out.RuntimeName != "${S}" {
		t.Errorf("%+v", out)
	}
}
