package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The brief (#1801): what every agent is told once, before its first turn, that it cannot
// work out from its tools. A tool description is read only when an agent goes looking; a
// prompt is read every time. It went with the Swift daemon (#1370) and comes back here.
// The rest of the old Briefing.swift, its standing words and AppToolPreface came back
// with #1806.
//
// The runtime keeps the brief in the conversation and replays it when the person picks up
// that conversation. If the runtime advertises the ACP session system-prompt capability,
// the daemon sends the brief outside the first user prompt on new, load, resume and fork.
// Otherwise, a compatibility adapter may do this. Other runtimes get it before the
// person's words in the first prompt of a new conversation (#763). A writer (purpose,
// #858) has no brief: its prompt is its whole brief.

// eventsBrief is EventWords.briefing (042): wait rather than poll.
const eventsBrief = "Wait for an event (checks passing, this Mac waking) with wait_for_event, for sessions " +
	"with wait_for_agents, and to resume at a time with check_again, not repeated checks. " +
	"If told you are still waiting, you may end your turn; you will be started again when it happens."

// leasesBrief is LeaseWords.briefing (036 FR-015).
const leasesBrief = "Lease a shared resource with lease_resource before using it and release_resource " +
	"the moment you are done. Keep leases short and extend them, and take several in the " +
	"same order every time. A simulator, a browser and the screen (mouse, keyboard, front " +
	"window) are for one agent at a time. If told you are in line, end your turn: a " +
	"lease.granted event starts you again when it is yours."

// endingBrief names the three ways a turn ends (#1801). Without it an agent learnt about
// archiving only from archive_session's description, and one that had finished with
// nothing for the person stopped and left an unread row. suggest_next_prompt is named here
// too (#2171): Claude defers MCP tools, so its description alone was never read.
func endingBrief(runtimeID string) string {
	ask := askToolWords(runtimeID)
	// Only a question puts a turn in Needs you (#1916), so one that needs the person asks; and
	// a question quoted in a report goes before its last paragraph, or it reads as asked.
	return "End each turn in one of three ways. If you cannot continue without me, ask me: say " +
		"what you need, as a question, with " + ask + ". End your last message with a question " +
		"only when you ask me one; put any other question, such as an issue's open questions, " +
		"before your last paragraph. If you are done and have something for me " +
		"(a report, a document, a diagram), call show_file on it once and end the turn; do not " +
		"archive. When such a turn, or a done reply, leaves one clear next step for me, call " +
		"suggest_next_prompt with it before you end the turn; not with a question waiting, nor " +
		"when you archive. If you are done and have nothing for me, clean up, then call " +
		"archive_session with no id."
}

// compatibilitySystemPromptDelivery describes runtime-specific fallback routes, used only
// when initialize does not advertise ACP's session system-prompt capability. Codex ACP 2.2.2
// reads customInstructions from JetBrains AIR metadata. Antigravity 1.4.5 advertises its own
// route in initialize, which acp reads like the standard one (#2613). Cursor has no
// fallback.
var compatibilitySystemPromptDelivery = map[string]string{"claude": "append", "grok": "rules", "codex": "customInstructions"}

// brief is the whole of it for an agent, in the order it is said: who is who first, since
// the paragraphs after it say "I" and "me" and that is the person it names; then the three
// of #1801; then the rest of Briefing.lines(for:), the ones that depend on the runtime
// last; then the persona the agent was started as (#760), standing context like the rest.
func (d *Daemon) brief(a *wire.Agent) string {
	parts := []string{d.namingBrief(a), leasesWithDeclared(d.declaredResources()), eventsBrief,
		endingBrief(a.RuntimeID), liveDocumentBrief, escalationBrief(a.RuntimeID),
		workflowsBrief(a.RuntimeID), helpersBrief, sessionsBrief}
	if appToolServed("move_worktree") && runtimeCanMove(a.RuntimeID) {
		parts = append(parts, worktreesBrief)
	}
	if r := residueBrief[a.RuntimeID]; r != "" {
		parts = append(parts, r)
	}
	if c := firstPromptCards[a.RuntimeID]; c != "" {
		parts = append(parts, c)
	}
	if p := personaPrompt(a); p != "" {
		parts = append(parts, p)
	}
	return strings.Join(parts, "\n\n")
}

// briefFor is the brief for this agent, "" for a writer.
func (d *Daemon) briefFor(a *wire.Agent) string {
	if a.Purpose != nil {
		return ""
	}
	return d.brief(a)
}

// namingBrief is Briefing.naming (#121, #335): names instead of "I" and "you". A question
// card read on a phone beside other agents' cards cannot say who "I" is, so the agent is
// told its own name and the person's and uses them in questions; in its own conversation
// "I" and "you" are plain. Pronouns are the person's to give: where they gave none, "they",
// never a guess. A helper is told who started it, by title.
func (d *Daemon) namingBrief(a *wire.Agent) string {
	runtime, you := runtimeName(a.RuntimeID), runtimeName(a.RuntimeID)
	if a.StartedByAgent != nil {
		var title *string
		if starter := d.Store.Agent(*a.StartedByAgent); starter != nil {
			title = starter.Title
		}
		you += ", started by " + agentName(title)
	}
	person := readPerson(filepath.Join(d.SettingsDir, "person.json"))
	name, refer := personName(person.Name), `as "they"`
	if person.Pronouns != nil && strings.TrimSpace(*person.Pronouns) != "" {
		refer = "as " + strings.TrimSpace(*person.Pronouns)
	}
	return "You are " + you + "; I am " + name + ". In a question to me (a form card, a turn " +
		"ending on my answer, a question in a reply), write \"" + runtime + " (this agent) will…\" " +
		"and \"" + name + ", do you want…?\", never a bare \"I\" or \"you\". Elsewhere, plain \"I\" " +
		"and \"you\" are fine. Name other agents by their title; refer to me by name or " + refer + "."
}

// personName is PersonSettings.effectiveName: the name set, else the first name of this
// account, else "the person".
func personName(set *string) string {
	if set != nil && strings.TrimSpace(*set) != "" {
		return strings.TrimSpace(*set)
	}
	if u, err := user.Current(); err == nil {
		if f := strings.Fields(u.Name); len(f) > 0 {
			return f[0]
		}
	}
	return "the person"
}

// liveDocumentBrief is Briefing.liveDocument (022): from show_file's description alone,
// neither Claude nor Grok called it. It names what counts (#1057): what the person asked
// for, not a change's files.
const liveDocumentBrief = "Before first writing a Markdown report, plan or spec I asked for, call " +
	"show_file on it once."

// askToolWords names the tool to ask the person with: the runtime's own where the app keeps
// one, and the app's ask_question for the rest. Antigravity's own tool has the app's name
// too (#2298), so the two are told apart by whose they are, not by the name.
func askToolWords(runtimeID string) string {
	own := escalationTools[runtimeID]
	switch {
	case own == "":
		return "ask_question"
	case own == "ask_question":
		return "your runtime's own ask_question (or the app's ask_question, from the agents server, if yours is missing)"
	}
	return own + " (or ask_question if you lack it)"
}

// escalationBrief is Briefing.escalation: what is the person's to decide, asked with the
// runtime's own question tool where the app keeps one, and decide-and-tell for the rest
// (#601, #1083). Of 196 forms answered by 2026-10-15, 79% of questions took the
// recommended option, and agents waited 65 hours on them. A secret has a tool of its own,
// so its value stays out of the chat (#2885).
func escalationBrief(runtimeID string) string {
	named := askToolWords(runtimeID)
	return "When something is mine to decide (anything hard to undo, money or an outside " +
		"account, a restart or an install on my devices, a missing credential, a choice with " +
		"no clear best answer), ask me with " + named + " rather than guessing or asking in your " +
		"reply. That question reaches me anywhere and waits for me; a question inside a reply " +
		"may go unread. Any other choice, scope or design included, whose answer you would mark " +
		"recommended and is easy to undo: take it, write `Decided: <what>, because <why>.` (I can " +
		"overrule it) in the issue or pull request and in your reply, and carry on. Do not ask " +
		"about the next step of what I asked for, a report with nothing to choose, anything you " +
		"can find out yourself, or the same thing twice. Ask for a missing secret (an API key, a " +
		"token) with ask_secret, never in a question or a reply, where what is typed goes into the chat."
}

// schedulingRemoved is the runtimes whose own scheduling tools the tool policy takes away
// (runtimes.go): Claude's Cron tools, Grok's scheduler and Codex's automations. They are
// not told not to use what they no longer have (015).
var schedulingRemoved = map[string]bool{"claude": true, "grok": true, "codex": true}

// workflowsBrief is Briefing.workflows: standing arrangements are the app's, and an agent
// told it can schedule things will, so only when asked.
func workflowsBrief(runtimeID string) string {
	restraint := "Write no cron entries, launch agents or scripts that nothing will run. "
	if schedulingRemoved[runtimeID] {
		restraint = ""
	}
	return "Anything I want to happen on its own (on a schedule, or when an agent finishes, " +
		"stops or asks) is a workflow: use manage_workflows. " + restraint + "Create none I did not ask for."
}

// helpersBrief is Briefing.helpers (028, #940): every agent is told, a helper too, with the
// limits said before the first call rather than learnt from a refusal.
const helpersBrief = "For work that can run alongside yours, use start_session within my limits " +
	"on how many may run and be kept. Stop the sessions you started when they are done, and " +
	"archive them once their work is merged or abandoned. Do not start one for work you could " +
	"simply do yourself."

// sessionsBrief is Briefing.sessions (065): the person says "continue Login redirect" to
// whichever chat they opened. Archiving this session is in endingBrief now.
const sessionsBrief = "To continue another session in this folder, read it with read_session " +
	"(by id or exact title; reading changes nothing). list_sessions lists them."

// worktreesBrief is Briefing.worktrees (#615): with move_worktree only described, agents
// ran git worktree add and the app showed them in the wrong folder. Said only where the
// tool is offered.
const worktreesBrief = "For a branch of your own, move into a worktree with move_worktree and " +
	"end your turn; you are started again there. Never edit in a worktree you did not move " +
	"into this way, nor make one with `git worktree add` when it can."

// residueBrief is Briefing.residue: a runtime's tool the tool policy could not take away,
// said out loud (ToolPolicyCatalog). Copilot's search_code_subagent rejected every spelling
// tried for --excluded-tools.
var residueBrief = map[string]string{
	"copilot": "`search_code_subagent` does not work in this app. For another agent, use start_session.",
}

// firstPromptCards is AppToolPreface.firstPrompt: Cursor has the app's tools from the
// agents server itself and only needs pointing at them.
var firstPromptCards = map[string]string{"cursor": "Call `agents` tools directly."}

// appToolServed is whether this host serves an app tool, so the brief names none it lacks.
func appToolServed(name string) bool {
	for _, t := range appToolCalls() {
		if t.name == name {
			return true
		}
	}
	return false
}

// personaPrompt is the prompt of the persona the agent was started as (#760): the folder's
// .agents/personas/<id>.md, else the person's, read now so an edit reaches the next
// conversation. None for a persona that is not there or will not parse.
func personaPrompt(a *wire.Agent) string {
	if a.Persona == nil {
		return ""
	}
	id := *a.Persona
	if id == "" || strings.Contains(id, "/") || strings.HasPrefix(id, ".") {
		return ""
	}
	for _, from := range []struct{ base, origin string }{{folderPath(a), "folder"}, {personaHome(), "personal"}} {
		if from.base == "" {
			continue
		}
		b, ok := regularFileBytes(filepath.Join(from.base, ".agents", "personas", id+".md"))
		if !ok {
			continue
		}
		if parsePersona(string(b), id, from.origin).Problem != nil {
			return ""
		}
		return strings.TrimSpace(stripFrontMatter(string(b)))
	}
	return ""
}

// grokRules is AppToolPreface.rules: Grok puts an MCP server's tools behind search_tool and
// will not call one before a search returns its schema, so the app's tools waited on a search
// that often never came. Its _meta.rules is appended to its system prompt; these are the
// tools this host offers it, under the names Grok calls.
func grokRules() string {
	var cards []string
	// Written once, for every host (#3004): never claims drive_screen, since whether this
	// one host has agents-drive beside it is not known here.
	for _, raw := range offeredTools(runtimeCanMove("grok"), false, false) {
		var t map[string]any
		if json.Unmarshal(raw, &t) != nil {
			continue
		}
		name, _ := t["name"].(string)
		if name == "" {
			continue
		}
		title, _ := t["title"].(string)
		if title == "" {
			title = name
		}
		schema, _ := t["inputSchema"].(map[string]any)
		body := toolFields(schema, "  ", 0)
		if body == "" {
			body = "  (no arguments)"
		}
		cards = append(cards, appServerName+"__"+name+" — "+title+"\n"+body)
	}
	return "These tools are fully specified. Call one with use_tool, setting tool_name to the " +
		"name given and tool_input to its arguments. Do not call search_tool for these names. " +
		"Tools from any other server still need a search.\n\n" + strings.Join(cards, "\n\n")
}

// toolFields is one line per argument, required ones first, objects and arrays of objects
// one level further, as deep as any of these schemas go.
func toolFields(schema map[string]any, indent string, depth int) string {
	required := map[string]bool{}
	if rs, ok := schema["required"].([]any); ok {
		for _, r := range rs {
			if s, ok := r.(string); ok {
				required[s] = true
			}
		}
	}
	props, _ := schema["properties"].(map[string]any)
	keys := make([]string, 0, len(props))
	for k := range props {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if required[keys[i]] != required[keys[j]] {
			return required[keys[i]]
		}
		return keys[i] < keys[j]
	})
	lines := make([]string, len(keys))
	for i, k := range keys {
		p, _ := props[k].(map[string]any)
		line := indent + k + ": " + toolFieldPhrase(p, required[k])
		if depth < 2 {
			nested := map[string]any(nil)
			switch p["type"] {
			case "object":
				nested = p
			case "array":
				if items, ok := p["items"].(map[string]any); ok && items["type"] == "object" {
					nested = items
				}
			}
			if n := toolFields(nested, indent+"  ", depth+1); nested != nil && n != "" {
				line += "\n" + n
			}
		}
		lines[i] = line
	}
	return strings.Join(lines, "\n")
}

