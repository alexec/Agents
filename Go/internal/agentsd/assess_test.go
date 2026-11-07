package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports RuntimeAssessmentTests' start and RuntimeAssessmentVerifierTests' reading: an
// assessment starts an agent labelled for it with the brief, every app tool call is kept
// as answered, and the score is taken from that record, not the agent's word.

func TestARuntimeAssessedFromTheRecord(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var started wire.AssessRuntimeResult
	json.Unmarshal(c.call(t, 2, "runtimes/assess", map[string]any{"runtimeID": "claude", "folder": "file://" + folder, "model": "default"}), &started)
	a := d.Store.Agent(started.AgentID)
	if a == nil || started.Model != nil || !strings.Contains(started.ReportPath, filepath.Join(folder, ".agents", "reviews", "runtimes", "claude-")) {
		t.Fatalf("%+v %+v", started, a)
	}
	if len(a.Labels) != 1 || a.Labels[0].Value != assessLabel {
		t.Fatalf("%+v", a.Labels)
	}
	waitFor(t, "the brief in the chat", func() bool { return len(userMessages(d, a.ID)) > 0 })
	if u := userMessages(d, a.ID); len(u) == 0 || !strings.HasPrefix(u[0], "Assess the Claude runtime (#47).") ||
		!strings.Contains(u[0], "`AskUserQuestion`") || !strings.Contains(u[0], started.ReportPath) {
		t.Fatalf("%q", u)
	}
	if _, err := os.Stat(filepath.Join(d.assessmentsPath(), string(a.ID)+".start.json")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Dir(started.ReportPath)); err != nil || !info.IsDir() {
		t.Fatal(err)
	}

	// The report shown before it is written, then written naming every step.
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	m.tool(2, "show_file", map[string]any{"path": started.ReportPath})
	m.tool(3, "lease_resource", map[string]any{"name": "assess-x", "minutes": 5})
	m.tool(4, "list_resources", map[string]any{})
	m.tool(5, "release_resource", map[string]any{"name": "assess-x"})
	var steps []string
	for _, s := range assessSteps {
		steps = append(steps, "| "+s.id+" | passed |")
	}
	os.WriteFile(started.ReportPath, []byte(strings.Join(steps, "\n")), 0o644)

	calls := d.appToolCalls(a.ID)
	if len(calls) != 4 || calls[0].Method != "files/show" || !calls[0].Ok || !strings.Contains(*calls[0].Answer, "open, empty") ||
		calls[1].Method != "resources/lease" {
		t.Fatalf("%+v", calls)
	}

	var score wire.RuntimeAssessmentScore
	json.Unmarshal(c.call(t, 3, "runtimes/assessment", map[string]any{"agentID": a.ID}), &score)
	verdicts := map[string]wire.RuntimeAssessmentCheck{}
	for _, ch := range score.Checks {
		verdicts[ch.ID] = ch
	}
	if len(score.Checks) != 16 || verdicts["show_file"].Verdict != passed || verdicts["report"].Verdict != passed ||
		verdicts["leases"].Verdict != passed || verdicts["ask_question"].Verdict != failedStep ||
		verdicts["ask_question"].Evidence != "`ask_question` never called" {
		t.Fatalf("%+v", score.Checks)
	}
	if _, err := os.Stat(filepath.Join(d.assessmentsPath(), string(a.ID)+".json")); err != nil {
		t.Fatal(err)
	}
	if note := assessNote(score); !strings.HasPrefix(note, "The app scored this assessment of claude (model ") &&
		!strings.HasPrefix(note, "The app scored this assessment of claude (on ") {
		t.Fatal(note)
	}
}

// A runtime that names its conversation after read_session (Codex, #492) still passes
// sessions: the title list_sessions gave just before the read counts (#1432).
func TestSessionsTakesTheTitleListedBeforeTheRead(t *testing.T) {
	me, now := "F19C1064-5986-4C97-B007-D8283136B992", now()
	title := "Assess Codex runtime"
	text := func(s string) *string { return &s }
	call := func(method, answer string, args map[string]json.RawMessage) appToolCall {
		return appToolCall{At: now, Method: method, Ok: true, Arguments: args, Answer: text(answer)}
	}
	r := assessRecord{agent: wire.Agent{ID: wire.UUID(me), Title: &title}, calls: []appToolCall{
		call("sessions/list", "- "+me+": “Assess the Codex runtime (#47)…” (you) — Codex, Working", nil),
		call("sessions/read", "# Session “Assess the Codex runtime (#47)…”\n\n- Id: "+me, map[string]json.RawMessage{"session": json.RawMessage(`"` + me + `"`)}),
	}}
	if v, why := r.sessions(); v != passed {
		t.Fatal(why)
	}
	r.calls[1].Answer = text("# Session “Something else”\n\n- Id: " + me)
	if v, _ := r.sessions(); v != failedStep {
		t.Fatal("a title neither listed nor current passed")
	}
}

