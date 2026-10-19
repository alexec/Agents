package agentsd

import (
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/wire"
)

// Find in a chat (#1532): agents/find reads what was said in one transcript, prompts and
// replies, and answers the messages that hold the text, any case. A reply's chunks are one
// message, found at its first chunk, which is the id the chat draws it with.

const (
	// findLimit is the most matches one answer carries: the newest ones.
	findLimit = 200
	// findChunk is how many lines are read and decoded at a time.
	findChunk = 1000
	// findLineRunes is how much of the matching line comes back.
	findLineRunes = 120
)

func (d *Daemon) find(r wire.FindRequest) (wire.FindResult, error) {
	if d.Store.Agent(r.AgentID) == nil {
		return wire.FindResult{}, noSuchAgent()
	}
	result := wire.FindResult{Matches: []wire.FindMatch{}}
	text := strings.ToLower(strings.TrimSpace(r.Text))
	if text == "" {
		return result, nil
	}
	limit := findLimit
	if r.Limit != nil && *r.Limit > 0 {
		limit = int(min(*r.Limit, int64(findLimit)))
	}
	ends, err := d.Store.LineEnds(r.AgentID)
	if err != nil {
		return wire.FindResult{}, err
	}
	// The message being joined, and where it started.
	var current *wire.TranscriptEntry
	currentAt := 0
	take := func() {
		if current == nil {
			return
		}
		if line, ok := findLine(findText(*current), text); ok {
			result.Matches = append(result.Matches, wire.FindMatch{Index: int64(currentAt), EntryID: current.ID, Line: line})
			// Bounded as it goes: the newest `limit` are kept.
			if len(result.Matches) > limit {
				result.Matches = result.Matches[1:]
				result.More = true
			}
		}
	}
	for from := 0; from < len(ends); from += findChunk {
		entries, at, err := d.Store.Entries(r.AgentID, ends, from, min(from+findChunk, len(ends)))
		if err != nil {
			return wire.FindResult{}, err
		}
		for i, e := range entries {
			// A subagent's words are its own, and do not break the reply around them.
			if e.SubagentID != nil {
				continue
			}
			if joined := joinEntry(e, current); joined != nil {
				current = joined
				continue
			}
			take()
			current, currentAt = nil, at[i]
			if findText(e) != "" {
				c := e
				current = &c
			}
		}
	}
	take()
	return result, nil
}

// findText is what an entry says, when it is a prompt or a reply: the person's, another
// agent's, the app's question or the agent's own words. Nothing else is searched.
func findText(e wire.TranscriptEntry) string {
	switch {
	case e.Kind.UserMessage != nil:
		return e.Kind.UserMessage.Value
	case e.Kind.AgentMessage != nil:
		return e.Kind.AgentMessage.Text
	}
	return ""
}

// findLine is the line of `message` that holds `lower` (already lower case), cut to
// findLineRunes around it.
func findLine(message, lower string) (string, bool) {
	for line := range strings.SplitSeq(message, "\n") {
		line = strings.TrimSpace(line)
		folded := strings.ToLower(line)
		at := strings.Index(folded, lower)
		if at < 0 {
			continue
		}
		if utf8.RuneCountInString(line) <= findLineRunes {
			return line, true
		}
		runes := []rune(line)
		start := max(0, utf8.RuneCountInString(folded[:at])-findLineRunes/3)
		end := min(len(runes), start+findLineRunes)
		cut := string(runes[start:end])
		if start > 0 {
			cut = "…" + cut
		}
		if end < len(runes) {
			cut += "…"
		}
		return cut, true
	}
	return "", false
}
