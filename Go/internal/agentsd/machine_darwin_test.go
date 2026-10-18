package agentsd

import (
	"os"
	"path/filepath"
	"testing"
)

// agents-watch --machine's words, as a host hears them (#1368): what the first look found
// carries the restart, what follows does not, and the helper is told how the person stood.
func TestTheMachineWatchIsHeard(t *testing.T) {
	dir := t.TempDir()
	asked := filepath.Join(dir, "asked")
	helper := filepath.Join(dir, "agents-watch")
	os.WriteFile(helper, []byte("#!/bin/sh\necho \"$@\" > "+asked+"\nprintf 'back:locked\\000\\000ready\\000sleep\\000wake\\000away:idle\\000'\ncat > /dev/null\n"), 0o755)
	old := watchHelper
	watchHelper = func() string { return helper }
	defer func() { watchHelper = old }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	locked := "locked"
	d.eventMu.Lock()
	d.eventStateNow.PersonAway = &locked
	d.eventMu.Unlock()
	d.machineMu.Lock()
	d.machineAfterRestart = true
	d.machineMu.Unlock()
	d.StartMachineWatch()
	waitFor(t, "away:idle", func() bool { return lastEvent(d, "person.away") != nil })
	if b, _ := os.ReadFile(asked); string(b) != "--machine locked\n" {
		t.Fatalf("%q", b)
	}
	if e := lastEvent(d, "person.back"); e == nil || e.Details["noticed"] != "after_restart" {
		t.Fatalf("%+v", e)
	}
	if lastEvent(d, "mac.sleep") == nil || lastEvent(d, "mac.wake") == nil {
		t.Fatal("no sleep or wake")
	}
	if e := lastEvent(d, "person.away"); e.Details["why"] != "idle" || e.Details["noticed"] != "" || d.personAway() != "idle" {
		t.Fatalf("%+v", e)
	}
}

// The real helper, built from Host/AgentsWatch: its first look ends with ready.
func TestTheRealMachineWatchSaysReady(t *testing.T) {
	prepareWatch(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.machineMu.Lock()
	d.machineAfterRestart = true
	d.machineMu.Unlock()
	d.StartMachineWatch()
	waitFor(t, "ready", func() bool {
		d.machineMu.Lock()
		defer d.machineMu.Unlock()
		return !d.machineAfterRestart
	})
}
