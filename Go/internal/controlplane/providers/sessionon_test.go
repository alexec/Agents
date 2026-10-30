package providers

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// start_session on another machine (#2887): machines/startSession goes to that machine's
// own agents/start, found by its name, saying in the control plane's words which agent on
// which machine asked; a stopped workspace keeps it; another person's machine is not there.

func sessionOn(host string) map[string]any {
	return map[string]any{"host": host, "start": map[string]any{"runtimeID": "claude", "cwd": "file:///home/me/app", "prompt": "Check it",
		"attachments": []any{}, "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []any{}},
		"additionalDirectories": []any{}, "mcpServers": []any{}, "labels": []any{},
		"startedFrom": map[string]any{"machine": "a lie", "agent": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "who": "a lie"}}}
}

func TestAnAgentStartsASessionOnAnotherMachineByItsName(t *testing.T) {
	h := newHarness(t)
	made := records.NewUUID()
	h.router.mu.Lock()
	h.router.answer = func(host, method string, params json.RawMessage) *Reply { return &Reply{Result: rawOf(made)} }
	h.router.mu.Unlock()
	h.router.setOnline(devbox, true)

	listed, err := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if hosts := listed.(AgentMachines).Hosts; err != nil || len(hosts) != 2 || hosts[0].Name != "devbox" || hosts[0].State != "online" {
		t.Fatalf("%v %+v", err, listed)
	}

	out, err := h.agentCall(MethodSessionOnMachine, sessionOn("DEVBOX"))
	if err != nil || string(out.(wire.UUID)) != made {
		t.Fatalf("%v %+v", err, out)
	}
	sent := h.router.deliveries()
	if len(sent) != 1 || sent[0].host != devbox || sent[0].method != MethodAgentsStart {
		t.Fatalf("%+v", sent)
	}
	var start wire.StartRequest
	if err := json.Unmarshal(sent[0].params, &start); err != nil {
		t.Fatal(err)
	}
	if f := start.StartedFrom; f == nil || f.Machine != "other" || f.Who != "Claude (fix-login)" || f.Agent != "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" ||
		start.Cwd != "file:///home/me/app" {
		t.Fatalf("%+v", start)
	}

	// The host says no, in its own words.
	h.router.mu.Lock()
	h.router.answer = func(string, string, json.RawMessage) *Reply {
		return &Reply{Error: &Failure{Code: -32004, Message: "/home/me/app is not there any more."}}
	}
	h.router.mu.Unlock()
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Message != "/home/me/app is not there any more." {
		t.Fatalf("%v", err)
	}

	// Offline, with no workspace to start: not sent.
	h.router.setOnline(devbox, false)
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Code != CodeHostOffline {
		t.Fatalf("%v", err)
	}
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("nowhere")); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
}

func TestASessionOnAStoppedWorkspaceIsKept(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.keeper()
	_, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox"))
	if s := keptSummary(t, failureOf(err)); s.Kind != "start" {
		t.Fatalf("%+v", s)
	}
}

func TestAnAgentCannotStartASessionOnAnotherPersonsMachine(t *testing.T) {
	h := newHarness(t)
	h.providers.hooks.OwnerOf = func(host string) string {
		if host == devbox {
			return "kim"
		}
		return "lee"
	}
	h.router.setOnline(devbox, true)
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
	listed, _ := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if hosts := listed.(AgentMachines).Hosts; len(hosts) != 1 || hosts[0].Name != "other" {
		t.Fatalf("%+v", hosts)
	}
	if len(h.router.deliveries()) != 0 {
		t.Fatal("sent")
	}
}

