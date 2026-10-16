package controlplane

import (
	"os"
	"strings"
	"sync"
	"time"
)

// Log is ControlLog: every line stamped with the time and its zone, into control.log
// when serving with one (#93), rolled past 4 MB to control.previous.log (#174).
type Log struct {
	mu    sync.Mutex
	file  string
	limit int64
	out   *os.File
}

// LogLimit is ControlLog.limit.
const LogLimit = 4 * 1024 * 1024

// NewLog writes to standard error until Take.
func NewLog() *Log { return &Log{limit: LogLimit, out: os.Stderr} }

// Take sends every line, and the process's own standard output and error, to file.
func (l *Log) Take(file string, limit int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.file, l.limit = file, limit
	l.reopen()
}

// Taken says whether lines go to a file.
func (l *Log) Taken() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file != ""
}

// Write writes a line, each of its lines stamped.
func (l *Log) Write(line string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file != "" {
		l.rollIfNeeded()
	}
	l.out.WriteString(stamped(line, time.Now()))
}

// stamped is ControlLog.stamped: ISO 8601 with milliseconds and the local zone, before
// every line.
func stamped(message string, at time.Time) string {
	stamp := at.Local().Format("2006-01-02T15:04:05.000Z07:00")
	var b strings.Builder
	for _, line := range strings.Split(message, "\n") {
		b.WriteString(stamp + " " + line + "\n")
	}
	return b.String()
}

func (l *Log) rollIfNeeded() {
	info, err := l.out.Stat()
	if err != nil || info.Size() <= l.limit {
		return
	}
	previous := strings.TrimSuffix(l.file, ".log") + ".previous.log"
	os.Rename(l.file, previous)
	l.reopen()
}

func (l *Log) reopen() {
	f, err := os.OpenFile(l.file, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	// Whatever the runtime itself writes (a panic) lands beside the lines.
	dupTo(int(f.Fd()), 1)
	dupTo(int(f.Fd()), 2)
	if l.out != os.Stderr {
		l.out.Close()
	}
	l.out = f
}
