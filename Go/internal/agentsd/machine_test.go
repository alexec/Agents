package agentsd

import (
	"testing"
)

func countEvents(d *Daemon, name string) int {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	n := 0
	for _, e := range d.eventList {
		if e.Name == name {
			n += int(e.Count)
		}
	}
	return n
}

// The Mac and the person, as the Swift host says them (#1368): the sentence, why, and the
// person's standing kept for the next host's first look (#1219).
func TestMachineChangesAreItsEvents(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	for _, w := range []string{"", "nap", "away", "away:asleep", "sleep:x"} {
		if _, ok := parseMachineChange(w); ok {
			t.Fatalf("%q read", w)
		}
	}
	for _, w := range []string{"sleep", "wake", "away:locked", "back:locked", "away:idle", "back:idle"} {
		c, ok := parseMachineChange(w)
		if !ok {
			t.Fatalf("%q not read", w)
		}
		d.machineChanged(c)
	}
	if e := lastEvent(d, "mac.sleep"); e == nil || e.Sentence != "This Mac went to sleep." || e.Scope.Mac == nil {
		t.Fatalf("%+v", e)
	}
	if e := lastEvent(d, "mac.wake"); e == nil || e.Sentence != "This Mac woke up." {
		t.Fatalf("%+v", e)
	}
	if n := countEvents(d, "person.away"); n != 2 {
		t.Fatalf("%d", n)
	}
	if e := lastEvent(d, "person.back"); e == nil || e.Sentence != "You came back." || e.Details["why"] != "idle" || e.Details["noticed"] != "" {
		t.Fatalf("%+v", e)
	}
	if d.personAway() != "" {
		t.Fatal(d.personAway())
	}
	// Heard in the first look after a restart: it happened while no host ran.
	d.machineMu.Lock()
	d.machineAfterRestart = true
	d.machineMu.Unlock()
	d.machineChanged(machineChange{kind: "away", why: "locked"})
	if e := lastEvent(d, "person.away"); e.Sentence != "You locked the screen." || e.Details["noticed"] != "after_restart" {
		t.Fatalf("%+v", e)
	}
	if d.personAway() != "locked" {
		t.Fatal(d.personAway())
	}
	d.machineFirstLookDone()
	d.machineChanged(machineChange{kind: "back", why: "locked"})
	if e := lastEvent(d, "person.back"); e.Sentence != "You unlocked the screen." || e.Details["noticed"] != "" {
		t.Fatalf("%+v", e)
	}
}