// Every app tool is one method, `<the tool's noun, plural>/<its verb>` (#2172): a new tool
// cannot be left out, nor named after something else.
func TestEveryAppToolIsOneMethodNamedAfterIt(t *testing.T) {
	// The tools whose noun is not in their name: ask_question asks a question (#2298), and
	// cancel_wait cancels a wait for an event.
	// hang_up hangs up a voice call (#2375), notify tells the person (#2805), and bring_back
	// brings back a branch (#2947). drive_screen's noun, the screen, is singular: there is
	// one of it (#3004). write_daily_summary writes summaries (#3192), and check_folders checks the
	// quiet folders (#3355). docs_search and docs_read name their noun first, as the docs/search
	// and docs/read methods they are over (#3317). make_app_repository makes repositories, whose
	// plural is not the noun with an s (#3708).
	nouns := map[string]string{"bring_back": "branches", "notify": "people", "ask_question": "questions", "cancel_wait": "events", "wait_for_event": "events", "check_again": "waits", "hang_up": "calls", "cancel_message": "sessions", "drive_screen": "screen", "write_daily_summary": "summaries", "docs_search": "docs", "docs_read": "docs", "make_app_repository": "repositories"}
	verbs := map[string]string{"docs_search": "search", "docs_read": "read"}
	seen := map[string]string{}
	for _, tool := range appToolCalls() {
		method, ok := appToolMethods[tool.name]
		if !ok {
			t.Errorf("%s has no method", tool.name)
			continue
		}
		if other, dup := seen[method]; dup {
			t.Errorf("%s and %s are both %s", tool.name, other, method)
		}
		seen[method] = tool.name
		noun, verb, ok := strings.Cut(method, "/")
		words := strings.Split(tool.name, "_")
		toolVerb := words[0]
		if v := verbs[tool.name]; v != "" {
			toolVerb = v
		}
		if !ok || !strings.HasPrefix(strings.ToLower(verb), toolVerb) {
			t.Errorf("%s: %s does not start with the tool's verb, %s", tool.name, method, toolVerb)
		}
		want := nouns[tool.name]
		if want == "" {
			for _, w := range words[1:] {
				if plural := strings.TrimSuffix(w, "s") + "s"; plural == noun {
					want = noun
				}
			}
		}
		if noun != want {
			t.Errorf("%s: %s is not after the tool's noun", tool.name, method)
		}
	}
	if len(seen) != len(appToolMethods) {
		t.Errorf("appToolMethods has %d tools, the host serves %d", len(appToolMethods), len(seen))
	}
}

// should_ask passes only on a question the agent chose to ask before the brief told it to
// (#2416); the brief's own form and the runtime's "running unattended" question are later
// steps, and a question by the runtime's own tool counts once, for the step it came in.
func TestShouldAskCountsOnlyTheQuestionsBeforeTheBriefSaysToAsk(t *testing.T) {
	text := func(s string) *string { return &s }
	asked := func(at wire.Date, message string) wire.TranscriptEntry {
		return wire.TranscriptEntry{At: at, Kind: wire.TranscriptEntryKind{ElicitationAsked: &wire.TranscriptEntryKindElicitationAsked{
			Value: wire.ElicitationRequest{Message: text(message)}}}}
	}
	form := appToolCall{At: 20, Method: "questions/ask", Ok: true, Arguments: map[string]json.RawMessage{
		"questions": json.RawMessage(`[{"id":"pick","prompt":"Pick one","options":[{"id":"a"}]},{"id":"words","prompt":"Type any short phrase"}]`)}}
	report := "# Codex assessment\nShelf: kept\n"
	r := assessRecord{escalation: "request_user_input", calls: []appToolCall{form}, reportText: &report,
		transcript: []wire.TranscriptEntry{asked(20, "Pick one"), asked(30, "Is this assessment running unattended?")}}
	if v, why := r.shouldAsk(); v != failedStep || why != "chose without asking: \"Shelf: kept\"" {
		t.Fatal(v, why)
	}
	if v, why := r.ownAsk(); v != passed || why != "1 question reached the app through `request_user_input`" {
		t.Fatal(v, why)
	}

	r.transcript = append([]wire.TranscriptEntry{asked(10, "Which shelf?")}, r.transcript...)
	if v, why := r.shouldAsk(); v != passed || why != "asked the person with `request_user_input`" {
		t.Fatal(v, why)
	}
	if v, _ := r.ownAsk(); v != passed {
		t.Fatal("the shelf question changed own_ask")
	}

	r.calls = append([]appToolCall{{At: 10, Method: "questions/ask", Ok: true}}, r.calls...)
	if v, why := r.shouldAsk(); v != passed || why != "asked the person with the app's `ask_question`" {
		t.Fatal(v, why)
	}
}

