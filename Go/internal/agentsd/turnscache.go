package agentsd

import (
	"bufio"
	"bytes"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Where a chat's turns start, and their summaries kept (AgentStore.turns, #91). Where
// turns start is found by looking through the transcript's bytes for "userMessage" and
// decoding only those lines, so a conversation of 100,000 entries costs a few hundred
// decodes, not all of them. A summary is made only for a turn on the page asked for, and
// the rest are filled in behind it. The ones from the first turn on, without a gap, are
// kept in <cache>/turns/<id>.jsonl, the Swift host's file, so the next start reads them
// rather than makes them; one that no longer matches where its turn starts is made again.

// turnsKept is the conversations whose turns are held in memory, at most.
const turnsKept = 32

type turnState struct {
	// asks is the lines that are an ask, up to scanned.
	asks    []int
	scanned int
	// people is the lines of asks that are the person's, in order: what numbers the
	// Prompts list from the first prompt (#1862).
	people []int
	// known is the summaries of the first turns, without a gap: what turns.jsonl holds.
	known []wire.TurnSummary
	// later is summaries of later turns by position, made for a page before the ones
	// ahead of them were; moved into known once the gap before them is filled.
	later map[int]wire.TurnSummary
	used  uint64
}

type turnBook struct {
	turnMu   sync.Mutex
	turnsOf  map[wire.UUID]*turnState
	turnTick uint64
	filling  map[wire.UUID]bool
}

// starts is where each turn starts: the first line, then every ask after it. The last is
// the turn still going.
func (t *turnState) starts(total int) []int {
	if total == 0 {
		return nil
	}
	out := []int{0}
	for _, a := range t.asks {
		if a != 0 {
			out = append(out, a)
		}
	}
	return out
}

var errShrunk = errors.New("the transcript shrank")

// turns is agents/turns.
func (d *Daemon) turns(r wire.TurnsRequest) (wire.TurnsPage, error) {
	if d.Store.Agent(r.AgentID) == nil {
		return wire.TurnsPage{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(r.AgentID)}
	}
	if r.Limit < 0 || r.Before != nil && *r.Before < 0 {
		return wire.TurnsPage{}, Invalid("a page of turns is counted from zero")
	}
	d.turnMu.Lock()
	defer d.turnMu.Unlock()
	ends, err := d.Store.LineEnds(r.AgentID)
	if err != nil {
		return wire.TurnsPage{}, err
	}
	t, err := d.currentTurns(r.AgentID, ends)
	if err != nil {
		return wire.TurnsPage{}, err
	}
	starts := t.starts(len(ends))
	closed := max(0, len(starts)-1)
	end := closed
	if r.Before != nil {
		end = min(int(*r.Before), closed)
	}
	start := end - min(int(min(r.Limit, turnsLimitCeiling)), end)
	var needed []int
	for p := start; p < end; p++ {
		if _, ok := t.later[p]; p >= len(t.known) && !ok {
			needed = append(needed, p)
		}
	}
	if err := d.makeTurns(r.AgentID, t, needed, starts, ends); err != nil {
		return wire.TurnsPage{}, err
	}
	page := wire.TurnsPage{Turns: []wire.TurnSummary{}, FirstTurn: int64(start)}
	if len(starts) > 0 {
		page.OpenStart = int64(starts[len(starts)-1])
	}
	before := 0
	if start < len(starts) {
		before = sort.SearchInts(t.people, starts[start])
	}
	page.FirstPrompt = new(int64(before))
	for p := start; p < end; p++ {
		if p < len(t.known) {
			// A file the Swift host wrote before 069 kept no outcome: made again for the page.
			if k := t.known[p]; k.Concise == nil || k.Outcome == nil {
				entries, _, err := d.Store.Entries(r.AgentID, ends, int(k.Start), int(k.End))
				if err != nil {
					return wire.TurnsPage{}, err
				}
				fresh := turnSummaryOf(entries, k.Start)
				t.known[p].Concise, t.known[p].Outcome, t.known[p].Steps = fresh.Concise, fresh.Outcome, fresh.Steps
			}
			page.Turns = append(page.Turns, t.known[p])
		} else if s, ok := t.later[p]; ok {
			page.Turns = append(page.Turns, s)
		}
	}
	d.keepWhatFollows(r.AgentID, t)
	if len(t.known)+1 < len(starts) {
		d.fillTurnsSoon(r.AgentID)
	}
	return page, nil
}

// currentTurns is what is known of a chat's turns, brought up to the end of its
// transcript. Called with turnMu held.
func (d *Daemon) currentTurns(id wire.UUID, ends []int64) (*turnState, error) {
	total := len(ends)
	if d.turnsOf == nil {
		d.turnsOf = map[wire.UUID]*turnState{}
	}
	t := d.turnsOf[id]
	if t == nil {
		t = &turnState{known: d.readTurns(id), later: map[int]wire.TurnSummary{}}
		if err := d.checkKept(id, t, ends); err != nil {
			return nil, err
		}
		d.turnsOf[id] = t
		if len(d.turnsOf) > turnsKept {
			var oldest wire.UUID
			at := ^uint64(0)
			for k, v := range d.turnsOf {
				if k != id && v.used < at {
					oldest, at = k, v.used
				}
			}
			delete(d.turnsOf, oldest)
		}
	}
	d.turnTick++
	t.used = d.turnTick
	// Read from some other transcript than this one: look again.
	if t.scanned > total {
		t.asks, t.people, t.scanned, t.later = nil, nil, 0, map[int]wire.TurnSummary{}
	}
	lines, err := d.Store.LinesContaining(id, ends, `"userMessage"`, t.scanned)
	if err != nil {
		return nil, err
	}
	for _, l := range lines {
		if ask, person := d.askAt(id, ends, l); ask {
			t.asks = append(t.asks, l)
			if person {
				t.people = append(t.people, l)
			}
		}
	}
	t.scanned = total
	// The kept summaries hold only while each still starts and ends where its turn does.
	starts := t.starts(total)
	closed := max(0, len(starts)-1)
	valid := 0
	for valid < len(t.known) && valid < closed && int(t.known[valid].Start) == starts[valid] && int(t.known[valid].End) == starts[valid+1] {
		valid++
	}
	if valid < len(t.known) {
		t.known = t.known[:valid]
		d.writeTurns(id, t.known)
	}
	for p, s := range t.later {
		if p >= closed || int(s.Start) != starts[p] || int(s.End) != starts[p+1] {
			delete(t.later, p)
		}
	}
	return t, nil
}

func (d *Daemon) isAskLine(id wire.UUID, ends []int64, line int) bool {
	ask, _ := d.askAt(id, ends, line)
	return ask
}

// askAt is whether the line starts a turn, and whether the person sent it.
func (d *Daemon) askAt(id wire.UUID, ends []int64, line int) (ask, person bool) {
	if line >= len(ends) {
		return false, false
	}
	entries, _, err := d.Store.Entries(id, ends, line, line+1)
	if err != nil || len(entries) != 1 {
		return false, false
	}
	if isPersonsAsk(&entries[0]) {
		return true, isPersonsPrompt(&entries[0])
	}
	return d.bringsLateAnswer(id, ends, line, &entries[0]), false
}

// lateAnswerLookBack is how many lines askAt passes over, back from an app prompt, to the
// form answer it brings: state changes and passing lines ("Starting Claude…").
const lateAnswerLookBack = 8

// bringsLateAnswer is startsTurn(after:) for the app's prompt: the one that brings the
// answer to a form left open (#1641) starts a turn, so the answer is drawn at the end of
// the turn that asked (#2934).
func (d *Daemon) bringsLateAnswer(id wire.UUID, ends []int64, line int, e *wire.TranscriptEntry) bool {
	u := e.Kind.UserMessage
	if u == nil || u.From == nil || *u.From != wire.PromptOriginApp {
		return false
	}
	from := max(0, line-lateAnswerLookBack)
	before, _, err := d.Store.Entries(id, ends, from, line)
	if err != nil {
		return false
	}
	for i := len(before) - 1; i >= 0; i-- {
		if before[i].Kind.StateChanged == nil && !entryIsPassing(&before[i]) {
			return before[i].Kind.ElicitationAnswered != nil
		}
	}
	return false
}

// isPersonsPrompt is a prompt the person sent, as promptNumber counts them.
func isPersonsPrompt(e *wire.TranscriptEntry) bool {
	u := e.Kind.UserMessage
	return u != nil && (u.From == nil || *u.From == wire.PromptOriginPerson)
}

// checkKept is checkKept: the kept turns hold while each starts on the entry it began
// with and an ask is still where the last ends. The last is checked first; only when it
// fails is each looked at, and the file cut back to before the first that does not hold.
func (d *Daemon) checkKept(id wire.UUID, t *turnState, ends []int64) error {
	known := t.known
	if len(known) == 0 {
		return nil
	}
	begins := func(s wire.TurnSummary) bool {
		if int(s.Start) >= len(ends) {
			return false
		}
		entries, _, err := d.Store.Entries(id, ends, int(s.Start), int(s.Start)+1)
		return err == nil && len(entries) == 1 && entries[0].ID == s.ID
	}
	joined := known[0].Start == 0
	for i := 1; joined && i < len(known); i++ {
		joined = known[i-1].End == known[i].Start
	}
	last := known[len(known)-1]
	if !joined || !begins(last) || !d.isAskLine(id, ends, int(last.End)) {
		holding := 0
		for holding < len(known) {
			want := int64(0)
			if holding > 0 {
				want = known[holding-1].End
			}
			if known[holding].Start != want || !begins(known[holding]) {
				break
			}
			holding++
		}
		if holding > 0 && !d.isAskLine(id, ends, int(known[holding-1].End)) {
			holding--
		}
		t.known = known[:holding]
		d.writeTurns(id, t.known)
	}
	t.asks, t.people = nil, nil
	for i, k := range t.known {
		if i > 0 {
			t.asks = append(t.asks, int(k.Start))
		}
		if k.Ask != nil && isPersonsPrompt(k.Ask) {
			t.people = append(t.people, int(k.Start))
		}
	}
	if n := len(t.known); n > 0 {
		t.scanned = int(t.known[n-1].End)
	}
	return nil
}

// makeTurns makes the summaries of the turns at these positions, from one read, for later.
func (d *Daemon) makeTurns(id wire.UUID, t *turnState, positions []int, starts []int, ends []int64) error {
	if len(positions) == 0 {
		return nil
	}
	first, last := positions[0], positions[len(positions)-1]
	entries, at, err := d.Store.Entries(id, ends, starts[first], starts[last+1])
	if err != nil {
		return err
	}
	if len(ends) < starts[last+1] {
		return errShrunk
	}
	i := 0
	for _, p := range positions {
		from, to := starts[p], starts[p+1]
		for i < len(at) && at[i] < from {
			i++
		}
		j := i
		for j < len(at) && at[j] < to {
			j++
		}
		s := turnSummaryOf(entries[i:j], int64(from))
		// By the line, as agents/transcript counts: a line that did not decode is still one.
		s.End = int64(to)
		t.later[p] = s
		i = j
	}
	return nil
}

// keepWhatFollows keeps the made summaries that follow the kept ones without a gap.
func (d *Daemon) keepWhatFollows(id wire.UUID, t *turnState) {
	var gained []wire.TurnSummary
	for {
		s, ok := t.later[len(t.known)]
		if !ok {
			break
		}
		delete(t.later, len(t.known))
		t.known = append(t.known, s)
		gained = append(gained, s)
	}
	if len(gained) > 0 {
		d.appendTurns(id, gained)
	}
}

// fillTurnsSoon makes the summaries a page did not need, oldest first, one turn at a time,
// so turns.jsonl is whole by the next start and nothing waits long behind it. It stops when
// there is no gap left, or the chat is no longer held.
func (d *Daemon) fillTurnsSoon(id wire.UUID) {
	if d.filling == nil {
		d.filling = map[wire.UUID]bool{}
	}
	if d.filling[id] {
		return
	}
	d.filling[id] = true
	safe.Go("fill turns", func() {
		defer func() {
			d.turnMu.Lock()
			delete(d.filling, id)
			d.turnMu.Unlock()
		}()
		for d.ctx.Err() == nil {
			d.turnMu.Lock()
			t := d.turnsOf[id]
			if t == nil {
				d.turnMu.Unlock()
				return
			}
			ends, err := d.Store.LineEnds(id)
			starts := t.starts(t.scanned)
			p := len(t.known)
			if err != nil || p+1 >= len(starts) || len(ends) < t.scanned {
				d.turnMu.Unlock()
				return
			}
			if _, ok := t.later[p]; !ok {
				if err := d.makeTurns(id, t, []int{p}, starts, ends); err != nil {
					d.turnMu.Unlock()
					return
				}
			}
			d.keepWhatFollows(id, t)
			d.turnMu.Unlock()
		}
	})
}

func (d *Daemon) readTurns(id wire.UUID) []wire.TurnSummary {
	b, err := os.ReadFile(d.Store.Loc.Turns(string(id)))
	if err != nil {
		return nil
	}
	var out []wire.TurnSummary
	for _, line := range bytes.Split(b, []byte{'\n'}) {
		var s wire.TurnSummary
		if len(bytes.TrimSpace(line)) > 0 && diskjson.Unmarshal(line, &s) == nil {
			out = append(out, s)
		}
	}
	return out
}

func encodeTurns(turns []wire.TurnSummary) []byte {
	var buf bytes.Buffer
	for _, s := range turns {
		if b, err := diskjson.Marshal(s); err == nil {
			buf.Write(b)
			buf.WriteByte('\n')
		}
	}
	return buf.Bytes()
}

// writeTurns is the kept summaries in place of what the file held.
func (d *Daemon) writeTurns(id wire.UUID, turns []wire.TurnSummary) {
	path := d.Store.Loc.Turns(string(id))
	if len(turns) == 0 {
		os.Remove(path)
		return
	}
	os.MkdirAll(filepath.Dir(path), 0o755)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, encodeTurns(turns), 0o644); err != nil {
		log.Printf("agent %s: turns not kept: %v", id, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("agent %s: turns not kept: %v", id, err)
	}
}

func (d *Daemon) appendTurns(id wire.UUID, turns []wire.TurnSummary) {
	path := d.Store.Loc.Turns(string(id))
	os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("agent %s: turns not kept: %v", id, err)
		return
	}
	w := bufio.NewWriter(f)
	w.Write(encodeTurns(turns))
	if err := w.Flush(); err != nil {
		log.Printf("agent %s: turns not kept: %v", id, err)
	}
	f.Close()
}
