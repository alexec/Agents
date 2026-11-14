package agentsd

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A lease's line (#4268): a wait can say `by`, when its step stops mattering, which puts
// it ahead in the line.

// leaseBy is lease_resource's `by`: minutes from now ("5", or 5), a time today ("14:05"),
// or an ISO 8601 time. Nil when none was given or it cannot be read.
func leaseBy(raw json.RawMessage, at time.Time) *wire.Date {
	if len(raw) == 0 {
		return nil
	}
	var n float64
	var s string
	switch {
	case json.Unmarshal(raw, &n) == nil:
	case json.Unmarshal(raw, &s) == nil:
		s = strings.TrimSpace(s)
		if m, err := strconv.ParseFloat(s, 64); err == nil {
			n = m
			break
		}
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			by := wire.DateOf(t)
			return &by
		}
		if t, err := time.ParseInLocation("15:04", s, at.Location()); err == nil {
			y, mo, day := at.Date()
			by := wire.DateOf(time.Date(y, mo, day, t.Hour(), t.Minute(), 0, 0, at.Location()))
			return &by
		}
		return nil
	default:
		return nil
	}
	if n <= 0 {
		return nil
	}
	by := wire.DateOf(at.Add(time.Duration(n * float64(time.Minute))))
	return &by
}

// lineBefore is the line's order: a wait with a `by` before one with none, the earliest
// `by` first, then whoever asked first (#4041).
func lineBefore(a, b waiter) bool {
	if (a.By != nil) != (b.By != nil) {
		return a.By != nil
	}
	if a.By != nil && *a.By != *b.By {
		return *a.By < *b.By
	}
	return a.AskedAt < b.AskedAt
}

// joinLine puts a waiter in its place in the line, and says that place (from 1).
func joinLine(e *leaseEntry, w waiter) int {
	i := 0
	for i < len(e.Line) && !lineBefore(w, e.Line[i]) {
		i++
	}
	e.Line = append(e.Line[:i], append([]waiter{w}, e.Line[i:]...)...)
	return i + 1
}
