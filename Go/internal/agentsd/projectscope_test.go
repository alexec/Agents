package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The agent tools scoped to the project (#3277): list_sessions, read_session,
// message_session and wait_for_event on agent.ended reach every session of the agent's project, in this
// machine's other folders of it and on the person's other machines; start_session with
// machine alone finds the project's folder there; stop and archive stay the starter's.

func projectFolder(t *testing.T, project string) string {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".agents"), 0o755)
	os.WriteFile(filepath.Join(dir, ".agents", "folder.json"), []byte(`{"project": "`+project+`"}`), 0o644)
	return dir
}

func TestSessionToolsReachTheProjectOnThisMachine(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	mine, clone, other := projectFolder(t, "p-agents"), projectFolder(t, "p-agents"), projectFolder(t, "p-other")
	running := func(title string) func(a *wire.Agent) {
		return func(a *wire.Agent) {
			a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
		}
	}
	me := seeded(t, d, mine, running("lead"))
	lane := seeded(t, d, clone, running("lane in the clone"))
	stranger := seeded(t, d, other, running("another project"))
	m := appClient(t, d, me.ID)
	m.post("initialize", map[string]any{}, 1)

	text, _ := m.tool(2, "list_sessions", map[string]any{})
	if !strings.HasPrefix(text, "Sessions in this project,") || !strings.Contains(text, string(lane.ID)) ||
		!strings.Contains(text, "In "+folderPath(&lane)+".") || strings.Contains(text, string(stranger.ID)) {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "read_session", map[string]any{"session": "lane in the clone"}); !strings.Contains(text, "# Session “lane in the clone”") {
		t.Fatal(text)
	}
	if text, _ := m.tool(4, "read_session", map[string]any{"session": "another project"}); text != "There is no session named “another project” in this project." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{string(lane.ID)}}, "until_minutes": 30}); isErr {
		t.Fatal(text)
	}
	if text, isErr := m.tool(6, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{string(stranger.ID)}}, "until_minutes": 30}); !isErr ||
		!strings.Contains(text, "is in another folder, not in this project") {
		t.Fatal(text)
	}
}

func TestSessionToolsReachTheProjectOnOtherMachines(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	me := seeded(t, d, projectFolder(t, "p-agents"), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", new("lead")
	})
	m := appClient(t, d, me.ID)
	m.post("initialize", map[string]any{}, 1)
	d.SetMember(&controllink.Membership{Host: "h-mac"})

	lane := wire.Agent{ID: there, Title: new("lane on the pc"), RuntimeID: "claude", State: wire.AgentStateRunning, Cwd: "file:///home/me/agents"}
	var mu sync.Mutex
	var calls []wire.MachineSessionCall
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, _ := params.(wire.MachineWorkspaceCall)
		b, _ := json.Marshal(call.Params)
		switch call.Method {
		case "machines/projectSessions":
			var r wire.ProjectSessionsRequest
			json.Unmarshal(b, &r)
			if r.Project != "p-agents" {
				t.Errorf("%+v", r)
			}
			// This machine's own are listed from its store, not twice.
			return json.Marshal(wire.ProjectSessions{
				Sessions: []wire.ProjectSession{{Machine: "h-pc", MachineName: "pc", Session: lane},
					{Machine: "h-mac", MachineName: "mac", Session: *d.Store.Agent(me.ID)}},
				Unreached: []wire.ProjectMachine{{Machine: "h-laptop", MachineName: "laptop"}}})
		case "machines/projectFolders":
			return json.Marshal(wire.ProjectFolders{Machines: []wire.ProjectMachineFolders{
				{Machine: "h-pc", MachineName: "pc", Folders: []string{"/home/me/agents"}},
				{Machine: "h-laptop", MachineName: "laptop", Folders: []string{"/a", "/b"}}}})
		case "machines/sessionCall":
			var s wire.MachineSessionCall
			json.Unmarshal(b, &s)
			mu.Lock()
			calls = append(calls, s)
			mu.Unlock()
			return json.Marshal(wire.SessionCallReply{Said: s.Call.Op + " said", Title: lane.Title})
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})
	last := func() wire.MachineSessionCall {
		mu.Lock()
		defer mu.Unlock()
		return calls[len(calls)-1]
	}

	text, _ := m.tool(2, "list_sessions", map[string]any{})
	if !strings.Contains(text, string(there)+": “lane on the pc”") || !strings.Contains(text, "On pc, in /home/me/agents.") ||
		strings.Count(text, string(me.ID)) != 1 || !strings.HasSuffix(text, "Not reached, so their sessions are not listed: laptop.") {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "read_session", map[string]any{"session": string(there)}); text != "read said" {
		t.Fatal(text)
	}
	if s := last(); s.Host != "pc" || s.Call.Op != "read" || deref(s.Call.Project) != "p-agents" || s.Call.From.Agent != me.ID {
		t.Fatalf("%+v", s)
	}
	if text, _ := m.tool(4, "message_session", map[string]any{"to": "lane on the pc", "message": "Rebase on main."}); text != "message said" {
		t.Fatal(text)
	}

	// A wait on it asks its machine to say when it ends, and closes when it does.
	if text, isErr := m.tool(5, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"lane on the pc"}}, "until_minutes": 30}); isErr {
		t.Fatal(text)
	}
	if s := last(); s.Call.Op != "status" || s.Call.Watch == nil || !*s.Call.Watch || deref(s.Call.Project) != "p-agents" {
		t.Fatalf("%+v", s)
	}
	c.call(t, 6, "agents/endedElsewhere", map[string]any{"machine": "pc", "session": string(there), "starter": string(me.ID),
		"how": map[string]any{"finished": map[string]any{"outcome": "done", "message": "Merged."}}})
	waitFor(t, "the wait to close", func() bool {
		r := d.Store.Agent(me.ID).Report
		return r != nil && r.Block != nil && len(r.Block.Waits) == 1 && r.Block.Waits[0].Ending != nil
	})
	if len(d.watchedBy(me.ID)) != 0 {
		t.Fatal("still watched")
	}

	// start_session with machine alone: the project's folder there.
	if f, err := d.projectFolderOn(d.Store.Agent(me.ID), "PC"); err != nil || f != "/home/me/agents" {
		t.Fatalf("%q %v", f, err)
	}
	if _, err := d.projectFolderOn(d.Store.Agent(me.ID), "laptop"); err == nil || !strings.Contains(err.Error(), "2 folders on laptop") {
		t.Fatal(err)
	}
	if _, err := d.projectFolderOn(d.Store.Agent(me.ID), "nas"); err == nil || !strings.Contains(err.Error(), "no folder on nas (it has one on pc, laptop)") {
		t.Fatal(err)
	}
}

