package agentsd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The test binary is also a fake ACP runtime: with AGENTS_FAKE_ACP=1 it serves one on its
// stdin and stdout. A prompt with "ask" in it asks for permission before it answers; one
// with "wait for me" waits to be cancelled, and one with "keep going" waits for a SIGTERM.
func TestMain(m *testing.M) {
	if os.Getenv("AGENTS_FAKE_MCP") == "1" {
		fakeMCPServer()
		return
	}
	if os.Getenv("AGENTS_FAKE_ACP") == "1" {
		f := &fakeRuntime{ready: make(chan struct{})}
		f.conn = sdk.NewAgentSideConnection(f, os.Stdout, os.Stdin)
		close(f.ready)
		<-f.conn.Done()
		return
	}
	// No test asks the person's gh about merged pull requests unless it says so.
	findGH = func() string { return "" }
	// Nor asks the forge for an issue's milestone (#2935): a test sets issueLookup.
	milestoneLookup = func(context.Context, string, forgeRepo, int) (int, error) { return 0, errNoForgeInTests }
	// Nor erases a deleted agent's runtime copy (#1001): that starts the runtime.
	erasing = false
	os.Exit(m.Run())
}

type fakeRuntime struct {
	sdk.Agent // what it does not answer
	conn      *sdk.AgentSideConnection
	// ready is closed once conn is set: the SDK serves before it returns the connection.
	ready chan struct{}
	// sandboxOff is whether session/new's _meta turned Claude's sandbox off.
	sandboxOff bool
	// rateLimited is whether "rate limit me" was refused once already.
	rateLimited bool
	// systemPrompt is the runtime's system-prompt field from session/new or resume.
	systemPrompt string
}

// systemPromptOf is the brief a runtime was given in _meta, as Claude or Grok take it.
func systemPromptOf(meta any) string {
	m, _ := meta.(map[string]any)
	if sp, ok := m["systemPrompt"].(map[string]any); ok {
		s, _ := sp["append"].(string)
		return s
	}
	if jetbrains, ok := m["jetbrains"].(map[string]any); ok {
		if air, ok := jetbrains["air"].(map[string]any); ok {
			s, _ := air["customInstructions"].(string)
			if s != "" {
				return s
			}
		}
	}
	s, _ := m["rules"].(string)
	return s
}

func (f *fakeRuntime) Initialize(context.Context, sdk.InitializeRequest) (sdk.InitializeResponse, error) {
	// AGENTS_FAKE_STARTS names a file the fake adds a line to each time it starts.
	if file := os.Getenv("AGENTS_FAKE_STARTS"); file != "" {
		if f, err := os.OpenFile(file, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
			f.WriteString("started\n")
			f.Close()
		}
	}
	// AGENTS_FAKE_NO_DELETE: an adapter that cannot delete a session.
	var del *sdk.SessionDeleteCapabilities
	if os.Getenv("AGENTS_FAKE_NO_DELETE") == "" {
		del = &sdk.SessionDeleteCapabilities{}
	}
	return sdk.InitializeResponse{ProtocolVersion: sdk.ProtocolVersionNumber, AuthMethods: fakeAuthMethods(),
		AgentCapabilities: sdk.AgentCapabilities{Auth: sdk.AgentAuthCapabilities{Logout: &sdk.LogoutCapabilities{}},
			Providers: &sdk.ProvidersCapabilities{}, LoadSession: true, SessionCapabilities: sdk.SessionCapabilities{Resume: &sdk.SessionResumeCapabilities{},
				Fork: &sdk.SessionForkCapabilities{}, List: &sdk.SessionListCapabilities{}, Delete: del}}}, nil
}

// The fake holds one conversation the app did not start, "theirs", in any folder.
func (f *fakeRuntime) ListSessions(_ context.Context, r sdk.ListSessionsRequest) (sdk.ListSessionsResponse, error) {
	title, at := "Their talk", "2026-10-16T09:00:00Z"
	return sdk.ListSessionsResponse{Sessions: []sdk.SessionInfo{{SessionId: "theirs", Cwd: *r.Cwd, Title: &title, UpdatedAt: &at}}}, nil
}

