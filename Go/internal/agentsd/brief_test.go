package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/store"

	"github.com/alexec/agents/Go/wire"
)

// The three endings name the runtime's own question tool where the app knows it, and
// ask_question always.
func TestTheEndingBriefNamesTheThreeEndings(t *testing.T) {
	for runtimeID, ask := range map[string]string{"claude": "AskUserQuestion (or ask_question if you lack it)", "grok": "with ask_question."} {
		got := endingBrief(runtimeID)
		// Only a question needs the person (#1916): no stuck or blocked ending.
		if strings.Contains(got, "stuck") {
			t.Fatalf("%s: %q", runtimeID, got)
		}
		for _, want := range []string{ask, "as a question", "before your last paragraph", "show_file on it once", "do not archive", "suggest_next_prompt with it", "archive_session with no id"} {
			if !strings.Contains(got, want) {
				t.Fatalf("%s: %q has no %q", runtimeID, got, want)
			}
		}
	}
}

// What the person declared is said inside the lease paragraph, once.
func TestTheLeaseBriefSaysWhatWasDeclared(t *testing.T) {
	if got := leasesWithDeclared(nil); got != leasesBrief {
		t.Fatalf("%q", got)
	}
	got := leasesWithDeclared([]wire.DeclaredResource{{Name: "gpu", DisplayName: "GPU", Description: "For training.", Holders: 2}})
	if !strings.HasSuffix(got, " Also declared, each to lease whenever its description applies:\n- GPU (2 at once): For training.") {
		t.Fatalf("%q", got)
	}
}

// Claude's is _meta.systemPrompt.append, Grok's goes before its rules, Codex's uses AIR
// custom instructions, and a runtime with no system prompt has its _meta as it was.
func TestTheBriefGoesWhereTheRuntimeTakesASystemPrompt(t *testing.T) {
	claude := withSystemPrompt(sessionMeta("claude"), "claude", "words")
	if systemPromptOf(claude) != "words" || claude["claudeCode"] == nil {
		t.Fatalf("%v", claude)
	}
	grok := withSystemPrompt(map[string]any{"rules": "cards"}, "grok", "words")
	if systemPromptOf(grok) != "words\n\ncards" {
		t.Fatalf("%v", grok)
	}
	codex := withSystemPrompt(map[string]any{"jetbrains": map[string]any{"air": map[string]any{"version": 1, "capabilities": []string{"sessionFailure"}}}}, "codex", "words")
	air := codex["jetbrains"].(map[string]any)["air"].(map[string]any)
	if air["customInstructions"] != "words" || len(air["capabilities"].([]string)) != 1 || systemPromptOf(codex) != "words" {
		t.Fatalf("%v", codex)
	}
	if m := withSystemPrompt(nil, "cursor", "words"); m != nil {
		t.Fatalf("%v", m)
	}
}

// OpenCode's brief is a file in the agent's own folder, added to the instructions of the
// configuration the app gives it, and only the brief's words are in the file (#2612).
func TestOpenCodeHasTheBriefAsAnInstructionsFile(t *testing.T) {
	folder := t.TempDir()
	l := withToolPolicy(acp.Launch{Env: []string{"HOME=/h"}}, "opencode")
	l, err := withBriefFile(l, "opencode", folder, "words")
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(folder, briefFileName)
	if b, _ := os.ReadFile(file); string(b) != "words\n" {
		t.Fatalf("%q", b)
	}
	var config map[string]any
	for _, kv := range l.Env {
		if v, ok := strings.CutPrefix(kv, "OPENCODE_CONFIG_CONTENT="); ok {
			json.Unmarshal([]byte(v), &config)
		}
	}
	if got, _ := config["instructions"].([]any); len(got) != 1 || got[0] != file || config["share"] != "disabled" {
		t.Fatalf("%v", config)
	}
	if again, _ := withBriefFile(acp.Launch{Env: []string{"HOME=/h"}}, "cursor", folder, "words"); len(again.Env) != 1 {
		t.Fatalf("%v", again.Env)
	}
}