// toolDescriptionLimit keeps a short example and keeps a catalogue pasted into a description
// out of every Grok prompt.
const toolDescriptionLimit = 700

func toolFieldPhrase(p map[string]any, required bool) string {
	kind, _ := p["type"].(string)
	if kind == "" {
		kind = "value"
	}
	parts := []string{kind}
	if required {
		parts = append(parts, "required")
	}
	if values, ok := p["enum"].([]any); ok && len(values) > 0 {
		var names []string
		for _, v := range values {
			if s, ok := v.(string); ok {
				names = append(names, s)
			}
		}
		if len(names) > 0 {
			parts = append(parts, "one of "+strings.Join(names, ", "))
		}
	}
	minimum, hasMin := p["minimum"].(float64)
	maximum, hasMax := p["maximum"].(float64)
	switch {
	case hasMin && hasMax:
		parts = append(parts, fmt.Sprintf("%d...%d", int(minimum), int(maximum)))
	case hasMin:
		parts = append(parts, fmt.Sprintf("at least %d", int(minimum)))
	}
	text := strings.Join(parts, ", ")
	if d, _ := p["description"].(string); strings.TrimSpace(d) != "" {
		d = strings.TrimSpace(d)
		if r := []rune(d); len(r) > toolDescriptionLimit {
			d = strings.TrimSpace(string(r[:toolDescriptionLimit])) + "…"
		}
		text += ". " + d
	}
	return text
}