// LoadSession replays "theirs": the person's words in two chunks, then the reply.
func (f *fakeRuntime) LoadSession(ctx context.Context, r sdk.LoadSessionRequest) (sdk.LoadSessionResponse, error) {
	if r.SessionId != "theirs" {
		return sdk.LoadSessionResponse{}, fmt.Errorf("no session %s", r.SessionId)
	}
	<-f.ready
	for _, u := range []sdk.SessionUpdate{sdk.UpdateUserMessageText("What is "), sdk.UpdateUserMessageText("two and two?"), sdk.UpdateAgentMessageText("Four.")} {
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: r.SessionId, Update: u})
	}
	return sdk.LoadSessionResponse{}, nil
}

func (f *fakeRuntime) UnstableDeleteSession(_ context.Context, r sdk.UnstableDeleteSessionRequest) (sdk.UnstableDeleteSessionResponse, error) {
	// AGENTS_FAKE_DELETED names a file the fake adds each deleted session's ID to, a line each.
	if file := os.Getenv("AGENTS_FAKE_DELETED"); file != "" {
		if f, err := os.OpenFile(file, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
			f.WriteString(string(r.SessionId) + "\n")
			f.Close()
		}
	}
	return sdk.UnstableDeleteSessionResponse{}, nil
}

func (f *fakeRuntime) UnstableForkSession(_ context.Context, r sdk.UnstableForkSessionRequest) (sdk.UnstableForkSessionResponse, error) {
	return sdk.UnstableForkSessionResponse{SessionId: "forked-" + r.SessionId}, nil
}

// ResumeSession has its own conversation, and no other. In a folder called reconnecting
// it hands back a mode of its own ("default"), as a runtime's fresh process does before
// the daemon re-pushes the agent's saved mode (#3082).
func (f *fakeRuntime) ResumeSession(_ context.Context, r sdk.ResumeSessionRequest) (sdk.ResumeSessionResponse, error) {
	if r.SessionId != "fake-session" {
		return sdk.ResumeSessionResponse{}, fmt.Errorf("no session %s", r.SessionId)
	}
	b, _ := json.Marshal(r.Meta)
	f.sandboxOff = strings.Contains(string(b), `"sandbox":{"enabled":false}`)
	f.systemPrompt = systemPromptOf(r.Meta)
	var out sdk.ResumeSessionResponse
	if filepath.Base(r.Cwd) == "reconnecting" {
		json.Unmarshal([]byte(`{"configOptions":[{"type":"select","id":"mode","name":"Mode","currentValue":"default",
			"options":[{"value":"default","name":"Default"},{"value":"plan","name":"Plan"}]}]}`), &out)
	}
	return out, nil
}

// NewSession in a folder called offers offers a model, and a command a moment after; in
// one called signedout it wants a sign-in, as Cursor and Antigravity do (#1430).
func (f *fakeRuntime) NewSession(_ context.Context, r sdk.NewSessionRequest) (sdk.NewSessionResponse, error) {
	var out sdk.NewSessionResponse
	if filepath.Base(r.Cwd) == "signedout" {
		return out, &sdk.RequestError{Code: authRequired, Message: "Authentication required"}
	}
	b, _ := json.Marshal(r.Meta)
	f.sandboxOff = strings.Contains(string(b), `"sandbox":{"enabled":false}`)
	f.systemPrompt = systemPromptOf(r.Meta)
	if filepath.Base(r.Cwd) != "offers" {
		return sdk.NewSessionResponse{SessionId: "fake-session"}, nil
	}
	json.Unmarshal([]byte(`{"sessionId":"fake-session","configOptions":[{"type":"select","id":"model","name":"Model",
		"currentValue":"opus","options":[{"value":"opus","name":"Opus"},{"value":"sonnet","name":"Sonnet"}]}]}`), &out)
	go func() {
		<-f.ready
		time.Sleep(50 * time.Millisecond)
		var u sdk.SessionUpdate
		json.Unmarshal([]byte(`{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review the change"}]}`), &u)
		f.conn.SessionUpdate(context.Background(), sdk.SessionNotification{SessionId: "fake-session", Update: u})
	}()
	return out, nil
}
func (f *fakeRuntime) Cancel(context.Context, sdk.CancelNotification) error { return nil }

