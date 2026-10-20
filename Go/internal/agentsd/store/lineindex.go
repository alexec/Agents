package store

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// A transcript read in part (TranscriptReader, #91): where each line ends, found once
// and extended as the file grows, so a page or a turn decodes only its own lines, and a
// look for a kind of entry reads the bytes without decoding them. The indexes of the
// transcripts read most recently are kept, at most indexedTranscripts of them.

const indexedTranscripts = 32

type lineIndex struct {
	// ends is where each whole line ends, after its newline.
	ends []int64
	// used orders the kept indexes: the least recently used goes first.
	used uint64
}

type indexBook struct {
	mu      sync.Mutex
	indexes map[wire.UUID]*lineIndex
	clock   uint64
}

// LineEnds is where each line of the transcript ends, as of now: its length is the
// transcript's count of lines. The slice is the caller's to read, never to change.
func (s *Store) LineEnds(id wire.UUID) ([]int64, error) {
	s.ib.mu.Lock()
	defer s.ib.mu.Unlock()
	if s.ib.indexes == nil {
		s.ib.indexes = map[wire.UUID]*lineIndex{}
	}
	f, err := os.Open(s.Loc.Transcript(string(id)))
	if os.IsNotExist(err) {
		delete(s.ib.indexes, id)
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	ix := s.ib.indexes[id]
	if ix == nil {
		ix = &lineIndex{}
		s.ib.indexes[id] = ix
		if len(s.ib.indexes) > indexedTranscripts {
			var oldest wire.UUID
			var at uint64 = ^uint64(0)
			for k, v := range s.ib.indexes {
				if k != id && v.used < at {
					oldest, at = k, v.used
				}
			}
			delete(s.ib.indexes, oldest)
		}
	}
	s.ib.clock++
	ix.used = s.ib.clock
	from := int64(0)
	if n := len(ix.ends); n > 0 {
		from = ix.ends[n-1]
	}
	// Shorter than what was indexed: some other transcript now. Look again.
	if info.Size() < from {
		ix.ends, from = nil, 0
	}
	if info.Size() == from {
		return ix.ends, nil
	}
	r := bufio.NewReaderSize(io.NewSectionReader(f, from, info.Size()-from), 1<<16)
	at := from
	for {
		chunk, err := r.ReadSlice('\n')
		at += int64(len(chunk))
		if len(chunk) > 0 && chunk[len(chunk)-1] == '\n' {
			ix.ends = append(ix.ends, at)
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			break
		}
	}
	return ix.ends, nil
}

func startOf(ends []int64, line int) int64 {
	if line == 0 {
		return 0
	}
	return ends[line-1]
}

// EachLine calls see with every line from from to to (not included), its bytes and its index,
// until see says false. The bytes are only see's until it returns.
func (s *Store) EachLine(id wire.UUID, ends []int64, from, to int, see func(line []byte, i int) bool) error {
	to = min(to, len(ends))
	if from >= to {
		return nil
	}
	f, err := os.Open(s.Loc.Transcript(string(id)))
	if err != nil {
		return err
	}
	defer f.Close()
	start := startOf(ends, from)
	r := bufio.NewReaderSize(io.NewSectionReader(f, start, ends[to-1]-start), 1<<16)
	var line []byte
	for i := from; i < to; {
		chunk, err := r.ReadSlice('\n')
		line = append(line, chunk...)
		if err == bufio.ErrBufferFull {
			continue
		}
		if len(line) > 0 {
			if !see(line, i) {
				return nil
			}
			i++
			line = line[:0]
		}
		if err != nil {
			return nil
		}
	}
	return nil
}

// Entries is the entries on lines from to to (not included) of the transcript as indexed
// by ends, each with its line. A line that will not decode is skipped, as
// TranscriptReader skips one, and still counts as a line.
func (s *Store) Entries(id wire.UUID, ends []int64, from, to int) ([]wire.TranscriptEntry, []int, error) {
	var out []wire.TranscriptEntry
	var at []int
	err := s.EachLine(id, ends, from, to, func(line []byte, i int) bool {
		if len(bytes.TrimSpace(line)) == 0 {
			return true
		}
		var e wire.TranscriptEntry
		if diskjson.Unmarshal(line, &e) == nil {
			out = append(out, e)
			at = append(at, i)
		}
		return true
	})
	return out, at, err
}

// LinesContaining is the lines from from on whose bytes hold what, none of them decoded:
// a key such as "userMessage" in quotes is only ever a key, since a string's quotes are
// escaped.
func (s *Store) LinesContaining(id wire.UUID, ends []int64, what string, from int) ([]int, error) {
	var out []int
	needle := []byte(what)
	err := s.EachLine(id, ends, from, len(ends), func(line []byte, i int) bool {
		if bytes.Contains(line, needle) {
			out = append(out, i)
		}
		return true
	})
	return out, err
}

// EntriesFrom calls see with each entry on the whole lines after byte from, with where its
// line starts and ends, past the kept line indexes: a reader that keeps its own place (said.json,
// P20261019-1) pushes no open chat's index out. end is where the last whole line ends and size
// the transcript's size as read; under from, it is some other transcript now, and nothing is read.
func (s *Store) EntriesFrom(id wire.UUID, from int64, see func(e wire.TranscriptEntry, start, end int64)) (end, size int64, err error) {
	f, err := os.Open(s.Loc.Transcript(string(id)))
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return 0, 0, err
	}
	if size = info.Size(); size <= from {
		return min(from, size), size, nil
	}
	r := bufio.NewReaderSize(io.NewSectionReader(f, from, size-from), 1<<16)
	end = from
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		line = append(line, chunk...)
		if err == bufio.ErrBufferFull {
			continue
		}
		if len(line) == 0 || line[len(line)-1] != '\n' {
			return end, size, nil
		}
		start := end
		end += int64(len(line))
		if len(bytes.TrimSpace(line)) > 0 {
			var e wire.TranscriptEntry
			if diskjson.Unmarshal(line, &e) == nil {
				see(e, start, end)
			}
		}
		line = line[:0]
		if err != nil {
			return end, size, nil
		}
	}
}
