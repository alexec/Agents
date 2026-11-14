package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A lease's line in `by` order (#4268).

func TestLeaseByReadsMinutesAndTimes(t *testing.T) {
	at := time.Date(2026, 11, 9, 14, 0, 0, 0, time.Local)
	for _, tc := range []struct {
		raw  string
		want time.Time
	}{
		{`5`, at.Add(5 * time.Minute)},
		{`"5"`, at.Add(5 * time.Minute)},
		{`"14:30"`, at.Add(30 * time.Minute)},
		{`"2026-11-09T22:10:00Z"`, time.Date(2026, 11, 9, 22, 10, 0, 0, time.UTC)},
	} {
		got := leaseBy(json.RawMessage(tc.raw), at)
		if got == nil || !got.Time().Equal(tc.want) {
			t.Fatalf("%s: %v, want %v", tc.raw, got, tc.want)
		}
	}
	for _, raw := range []string{``, `0`, `"soon"`, `true`} {
		if got := leaseBy(json.RawMessage(raw), at); got != nil {
			t.Fatalf("%q: %v", raw, *got)
		}
	}
}

func TestTheLineIsInByOrder(t *testing.T) {
	at := time.Date(2026, 11, 9, 14, 0, 0, 0, time.UTC)
	when := func(m int) *wire.Date { d := wire.DateOf(at.Add(time.Duration(m) * time.Minute)); return &d }
	e := &leaseEntry{}
	w := func(id string, asked int, by *wire.Date) waiter {
		return waiter{AgentID: wire.UUID(id), AskedAt: wire.DateOf(at.Add(time.Duration(asked) * time.Second)), By: by}
	}
	places := []int{
		joinLine(e, w("none-1", 1, nil)),
		joinLine(e, w("by-10", 2, when(10))),
		joinLine(e, w("by-5", 3, when(5))),
		joinLine(e, w("none-2", 4, nil)),
		joinLine(e, w("by-5-later", 5, when(5))),
	}
	var got []string
	for _, l := range e.Line {
		got = append(got, string(l.AgentID))
	}
	if strings.Join(got, " ") != "by-5 by-5-later by-10 none-1 none-2" || places[2] != 1 || places[3] != 4 || places[4] != 2 {
		t.Fatalf("%v %v", got, places)
	}
}