// SetSessionConfigOption, for a value ID, hands back what it was just set to: a runtime
// saying its options are different from what the daemon asked for (#3082).
func (f *fakeRuntime) SetSessionConfigOption(_ context.Context, r sdk.SetSessionConfigOptionRequest) (sdk.SetSessionConfigOptionResponse, error) {
	if r.ValueId == nil {
		return sdk.SetSessionConfigOptionResponse{}, nil
	}
	var opt sdk.SessionConfigOption
	raw, _ := json.Marshal(map[string]any{"type": "select", "id": r.ValueId.ConfigId, "name": "Mode",
		"currentValue": r.ValueId.Value, "options": []map[string]any{{"value": r.ValueId.Value, "name": r.ValueId.Value}}})
	json.Unmarshal(raw, &opt)
	return sdk.SetSessionConfigOptionResponse{ConfigOptions: []sdk.SessionConfigOption{opt}}, nil
}

func (f *fakeRuntime) Prompt(ctx context.Context, p sdk.PromptRequest) (sdk.PromptResponse, error) {
	<-f.ready
	// The person's words are the last text: ours (a preface, the brief) go before them.
	text := ""
	var before []string
	for _, b := range p.Prompt {
		if b.Text != nil {
			if text != "" {
				before = append(before, text)
			}
			text = b.Text.Text
		}
	}
	say := func(s string) {
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.UpdateAgentMessageText(s)})
	}
	// What it was told besides the words: its system prompt and what came before them.
	if strings.Contains(text, "say your brief") {
		say("System: " + f.systemPrompt + "\nBefore: " + strings.Join(before, "\n"))
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	// An agent on an org account (#999): it calls the model with what its environment
	// holds (the relay's address, a stand-in and the relay's CA), then prints that
	// environment, as an agent that runs env would.
	if strings.Contains(text, "call the model") {
		say("The model said " + callTheModel() + ".\nMy environment:\n" + strings.Join(os.Environ(), "\n"))
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	// A token split over two chunks, and a last word held back to the turn's end (#1001).
	if strings.Contains(text, "split a token") {
		token := "ghp_" + strings.Repeat("a1B2", 9)
		say("Your token is " + token[:10])
		say(token[10:] + " so keep it. Done")
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	// Deaf to session/cancel, as Claude was waiting on CI (#1611): only a SIGTERM ends it.
	if strings.Contains(text, "keep going") {
		select {}
	}
	if strings.Contains(text, "wait for me") {
		<-ctx.Done()
		return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
	}
	// A pause before ending the turn, so a test can open an event wait on this agent
	// first, as joining a lease's line does mid-turn (#2911).
	if strings.Contains(text, "line for a lease") {
		time.Sleep(300 * time.Millisecond)
		say("Waiting for the build lease.")
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	// Refused once for too many requests, then answered.
	if strings.Contains(text, "rate limit me") {
		if !f.rateLimited {
			f.rateLimited = true
			return sdk.PromptResponse{}, &sdk.RequestError{Code: 429, Message: "Too many requests"}
		}
		say("Answered at last.")
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	// Claude's plan window says spent, and the refusal comes typed beside end_turn (052).
	if strings.Contains(text, "typed limit") || strings.Contains(text, "pay extra") {
		var u sdk.SessionUpdate
		w := fmt.Sprintf(`{"status":"rejected","resetsAt":%d,"rateLimitType":"five_hour","utilization":1}`, time.Now().Add(3*time.Hour).Unix())
		if strings.Contains(text, "pay extra") {
			w = `{"status":"allowed","rateLimitType":"five_hour","utilization":0.4,"isUsingOverage":true}`
		}
		json.Unmarshal([]byte(`{"sessionUpdate":"usage_update","used":10,"size":100,"_meta":{"_claude/rateLimit":`+w+`}}`), &u)
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: u})
		if strings.Contains(text, "pay extra") {
			say("Done, on extra usage.")
			return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
		}
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn, Meta: map[string]any{"jetbrains": map[string]any{"air": map[string]any{
			"sessionFailure": map[string]any{"id": "f1", "category": "limit", "title": "You've hit your session limit", "actions": []any{}}}}}}, nil
	}
	if strings.Contains(text, "spend it all") {
		return sdk.PromptResponse{}, &sdk.RequestError{Code: -32603, Message: "Internal error", Data: map[string]any{"message": "Your credit balance is too low to access the API."}}
	}
	if strings.Contains(text, "sandbox fails") && !f.sandboxOff {
		// A command whose sandbox could not be set up, as Claude's Bash says it.
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.StartToolCall("call_s", "Run make",
			sdk.WithStartKind(sdk.ToolKindExecute), sdk.WithStartStatus(sdk.ToolCallStatusCompleted),
			sdk.WithStartContent([]sdk.ToolCallContent{sdk.ToolContent(sdk.TextBlock("sandbox_apply: Operation not permitted"))}))})
		say("The command could not run.")
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	if strings.Contains(text, "a form") {
		return f.form(ctx, p.SessionId, strings.Contains(text, "withdraw"), say)
	}
	f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.StartToolCall("call_1", "Write hi.txt",
		sdk.WithStartKind(sdk.ToolKindEdit), sdk.WithStartStatus(sdk.ToolCallStatusPending))})
	if strings.Contains(text, "Please ask") {
		r, _ := f.conn.RequestPermission(ctx, sdk.RequestPermissionRequest{SessionId: p.SessionId,
			ToolCall: sdk.ToolCallUpdate{ToolCallId: "call_1", Title: sdk.Ptr("Write hi.txt")},
			Options: []sdk.PermissionOption{{Kind: sdk.PermissionOptionKindAllowOnce, Name: "Allow", OptionId: "allow"},
				{Kind: sdk.PermissionOptionKindRejectOnce, Name: "Reject", OptionId: "reject"}}})
		if r.Outcome.Selected == nil || r.Outcome.Selected.OptionId != "allow" {
			say("You said no.")
			return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
		}
	}
	f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.UpdateToolCall("call_1",
		sdk.WithUpdateStatus(sdk.ToolCallStatusCompleted))})
	say("I wrote hi.txt. ")
	say("Anything else?")
	return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
}