func agentMessages(d *Daemon, id wire.UUID) string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if e.Kind.AgentMessage != nil {
			out = append(out, e.Kind.AgentMessage.Text)
		}
	}
	return strings.Join(out, "")
}

// Each runtime has the brief the way it takes one: Claude as _meta.systemPrompt.append,
// Grok as _meta.rules, Codex as session custom instructions, OpenCode as a file of its own
// named in its configuration, and the rest before the first prompt. The transcript records only the person's words.
func TestEachRuntimeHasTheBriefTheWayItTakesIt(t *testing.T) {
	fakeRuntimes(t)
	for _, rt := range catalog {
		t.Run(rt.ID, func(t *testing.T) {
			d, c := start(t, t.TempDir())
			defer d.Shutdown()
			os.WriteFile(d.resourcesFile(), []byte(`[{"name":"gpu","displayName":"GPU","description":"For training.","holders":1}]`), 0o644)
			var id wire.UUID
			json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": rt.ID, "cwd": "file://" + t.TempDir(), "prompt": "say your brief"}), &id)
			c.until(t, "the end", ended(id, wire.AgentStateFinished))
			brief := d.brief(d.Store.Agent(id))
			if !strings.Contains(brief, "You are "+rt.Name+"; I am ") || !strings.Contains(brief, "- GPU (one at a time): For training.") {
				t.Fatalf("brief %q", brief)
			}
			system, before := "", brief
			switch rt.ID {
			case "claude":
				system, before = brief, ""
			case "grok":
				system, before = brief+"\n\n"+grokRules(), ""
			case "codex", "opencode":
				system, before = brief, ""
			}
			if said := agentMessages(d, id); said != "System: "+system+"\nBefore: "+before {
				t.Fatalf("said %q", said)
			}
			if u := userMessages(d, id); len(u) != 1 || u[0] != "say your brief" {
				t.Fatalf("%v", u)
			}
		})
	}
}

// A runtime with no system prompt has the brief before the words of its first prompt, and
// not again.
func TestCursorHasTheBriefInItsFirstPromptOnly(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "cursor", "cwd": "file://" + t.TempDir(), "prompt": "say your brief"}), &id)
	c.until(t, "the first end", ended(id, wire.AgentStateFinished))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "say your brief again", "from": "person"})
	waitFor(t, "the second answer", func() bool { return strings.Count(agentMessages(d, id), "System: ") == 2 })
	if said := agentMessages(d, id); !strings.HasSuffix(said, "System: \nBefore: ") {
		t.Fatalf("said %q", said)
	}
}

// What the person changed on a live page is told before the words of the agent's next
// prompt, once.
func TestAPageEditIsToldOnTheNextTurn(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	work := t.TempDir()
	id := startAgent(t, c, 1, work, "hi")
	c.until(t, "the first end", ended(id, wire.AgentStateFinished))
	page := filepath.Join(work, "plan.md")
	os.WriteFile(page, []byte("# Plan\n\nStep one."), 0o644)
	c.call(t, 2, "artifact/write", map[string]any{"agentID": id, "path": page, "text": "# Plan\n\nStep one, as I put it."})
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": id, "text": "say your brief", "from": "person"})
	waitFor(t, "the answer", func() bool { return strings.Contains(agentMessages(d, id), "Before: ") })
	if said := agentMessages(d, id); !strings.Contains(said, "Before: Since your last turn I edited `"+page+"`. Lines 3–3 now read:\n\n```\nStep one, as I put it.\n```") {
		t.Fatalf("said %q", said)
	}
	if d.pageEdits.take(id) != "" {
		t.Fatal("told twice")
	}
}