// A session started on another machine (#2927): the starter's calls go to that machine's
// agents/fromStarter, saying in the control plane's words which machine and agent ask;
// its end goes to the starter's machine as agents/endedElsewhere, naming the machine it
// ran on.
func TestTheStarterReachesItsSessionThroughTheControlPlane(t *testing.T) {
	h := newHarness(t)
	h.router.mu.Lock()
	h.router.answer = func(host, method string, params json.RawMessage) *Reply {
		if method == MethodAgentsFromStarter {
			return &Reply{Result: rawOf(wire.SessionCallReply{Said: "working"})}
		}
		return &Reply{Result: rawOf(map[string]any{})}
	}
	h.router.mu.Unlock()
	call := map[string]any{"host": "devbox", "call": map[string]any{"session": "11111111-2222-3333-4444-555555555555", "op": "status",
		"from": map[string]any{"machine": "a lie", "agent": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "who": "a lie"}}}
	if _, err := h.agentCall(MethodSessionCall, call); failureOf(err) == nil || failureOf(err).Code != CodeHostOffline {
		t.Fatalf("%v", err)
	}
	h.router.setOnline(devbox, true)
	out, err := h.agentCall(MethodSessionCall, call)
	if err != nil || out.(wire.SessionCallReply).Said != "working" {
		t.Fatalf("%v %+v", err, out)
	}
	sent := h.router.deliveries()
	var asked wire.SessionCall
	if len(sent) != 1 || sent[0].host != devbox || sent[0].method != MethodAgentsFromStarter || json.Unmarshal(sent[0].params, &asked) != nil ||
		asked.From.Machine != "other" || asked.From.Who != "Claude (fix-login)" || asked.From.Agent != "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" || asked.Op != "status" {
		t.Fatalf("%+v %+v", sent, asked)
	}

	// other's session ended; devbox started it.
	ended := map[string]any{"machine": "DEVBOX", "session": "11111111-2222-3333-4444-555555555555", "starter": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
		"how": map[string]any{"finished": map[string]any{}}}
	if _, err := h.agentCall(MethodSessionEnded, ended); err != nil {
		t.Fatal(err)
	}
	sent = h.router.deliveries()
	var told wire.SessionEnded
	if len(sent) != 2 || sent[1].host != devbox || sent[1].method != MethodAgentsEndedThere || json.Unmarshal(sent[1].params, &told) != nil ||
		told.Machine != "other" || told.How.Finished == nil {
		t.Fatalf("%+v %+v", sent, told)
	}
	ended["machine"] = "nowhere"
	if _, err := h.agentCall(MethodSessionEnded, ended); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}

	// Another person's machine is not there.
	h.providers.hooks.OwnerOf = func(host string) string {
		if host == devbox {
			return "kim"
		}
		return "lee"
	}
	ended["machine"] = "devbox"
	if _, err := h.agentCall(MethodSessionCall, call); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
	if _, err := h.agentCall(MethodSessionEnded, ended); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
	if len(h.router.deliveries()) != 2 {
		t.Fatal("sent")
	}
}

// start_session with send (#2929): each step of machines/sendFolder goes to that machine's
// own folders/receive* method, and its answer comes back; an offline machine gets none.
func TestAnAgentSendsAFolderToAnotherMachine(t *testing.T) {
	h := newHarness(t)
	h.router.mu.Lock()
	h.router.answer = func(host, method string, params json.RawMessage) *Reply {
		switch method {
		case MethodReceiveState:
			return &Reply{Result: rawOf(wire.ReceiveState{Folder: "file:///home/me/app/", Exists: true, Repository: true, Heads: []string{"abc"}})}
		case MethodReceive:
			return &Reply{Result: rawOf(wire.FolderSummary{Name: "app"})}
		}
		return &Reply{Result: rawOf(map[string]any{})}
	}
	h.router.mu.Unlock()
	h.router.setOnline(devbox, true)

	out, err := h.agentCall(MethodSendFolder, map[string]any{"host": "devbox", "state": map[string]any{"folder": "/home/me/app"}})
	if s := out.(wire.MachineFolderSent).State; err != nil || s == nil || len(s.Heads) != 1 {
		t.Fatalf("%v %+v", err, out)
	}
	if _, err := h.agentCall(MethodSendFolder, map[string]any{"host": "devbox",
		"upload": map[string]any{"upload": records.NewUUID(), "offset": 0, "data": "aGVsbG8="}}); err != nil {
		t.Fatal(err)
	}
	out, err = h.agentCall(MethodSendFolder, map[string]any{"host": "devbox", "receive": map[string]any{"folder": "/home/me/app",
		"branches": []any{map[string]any{"name": "main", "commit": "0123456789012345678901234567890123456789"}}, "checkout": "main"}})
	if f := out.(wire.MachineFolderSent).Folder; err != nil || f == nil || f.Name != "app" {
		t.Fatalf("%v %+v", err, out)
	}
	sent := h.router.deliveries()
	if len(sent) != 3 || sent[0].method != MethodReceiveState || sent[1].method != MethodReceiveUpload || sent[2].method != MethodReceive || sent[2].host != devbox {
		t.Fatalf("%+v", sent)
	}
	var upload wire.ReceiveUploadRequest
	if json.Unmarshal(sent[1].params, &upload) != nil || string(upload.Data) != "hello" {
		t.Fatalf("%s", sent[1].params)
	}

	if _, err := h.agentCall(MethodSendFolder, map[string]any{"host": "devbox"}); failureOf(err) == nil || failureOf(err).Code != CodeInvalidParams {
		t.Fatalf("%v", err)
	}
	h.router.setOnline(devbox, false)
	if _, err := h.agentCall(MethodSendFolder, map[string]any{"host": "devbox", "state": map[string]any{"folder": "/a"}}); failureOf(err) == nil || failureOf(err).Code != CodeHostOffline {
		t.Fatalf("%v", err)
	}
	if len(h.router.deliveries()) != 3 {
		t.Fatal("sent to an offline machine")
	}
}