// An agent's app tool calls go in its own folder, upper case as Delete removes it, also for
// an ID given in lower case: Linux is case-sensitive (#3651).
func TestAppToolCallsGoInTheAgentsUpperCaseFolder(t *testing.T) {
	root := t.TempDir()
	d := &Daemon{Store: &store.Store{Loc: store.Locations{Root: root}}}
	const id = "0a1b2c3d-0000-4000-8000-00000000abcd"
	d.keepAppToolCall(wire.UUID(id), "show_file", nil, "", nil, time.Now())
	if _, err := os.Stat(filepath.Join(root, "agents", strings.ToUpper(id), "app-tools.jsonl")); err != nil {
		t.Fatal(err)
	}
	if calls := d.appToolCalls(wire.UUID(strings.ToUpper(id))); len(calls) != 1 || calls[0].Method != "files/show" {
		t.Fatalf("%+v", calls)
	}
}

// ask_question is scored on the brief's form, not on should_ask's question by ask_question
// before it, and workspaces on list_machines, which says when there are no providers (#1356).
func TestAskQuestionAndWorkspacesAfterTheShelfQuestion(t *testing.T) {
	text := func(s string) *string { return &s }
	shelf := appToolCall{At: 10, Method: "questions/ask", Ok: true, Answer: text("They answered:\n- Which shelf?: kept"), Arguments: map[string]json.RawMessage{
		"questions": json.RawMessage(`[{"id":"shelf","prompt":"Which shelf?","options":[{"id":"kept"},{"id":"scratch"}]}]`)}}
	form := appToolCall{At: 20, Method: "questions/ask", Ok: true, Answer: text("They answered:\n- Pick one: Alpha\n- Type any short phrase: plum lantern 47"), Arguments: map[string]json.RawMessage{
		"questions": json.RawMessage(`[{"id":"pick","prompt":"Pick one","options":[{"id":"a"}]},{"id":"words","prompt":"Type any short phrase"}]`)}}
	machines := appToolCall{At: 5, Method: "machines/list", Ok: true, Answer: text("This control plane has no machine providers. The person adds them in Settings ▸ Machine Providers.")}
	answered := func(at wire.Date, answers ...wire.ElicitationAnswer) wire.TranscriptEntry {
		return wire.TranscriptEntry{At: at, Kind: wire.TranscriptEntryKind{ElicitationAnswered: &wire.TranscriptEntryKindElicitationAnswered{Answers: answers}}}
	}
	report := "Shelf: kept\n| ask_question | passed | plum lantern 47 |\n"
	r := assessRecord{calls: []appToolCall{machines, shelf, form}, reportText: &report, transcript: []wire.TranscriptEntry{
		answered(11, wire.ElicitationAnswer{Question: "Which shelf?", Answer: "kept"}),
		answered(21, wire.ElicitationAnswer{Question: "Pick one", Answer: "Alpha"}, wire.ElicitationAnswer{Question: "Type any short phrase", Answer: "plum lantern 47"}),
	}}
	if v, why := r.askQuestion(); v != passed {
		t.Fatal(why)
	}
	if v, why := r.workspaces(); v != passed || why != "`list_machines` answered" {
		t.Fatal(v, why)
	}
	r.calls = []appToolCall{shelf}
	if v, why := r.askQuestion(); v != failedStep || why != "`ask_question` was not asked with both a choice and a text field" {
		t.Fatal(v, why)
	}
	if v, why := r.workspaces(); v != failedStep || why != "`list_machines` never called" {
		t.Fatal(v, why)
	}
}

