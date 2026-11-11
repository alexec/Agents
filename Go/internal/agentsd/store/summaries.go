package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The archived records' summaries (#4653). An archived record is held without its
// runtime's commands, which are nine tenths of it, and the start reads the summaries from
// one file rather than decoding every record. Each summary keeps the size and time of the
// record it was made from, so one whose record changed since (written by another build,
// or after the file was last written) is not trusted: that record is read in full and the
// file written again. The file is a cache: without it the start reads every record.

// summariesVersion is the file's shape; a file of another is read as missing.
const summariesVersion = 1

// summaryDelay is how long after an archived record changes the file is written, so a
// burst of archives writes it once. A test shortens it.
var summaryDelay = 2 * time.Second

type summaryFile struct {
	Version int                         `json:"version"`
	Records map[wire.UUID]summaryRecord `json:"records"`
}

type summaryRecord struct {
	Stamp stamp      `json:"stamp"`
	Agent wire.Agent `json:"agent"`
}

// stamp is a record file as it was when its summary was made.
type stamp struct {
	Size int64 `json:"size"`
	Mod  int64 `json:"mod"`
}

func stampOf(fi os.FileInfo) stamp { return stamp{Size: fi.Size(), Mod: fi.ModTime().UnixNano()} }

// noCommands is an archived summary's commands: none held, an empty list on the wire.
var noCommands = []wire.SlashCommand{}

// summary is an archived record as the store holds it: without its commands.
func summary(a *wire.Agent) *wire.Agent {
	c := *a
	c.AvailableCommands = noCommands
	return &c
}

// readSummaries is the file's records, or why there are none to trust.
func (s *Store) readSummaries() (map[wire.UUID]summaryRecord, string) {
	b, err := os.ReadFile(s.Loc.Summaries())
	if errors.Is(err, os.ErrNotExist) {
		return nil, "missing"
	}
	if err != nil {
		return nil, err.Error()
	}
	var f summaryFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, "unreadable: " + err.Error()
	}
	if f.Version != summariesVersion {
		return nil, fmt.Sprintf("version %d, not %d", f.Version, summariesVersion)
	}
	return f.Records, ""
}

// trusted is the summary of the record id when its record is unchanged since it was made.
func (s *Store) trusted(records map[wire.UUID]summaryRecord, id string) (*wire.Agent, stamp, bool) {
	r, ok := records[wire.UUID(id)]
	if !ok || r.Agent.State != wire.AgentStateArchived || string(r.Agent.ID) != id {
		return nil, stamp{}, false
	}
	fi, err := os.Stat(s.Loc.Record(id))
	if err != nil || stampOf(fi) != r.Stamp {
		return nil, stamp{}, false
	}
	a := r.Agent
	a.AvailableCommands = noCommands
	return &a, r.Stamp, true
}

// stampSummary keeps the stamp of an archived record just written, and has the file
// written soon; a record not archived leaves it. With mu held.
func (s *Store) stampSummary(a *wire.Agent, st stamp) {
	if a.State != wire.AgentStateArchived {
		return
	}
	s.stamps[a.ID] = st
	s.summariesSoon()
}

// summariesSoon writes the file summaryDelay after the last change that calls it. With mu
// held.
func (s *Store) summariesSoon() {
	if s.summaryTimer != nil {
		s.summaryTimer.Reset(summaryDelay)
		return
	}
	var t *time.Timer
	t = time.AfterFunc(summaryDelay, func() {
		// Under summaryWrite from the check to the end of the write, so FlushSummaries
		// waits for a write that has begun, and a timer it took writes nothing after it
		// (#4666): the host's stop then leaves no writer in the root.
		s.summaryWrite.Lock()
		defer s.summaryWrite.Unlock()
		s.mu.Lock()
		mine := s.summaryTimer == t
		if mine {
			s.summaryTimer = nil
		}
		s.mu.Unlock()
		// Not this timer's write any more: FlushSummaries wrote it, or this is a second
		// firing after a Reset of a timer that had already fired.
		if !mine {
			return
		}
		// A root gone (a test's, removed) gets no cache made again.
		if _, err := os.Stat(s.Loc.Root); err != nil {
			return
		}
		if err := s.writeSummaries(); err != nil {
			log.Printf("could not write the archived agents' summaries: %v", err)
		}
	})
	s.summaryTimer = t
}

// FlushSummaries writes the summaries' file now when a write is due, and leaves none due:
// for the host's stop, so the next start trusts every summary. A write the timer began is
// done when it returns, and the timer writes nothing after it (#4666).
func (s *Store) FlushSummaries() {
	s.summaryWrite.Lock()
	defer s.summaryWrite.Unlock()
	s.mu.Lock()
	due := s.summaryTimer != nil
	if due {
		s.summaryTimer.Stop()
		s.summaryTimer = nil
	}
	s.mu.Unlock()
	if !due {
		return
	}
	if err := s.writeSummaries(); err != nil {
		log.Printf("could not write the archived agents' summaries: %v", err)
	}
}

// WriteSummaries writes the archived records' summaries now: what the next start reads.
func (s *Store) WriteSummaries() error {
	s.summaryWrite.Lock()
	defer s.summaryWrite.Unlock()
	return s.writeSummaries()
}

// writeSummaries is WriteSummaries with summaryWrite held.
func (s *Store) writeSummaries() error {
	s.mu.Lock()
	f := summaryFile{Version: summariesVersion, Records: make(map[wire.UUID]summaryRecord, len(s.stamps))}
	for id, st := range s.stamps {
		if a := s.agents[id]; a != nil && a.State == wire.AgentStateArchived {
			f.Records[id] = summaryRecord{Stamp: st, Agent: *a}
		}
	}
	s.mu.Unlock()
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return WriteAtomically(s.Loc.Summaries(), b, 0o600)
}

// Commands is an agent's runtime's commands: an archived record's are read from its file.
func (s *Store) Commands(id wire.UUID) []wire.SlashCommand {
	a := s.Agent(id)
	if a == nil {
		return noCommands
	}
	return a.AvailableCommands
}

// commandsOnDisk is the commands in an agent's record file, or none.
func (s *Store) commandsOnDisk(id wire.UUID) []wire.SlashCommand {
	b, err := os.ReadFile(s.Loc.Record(string(id)))
	if err != nil {
		return noCommands
	}
	var r struct {
		AvailableCommands []wire.SlashCommand `json:"availableCommands"`
	}
	if err := diskjson.Unmarshal(b, &r); err != nil || r.AvailableCommands == nil {
		return noCommands
	}
	return r.AvailableCommands
}
