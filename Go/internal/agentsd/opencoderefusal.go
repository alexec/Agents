package agentsd

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A refused OpenCode turn (#3736): when its model provider refuses (a spent free allowance,
// a bad key), OpenCode writes a "stream error" to its own log and then neither sends an
// update nor answers session/prompt, so the turn would run for ever. The daemon reads the
// new lines of that log while an OpenCode turn runs, and a refusal for the turn's session,
// with no update after it for a while, ends the turn with the provider's words.

// openCodeRefusalPoll is how often the log is read; openCodeRefusalGrace is how long the
// runtime has after a stream error to show it is still going (a retry of its own).
var (
	openCodeRefusalPoll  = 5 * time.Second
	openCodeRefusalGrace = 20 * time.Second
)

// openCodeLogReadLimit bounds one read of the log: OpenCode's log is one file that grows,
// and only what it wrote during the turn is read.
const openCodeLogReadLimit = 1 << 20

// openCodeLogDir is where OpenCode writes its log, for the environment it was launched with.
func openCodeLogDir(getenv func(string) string) string {
	data := getenv("XDG_DATA_HOME")
	if data == "" {
		home := getenv("HOME")
		if home == "" {
			return ""
		}
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "opencode", "log")
}

// openCodeLog is the log OpenCode writes now: opencode.log, else the newest *.log, else
// opencode.log as the one it will make.
func openCodeLog(dir string) string {
	if dir == "" {
		return ""
	}
	if p := filepath.Join(dir, "opencode.log"); fileExists(p) {
		return p
	}
	paths, _ := filepath.Glob(filepath.Join(dir, "*.log"))
	newest, at := "", time.Time{}
	for _, p := range paths {
		if fi, err := os.Stat(p); err == nil && fi.ModTime().After(at) {
			newest, at = p, fi.ModTime()
		}
	}
	if newest == "" {
		return filepath.Join(dir, "opencode.log")
	}
	return newest
}

// openCodeLogTail reads what a log gained since offset: the next offset and its whole lines.
// A log that got shorter was started again, and is read from its start.
type openCodeLogTail struct {
	path   string
	offset int64
}

func newOpenCodeLogTail(path string) *openCodeLogTail {
	t := &openCodeLogTail{path: path}
	if fi, err := os.Stat(path); err == nil {
		t.offset = fi.Size()
	}
	return t
}

func (t *openCodeLogTail) lines() []string {
	f, err := os.Open(t.path)
	if err != nil {
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil
	}
	if fi.Size() < t.offset {
		t.offset = 0
	}
	if fi.Size() == t.offset {
		return nil
	}
	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return nil
	}
	b, _ := io.ReadAll(io.LimitReader(f, openCodeLogReadLimit))
	// Only whole lines: the rest is read next time, unless one line is longer than a read.
	end := bytes.LastIndexByte(b, '\n')
	if end < 0 {
		if len(b) < openCodeLogReadLimit {
			return nil
		}
		end = len(b) - 1
	}
	t.offset += int64(end + 1)
	var out []string
	sc := bufio.NewScanner(bytes.NewReader(b[:end+1]))
	sc.Buffer(make([]byte, 0, 64<<10), openCodeLogReadLimit)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out
}

// openCodeStreamError is a log line's refusal for the session: the provider's words, when
// the line is a stream error of the session's main agent (not its title, small=true).
func openCodeStreamError(line, sessionID string) (string, bool) {
	if sessionID == "" || !strings.Contains(line, `message="stream error"`) ||
		!strings.Contains(line, " session.id="+sessionID+" ") || strings.Contains(line, " small=true") {
		return "", false
	}
	_, rest, ok := strings.Cut(line, ` error.error="`)
	if !ok {
		return "", false
	}
	msg, _, _ := strings.Cut(rest, `"`)
	// "AI_APICallError: Free usage limit reached…": the words are the provider's.
	if kind, words, ok := strings.Cut(msg, ": "); ok && strings.HasPrefix(kind, "AI_") {
		msg = words
	}
	msg = strings.TrimSpace(msg)
	return msg, msg != ""
}

// watchOpenCodeRefusal reads the log until ctx ends, and calls refused once with the
// provider's words when the session's turn was refused and no update came for the grace
// after it. lastUpdate is when the runtime last sent an update this turn.
func watchOpenCodeRefusal(ctx context.Context, path, sessionID string, lastUpdate func() time.Time, refused func(string)) {
	if path == "" || sessionID == "" {
		return
	}
	tail := newOpenCodeLogTail(path)
	grace := openCodeRefusalGrace
	tick := time.NewTicker(openCodeRefusalPoll)
	defer tick.Stop()
	var said string
	var seen time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		for _, line := range tail.lines() {
			if msg, ok := openCodeStreamError(line, sessionID); ok {
				said, seen = msg, time.Now()
			}
		}
		if said == "" {
			continue
		}
		// An update after it: OpenCode went on (a retry of its own that worked).
		if lastUpdate().After(seen) {
			said = ""
			continue
		}
		if time.Since(seen) >= grace {
			refused(said)
			return
		}
	}
}

// openCodeRefused ends a turn OpenCode's provider refused: a spent allowance as one, else a
// failed turn in the provider's words. It is true when what is queued behind may go next.
func (d *Daemon) openCodeRefused(l *live, a *wire.Agent, said string) bool {
	log.Printf("agent %s: opencode provider refused the turn: %s", l.id, said)
	l.closeForms(false)
	l.mu.Lock()
	window := l.rateLimit
	l.mu.Unlock()
	if why, ok, retryAt := d.applyLimit(l, classifyLimit(a.RuntimeID, nil, window, nil, "", said), false); ok {
		d.end(l, wire.AgentStateStopped, why)
		if !retryAt.IsZero() {
			l.retryLater(retryAt)
		}
		return false
	}
	d.record(l.id, notice("error", "The turn failed", "OpenCode’s model provider refused it: "+said))
	d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
	return true
}
