package controlplane

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/redact"
	"github.com/alexec/agents/Go/internal/rolllog"
)

// Log is ControlLog: every line stamped with the time and its zone, into control.log
// when serving with one (#93), rolled past 4 MB to control.previous.log (#174) by the
// shared roller (#1555).
//
// For an operations team (#2176) it writes JSON lines instead (Configure "json"), one
// object a line with time, level and msg, and the copy, method, client, person, host and
// request id where a line has them. A level drops the lines below it. Either way no line
// holds a code, a bearer token or a token=, secret= or password= value: they are cut out.
type Log struct {
	mu    sync.Mutex
	file  *rolllog.File
	json  bool
	level slog.Level
	// to takes the lines instead of standard error, when set: for tests.
	to io.Writer
}

// LogLimit is ControlLog.limit.
const LogLimit = rolllog.Limit

// NewLog writes to standard error until Take.
func NewLog() *Log { return &Log{} }

// Configure sets the format, "text" (the default) or "json", and the lowest level written:
// "debug", "info" (the default), "warn" or "error". Empty leaves each as it is.
func (l *Log) Configure(format, level string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch strings.ToLower(format) {
	case "":
	case "text":
		l.json = false
	case "json":
		l.json = true
	default:
		return fmt.Errorf("the log format %q is not text or json", format)
	}
	if level != "" {
		var v slog.Level
		if err := v.UnmarshalText([]byte(level)); err != nil {
			return fmt.Errorf("the log level %q is not debug, info, warn or error", level)
		}
		l.level = v
	}
	return nil
}

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

// Write writes a line at info, each of its lines stamped.
func (l *Log) Write(line string) { l.WriteAt(slog.LevelInfo, line) }

// WriteAt writes a line at a level. "agents-control[copy]: " in front is the copy's, a
// field of its own in JSON.
func (l *Log) WriteAt(level slog.Level, line string) {
	var attrs []slog.Attr
	if l.isJSON() {
		if rest, ok := strings.CutPrefix(line, "agents-control["); ok {
			if copyID, msg, ok := strings.Cut(rest, "]: "); ok {
				attrs, line = []slog.Attr{slog.String("copy", copyID)}, msg
			}
		} else if msg, ok := strings.CutPrefix(line, "agents-control: "); ok {
			line = msg
		}
	}
	l.emit(time.Now(), level, line, attrs)
}

func (l *Log) isJSON() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.json
}

// Logger is a slog.Logger that writes through this log, in its format and above its level.
func (l *Log) Logger() *slog.Logger { return slog.New(&logHandler{log: l}) }

func (l *Log) emit(at time.Time, level slog.Level, msg string, attrs []slog.Attr) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if level < l.level {
		return
	}
	msg = Redact(msg)
	for i, a := range attrs {
		if a.Value.Kind() == slog.KindString {
			attrs[i].Value = slog.StringValue(Redact(a.Value.String()))
		}
	}
	var text string
	if l.json {
		var b bytes.Buffer
		h := slog.NewJSONHandler(&b, &slog.HandlerOptions{Level: slog.LevelDebug})
		r := slog.NewRecord(at, level, msg, 0)
		r.AddAttrs(attrs...)
		h.Handle(context.Background(), r)
		text = b.String()
	} else {
		var b strings.Builder
		b.WriteString(msg)
		for _, a := range attrs {
			b.WriteString(" " + a.Key + "=" + a.Value.String())
		}
		text = stamped(b.String(), at)
	}
	switch {
	case l.file != nil:
		l.file.Write([]byte(text))
	case l.to != nil:
		io.WriteString(l.to, text)
	default:
		os.Stderr.WriteString(text)
	}
}

// logHandler is Logger's handler.
type logHandler struct {
	log   *Log
	attrs []slog.Attr
}

func (h *logHandler) Enabled(_ context.Context, level slog.Level) bool {
	h.log.mu.Lock()
	defer h.log.mu.Unlock()
	return level >= h.log.level
}

func (h *logHandler) Handle(_ context.Context, r slog.Record) error {
	attrs := append([]slog.Attr{}, h.attrs...)
	r.Attrs(func(a slog.Attr) bool {
		attrs = append(attrs, a)
		return true
	})
	h.log.emit(r.Time, r.Level, r.Message, attrs)
	return nil
}

func (h *logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &logHandler{log: h.log, attrs: append(append([]slog.Attr{}, h.attrs...), attrs...)}
}

// WithGroup is not used: the fields are flat.
func (h *logHandler) WithGroup(string) slog.Handler { return h }

// redactions are what Redact cuts out of a line.
var redactions = []struct {
	re   *regexp.Regexp
	with string
}{
	// A code to pair or join: agents-control:<version>:…
	{regexp.MustCompile(`agents-control:\d+:[^\s'"]+`), "agents-control:<code>"},
	{regexp.MustCompile(`(?i)(bearer\s+)[^\s'"]+`), "${1}<token>"},
	{regexp.MustCompile(`(?i)\b((?:access_|refresh_|id_)?token|secret|password|passwd)=[^\s&'"]+`), "${1}=<redacted>"},
}

// Redact cuts codes and tokens out of a log line: its own shapes, then the known token
// shapes a machine cuts out of transcripts (#1001, redact.Text).
func Redact(line string) string {
	for _, r := range redactions {
		line = r.re.ReplaceAllString(line, r.with)
	}
	return redact.Text(line)
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