// form asks which colour, and says what it heard; with withdraw, it asks for a page by
// its own id and takes the question down itself.
func (f *fakeRuntime) form(ctx context.Context, session sdk.SessionId, withdraw bool, say func(string)) (sdk.PromptResponse, error) {
	req := sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Mode: "form", Message: "Which colour?",
		RequestedSchema: sdk.UnstableElicitationSchema{Type: "object", Required: []string{"colour"},
			Properties: map[string]any{"colour": map[string]any{"type": "string", "enum": []string{"red", "blue"}}}}}}
	if withdraw {
		req = sdk.UnstableCreateElicitationRequest{Url: &sdk.UnstableCreateElicitationUrl{Mode: "url", Message: "Sign in",
			ElicitationId: "e1", Url: "https://example.com/sign-in"}}
		go func() {
			time.Sleep(300 * time.Millisecond)
			f.conn.UnstableCompleteElicitation(ctx, sdk.UnstableCompleteElicitationNotification{ElicitationId: "e1"})
		}()
	}
	r, err := f.conn.UnstableCreateElicitation(ctx, req)
	switch {
	case ctx.Err() != nil: // session/cancel came first
		return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
	case err != nil:
		say("No form: " + err.Error())
	case r.Accept != nil:
		say(fmt.Sprintf("You chose %v.", r.Accept.Content["colour"]))
	case r.Decline != nil:
		say("You would not say.")
	default:
		// Cancelled by a stop: session/cancel follows the answer.
		select {
		case <-ctx.Done():
			return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
		case <-time.After(300 * time.Millisecond):
		}
		say("The form was closed.")
	}
	return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
}

func fakeRuntimes(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_ACP", "1")
	old := locateFor
	locateFor = func(*runtimeDef) (string, []string, []string) { return self, nil, nil }
	t.Cleanup(func() { locateFor = old })
}

// notes collects the notifications a client hears.
func (c *conn) until(t *testing.T, what string, ok func(method string, params json.RawMessage) bool) {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != "" && ok(m.Method, m.Params) {
				return
			}
		case <-deadline:
			t.Fatalf("never heard %s", what)
		}
	}
}

func ended(id wire.UUID, state wire.AgentState) func(string, json.RawMessage) bool {
	return func(method string, p json.RawMessage) bool {
		if method != "agent/changed" {
			return false
		}
		var a wire.Agent
		json.Unmarshal(p, &a)
		return a.ID == id && a.State == state
	}
}

