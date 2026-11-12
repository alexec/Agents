package mcpevents

import (
	"testing"
	"time"
)

func TestTimesAreInTheOneLayout(t *testing.T) {
	if got := TimeString(time.Date(2026, 11, 2, 9, 15, 0, 5e6, time.FixedZone("x", 3600))); got != "2026-11-02T08:15:00.005Z" {
		t.Fatalf("TimeString: %q", got)
	}
	if got := Normalized("2026-11-02T09:15:00+01:00"); got != "2026-11-02T08:15:00.000Z" {
		t.Fatalf("Normalized: %q", got)
	}
	if got := Normalized("yesterday"); got != "" {
		t.Fatalf("Normalized of no time: %q", got)
	}
	if !Before("2026-11-02T08:00:00Z", "2026-11-02T09:00:00+00:00") || Before("2026-11-02T09:00:00Z", "2026-11-02T08:00:00Z") {
		t.Fatal("Before does not order two times")
	}
	if !Before("not a time", "2026-11-02T08:00:00Z") || Before("2026-11-02T08:00:00Z", "not a time") || Before("x", "y") {
		t.Fatal("a time that is not one is not earliest of all")
	}
}

func TestListedSawKeepsTheNewest(t *testing.T) {
	l := Listed{Truncated: true}.Saw("2026-11-02T09:00:00+01:00").Saw("2026-11-01T00:00:00Z").Saw("not a time")
	if l.Newest != "2026-11-02T08:00:00.000Z" || !l.Truncated {
		t.Fatalf("%+v", l)
	}
}
