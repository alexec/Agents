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
// session and no transcript is read whole twice. A transcript the same size as last time is
// not read at all, so agents/list{query} after agents/said reads only said.json (P20261019-1).

const (
	// saidBytes is the most text one session's index keeps: its newest messages.
	saidBytes = 32 * 1024
	// saidSessions is how many sessions a search reads, the most recently active first.
	saidSessions = 300
	// saidMatches is the most sessions one search answers.
	saidMatches = 100
)

// saidIndex is said.json: the messages kept, oldest first, the byte to read on from, and the
// transcript's size when it was read, so a search over a transcript that has not grown reads
// only said.json (P20261019-1). The last message may still be growing (a reply in chunks), so
// it is not kept: offset is its first line, it is read again once the transcript grows, and
// tail is it as of size.
type saidIndex struct {
	Offset   int64    `json:"offset"`
	Size     int64    `json:"size"`
	Messages []string `json:"messages"`
	Tail     string   `json:"tail,omitempty"`
}

var saidMu sync.Mutex

func saidFile(loc store.Locations, id wire.UUID) string {
	return filepath.Join(loc.Agent(string(id)), "said.json")
}

// said is a session's messages as of now: said.json brought up to date, and the message
// still growing at the end. The transcript is read from where said.json stopped, past the
// store's kept line indexes, and not at all when its size is the same.
func (d *Daemon) said(id wire.UUID) []string {
	var index saidIndex
	if b, err := os.ReadFile(saidFile(d.Store.Loc, id)); err == nil {
		_ = json.Unmarshal(b, &index)
	}
	info, err := os.Stat(d.Store.Loc.Transcript(string(id)))
	if err != nil {
		return nil
	}
	if index.Size > 0 && info.Size() == index.Size {
		return index.messages()
	}
	// Shorter than what was read (some other transcript now), or a said.json from before sizes.
	if info.Size() < index.Size || index.Size == 0 {
		index = saidIndex{}
	}
	var current *wire.TranscriptEntry
	currentAt := index.Offset
	kept := index.Messages
	end, size, err := d.Store.EntriesFrom(id, index.Offset, func(e wire.TranscriptEntry, start, end int64) {
		if e.SubagentID != nil {
			return
		}
		if joined := joinEntry(e, current); joined != nil {
			current = joined
			return
		}
		if current != nil {
			kept = append(kept, findText(*current))
		}
		current, currentAt = nil, end
		if findText(e) != "" {
			c := e
			current, currentAt = &c, start
		}
	})
	if err != nil {
		return index.messages()
	}
	if current == nil {
		currentAt = end
	}
	index = saidIndex{Offset: currentAt, Size: size, Messages: boundSaid(kept)}
	if current != nil {
		index.Tail = findText(*current)
	}
	if b, err := json.Marshal(index); err == nil {
		_ = store.WriteAtomically(saidFile(d.Store.Loc, id), b, 0o644)
	}
	return index.messages()
}

// messages is what was said: the messages kept and the one still growing.
func (index saidIndex) messages() []string {
	if index.Tail != "" {
		return append(index.Messages[:len(index.Messages):len(index.Messages)], index.Tail)
	}
	return index.Messages
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
		if r.Folder != nil && folderPath(&a) != store.FolderPath(*r.Folder) {
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