// A whole turn: the agent starts, the runtime asks, the card is answered, the turn ends
// finished with a report from its last words, and the records on disk are today's.
func TestATurnWithACard(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	work := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work,
		"prompt": "Please ask, then write hi.txt", "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}), &id)
	var permission wire.PermissionRequest
	c.until(t, "a card", func(method string, p json.RawMessage) bool {
		var n wire.PermissionNotification
		if method == "agent/permission" && json.Unmarshal(p, &n) == nil && n.Request != nil {
			permission = *n.Request
			return true
		}
		return false
	})
	if got := d.pendingPermissions(); len(got) != 1 || got[0].ID != permission.ID {
		t.Fatalf("pending %v", got)
	}
	if a := d.Store.Agent(id); a.State != wire.AgentStateWaitingOnUser {
		t.Fatalf("state %s while asking", a.State)
	}
	c.call(t, 2, "permissions/answer", map[string]any{"permissionID": permission.ID, "optionID": "allow"})
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	a := d.Store.Agent(id)
	if a.Report == nil || a.Report.Outcome != wire.WorkOutcomeNeedsAnswer || a.Report.Message != "I wrote hi.txt." {
		t.Fatalf("report %+v", a.Report)
	}
	if a.RuntimeSessionID == nil || *a.RuntimeSessionID != "fake-session" || a.EndedReason == nil || *a.EndedReason != wire.EndedReasonEndTurn {
		t.Fatalf("%+v", a)
	}
	// The record's last line follows the agent/changed that says it ended.
	waitFor(t, "the ending recorded", func() bool { k := kinds(d, id); return len(k) > 0 && k[len(k)-1] == "stateChanged" })
	entries, _, _ := d.Store.Transcript(id, 0)
	var kinds []string
	for _, e := range entries {
		b, _ := json.Marshal(e.Kind)
		var k map[string]any
		json.Unmarshal(b, &k)
		for name := range k {
			kinds = append(kinds, name)
		}
	}
	want := "runtimeNote userMessage stateChanged toolCall permissionAsked stateChanged permissionAnswered stateChanged toolCallUpdate agentMessage agentMessage stateChanged"
	if got := strings.Join(kinds, " "); got != want {
		t.Fatalf("transcript\n got %s\nwant %s", got, want)
	}
	// The record on disk is the Swift store's: ISO dates.
	b, _ := os.ReadFile(filepath.Join(root, "agents", string(id), "agent.json"))
	var back wire.Agent
	if err := diskjson.Unmarshal(b, &back); err != nil || !strings.Contains(string(b), `"createdAt":"20`) {
		t.Fatalf("agent.json %s: %v", b, err)
	}
}

func TestStopEndsTheTurnCancelled(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	time.Sleep(200 * time.Millisecond)
	c.call(t, 2, "agents/stop", map[string]any{"agentID": id})
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if a := d.Store.Agent(id); *a.EndedReason != wire.EndedReasonCancelled {
		t.Fatalf("ended %s", *a.EndedReason)
	}
	c.call(t, 3, "agents/archive", map[string]any{"agentID": id})
	if a := d.Store.Agent(id); a.State != wire.AgentStateArchived || a.ArchivedAt == nil {
		t.Fatalf("archived %+v", a.State)
	}
}

// An admin's stop from the Console (#2435) reads as theirs, not "Stopped by you"; the
// owner's next stop is the owner's again.
func TestAnAdminsStopSaysSo(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	time.Sleep(200 * time.Millisecond)
	c.call(t, 2, "agents/stop", map[string]any{"agentID": id, "byAdmin": true})
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if a := d.Store.Agent(id); *a.EndedReason != wire.EndedReasonStoppedByAdmin {
		t.Fatalf("ended %s", *a.EndedReason)
	}
	if endedSummary[wire.EndedReasonStoppedByAdmin] != "Stopped by an admin in the Console" {
		t.Fatal(endedSummary[wire.EndedReasonStoppedByAdmin])
	}
	d.noteAdminStop(id, true)
	d.noteAdminStop(id, false)
	if d.takeAdminStop(id) {
		t.Fatal("the owner's own stop read as an admin's")
	}
}

func TestAStartInAFolderThatIsNotThere(t *testing.T) {
	_, c := start(t, t.TempDir())
	c.in <- `{"jsonrpc":"2.0","id":1,"method":"agents/start","params":{"runtimeID":"claude","cwd":"file:///no/such","prompt":"x"}}`
	for line := range c.out {
		if strings.Contains(line, `"id":1`) {
			if !strings.Contains(line, "-32004") {
				t.Fatal(line)
			}
			return
		}
	}
}