// declaredResources is resources.json as it is on disk now, so a declaration made since the
// lease book was loaded is said too.
func (d *Daemon) declaredResources() []wire.DeclaredResource {
	var declared []wire.DeclaredResource
	if b, err := os.ReadFile(d.resourcesFile()); err == nil {
		diskjson.Unmarshal(b, &declared)
	}
	return declared
}

// leasesWithDeclared is LeaseWords.briefing(declared:): each declared resource with its
// description, and when to lease it.
func leasesWithDeclared(declared []wire.DeclaredResource) string {
	if len(declared) == 0 {
		return leasesBrief
	}
	lines := make([]string, len(declared))
	for i, r := range declared {
		lines[i] = "- " + r.DisplayName + " (" + placesWords(r.Holders) + "): " + r.Description
	}
	return leasesBrief + " Also declared, each to lease whenever its description applies:\n" + strings.Join(lines, "\n")
}

// withSystemPrompt is meta with words as the system prompt, where runtimeID takes one.
func withSystemPrompt(meta map[string]any, runtimeID, words string) map[string]any {
	how := compatibilitySystemPromptDelivery[runtimeID]
	if words == "" || how == "" {
		return meta
	}
	out := map[string]any{}
	for k, v := range meta {
		out[k] = v
	}
	switch how {
	case "append":
		out["systemPrompt"] = map[string]any{"append": words}
	case "rules":
		if rules, _ := out["rules"].(string); rules != "" {
			words += "\n\n" + rules
		}
		out["rules"] = words
	case "customInstructions":
		jetbrains, _ := out["jetbrains"].(map[string]any)
		jetbrains = cloneMeta(jetbrains)
		air, _ := jetbrains["air"].(map[string]any)
		air = cloneMeta(air)
		air["version"] = 1
		air["customInstructions"] = words
		jetbrains["air"] = air
		out["jetbrains"] = jetbrains
	}
	return out
}

func cloneMeta(meta map[string]any) map[string]any {
	copy := make(map[string]any, len(meta)+1)
	for key, value := range meta {
		copy[key] = value
	}
	return copy
}
