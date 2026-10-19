package controlplane

import (
	"os"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/rolllog"
)

// Log is ControlLog: every line stamped with the time and its zone, into control.log
// when serving with one (#93), rolled past 4 MB to control.previous.log (#174) by the
// shared roller (#1555).
type Log struct {
	mu   sync.Mutex
	file *rolllog.File
}

// LogLimit is ControlLog.limit.
const LogLimit = rolllog.Limit

// NewLog writes to standard error until Take.
func NewLog() *Log { return &Log{} }

// Take sends every line, and the process's own standard output and error, to file.
func (l *Log) Take(file string, limit int64) {
	f, err := rolllog.Open(file, limit, true)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file != nil {
		l.file.Close()
	}
	l.file = f
}

// Taken says whether lines go to a file.
func (l *Log) Taken() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file != nil
}

// Write writes a line, each of its lines stamped.
func (l *Log) Write(line string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	text := stamped(line, time.Now())
	if l.file != nil {
		l.file.Write([]byte(text))
		return
	}
	os.Stderr.WriteString(text)
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