// Who is who: the runtime's name, the person's from person.json, their pronouns or "they",
// and for a helper the title of the agent that started it (#121, #335).
func TestTheBriefSaysWhoIsWho(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	title := "Login redirect"
	parent := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Title = &title })
	os.MkdirAll(d.SettingsDir, 0o700)
	os.WriteFile(filepath.Join(d.SettingsDir, "person.json"), []byte(`{"name":"Sam","pronouns":" she/her "}`), 0o644)
	helper := wire.Agent{RuntimeID: "grok", StartedByAgent: &parent.ID}
	got := d.namingBrief(&helper)
	for _, want := range []string{"You are Grok, started by “Login redirect”; I am Sam.", "\"Grok (this agent) will…\"",
		"\"Sam, do you want…?\"", "refer to me by name or as she/her."} {
		if !strings.Contains(got, want) {
			t.Fatalf("%q has no %q", got, want)
		}
	}
	os.WriteFile(filepath.Join(d.SettingsDir, "person.json"), []byte(`{"name":"Sam"}`), 0o644)
	if got := d.namingBrief(&wire.Agent{RuntimeID: "claude"}); !strings.HasPrefix(got, "You are Claude; I am Sam.") || !strings.HasSuffix(got, `or as "they".`) {
		t.Fatal(got)
	}
}

// Asking names the runtime's own question tool where the app keeps one, and says what is
// decided and told (#601, #1083).
func TestTheBriefSaysWhatToAskAndWhatToDecide(t *testing.T) {
	if got := escalationBrief("cursor"); !strings.Contains(got, "ask me with AskQuestion (or ask_question if you lack it) rather than guessing") ||
		!strings.Contains(got, "write `Decided: <what>, because <why>.`") {
		t.Fatal(got)
	}
	// A choice the task says is the person's is asked, also when it is easy to undo (#3699).
	if got := escalationBrief("claude"); !strings.Contains(got, "a choice that I or your task say is mine") ||
		!strings.Contains(got, "Never decide and tell a choice that is mine") {
		t.Fatal(got)
	}
	// Antigravity's own tool has the app's name (#2298): said by whose it is.
	if got := escalationBrief("antigravity"); !strings.Contains(got, "ask me with your runtime's own ask_question (or the app's ask_question, from the agents server, if yours is missing) rather than guessing") {
		t.Fatal(got)
	}
	if got := escalationBrief("grok"); !strings.Contains(got, "ask me with ask_question rather than guessing") ||
		!strings.Contains(got, "Ask for a missing secret (an API key, a token) with ask_secret") {
		t.Fatal(got)
	}
}

// The workflow line forbids cron entries only where the runtime still has its scheduler.
func TestTheWorkflowBriefIsShorterWhereSchedulingIsRemoved(t *testing.T) {
	cron := "Write no cron entries"
	if strings.Contains(workflowsBrief("claude"), cron) || !strings.Contains(workflowsBrief("copilot"), cron) ||
		!strings.HasSuffix(workflowsBrief("claude"), "use manage_workflows. Create none I did not ask for.") {
		t.Fatal(workflowsBrief("claude"), workflowsBrief("copilot"))
	}
}

// Live documents, helpers, sessions and memory are told to every agent, worktrees only where
// move_worktree is offered, residue and first-prompt cards only on their runtime.
func TestTheBriefSaysTheRestWhereItApplies(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	for _, rt := range catalog {
		got := d.brief(&wire.Agent{RuntimeID: rt.ID})
		for _, want := range []string{liveDocumentBrief, helpersBrief, sessionsBrief, memoryBrief} {
			if !strings.Contains(got, want) {
				t.Fatalf("%s: no %q", rt.ID, want)
			}
		}
		if strings.Contains(got, "move_worktree") != (appToolServed("move_worktree") && runtimeCanMove(rt.ID)) {
			t.Fatalf("%s: worktrees", rt.ID)
		}
		if strings.Contains(got, "search_code_subagent") != (rt.ID == "copilot") ||
			strings.Contains(got, "Call `agents` tools directly.") != (rt.ID == "cursor") {
			t.Fatalf("%s: %q", rt.ID, got)
		}
	}
}

// toolsBriefSkips are the app's tools no brief line names, each with where an agent is told
// of it instead (#3608).
var toolsBriefSkips = map[string]string{
	"hang_up":             "voice mode's own words (agents.go)",
	"write_daily_summary": "the Daily summary workflow's prompt",
	"check_folders":       "the Daily checks workflow's prompt",
	"cancel_wait":         "every wait's answer",
	"cancel_message":      "message_session's refusal of a second message",
	"list_resources":      "lease_resource's description; the declared resources are in the brief",
}

