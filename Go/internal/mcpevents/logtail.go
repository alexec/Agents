package mcpevents

import (
	"bufio"
	"bytes"
	"io"
	"strings"
)

// tailSlack is how many lines before the last n are kept too, for those at the end that are
// nothing once cleaned.
const tailSlack = 100

// maxLogLine is how much of one line of a log is kept: its start.
const maxLogLine = 16 << 10

// LogTail is the last n lines of a CI log as it is read, each cleaned by plain and without a
// trailing \r, and without the trailing lines that are blank once cleaned; with partial, the
// first line is dropped, as it is the end of one a range cut. A log can be tens of MB: it is
// never held whole, as its lines are kept in a ring. err is the reader's.
func LogTail(r io.Reader, n int, partial bool, plain func(string) string) (string, error) {
	br := bufio.NewReaderSize(r, 64<<10)
	ring := make([][]byte, n+tailSlack)
	next, count := 0, 0
	var line []byte
	for {
		chunk, err := br.ReadSlice('\n')
		if len(line) < maxLogLine {
			line = append(line, chunk[:min(len(chunk), maxLogLine-len(line))]...)
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if len(chunk) > 0 && chunk[len(chunk)-1] == '\n' || (err == io.EOF && len(line) > 0) {
			if partial {
				partial = false
			} else {
				ring[next] = append(ring[next][:0], bytes.TrimSuffix(line, []byte("\n"))...)
				next, count = (next+1)%len(ring), count+1
			}
			line = line[:0]
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
	}
	kept := min(count, len(ring))
	lines := make([]string, 0, kept)
	for i := range kept {
		lines = append(lines, strings.TrimSuffix(plain(string(ring[(next-kept+i+len(ring))%len(ring)])), "\r"))
	}
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n"), nil
}
