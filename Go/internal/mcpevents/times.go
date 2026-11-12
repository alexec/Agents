package mcpevents

import "time"

// The servers' one time layout (#4187): a cursor's time, and the newest a listing saw, are
// UTC with milliseconds, so two times sort as text.

// TimeLayout is the one layout of the servers' times.
const TimeLayout = "2006-01-02T15:04:05.000Z"

// TimeString is t in TimeLayout.
func TimeString(t time.Time) string { return t.UTC().Format(TimeLayout) }

// ParseTime is text as an RFC 3339 time; ok is false when it is not one.
func ParseTime(text string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, text)
	return t, err == nil
}

// Normalized is text in TimeLayout, or "" when it is not a time.
func Normalized(text string) string {
	t, ok := ParseTime(text)
	if !ok {
		return ""
	}
	return TimeString(t)
}

// Before says whether a is earlier than b; a time that is not one is earliest of all.
func Before(a, b string) bool {
	ta, oka := ParseTime(a)
	tb, okb := ParseTime(b)
	switch {
	case !oka:
		return okb
	case !okb:
		return false
	}
	return ta.Before(tb)
}

// Saw is l with the time t seen too: Newest moves on to t, in TimeLayout, when t is later.
func (l Listed) Saw(t string) Listed {
	if t = Normalized(t); t > l.Newest {
		l.Newest = t
	}
	return l
}