// Every tool this host can list is named in the brief, or skipped above with a reason, so a
// new tool cannot be one an agent never hears of (#3608). The browser's own tools are named
// together as browser_*; the browser and drive_screen only where they are offered, and
// hand_to_person not on a bot's machine.
func TestTheBriefNamesEveryAppTool(t *testing.T) {
	var all []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(wire.AppTools, &all); err != nil {
		t.Fatal(err)
	}
	_, browserNames := browserTools()
	if len(browserNames) == 0 {
		t.Fatal("no browser tools")
	}
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	full := d.brief(&wire.Agent{RuntimeID: "claude"}) + "\n" + toolsBrief(true, true, false, true)
	for _, tool := range all {
		if toolsBriefSkips[tool.Name] == "" && !strings.Contains(full, tool.Name) {
			t.Errorf("the brief does not name %s: add a line to toolsBrief, or a reason to toolsBriefSkips", tool.Name)
		}
	}
	for name := range browserNames {
		if !strings.HasPrefix(name, "browser_") && !strings.Contains(full, name) {
			t.Errorf("the brief does not name %s", name)
		}
	}
	if !strings.Contains(full, "browser_* tools") {
		t.Error("the brief does not name the browser tools")
	}
	for _, c := range []struct {
		browser, screen, bot, github bool
		named, unnamed               []string
	}{
		{false, false, false, false, nil, []string{"browser_", "fill_secret", "hand_to_person", "drive_screen", "set_ci_secret", "make_app_repository", "start-a-new-app"}},
		{true, false, false, false, []string{"browser_* tools", "fill_secret", "hand_to_person", "take the browser lease themselves"}, []string{"drive_screen"}},
		{true, false, true, false, []string{"browser_* tools", "fill_secret"}, []string{"hand_to_person"}},
		{false, true, false, false, []string{"drive_screen", "takes the screen lease itself"}, []string{"browser_"}},
		{false, false, false, true, []string{"set_ci_secret", "set_ci_variable", "set_environment_gate", "make_app_repository", "start-a-new-app"}, []string{"browser_"}},
	} {
		got := toolsBrief(c.browser, c.screen, c.bot, c.github)
		for _, w := range c.named {
			if !strings.Contains(got, w) {
				t.Errorf("%+v: no %q in %q", c, w, got)
			}
		}
		for _, w := range c.unnamed {
			if strings.Contains(got, w) {
				t.Errorf("%+v: %q in %q", c, w, got)
			}
		}
	}
}

// #3712: the brief's start-a-new-app is a ready-made skill, so every person has it, and
// it names only app tools that this host serves.
func TestTheNewAppSkillIsReadyMade(t *testing.T) {
	const id = "start-a-new-app"
	found := false
	for _, s := range readyMadeSkillIDs() {
		found = found || s == id
	}
	if !found {
		t.Fatalf("%s is not a ready-made skill: %v", id, readyMadeSkillIDs())
	}
	skill, err := readyMadeSkillsFS.ReadFile("readymadeskills/" + id + "/SKILL.md")
	if err != nil || !strings.HasPrefix(string(skill), "---\nname: "+id+"\n") {
		t.Fatalf("its SKILL.md does not start with its name: %v", err)
	}
	for _, tool := range []string{"make_app_repository", "set_environment_gate", "set_ci_secret", "set_ci_variable", "ask_secret", "ask_question", "wait_for_event", "start_session"} {
		if !strings.Contains(string(skill), "`"+tool+"`") {
			t.Errorf("the skill does not name %s", tool)
		}
		if !appToolServed(tool) {
			t.Errorf("the skill names %s, which this host does not serve", tool)
		}
	}
}