// One call's arguments are cut as its answer is (#3687): a long one keeps its first
// appToolAnswerMost runes as text, a short one is kept as it was, the token never.
func TestAnAppToolCallsArgumentsAreCut(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	agent := wire.UUID("6F1C6E2A-3B57-4D0E-9C61-3D8A1F0B2C11")
	long := strings.Repeat("é", appToolAnswerMost+500)
	list, _ := json.Marshal(strings.Split(strings.Repeat("x,", appToolAnswerMost), ","))
	d.keepAppToolCall(agent, "notify", map[string]json.RawMessage{
		"body": json.RawMessage(`"` + long + `"`), "ids": list, "title": json.RawMessage(`"Done"`), "token": json.RawMessage(`"t"`),
	}, "ok", nil, time.Now())
	b, err := os.ReadFile(d.appToolsPath(agent))
	if err != nil {
		t.Fatal(err)
	}
	var call appToolCall
	if err := diskjson.Unmarshal(b, &call); err != nil {
		t.Fatal(err)
	}
	if got := argString(call.Arguments, "body"); got != long[:len("é")*appToolAnswerMost] {
		t.Fatalf("body is %d runes", len([]rune(got)))
	}
	if got := argString(call.Arguments, "ids"); len([]rune(got)) != appToolAnswerMost || !strings.HasPrefix(got, `["x","x"`) {
		t.Fatalf("ids %q", got)
	}
	if string(call.Arguments["title"]) != `"Done"` || call.Arguments["token"] != nil {
		t.Fatalf("%v", call.Arguments)
	}
}

// Antigravity 1.4.5's own ask_question reaches the app as a permission card on a tool call
// named interaction_<id>, its choices the options; and its helper archives itself before
// the assessing agent asks (#1361).
func TestAntigravityQuestionCardAndASelfArchivedHelper(t *testing.T) {
	text := func(s string) *string { return &s }
	card := func(at wire.Date, id, title string) wire.TranscriptEntry {
		return wire.TranscriptEntry{At: at, Kind: wire.TranscriptEntryKind{PermissionAsked: &wire.TranscriptEntryKindPermissionAsked{
			Value: wire.PermissionRequest{ToolCall: wire.ToolCall{ToolCallID: text(id), Title: title}}}}}
	}
	form := appToolCall{At: 20, Method: "questions/ask", Ok: true, Arguments: map[string]json.RawMessage{
		"questions": json.RawMessage(`[{"id":"pick","prompt":"Pick one","options":[{"id":"a"}]},{"id":"words","prompt":"Type any short phrase"}]`)}}
	report := "Shelf: scratch\n"
	r := assessRecord{escalation: "ask_question", calls: []appToolCall{form}, reportText: &report, transcript: []wire.TranscriptEntry{
		card(10, "6476b6fab22c467db87d", "agents_show_file"),
		{At: 20, Kind: wire.TranscriptEntryKind{ElicitationAsked: &wire.TranscriptEntryKindElicitationAsked{Value: wire.ElicitationRequest{Message: text("Pick one")}}}},
		card(30, "interaction_f4066315", "Is this assessment running unattended?")}}
	if v, why := r.shouldAsk(); v != failedStep {
		t.Fatal("a tool's permission card counted as a question:", why)
	}
	if v, why := r.ownAsk(); v != passed || why != "1 question reached the app through `ask_question`" {
		t.Fatal(v, why)
	}
	r.transcript = append([]wire.TranscriptEntry{card(5, "interaction_aa", "Which shelf, kept or scratch?")}, r.transcript...)
	if v, why := r.shouldAsk(); v != passed {
		t.Fatal(v, why)
	}

	helper := wire.UUID("BF77631E-2DEE-426F-B13F-FF0656448A19")
	byAgent := wire.AgentArchivedReasonByAgent
	at := wire.Date(45)
	r = assessRecord{
		calls: []appToolCall{
			{At: 40, Method: "sessions/start", Ok: true, AgentID: &helper},
			{At: 41, Method: "sessions/list", Ok: true, Arguments: map[string]json.RawMessage{"started_by": json.RawMessage(`"me"`)}},
			{At: 50, Method: "sessions/archive", Ok: false, Answer: text("Nothing changed: “Reply with the word OK.” is already archived."),
				Arguments: map[string]json.RawMessage{"id": json.RawMessage(`"` + string(helper) + `"`)}},
		},
		helpers:    []wire.Agent{{ID: helper, RuntimeID: "antigravity", ArchivedAt: &at, ArchivedReason: &byAgent}},
		transcript: []wire.TranscriptEntry{{At: 46, Kind: wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "The wait you reported has cleared"}}}},
	}
	if v, why := r.helperSteps(); v != passed || !strings.Contains(why, "archived itself") {
		t.Fatal(v, why)
	}
	r.calls[2].Answer = text("No session with that id.")
	if v, _ := r.helperSteps(); v != failedStep {
		t.Fatal("a refused archive passed")
	}
}