// A runtime with no sign-in ends the turn as not signed in, not as a crash, and its
// account says so (#1430).
func TestAStartWithNoSignIn(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := filepath.Join(t.TempDir(), "signedout")
	os.Mkdir(folder, 0o755)
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "cursor", "cwd": "file://" + folder, "prompt": "hi"}), &id)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if a := d.Store.Agent(id); a.EndedReason == nil || *a.EndedReason != wire.EndedReasonSignInRefused {
		t.Fatalf("%+v", a.EndedReason)
	}
	entries, _, _ := d.Store.Transcript(id, 0)
	said := false
	for _, e := range entries {
		said = said || e.Kind.Notice != nil && e.Kind.Notice.Value.Title == "Cursor is not signed in"
	}
	if !said {
		t.Fatal(kinds(d, id))
	}
	for _, a := range d.runtimeAccounts() {
		if a.RuntimeID == "cursor" && a.State != wire.RuntimeAccountStateNeedsSignIn {
			t.Fatal(a.State)
		}
	}
}

// Antigravity gets its own home in the root and the switches Swift gave it (049 D8).
func TestAntigravityLaunchesInItsOwnHome(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("GEMINI_API_KEY", "not-for-antigravity")
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	l, err := d.launchFor(runtimeByID("antigravity"), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	env := strings.Join(l.Env, "\n")
	for _, want := range []string{"GEMINI_HOME=" + filepath.Join(root, "runtimes", "antigravity", "home"),
		"AGY_ACP_DISABLE_WORKSPACE_TRUST=1", "AGY_ACP_FORCE_FILE_STORAGE=1"} {
		if !strings.Contains(env, want) {
			t.Fatalf("no %s in\n%s", want, env)
		}
	}
	if strings.Contains(env, "GEMINI_API_KEY") {
		t.Fatal(env)
	}
}

func TestRuntimesList(t *testing.T) {
	_, c := start(t, t.TempDir())
	var rs []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 1, "runtimes/list", nil), &rs)
	if len(rs) != 7 || rs[0].Runtime.ID != "antigravity" {
		t.Fatalf("%d runtimes, first %v", len(rs), rs)
	}
	for _, r := range rs {
		if r.Availability.Available == nil && r.Availability.Missing == nil {
			t.Fatalf("%s has no availability", r.Runtime.ID)
		}
	}
}

func TestAToolCallIsRecordedAsSwiftRecordsIt(t *testing.T) {
	tc := toolCall(sdk.SessionToolCallUpdate{ToolCallId: "c1", Status: sdk.Ptr(sdk.ToolCallStatusCompleted),
		RawOutput: map[string]any{"ok": true}, Meta: map[string]any{"x": 1}})
	if tc.Title != "Tool call" || *tc.ToolCallID != "c1" || *tc.Status != "completed" || string(tc.RawOutput) != `{"ok":true}` {
		t.Fatalf("%+v", tc)
	}
	if strings.Contains(string(tc.Raw), "rawOutput") || strings.Contains(string(tc.Raw), "_meta") || !strings.Contains(string(tc.Raw), "toolCallId") {
		t.Fatalf("raw %s", tc.Raw)
	}
	kind := toolCall(sdk.SessionToolCallUpdate{ToolCallId: "c2", Kind: sdk.Ptr(sdk.ToolKindEdit)})
	if kind.Title != "edit" {
		t.Fatalf("title %q", kind.Title)
	}
}

// callTheModel is the fake runtime's model request: to ANTHROPIC_BASE_URL with
// ANTHROPIC_AUTH_TOKEN, trusting NODE_EXTRA_CA_CERTS, as Claude Code does.
func callTheModel() string {
	pool := x509.NewCertPool()
	if ca, err := os.ReadFile(os.Getenv("NODE_EXTRA_CA_CERTS")); err == nil {
		pool.AppendCertsFromPEM(ca)
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}, Timeout: 10 * time.Second}
	req, err := http.NewRequest("POST", os.Getenv("ANTHROPIC_BASE_URL")+"/v1/messages", strings.NewReader(`{"model":"claude","messages":[]}`))
	if err != nil {
		return err.Error()
	}
	req.Header.Set("Authorization", "Bearer "+os.Getenv("ANTHROPIC_AUTH_TOKEN"))
	resp, err := client.Do(req)
	if err != nil {
		return err.Error()
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return strconv.Itoa(resp.StatusCode)
}