// The persona's prompt follows the brief: the folder's before the person's, its front
// matter left out, none for a persona that is not there or an id that is a path (#760).
func TestThePersonasPromptFollowsTheBrief(t *testing.T) {
	folder, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	write := func(base, id, text string) {
		os.MkdirAll(filepath.Join(base, ".agents", "personas"), 0o755)
		os.WriteFile(filepath.Join(base, ".agents", "personas", id+".md"), []byte(text), 0o644)
	}
	write(folder, "reviewer", "---\nname: Reviewer\nmodel: x\n---\n\nReview as a sceptic.\n")
	write(home, "reviewer", "The person's own.")
	write(home, "writer", "Write plainly.")
	write(folder, "broken", "---\nname: Broken\n")
	persona := func(id string) string {
		return personaPrompt(&wire.Agent{Cwd: store.FolderURL(folder), Persona: &id})
	}
	if persona("reviewer") != "Review as a sceptic." || persona("writer") != "Write plainly." ||
		persona("broken") != "" || persona("nobody") != "" || persona("../reviewer") != "" {
		t.Fatal(persona("reviewer"), persona("writer"), persona("broken"))
	}
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	id := "reviewer"
	if got := d.brief(&wire.Agent{RuntimeID: "claude", Cwd: store.FolderURL(folder), Persona: &id}); !strings.HasSuffix(got, "\n\nReview as a sceptic.") {
		t.Fatal(got)
	}
}

// Grok's rules write out each tool this host offers it, under the name Grok calls, with
// required arguments first (AppToolPreface).
func TestGroksRulesWriteOutTheAppsTools(t *testing.T) {
	rules := grokRules()
	if !strings.HasPrefix(rules, "These tools are fully specified.") || !strings.Contains(rules, "agents__show_file — ") ||
		!strings.Contains(rules, "agents__ask_question — ") || strings.Contains(rules, "agents__move_worktree") {
		t.Fatal(rules)
	}
	if m := sessionMeta("grok"); m["rules"] != rules {
		t.Fatalf("%v", m)
	}
	got := toolFields(map[string]any{"required": []any{"b"}, "properties": map[string]any{
		"a": map[string]any{"type": "integer", "minimum": 1.0, "maximum": 5.0},
		"b": map[string]any{"type": "string", "enum": []any{"x", "y"}, "description": " Which. "}}}, "  ", 0)
	if got != "  b: string, required, one of x, y. Which.\n  a: integer, 1...5" {
		t.Fatalf("%q", got)
	}
}

// A session started as a persona keeps it, and has its prompt at the end of its brief.
func TestASessionStartedAsAPersonaHasItsPrompt(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	work := t.TempDir()
	os.MkdirAll(filepath.Join(work, ".agents", "personas"), 0o755)
	os.WriteFile(filepath.Join(work, ".agents", "personas", "pirate.md"), []byte("---\nname: Pirate\n---\n\nSay ARRR.\n"), 0o644)
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work, "prompt": "say your brief", "persona": "pirate"}), &id)
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	if a := d.Store.Agent(id); a.Persona == nil || *a.Persona != "pirate" {
		t.Fatalf("%v", a.Persona)
	}
	if said := agentMessages(d, id); !strings.HasSuffix(said, "\n\nSay ARRR.\nBefore: ") {
		t.Fatalf("said %q", said)
	}
}

// Words sent from voice mode have the voice-mode text before them, and the next words
// sent without the flag do not (#2322).
func TestVoiceModeTextGoesBeforeTheWords(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := startAgent(t, c, 1, t.TempDir(), "hi")
	c.until(t, "the first end", ended(id, wire.AgentStateFinished))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "say your brief", "from": "person", "voice": true})
	waitFor(t, "the answer", func() bool { return strings.Count(agentMessages(d, id), "Before: ") == 1 })
	if said := agentMessages(d, id); !strings.HasSuffix(said, "Before: "+voicePreface) {
		t.Fatalf("said %q", said)
	}
	if u := userMessages(d, id); u[len(u)-1] != "say your brief" {
		t.Fatalf("the person's words %q", u)
	}
	c.until(t, "the second end", ended(id, wire.AgentStateFinished))
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": id, "text": "say your brief", "from": "person"})
	waitFor(t, "the second answer", func() bool { return strings.Count(agentMessages(d, id), "Before: ") == 2 })
	if said := agentMessages(d, id); !strings.HasSuffix(said, "Before: ") {
		t.Fatalf("said %q", said)
	}
}