func TestAProjectMemberOnAnotherMachineReadsButCannotStop(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var mu sync.Mutex
	var ended []wire.SessionEnded
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, _ := params.(wire.MachineWorkspaceCall)
		if call.Method == "machines/sessionEnded" {
			var e wire.SessionEnded
			b, _ := json.Marshal(call.Params)
			json.Unmarshal(b, &e)
			mu.Lock()
			ended = append(ended, e)
			mu.Unlock()
		}
		return json.RawMessage(`{}`), nil
	})
	lane := seeded(t, d, projectFolder(t, "p-agents"), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", new("lane")
	})
	from := map[string]any{"machine": "pc", "agent": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "who": "Claude (lead)"}
	params := func(op, project string) map[string]any {
		return map[string]any{"from": from, "session": string(lane.ID), "op": op, "project": project}
	}
	if e := c.callError(t, 1, "agents/fromStarter", params("status", "p-other")); e.Code != wire.FailureNotYours {
		t.Fatalf("%+v", e)
	}
	for i, op := range []string{"stop", "archive"} {
		if e := c.callError(t, 2+i, "agents/fromStarter", params(op, "p-agents")); e.Code != wire.FailureNotYours ||
			!strings.Contains(e.Message, "you did not start that session") {
			t.Fatalf("%+v", e)
		}
	}
	watch := params("status", "p-agents")
	watch["watch"] = true
	var reply wire.SessionCallReply
	json.Unmarshal(c.call(t, 4, "agents/fromStarter", watch), &reply)
	if deref(reply.Title) != "lane" {
		t.Fatalf("%+v", reply)
	}

	// Its end goes to the member that waits on it, once.
	d.tellStarter(lane.ID, wire.WaitEndingHow{Stopped: &wire.WaitEndingHowStopped{}})
	waitFor(t, "the member to be told", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(ended) == 1
	})
	mu.Lock()
	e := ended[0]
	mu.Unlock()
	if e.Machine != "pc" || e.Session != lane.ID || string(e.Starter) != "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" {
		t.Fatalf("%+v", e)
	}
	if len(d.takeWatchers(lane.ID)) != 0 {
		t.Fatal("told twice")
	}
}
