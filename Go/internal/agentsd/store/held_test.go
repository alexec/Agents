package store

import (
	"errors"
	"strings"
	"syscall"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

func refuseWrites(t *testing.T) func() {
	restore := RefuseWrites(syscall.ENOSPC)
	t.Cleanup(restore)
	return restore
}

func said(text string) wire.TranscriptEntry {
	return wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: text}}}
}

// A line the disk refuses is held, and written in order ahead of the next line once there
// is space (#3245).
func TestLinesTheDiskRefusesAreWrittenInOrderOnceThereIsSpace(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	s.Append(id, said("one"))
	restore := refuseWrites(t)
	for i, text := range []string{"two", "three"} {
		n, _, err := s.AppendOne(id, said(text))
		if !errors.Is(err, ErrHeld) || !errors.Is(err, syscall.ENOSPC) || n != i+1 {
			t.Fatalf("%s: index %d, %v", text, n, err)
		}
	}
	if lines, dropped := s.HeldLines(id); lines != 2 || dropped != 0 || !s.Holding() {
		t.Fatalf("held %d, dropped %d", lines, dropped)
	}
	if got, _, _ := s.Transcript(id, 0); len(got) != 1 {
		t.Fatalf("on disk while refused: %d", len(got))
	}
	restore()
	if n, err := s.Append(id, said("four")); err != nil || n != 3 {
		t.Fatalf("index %d, %v", n, err)
	}
	got, _, _ := s.Transcript(id, 0)
	var texts []string
	for _, e := range got {
		texts = append(texts, e.Kind.AgentMessage.Text)
	}
	if strings.Join(texts, " ") != "one two three four" || s.Holding() {
		t.Fatalf("read back %v", texts)
	}
}

// The disk check writes what is held with no new line to carry it.
func TestWriteHeldWritesWhatIsHeld(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	restore := refuseWrites(t)
	s.AppendOne(id, said("one"))
	if still, err := s.WriteHeld(); still != 1 || !errors.Is(err, syscall.ENOSPC) {
		t.Fatalf("still %d, %v", still, err)
	}
	restore()
	if still, err := s.WriteHeld(); still != 0 || err != nil {
		t.Fatalf("still %d, %v", still, err)
	}
	if got, _, _ := s.Transcript(id, 0); len(got) != 1 {
		t.Fatalf("read back %d", len(got))
	}
}

// Past the bound, the newest lines go; when the hold is written the chat says how many,
// where they would have been, and the next line's index counts the notice.
func TestAFullHoldSaysHowManyLinesWent(t *testing.T) {
	was := HeldBytesPerAgent
	HeldBytesPerAgent = 1
	t.Cleanup(func() { HeldBytesPerAgent = was })
	s, _ := Open(t.TempDir())
	var told []int
	s.OnGap = func(_ wire.UUID, e wire.TranscriptEntry, index int) {
		if e.Kind.Notice == nil || !strings.HasPrefix(e.Kind.Notice.Value.Title, "2 lines") {
			t.Errorf("gap %+v", e.Kind)
		}
		told = append(told, index)
	}
	id := NewUUID()
	restore := refuseWrites(t)
	s.AppendOne(id, said("kept"))
	for range 2 {
		if _, _, err := s.AppendOne(id, said("let go")); err == nil || errors.Is(err, ErrHeld) {
			t.Fatalf("past the bound: %v", err)
		}
	}
	if lines, dropped := s.HeldLines(id); lines != 1 || dropped != 2 {
		t.Fatalf("held %d, dropped %d", lines, dropped)
	}
	restore()
	if n, err := s.Append(id, said("after")); err != nil || n != 2 {
		t.Fatalf("index %d, %v", n, err)
	}
	got, _, _ := s.Transcript(id, 0)
	if len(got) != 3 || got[0].Kind.AgentMessage.Text != "kept" || got[1].Kind.Notice == nil || got[2].Kind.AgentMessage.Text != "after" {
		t.Fatalf("read back %+v", got)
	}
	if len(told) != 1 || told[0] != 1 {
		t.Fatalf("told %v", told)
	}
}

// A branch's copy the disk refuses is not held: the call says the refusal.
func TestAppendManyHoldsNothing(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	refuseWrites(t)
	if _, err := s.AppendMany(id, []wire.TranscriptEntry{said("a")}); err == nil || errors.Is(err, ErrHeld) {
		t.Fatalf("%v", err)
	}
	if s.Holding() {
		t.Fatal("held a branch's copy")
	}
}
