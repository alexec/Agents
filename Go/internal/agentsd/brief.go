package agentsd

import (
	"os"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The brief (#1801): what every agent is told once, before its first turn, that it cannot
// work out from its tools. A tool description is read only when an agent goes looking; a
// prompt is read every time. It went with the Swift daemon (#1370) and comes back here.
// The rest of the old Briefing.swift (who is who, asking, workflows, helpers, sessions,
// worktrees, live documents, the persona) is #1806.
//
// It is said once per conversation: it stays in the runtime's own history, which the
// runtime replays when the conversation is picked back up. A runtime in
// systemPromptDelivery has it as its system prompt, on session/new, load and resume (#1080),
// so its first prompt, and the title it makes from it, is the person's words alone. The
// others have it before the person's words in the first prompt of a new conversation
// (#763). A writer (purpose, #858) has none: its prompt is its whole brief.

// eventsBrief is EventWords.briefing (042): wait rather than poll.
const eventsBrief = "Wait for something to happen (checks passing, an agent finishing, this Mac waking) " +
	"with wait_for_event, not repeated checks. If told you are still waiting, you may " +
	"end your turn; you will be started again when it happens."

// leasesBrief is LeaseWords.briefing (036 FR-015).
const leasesBrief = "Lease a shared resource with lease_resource before using it and release_resource " +
	"the moment you are done. Keep leases short and extend them, and take several in the " +
	"same order every time. A simulator, a browser and the screen (mouse, keyboard, front " +
	"window) are for one agent at a time. If told you are in line, you may end your turn; " +
	"you will be started again when it is yours."

// endingBrief names the three ways a turn ends (#1801). Without it an agent learnt about
// archiving only from archive_session's description, and one that had finished with
// nothing for the person stopped and left an unread row.
func endingBrief(runtimeID string) string {
	ask := "ask_form"
	if own := escalationTools[runtimeID]; own != "" {
		ask = own + " (or ask_form if you lack it)"
	}
	return "End each turn in one of three ways. If you cannot continue without me, ask me with " +
		ask + ", or end the turn stuck or blocked. If you are done and have something for me " +
		"(a report, a document, a diagram), call show_file on it once and end the turn; do not " +
		"archive. If you are done and have nothing for me, clean up, then call archive_session " +
		"with no id."
}

// systemPromptDelivery is RuntimeCatalog's: how a runtime takes words of ours as its system
// prompt. "append" is _meta.systemPrompt.append (Claude's adapter gives it to the Agent
// SDK's preset prompt); "rules" is _meta.rules (Grok). Cursor and Gemini have no append
// (Gemini's GEMINI_SYSTEM_MD replaces its own prompt), so they have it in the first prompt.
// A runtime that gains an append comes here.
var systemPromptDelivery = map[string]string{"claude": "append", "grok": "rules"}

// brief is the whole of it for an agent on runtimeID, with what the person declared on
// this machine joined to the lease paragraph (#116, #599).
func (d *Daemon) brief(runtimeID string) string {
	return strings.Join([]string{leasesWithDeclared(d.declaredResources()), eventsBrief, endingBrief(runtimeID)}, "\n\n")
}

// briefFor is the brief for this agent, "" for a writer.
func (d *Daemon) briefFor(a *wire.Agent) string {
	if a.Purpose != nil {
		return ""
	}
	return d.brief(a.RuntimeID)
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
	how := systemPromptDelivery[runtimeID]
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
	}
	return out
}
