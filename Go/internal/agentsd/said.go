package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// What was said, for the session search (#1585): each session keeps its prompts and replies
// in said.json beside its transcript, the newest saidBytes of them. It is brought up to date
// from where it last stopped, only when a search asks, so a search costs a bounded read per
// session and no transcript is read whole twice.

const (
	// saidBytes is the most text one session's index keeps: its newest messages.
	saidBytes = 32 * 1024
	// saidSessions is how many sessions a search reads, the most recently active first.
	saidSessions = 300
	// saidMatches is the most sessions one search answers.
	saidMatches = 100
)

// saidIndex is said.json: the messages kept, oldest first, and the line to read on from.
// The last message may still be growing (a reply in chunks), so it is not kept: next is its
// first line, and it is read again next time.
type saidIndex struct {
	Next     int      `json:"next"`
	Messages []string `json:"messages"`
}

var saidMu sync.Mutex

func saidFile(loc store.Locations, id wire.UUID) string {
	return filepath.Join(loc.Agent(string(id)), "said.json")
}

// said is a session's messages as of now: said.json brought up to date, and the message
// still growing at the end.
func (d *Daemon) said(id wire.UUID) []string {
	var index saidIndex
	if b, err := os.ReadFile(saidFile(d.Store.Loc, id)); err == nil {
		_ = json.Unmarshal(b, &index)
	}
	ends, err := d.Store.LineEnds(id)
	if err != nil || index.Next > len(ends) {
		index = saidIndex{}
	}
	if err != nil {
		return nil
	}
	var current *wire.TranscriptEntry
	currentAt := index.Next
	kept := index.Messages
	changed := false
	for from := index.Next; from < len(ends); from += findChunk {
		entries, at, err := d.Store.Entries(id, ends, from, min(from+findChunk, len(ends)))
		if err != nil {
			break
		}
		for i, e := range entries {
			if e.SubagentID != nil {
				continue
			}
			if joined := joinEntry(e, current); joined != nil {
				current = joined
				continue
			}
			if current != nil {
				kept = append(kept, findText(*current))
				changed = true
			}
			current, currentAt = nil, at[i]+1
			if findText(e) != "" {
				c := e
				current, currentAt = &c, at[i]
			}
		}
	}
	if current == nil {
		currentAt = len(ends)
	}
	kept = boundSaid(kept)
	if changed || currentAt != index.Next {
		if b, err := json.Marshal(saidIndex{Next: currentAt, Messages: kept}); err == nil {
			_ = store.WriteAtomically(saidFile(d.Store.Loc, id), b, 0o644)
		}
	}
	if current != nil {
		return append(kept, findText(*current))
	}
	return kept
}

// boundSaid keeps the newest messages within saidBytes.
func boundSaid(messages []string) []string {
	total := 0
	for i := len(messages) - 1; i >= 0; i-- {
		total += len(messages[i])
		if total > saidBytes {
			return append([]string{}, messages[i+1:]...)
		}
	}
	return messages
}

// saidLine is the line of what a session said that holds `lower` (lower case already), the
// newest message first, or "".
func (d *Daemon) saidLine(id wire.UUID, lower string) string {
	messages := d.said(id)
	for i := len(messages) - 1; i >= 0; i-- {
		if !strings.Contains(strings.ToLower(messages[i]), lower) {
			continue
		}
		if line, ok := findLine(messages[i], lower); ok {
			return line
		}
	}
	return ""
}

// saidSearch is agents/said: the sessions whose prompts or replies hold the text, each with
// the line, the most recently active first.
func (d *Daemon) saidSearch(r wire.SaidSearchRequest) wire.SaidSearchResult {
	result := wire.SaidSearchResult{Matches: []wire.SaidMatch{}}
	lower := strings.ToLower(strings.TrimSpace(r.Text))
	if lower == "" {
		return result
	}
	limit := saidMatches
	if r.Limit != nil && *r.Limit > 0 {
		limit = int(min(*r.Limit, int64(saidMatches)))
	}
	saidMu.Lock()
	defer saidMu.Unlock()
	read := 0
	for _, a := range d.Store.Agents() {
		if r.Folder != nil && projectFolder(&a) != store.FolderPath(*r.Folder) {
			continue
		}
		if read++; read > saidSessions {
			break
		}
		if line := d.saidLine(a.ID, lower); line != "" {
			result.Matches = append(result.Matches, wire.SaidMatch{AgentID: a.ID, Line: line})
			if len(result.Matches) == limit {
				break
			}
		}
	}
	return result
}

// titleMatches is queryMatches without what was said: for sessions past saidSessions.
func (d *Daemon) titleMatches(a wire.Agent, query string) bool {
	words := strings.ToLower(strings.TrimSpace(query))
	return words == "" || strings.Contains(words, "label:") ||
		a.Title != nil && strings.Contains(strings.ToLower(*a.Title), words) ||
		a.Report != nil && strings.Contains(strings.ToLower(a.Report.Message), words)
}

// queryMatches is ListRequest.query as a session search reads it (#165, #1585): its title or
// last report holds the words, or what was said does. A query that asks for a label is left to
// the client, which knows how labels compare.
func (d *Daemon) queryMatches(a wire.Agent, query string) bool {
	if d.titleMatches(a, query) {
		return true
	}
	saidMu.Lock()
	defer saidMu.Unlock()
	return d.saidLine(a.ID, strings.ToLower(strings.TrimSpace(query))) != ""
}
