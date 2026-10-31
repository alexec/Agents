package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A sandbox that could not start (064, FR-006/007): its words in a command's output, in the
// reply of a runtime that says so there, or in the error of a runtime that fell over
// setting one up. The agent stops with the card, and agents/answerSandbox either keeps it
// stopped or turns its sandbox off and carries on.

const seatbelt = "sandbox_apply: Operation not permitted"

// sandboxFailurePatterns is SandboxCatalog's failurePatterns, and readsReply.
var sandboxFailurePatterns = map[string]struct {
	patterns   []string
	readsReply bool
}{
	"claude": {patterns: []string{"Sandbox required but unavailable", seatbelt}},
	"codex":  {patterns: []string{seatbelt, "bwrap: No permissions to create a new namespace"}, readsReply: true},
	"grok": {patterns: []string{"Refusing to start with its protections missing", "sandbox initialization failed"}},
}

const carryOnWithoutSandbox = "The command sandbox is now off. Carry on with the task."

var ansiEscape = regexp.MustCompile("\x1b\\[[0-9;]*[A-Za-z]")

// sandboxMatch is SandboxFailureDetector.match: the lines that say the sandbox failed, each
// from the sentence that says so, or "" for none.
func sandboxMatch(runtimeID, text string) string {
	patterns := sandboxFailurePatterns[runtimeID].patterns
	if len(patterns) == 0 || text == "" {
		return ""
	}
	var hits []string
	for _, line := range strings.FieldsFunc(ansiEscape.ReplaceAllString(text, ""), func(r rune) bool { return r == '\n' || r == '\r' }) {
		line = strings.Trim(line, " \t")
		for _, p := range patterns {
			if !saidUnquoted(line, p) {
				continue
			}
			hit := line
			if at := strings.Index(strings.ToLower(line), strings.ToLower(p)); at >= 0 {
				if stop := strings.LastIndex(line[:at], "."); stop >= 0 {
					hit = strings.Trim(line[stop+1:], " \t")
				}
			}
			if !slices.Contains(hits, hit) {
				hits = append(hits, hit)
			}
			break
		}
	}
	detail := strings.Join(hits, "\n")
	if utf8.RuneCountInString(detail) > 1200 {
		detail = string([]rune(detail)[:1200]) + "…"
	}
	return detail
}

// saidUnquoted is whether the line says the pattern other than straight after a quote: an
// agent quoting the words is not the sandbox failing.
func saidUnquoted(line, pattern string) bool {
	lower, p := strings.ToLower(line), strings.ToLower(pattern)
	for from := 0; ; {
		at := strings.Index(lower[from:], p)
		if at < 0 {
			return false
		}
		at += from
		if at == 0 {
			return true
		}
		before, _ := utf8.DecodeLastRuneInString(line[:at])
		if !strings.ContainsRune("\"'`“‘«", before) {
			return true
		}
		from = at + len(p)
	}
}

// turnEvidence is TurnEvidence: what the turn's commands printed, and what it replied.
type turnEvidence struct {
	outputs []evidenceOutput
	seen    map[string]bool
	reply   string
}

type evidenceOutput struct {
	didWork bool
	text    string
}

func lastBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[len(s)-n:]
	for len(s) > 0 && !utf8.RuneStart(s[0]) {
		s = s[1:]
	}
	return s
}

// takeCall keeps a finished call's output, once.
func (e *turnEvidence) takeCall(c wire.ToolCall) {
	if c.Status == nil || (*c.Status != "completed" && *c.Status != "failed") || c.ToolCallID == nil || len(e.outputs) >= 200 {
		return
	}
	if e.seen == nil {
		e.seen = map[string]bool{}
	}
	if e.seen[*c.ToolCallID] {
		return
	}
	e.seen[*c.ToolCallID] = true
	changes := c.Kind != nil && slices.Contains([]string{"execute", "edit", "delete", "move"}, *c.Kind)
	e.outputs = append(e.outputs, evidenceOutput{didWork: *c.Status == "completed" && changes, text: lastBytes(printedText(c), 8*1024)})
}

func (e *turnEvidence) takeReply(text string) { e.reply = lastBytes(e.reply+text, 8*1024) }

// printedText is ToolCall.printedText: its text content, then its raw output.
func printedText(c wire.ToolCall) string {
	var parts []string
	for _, item := range c.Content {
		b, _ := json.Marshal(item)
		var v struct {
			Content *struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		}
		if json.Unmarshal(b, &v) == nil && v.Content != nil && v.Content.Type == "text" {
			parts = append(parts, v.Content.Text)
		}
	}
	if len(c.RawOutput) > 0 && string(c.RawOutput) != "null" {
		var s string
		if json.Unmarshal(c.RawOutput, &s) == nil {
			parts = append(parts, s)
		} else {
			parts = append(parts, string(c.RawOutput))
		}
	}
	return strings.Join(parts, "\n")
}

