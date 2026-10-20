package agentsd

import (
	"bytes"
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// Find in a chat (#1532): agents/find reads what was said in one transcript, prompts and
// replies, and answers the messages that hold the text, any case. A reply's chunks are one
// message, found at its first chunk, which is the id the chat draws it with.

const (
	// findLimit is the most matches one answer carries: the newest ones.
	findLimit = 200
	// findCheck is how many lines are read between looks at whether the find is still wanted.
	findCheck = 1000
	// findLineRunes is how much of the matching line comes back.
	findLineRunes = 120
)

// Only a line whose bytes hold one of these keys can be a prompt or a reply (P20261019-2):
// the rest, tool calls and their output most of all, are not decoded. A key in quotes is
// only ever a key, since a string's quotes are escaped.
var findKeys = [][]byte{[]byte(`"userMessage"`), []byte(`"agentMessage"`)}

// errFindSuperseded answers a find that a newer one from the same client, in the same chat,
// took the place of: the client asks again at each pause while typing, and keeps only the last.
var errFindSuperseded = errors.New("a newer find in this chat took the place of this one")

// findBook keeps the newest find of each client in each chat, so the older ones stop.
type findBook struct {
	findMu sync.Mutex
	finds  map[findKey]uint64
	findN  uint64
}

type findKey struct {
	client int64
	agent  wire.UUID
}

// startFind makes this the client's newest find in the chat. wanted says whether it still
// is; done lets go of its place.
func (d *Daemon) startFind(key findKey) (wanted func() bool, done func()) {
	d.findMu.Lock()
	defer d.findMu.Unlock()
	if d.finds == nil {
		d.finds = map[findKey]uint64{}
	}
	d.findN++
	n := d.findN
	d.finds[key] = n
	wanted = func() bool {
		d.findMu.Lock()
		defer d.findMu.Unlock()
		return d.finds[key] == n
	}
	done = func() {
		d.findMu.Lock()
		defer d.findMu.Unlock()
		if d.finds[key] == n {
			delete(d.finds, key)
		}
	}
	return wanted, done
}

// findMessage is the message being joined: where it started, and its words so far.
type findMessage struct {
	id        wire.UUID
	at        int
	reply     bool
	messageID *string
	text      strings.Builder
}

func (d *Daemon) find(ctx context.Context, client int64, r wire.FindRequest) (wire.FindResult, error) {
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
	wanted, done := d.startFind(findKey{client: client, agent: r.AgentID})
	defer done()
	var current *findMessage
	take := func() {
		if current == nil {
			return
		}
		if line, ok := findLine(current.text.String(), text); ok {
			result.Matches = append(result.Matches, wire.FindMatch{Index: int64(current.at), EntryID: current.id, Line: line})
			// Bounded as it goes: the newest `limit` are kept.
			if len(result.Matches) > limit {
				result.Matches = result.Matches[1:]
				result.More = true
			}
		}
		current = nil
	}
	var stopped error
	err = d.Store.EachLine(r.AgentID, ends, 0, len(ends), func(line []byte, i int) bool {
		if i%findCheck == 0 {
			if stopped = ctx.Err(); stopped == nil && !wanted() {
				stopped = errFindSuperseded
			}
			if stopped != nil {
				return false
			}
		}
		message := slices.ContainsFunc(findKeys, func(k []byte) bool { return bytes.Contains(line, k) })
		// Some other entry can only end the message being joined: with none, it is not read.
		if !message && current == nil || len(bytes.TrimSpace(line)) == 0 {
			return true
		}
		var e wire.TranscriptEntry
		if diskjson.Unmarshal(line, &e) != nil {
			return true
		}
		// A subagent's words are its own, and do not break the reply around them.
		if e.SubagentID != nil {
			return true
		}
		// A chunk that goes on with the reply before it (joinEntry), joined without copying
		// what came before.
		if m := e.Kind.AgentMessage; m != nil && current != nil && current.reply && sameMessageID(current.messageID, m.MessageID) {
			current.text.WriteString(m.Text)
			return true
		}
		take()
		if said := findText(e); said != "" {
			current = &findMessage{id: e.ID, at: i, reply: e.Kind.AgentMessage != nil}
			if current.reply {
				current.messageID = e.Kind.AgentMessage.MessageID
			}
			current.text.WriteString(said)
		}
		return true
	})
	if err != nil {
		return wire.FindResult{}, err
	}
	if stopped != nil {
		return wire.FindResult{}, stopped
	}
	take()
	return result, nil
}

func sameMessageID(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }

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
