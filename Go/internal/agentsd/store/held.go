package store

import (
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agents/Go/wire"
)

// MARK: lines the disk refused (#212, #3245)

// ErrHeld is in the error AppendOne gives back for a line the disk refused and the store
// holds, to write ahead of the next line or at the next WriteHeld: the line is not lost,
// and the clients may be shown it.
var ErrHeld = errors.New("held until there is space")

// HeldBytesPerAgent is how much of one chat is held while the disk is full, as the Swift
// daemon held it (#282). A streaming agent writes a line a token; past this the newest are
// let go, and the chat says how many where they would have been.
var HeldBytesPerAgent = 1 << 20

// heldLines is one chat's lines waiting for space, oldest first.
type heldLines struct {
	buf   []byte
	lines int
	// dropped is the lines let go because the hold was full, said in the chat when the
	// hold is written. Once one is let go, every line after it is too, so the lines kept
	// are in order and the gap is in one place.
	dropped int
}

func (h *heldLines) count() int {
	if h == nil {
		return 0
	}
	return h.lines
}

// gap is the notice written where a full hold's lines would have been.
type gap struct {
	entry wire.TranscriptEntry
	index int
}

// writeLocked writes what the agent holds, then buf's count lines, in one write, and says
// the index of buf's first line. When the disk refuses and hold is set, buf is held (or,
// past the bound, let go); else it is given back as the error.
func (s *Store) writeLocked(id wire.UUID, buf []byte, count int, hold bool) (int, *gap, error) {
	n := s.lines[id]
	h := s.held[id]
	out := buf
	var g *gap
	if h != nil {
		out = append([]byte{}, h.buf...)
		if h.dropped > 0 {
			g = gapNote(h.dropped, n+h.lines)
			if b, err := diskjson.Marshal(g.entry); err == nil {
				out = append(append(out, b...), '\n')
			} else {
				g = nil
			}
		}
		out = append(out, buf...)
	}
	first := n + h.count()
	if g != nil {
		first++
	}
	err := s.writeTranscript(id, out)
	if err == nil {
		s.lines[id] = first + count
		delete(s.held, id)
		return first, g, nil
	}
	if !hold {
		return 0, nil, err
	}
	if h == nil {
		h = &heldLines{}
		s.held[id] = h
	}
	if h.dropped > 0 || (h.lines > 0 && len(h.buf)+len(buf) > HeldBytesPerAgent) {
		h.dropped += count
		return 0, nil, fmt.Errorf("the hold is full, so a line is let go: %w", err)
	}
	first = n + h.lines
	h.buf = append(h.buf, buf...)
	h.lines += count
	return first, nil, fmt.Errorf("%w: %w", ErrHeld, err)
}

func gapNote(dropped, index int) *gap {
	title := fmt.Sprintf("%d lines of this chat could not be kept", dropped)
	if dropped == 1 {
		title = "1 line of this chat could not be kept"
	}
	detail := "The disk was full, and more was said than could be held until there was space."
	return &gap{index: index, entry: wire.TranscriptEntry{ID: NewUUID(), At: wire.DateOf(time.Now()),
		Kind: wire.TranscriptEntryKind{Notice: &wire.TranscriptEntryKindNotice{Value: wire.SessionNotice{
			Severity: "warning", Title: title, Detail: &detail}}}}}
}

func (s *Store) tellGap(id wire.UUID, g *gap) {
	if g != nil && s.OnGap != nil {
		s.OnGap(id, g.entry, g.index)
	}
}

// WriteHeld tries every chat's held lines again, as the disk may have space now, and says
// how many chats still hold some and the first refusal. Nothing is let go by trying.
func (s *Store) WriteHeld() (int, error) {
	type written struct {
		id wire.UUID
		g  *gap
	}
	var gaps []written
	var first error
	s.mu.Lock()
	for id := range s.held {
		_, g, err := s.writeLocked(id, nil, 0, false)
		if err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		log.Printf("agent %s: wrote the lines held while the disk was full", id)
		gaps = append(gaps, written{id, g})
	}
	still := len(s.held)
	s.mu.Unlock()
	for _, w := range gaps {
		s.tellGap(w.id, w.g)
	}
	return still, first
}

// Holding says whether any chat has lines waiting for space.
func (s *Store) Holding() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.held) > 0
}

// HeldLines is how many of a chat's lines are held, and how many were let go. For a test.
func (s *Store) HeldLines(id wire.UUID) (lines, dropped int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := s.held[id]; h != nil {
		return h.lines, h.dropped
	}
	return 0, 0
}

// RefuseWrites makes every transcript open fail with err, as a full disk does, until the
// func it gives back is called. For a test, as AgentStore.refuseWrites was.
func RefuseWrites(err error) (restore func()) {
	was := openTranscript
	openTranscript = func(file string) (*os.File, error) {
		return nil, &os.PathError{Op: "open", Path: file, Err: err}
	}
	return func() { openTranscript = was }
}