// sandboxFailureIn is the failure a turn's evidence shows, and how many calls did work
// before it.
func sandboxFailureIn(e turnEvidence, runtimeID string) (string, int64) {
	entry, ok := sandboxFailurePatterns[runtimeID]
	if !ok {
		return "", 0
	}
	detail := ""
	var completed int64
	for _, o := range e.outputs {
		if m := sandboxMatch(runtimeID, o.text); m != "" {
			if detail == "" {
				detail = m
			}
		} else if o.didWork {
			completed++
		}
	}
	if detail == "" && entry.readsReply {
		detail = sandboxMatch(runtimeID, e.reply)
	}
	return detail, completed
}

// recordSandboxFailure puts the card on the agent and its conversation.
func (d *Daemon) recordSandboxFailure(id wire.UUID, detail string, completed int64) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	rec := wire.SandboxFailureRecord{RuntimeID: a.RuntimeID, Detail: detail,
		RecoveryOffered: slices.Contains(sandboxChoices(a.RuntimeID), wire.SandboxChoiceOff) && !sandboxRequired(d.orgPolicy()),
		CompletedToolCalls: completed}
	d.change(id, func(a *wire.Agent) { r := rec; a.PendingSandboxFailure = &r })
	d.record(id, wire.TranscriptEntryKind{SandboxFailure: &wire.TranscriptEntryKindSandboxFailure{Value: rec}})
	log.Printf("agent %s: %s's sandbox could not start: %s", id, a.RuntimeID, detail)
}

// answerSandbox is agents/answerSandbox: kept stopped, or carried on with its sandbox off:
// what was queued goes, or it is asked to carry on when commands already ran, or the
// person's last prompt is sent again.
func (d *Daemon) answerSandbox(ctx context.Context, r wire.AnswerSandboxRequest) (wire.Agent, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	pending := a.PendingSandboxFailure
	if pending == nil {
		return wire.Agent{}, &Error{Code: wire.FailureNotAllowed, Message: "That has been answered already."}
	}
	if r.CarryOn && sandboxRequired(d.orgPolicy()) {
		return wire.Agent{}, policyRefusal("policy", "sandbox", sandboxRequiredWords, nil)
	}
	if r.CarryOn && !pending.RecoveryOffered {
		return wire.Agent{}, &Error{Code: wire.FailureNotAllowed, Message: "The app cannot turn this runtime’s sandbox off."}
	}
	d.change(a.ID, func(a *wire.Agent) { a.PendingSandboxFailure = nil })
	name := runtimeName(a.RuntimeID)
	if !r.CarryOn {
		d.record(a.ID, runtimeNote("Kept stopped rather than run without "+name+"’s sandbox."))
		return *d.Store.Agent(a.ID), nil
	}
	off := wire.SandboxChoiceOff
	if _, err := d.setSandbox(ctx, wire.SetSandboxRequest{AgentID: a.ID, Choice: &off}); err != nil {
		return wire.Agent{}, err
	}
	d.record(a.ID, runtimeNote("Carried on without "+name+"’s sandbox."))
	a = d.Store.Agent(a.ID)
	switch {
	case len(a.QueuedPrompts) > 0:
		d.live(a.ID).kick()
	case pending.CompletedToolCalls > 0:
		d.enqueue(a.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: carryOnWithoutSandbox, QueuedAt: now(), From: wire.PromptOriginApp}, true)
	default:
		if text := d.lastPersonsPrompt(a.ID); text != "" {
			d.enqueue(a.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(), From: wire.PromptOriginApp}, true)
		}
	}
	return *d.Store.Agent(a.ID), nil
}

// lastPersonsPrompt is the words of the last prompt the person sent the agent.
func (d *Daemon) lastPersonsPrompt(id wire.UUID) string {
	entries, _, err := d.Store.Transcript(id, 0)
	if err != nil {
		return ""
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if u := entries[i].Kind.UserMessage; u != nil && (u.From == nil || *u.From == wire.PromptOriginPerson) {
			return u.Value
		}
	}
	return ""
}

// sandboxFailure records the card when the turn's error words or its evidence say its
// sandbox could not start, unless the turn said how it went itself, and returns the detail.
func (l *live) sandboxFailure(errWords string) string {
	a := l.d.Store.Agent(l.id)
	if a == nil {
		return ""
	}
	l.mu.Lock()
	reported, e := l.reported, l.evidence
	l.mu.Unlock()
	if reported {
		return ""
	}
	detail, completed := sandboxMatch(a.RuntimeID, errWords), int64(0)
	if detail == "" {
		detail, completed = sandboxFailureIn(e, a.RuntimeID)
	}
	if detail != "" {
		l.d.recordSandboxFailure(l.id, detail, completed)
	}
	return detail
}
