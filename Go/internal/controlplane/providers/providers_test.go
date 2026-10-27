package providers

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Machine providers on the control plane (#691): adding one, linking a host to its
// workspace, and Start and Stop, against a stand-in provider. A host comes online by the
// router being told so, as its uplink would. Ports WorkspaceProvidersTests.swift.

func TestAProviderIsListedWithItsWorkspacesAndNeverItsSecret(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	listed := h.must(MethodProvidersList, map[string]any{}).(map[string]any)["providers"].([]ProviderSummary)
	if len(listed) != 1 {
		t.Fatalf("listed %v", listed)
	}
	s := listed[0]
	if string(s.ID) != id || s.Name != "DigitalOcean" || deref(s.Preset) != "doctl" {
		t.Errorf("summary %+v", s)
	}
	if names := []string{s.Workspaces[0].Name, s.Workspaces[1].Name}; !reflect.DeepEqual(names, []string{"agents-devbox", "scratch-1"}) {
		t.Errorf("workspaces %v", names)
	}
	if !reflect.DeepEqual(s.Secrets, map[string]bool{"DIGITALOCEAN_TOKEN": true}) {
		t.Errorf("secrets %v", s.Secrets)
	}
	if strings.Contains(string(rawOf(s)), "hunter2") {
		t.Error("the summary holds the secret")
	}
	// Not in the store: only in the home's file, which only its user can read (FR-003).
	keys, _ := h.store.List(context.Background(), "")
	for _, k := range keys {
		object, _ := h.store.Get(context.Background(), k.Key)
		if strings.Contains(string(object.Data), "hunter2") {
			t.Errorf("%s holds the secret", k.Key)
		}
	}
	file := filepath.Join(h.home, SecretsFileName)
	data, err := os.ReadFile(file)
	if err != nil || !strings.Contains(string(data), "hunter2") {
		t.Errorf("secrets file %q %v", data, err)
	}
	if info, _ := os.Stat(file); info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", info.Mode())
	}
}

func TestTheProviderRecordIsKeptAtTheSwiftKey(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	object, _ := h.store.Get(context.Background(), "v1/providers/"+id+".json")
	if object == nil {
		t.Fatal("no record")
	}
	var stored map[string]any
	json.Unmarshal(object.Data, &stored)
	for _, key := range []string{"id", "name", "kind", "secretNames", "capabilities", "contract", "rev", "commands"} {
		if _, ok := stored[key]; !ok {
			t.Errorf("no %s in %s", key, object.Data)
		}
	}
	// A record as Swift writes it is read, and what this build does not know is kept.
	swift := `{"capabilities":[],"contract":1,"id":"do-x1y2","kind":"stdio","name":"DO","rev":1,"secretNames":[],"later":true}`
	var r ProviderRecord
	if err := json.Unmarshal([]byte(swift), &r); err != nil || r.WrittenBy != nil {
		t.Fatalf("%v %+v", err, r)
	}
	if !strings.Contains(string(rawOf(r)), `"later":true`) {
		t.Error("an unknown field was dropped")
	}
}

func TestAServerThatIsNotAProviderIsRefusedInItsWords(t *testing.T) {
	h := newHarness(t)
	h.provider.set("It isn’t a machine provider: it has no workspace_stop tool.", "", 0)
	_, err := h.call(MethodProvidersAdd, map[string]any{"name": "DigitalOcean", "kind": "commands", "commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || f.Code != CodeInvalidParams || f.Message != "It isn’t a machine provider: it has no workspace_stop tool." {
		t.Fatalf("%v", err)
	}
	if listed := h.must(MethodProvidersList, nil).(map[string]any)["providers"].([]ProviderSummary); len(listed) != 0 {
		t.Errorf("listed %v", listed)
	}
}

func TestAProviderWithoutANameIsRefused(t *testing.T) {
	h := newHarness(t)
	_, err := h.call(MethodProvidersAdd, map[string]any{"name": " ", "kind": "commands", "commands": map[string]any{"preset": "docker"}})
	if f := failureOf(err); f == nil || f.Message != "Give it a name." {
		t.Fatalf("%v", err)
	}
}

func TestProvidersAreReadBackAfterARestart(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	again := NewProviders(Config{Store: h.store, Records: h.records, Router: h.router, Methods: h.methods,
		Secrets: NewSecrets(h.home), Timing: quickTiming(),
		Hooks: Hooks{Connect: func(ProviderRecord, map[string]string) (Provider, error) { return h.provider, nil }}})
	again.Start()
	defer again.Stop()
	if s := again.Summaries(); len(s) != 1 || string(s[0].ID) != id {
		t.Errorf("%v", s)
	}
}

func TestALinkedHostWhoseWorkspaceIsStoppedIsShownStopped(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	r := h.row(devbox)
	if r.State != "stopped" || r.Workspace == nil || r.Workspace.WorkspaceName != "agents-devbox" ||
		r.Workspace.ProviderName != "DigitalOcean" || !r.Workspace.CanStart || !r.Workspace.StartWhenUsed ||
		r.Workspace.StopWhenIdleMinutes == nil || *r.Workspace.StopWhenIdleMinutes != 30 {
		t.Fatalf("%+v %+v", r, r.Workspace)
	}
	// The link is the host's record, so it is there after a restart.
	if link := LinkOf(h.records.Host(devbox)); link == nil || link.Workspace != "agents-devbox" {
		t.Errorf("link %+v", link)
	}
}

func TestLinkingAWorkspaceAgainMovesItsLink(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.link(id, devbox, "agents-devbox")
	h.link(id, other, "agents-devbox")
	if LinkOf(h.records.Host(devbox)) != nil {
		t.Error("devbox is still linked")
	}
	if link := LinkOf(h.records.Host(other)); link == nil || link.Workspace != "agents-devbox" {
		t.Error("other is not linked")
	}
	if r := h.row(devbox); r.State != "offline" {
		t.Errorf("%+v", r)
	}
}

func TestRemovingAProviderLeavesItsHostsUnlinked(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.link(id, devbox, "agents-devbox")
	h.must(MethodProvidersRemove, map[string]string{"id": id})
	r := h.row(devbox)
	if r.Workspace != nil || r.State != "offline" || h.records.Host(devbox) == nil {
		t.Fatalf("%+v", r)
	}
	data, _ := os.ReadFile(filepath.Join(h.home, SecretsFileName))
	if strings.Contains(string(data), "hunter2") {
		t.Error("the secret stayed")
	}
}

func TestStartShowsEachPhaseUntilTheHostConnects(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	started := h.must(MethodHostsStart, map[string]string{"host": devbox}).(row)
	if started.State != "starting" {
		t.Errorf("%+v", started)
	}
	waiting := h.waitFor("starting", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "connecting" })
	if deref(waiting.Workspace.Phase) != "connecting" {
		t.Errorf("phase %q", deref(waiting.Workspace.Phase))
	}
	if starts, _ := h.provider.count(); starts != 1 {
		t.Errorf("starts %d", starts)
	}
	h.router.setOnline(devbox, true)
	online := h.waitFor("online", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "" })
	if online.Workspace.WorkspaceState != "running" || !online.Workspace.CanStop || deref(online.Workspace.Problem) != "" {
		t.Errorf("%+v", online.Workspace)
	}
	// How long it took, for a wake-up call (#1004 FR-004).
	if link := LinkOf(h.records.Host(devbox)); link.MeasuredStartSeconds == nil {
		t.Error("no measured start")
	}
}

func TestASecondStartJoinsTheFirst(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "", 200*time.Millisecond)
	for range 3 {
		h.must(MethodHostsStart, map[string]string{"host": devbox})
	}
	h.waitFor("starting", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "connecting" })
	if starts, _ := h.provider.count(); starts != 1 {
		t.Errorf("starts %d", starts)
	}
}

func TestAFailedStartSaysWhyAndOffersStartAgain(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "Error: droplet is locked", 0)
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("stopped", devbox, 5, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	if deref(r.Workspace.Problem) != "Couldn’t start devbox: Error: droplet is locked" || !r.Workspace.CanStart {
		t.Errorf("%+v", r.Workspace)
	}
}

func TestAHostThatDoesNotConnectIsStartedOverSSHThenGivenUp(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter, o.timing.GiveUp = 100*time.Millisecond, 2*time.Second
	})
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	if !reflect.DeepEqual(h.ssh.all(), []string{"alex@127.0.0.1 -p 2222"}) {
		t.Errorf("ssh %v", h.ssh.all())
	}
	if deref(r.Workspace.Problem) != "devbox didn’t connect in 2 seconds." || !r.Workspace.CanStart {
		t.Errorf("%+v", r.Workspace)
	}
}

func TestAFailedSSHStartEndsTheStartAtOnceInWords(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter = 100 * time.Millisecond
		o.sshFails = SayHostKeyUnknown("alex@127.0.0.1 -p 2222")
	})
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	want := "devbox started, but its agentsd didn’t connect, and starting it over ssh failed. " +
		"Its host key isn’t in your known_hosts. Check and trust it with “ssh alex@127.0.0.1 -p 2222”, then start it again."
	if deref(r.Workspace.Problem) != want || !r.Workspace.CanStart {
		t.Errorf("%q", deref(r.Workspace.Problem))
	}
}

func TestWithoutTheProvidersSSHItStartsOverTheInstallsDestination(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter, o.timing.GiveUp = 100*time.Millisecond, 2*time.Second
		o.workspaces = []MachineInfo{{ID: "cs-1", Name: "cs-1", State: "stopped"}}
		o.installedOver = "cs.cs-1.main"
	})
	h.link(h.add(), devbox, "cs-1")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	if !reflect.DeepEqual(h.ssh.all(), []string{"cs.cs-1.main"}) || deref(r.Workspace.Problem) != "devbox didn’t connect in 2 seconds." {
		t.Errorf("%v %q", h.ssh.all(), deref(r.Workspace.Problem))
	}
}

// A workstation's host key is new at each start (#1701): the ssh start after the control
// plane's own Start is told to take the new one.
func TestTheSSHStartOfAWorkspaceThatRenewsItsKeyTakesTheNewOne(t *testing.T) {
	renews := true
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter, o.timing.GiveUp = 100*time.Millisecond, 2*time.Second
		o.workspaces = []MachineInfo{{ID: "ws-1", Name: "ws-1", State: "stopped", SSH: new("ws-1.alias"), HostKeyRenews: &renews}}
	})
	h.link(h.add(), devbox, "ws-1")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	h.waitFor("offline", devbox, 15, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	if !reflect.DeepEqual(h.ssh.all(), []string{"ws-1.alias (new key taken)"}) {
		t.Errorf("%v", h.ssh.all())
	}
	if got := h.providers.Listed(devbox); got != "ws-1.alias" {
		t.Errorf("listed %q", got)
	}
}

func TestLinkingListsTheProviderAgain(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.provider.setStateLocked("agents-devbox", "running")
	h.link(id, devbox, "agents-devbox")
	r := h.waitFor("offline", devbox, 5, func(r row) bool { return r.Workspace.WorkspaceState == "running" })
	if r.Workspace.WorkspaceState != "running" || r.Workspace.CanStart {
		t.Errorf("%+v", r.Workspace)
	}
}

func TestStopStopsTheWorkspace(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	stopping := h.must(MethodHostsStop, MachineStop{Host: devbox}).(row)
	if stopping.State != "stopping" {
		t.Errorf("%+v", stopping)
	}
	h.router.setOnline(devbox, false)
	stopped := h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.CanStart })
	if stopped.Workspace.WorkspaceState != "stopped" {
		t.Errorf("%+v", stopped.Workspace)
	}
	if _, stops := h.provider.count(); stops != 1 {
		t.Errorf("stops %d", stops)
	}
}

// #1701: a stopped host's connection can stay open a minute through a provider's tunnel.
// It is closed when the stop is done, so a Start waits for a new one and does not take
// the old one for it.
func TestAStoppedHostsOldConnectionIsClosed(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	h.must(MethodHostsStop, MachineStop{Host: devbox})
	h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.CanStart })
	h.router.mu.Lock()
	stopped := append([]string{}, h.router.stopped...)
	h.router.mu.Unlock()
	if len(stopped) != 1 || stopped[0] != devbox {
		t.Fatalf("closed %q", stopped)
	}
	if h.router.Online(devbox) {
		t.Fatal("still online after its stop")
	}
}

func TestStopWhileAgentsWorkIsAskedFirst(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, MachineStatus{Idle: false, Running: []string{"Claude (fix-login)", "Codex (docs)"}})
	_, err := h.call(MethodHostsStop, MachineStop{Host: devbox})
	f := failureOf(err)
	if f == nil || f.Code != CodeAgentsWorking || f.Message != "Stop devbox? Claude (fix-login) and Codex (docs) are working there." ||
		string(f.Data) != `{"running":["Claude (fix-login)","Codex (docs)"]}` {
		t.Fatalf("%v", err)
	}
	yes := true
	if r := h.must(MethodHostsStop, MachineStop{Host: devbox, ConfirmRunning: &yes}).(row); r.State != "stopping" {
		t.Errorf("%+v", r)
	}
}

func TestStopWhileStartingIsRefusedNotDropped(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "", 300*time.Millisecond)
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	_, err := h.call(MethodHostsStop, MachineStop{Host: devbox})
	if f := failureOf(err); f == nil || f.Code != CodeProviderFailed || f.Message != "devbox is starting. Stop it once it has started." {
		t.Fatalf("%v", err)
	}
	if _, stops := h.provider.count(); stops != 0 {
		t.Error("stopped")
	}
}

func TestStopTheMomentAStartedHostIsOnlineIsHeard(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	h.waitFor("starting", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "connecting" })
	h.router.setOnline(devbox, true)
	h.waitFor("online", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "" && r.Workspace.CanStop })
	if r := h.must(MethodHostsStop, MachineStop{Host: devbox}).(row); r.State != "stopping" {
		t.Errorf("%+v", r)
	}
	h.router.setOnline(devbox, false)
	h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.CanStart })
	if _, stops := h.provider.count(); stops != 1 {
		t.Errorf("stops %d", stops)
	}
}

func TestAnUnlinkedHostCannotBeStarted(t *testing.T) {
	h := newHarness(t)
	_, err := h.call(MethodHostsStart, map[string]string{"host": devbox})
	if f := failureOf(err); f == nil || f.Code != CodeNotLinked || f.Message != "devbox isn’t linked to a workspace." {
		t.Fatalf("%v", err)
	}
	if h.row(devbox).Workspace != nil {
		t.Error("a workspace")
	}
}

func TestAnIdleHostIsStoppedAndSaysSo(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) { o.timing.IdleMinute = 20 * time.Millisecond })
	id := h.add()
	h.link(id, devbox, "scratch-1")
	minutes := 2
	h.must(MethodHostsSetOptions, MachineOptions{Host: devbox, StopWhenIdleMinutes: int64Of(&minutes)})
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, MachineStatus{Idle: true, Running: []string{}})
	if !eventually(t, func() bool { _, stops := h.provider.count(); return stops == 1 }) {
		t.Fatal("not stopped")
	}
	h.router.setOnline(devbox, false)
	r := h.waitFor("stopped", devbox, 5, func(r row) bool { return deref(r.Workspace.StoppedBy) != "" })
	if deref(r.Workspace.StoppedBy) != "Stopped by Agents after 2 minutes idle" {
		t.Errorf("%q", deref(r.Workspace.StoppedBy))
	}
}

func TestBusyAgainCancelsTheIdleCount(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) { o.timing.IdleMinute = 30 * time.Millisecond })
	h.link(h.add(), devbox, "scratch-1")
	one := 1
	h.must(MethodHostsSetOptions, MachineOptions{Host: devbox, StopWhenIdleMinutes: int64Of(&one)})
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, MachineStatus{Idle: true, Running: []string{}})
	h.providers.Heard(devbox, MachineStatus{Idle: false, Running: []string{"Claude (x)"}})
	time.Sleep(100 * time.Millisecond)
	if _, stops := h.provider.count(); stops != 0 {
		t.Error("stopped while busy")
	}
}

func TestAHostsScheduleIsKeptOnItsLinkAndWakesIt(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	due := time.Now().Add(3 * time.Minute)
	h.providers.Heard(devbox, MachineStatus{Idle: true, Running: []string{}, Schedule: &MachineSchedule{At: dateOf(due), Workflow: new("nightly")}})
	link := LinkOf(h.records.Host(devbox))
	if link.Schedule == nil || link.Schedule.Workflow != "nightly" || !sameTime(link.Schedule.At, &due) {
		t.Fatalf("%+v", link.Schedule)
	}
	r := h.row(devbox)
	if deref(r.Workspace.NextWorkflow) != "nightly" || r.Workspace.WakeAt == nil || r.Workspace.TellsSchedule == nil || !*r.Workspace.TellsSchedule {
		t.Errorf("%+v", r.Workspace)
	}
	// Due within the 5 minutes' lead: started once, and marked so.
	h.providers.wakeUps(time.Now())
	h.waitFor("starting", devbox, 5, nil)
	if link := LinkOf(h.records.Host(devbox)); link.WokeFor == nil {
		t.Error("not marked woken")
	}
	eventually(t, func() bool { starts, _ := h.provider.count(); return starts == 1 })
	h.providers.wakeUps(time.Now())
	time.Sleep(100 * time.Millisecond)
	if starts, _ := h.provider.count(); starts != 1 {
		t.Errorf("starts %d", starts)
	}
}

func TestWakeUpCallsAndKeptUp(t *testing.T) {
	now := time.Now()
	at := now.Add(10 * time.Minute)
	seconds := 60
	link := WorkspaceLink{Schedule: &Schedule{At: &at}, MeasuredStartSeconds: &seconds}
	if w := wakeAt(link, now); w == nil || !w.Equal(at.Add(-180*time.Second)) {
		t.Errorf("wake %v", w)
	}
	off := false
	link.StartForSchedules = &off
	if wakeAt(link, now) != nil {
		t.Error("woken with the switch off")
	}
	if !keptUp(link, 15*time.Minute, now) || keptUp(link, 5*time.Minute, now) {
		t.Error("kept up wrong")
	}
	link.WokeFor = &at
	if !keptUp(link, time.Minute, now) {
		t.Error("started for it, but not kept up")
	}
}

func TestAMachineRecordWithALinkReadsAndWritesAsSwiftDoes(t *testing.T) {
	old := `{"id":"devbox01","name":"devbox","reach":{"dialOut":{}},"platform":"","version":"","installed":false,"rev":1}`
	var h records.MachineRecord
	if err := json.Unmarshal([]byte(old), &h); err != nil || LinkOf(&h) != nil {
		t.Fatalf("%v %v", err, LinkOf(&h))
	}
	swift := `{"provider":"do-x1","workspace":"w","startWhenUsed":true,"stopWhenIdleMinutes":30,
		"schedule":{"at":"2026-10-16T09:00:00.000Z","workflow":"nightly"},"wokeFor":"2026-10-16T09:00:00Z","later":1}`
	h.Workspace = json.RawMessage(swift)
	link := LinkOf(&h)
	if link == nil || link.Schedule.Workflow != "nightly" || !link.WokeFor.Equal(*link.Schedule.At) {
		t.Fatalf("%+v", link)
	}
	data, _ := json.Marshal(link)
	if !strings.Contains(string(data), `"later":1`) || !strings.Contains(string(data), `"at":"2026-10-16T09:00:00.000Z"`) {
		t.Errorf("%s", data)
	}
}

func TestOverlayAndOfflineRefusal(t *testing.T) {
	ws := &MachineWorkspace{HostState: new("stopped")}
	if Overlay(map[string]any{"state": "offline"}, false, ws)["state"] != "stopped" {
		t.Error("not laid over")
	}
	if Overlay(map[string]any{"state": "online"}, true, ws)["state"] != "online" {
		t.Error("laid over an online host")
	}
	if Overlay(map[string]any{"state": "online"}, true, &MachineWorkspace{HostState: new("stopping")})["state"] != "stopping" {
		t.Error("stopping not shown")
	}
	if OfflineRefusal(ws).Message != "That machine is stopped. Start it to reach it." || OfflineRefusal(nil).Message != "That machine is offline." {
		t.Error("refusal words")
	}
}

func TestProviderIDsAndWords(t *testing.T) {
	id := MakeProviderID("Digital Ocean!")
	if !strings.HasPrefix(id, "digital-ocean-") || len(id) != len("digital-ocean-")+4 {
		t.Errorf("%s", id)
	}
	if !strings.HasPrefix(MakeProviderID("ÄÖ"), "provider-") {
		t.Error("an empty slug")
	}
	if minuteWords(60) != "1 hour" || minuteWords(120) != "2 hours" || minuteWords(1) != "1 minute" || minuteWords(30) != "30 minutes" {
		t.Error("minute words")
	}
	if andList([]string{"a", "b", "c"}) != "a, b and c" || orList([]string{"a", "b", "c"}) != "a, b or c" {
		t.Error("lists")
	}
	if !MayBe(MachineInfo{Name: "devstack-d7539e59"}, "cws.devstack-d7539e59") || MayBe(MachineInfo{Name: "dev"}, "devstack") {
		t.Error("mayBe")
	}
}

// Making workspaces (#691 US5). Ports MakingWorkspacesTests.swift.

func (h *harness) create(name string, clones []string) (ProviderCreated, error) {
	provider := h.must(MethodProvidersList, nil).(map[string]any)["providers"].([]ProviderSummary)[0].ID
	out, err := h.call(MethodProvidersCreate, ProviderCreate{ID: provider, Name: name, Options: jsonValue(map[string]any{"size": "big"}), Clones: clones})
	if err != nil {
		return ProviderCreated{}, err
	}
	return out.(ProviderCreated), nil
}

func TestTheFormComesFromTheProvidersOptions(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	options := h.must(MethodProvidersOptions, map[string]string{"id": id}).(ProviderOptions)
	if get(get(get(valueOf(options.Schema), "properties"), "size"), "title") != "Size" {
		t.Errorf("%s", options.Schema)
	}
}

func TestAWorkspaceThatInstallsOnFirstBootJoinsAndIsLinked(t *testing.T) {
	h := newHarness(t)
	h.add()
	made, err := h.create("build-2", nil)
	if err != nil || !made.Joining || made.Workspace.ID != "ws-build-2" {
		t.Fatalf("%v %+v", err, made)
	}
	if len(h.provider.firstBoots) != 1 || !strings.HasSuffix(h.provider.firstBoots[0], "sh -s -- 'agents-control:2:h:secret' 'build-2'") {
		t.Errorf("%v", h.provider.firstBoots)
	}
	h.enroll("build002", "build-2")
	if !eventually(t, func() bool { l := LinkOf(h.records.Host("build002")); return l != nil && l.Workspace == "ws-build-2" }) {
		t.Error("not linked")
	}
}

func TestANewWorkspaceClonesItsFoldersOnceItJoins(t *testing.T) {
	h := newHarness(t)
	h.add()
	h.router.answer = func(string, string, json.RawMessage) *Reply { return &Reply{Result: json.RawMessage(`{}`)} }
	urls := []string{"https://github.com/alexec/one.git", "git@github.com:alexec/two.git"}
	if _, err := h.create("build-4", append(urls, "  ")); err != nil {
		t.Fatal(err)
	}
	h.enroll("build004", "build-4")
	eventually(t, func() bool { return len(h.router.deliveries()) == 2 })
	var got []string
	for _, d := range h.router.deliveries() {
		if d.method != MethodFoldersClone || d.host != "build004" || d.client != h.caller.Client {
			t.Errorf("%+v", d)
		}
		var params map[string]string
		json.Unmarshal(d.params, &params)
		got = append(got, params["url"])
	}
	if !reflect.DeepEqual(got, urls) {
		t.Errorf("%v", got)
	}
}

// A machine from a repository (#1809).

func (h *harness) createFrom(name, repository string, clones []string) (ProviderCreated, error) {
	provider := h.must(MethodProvidersList, nil).(map[string]any)["providers"].([]ProviderSummary)[0].ID
	out, err := h.call(MethodProvidersCreate, ProviderCreate{ID: provider, Name: name, Clones: clones, Repository: &repository})
	if err != nil {
		return ProviderCreated{}, err
	}
	return out.(ProviderCreated), nil
}

func TestAMachineFromARepositoryClonesItFirstOnceItJoins(t *testing.T) {
	h := newHarness(t)
	h.add()
	h.router.answer = func(string, string, json.RawMessage) *Reply { return &Reply{Result: json.RawMessage(`{}`)} }
	if _, err := h.createFrom("agents-1", " https://github.com/alexec/agents.git ", []string{"https://github.com/alexec/two"}); err != nil {
		t.Fatal(err)
	}
	h.enroll("agents001", "agents-1")
	eventually(t, func() bool { return len(h.router.deliveries()) == 2 })
	var got []string
	for _, d := range h.router.deliveries() {
		var params map[string]string
		json.Unmarshal(d.params, &params)
		got = append(got, params["url"])
	}
	if !reflect.DeepEqual(got, []string{"https://github.com/alexec/agents.git", "https://github.com/alexec/two"}) {
		t.Errorf("%v", got)
	}
}

func TestAProviderThatMakesItFromTheRepositoryIsGivenOwnerAndName(t *testing.T) {
	h := newHarness(t)
	h.add()
	h.provider.fromRepository = true
	h.provider.firstBootRuns = false
	if _, err := h.createFrom("agents-2", "https://github.com/alexec/agents", nil); err != nil {
		t.Fatal(err)
	}
	if got := h.provider.madeWith; len(got) != 1 || !reflect.DeepEqual(got[0], map[string]any{"repository": "alexec/agents"}) {
		t.Errorf("%v", got)
	}
}

func TestARepositoryIsAnHTTPSAddress(t *testing.T) {
	h := newHarness(t)
	h.add()
	for _, bad := range []string{"git@github.com:alexec/agents.git", "http://github.com/alexec/agents", "https://github.com/agents",
		"https://token@github.com/alexec/agents"} {
		if _, err := h.createFrom("agents-3", bad, nil); err == nil {
			t.Errorf("took %s", bad)
		}
	}
	if len(h.provider.firstBoots) != 0 {
		t.Error("asked the provider")
	}
}

func TestOneThatCantRunTheFirstBootIsLeftToAddOverSSH(t *testing.T) {
	h := newHarness(t)
	h.add()
	h.provider.firstBootRuns = false
	made, err := h.create("build-3", nil)
	if err != nil || made.Joining || deref(made.Workspace.SSH) != "root@10.0.0.9" {
		t.Fatalf("%v %+v", err, made)
	}
}

func TestANameAHostHasOrNoHostCouldHaveMakesNothing(t *testing.T) {
	h := newHarness(t)
	h.add()
	if _, err := h.create("devbox", nil); err == nil {
		t.Error("made devbox")
	}
	if _, err := h.create("two words", nil); err == nil {
		t.Error("made two words")
	}
	if len(h.provider.firstBoots) != 0 {
		t.Error("asked the provider")
	}
}

func TestDeleteWorkspaceTakesTheWorkspaceAndTheHost(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsDelete, map[string]string{"host": devbox})
	if !reflect.DeepEqual(h.provider.deleted, []string{"agents-devbox"}) || h.records.Host(devbox) != nil {
		t.Errorf("%v %v", h.provider.deleted, h.records.Host(devbox))
	}
}

// A machine is the only copy of its agents: one that is online backs up first, and is
// deleted once the backup is made (#1815). A backup that fails leaves it, and says why.
func TestDeleteWorkspaceBacksUpFirst(t *testing.T) {
	release := make(chan error)
	var asked atomic.Int32
	h := newHarness(t, func(o *harnessOptions) {
		o.backUp = func(host string, _ Caller) (bool, error) {
			asked.Add(1)
			return true, <-release
		}
	})
	h.link(h.add(), devbox, "agents-devbox")
	h.router.setOnline(devbox, true)
	h.must(MethodHostsDelete, map[string]string{"host": devbox})
	r := h.row(devbox)
	if r.Workspace == nil || deref(r.Workspace.HostState) != "stopping" || deref(r.Workspace.Phase) != "backing up" || r.Workspace.CanStart || r.Workspace.CanStop {
		t.Fatalf("while it backs up: %+v", r.Workspace)
	}
	if h.providers.Asleep(devbox) {
		t.Error("asleep while its backup goes over its link")
	}
	if _, err := h.call(MethodHostsStart, map[string]string{"host": devbox}); err == nil {
		t.Error("started while it is backed up to be deleted")
	}
	release <- errors.New("the store is full")
	h.waitFor("online", devbox, 5, func(r row) bool { return deref(r.Workspace.Problem) != "" })
	if p := deref(h.row(devbox).Workspace.Problem); !strings.HasPrefix(p, "Couldn’t back up devbox, so it wasn’t deleted: ") {
		t.Fatalf("problem %q", p)
	}
	if h.records.Host(devbox) == nil {
		t.Fatal("deleted after its backup failed")
	}
	h.must(MethodHostsDelete, map[string]string{"host": devbox})
	release <- nil
	deadline := time.Now().Add(5 * time.Second)
	for h.records.Host(devbox) != nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.records.Host(devbox) != nil || asked.Load() != 2 {
		t.Fatalf("not deleted after its backup; asked %d", asked.Load())
	}
}

func TestAnOfflineHostIsDeletedWithNoBackup(t *testing.T) {
	var asked atomic.Int32
	h := newHarness(t, func(o *harnessOptions) {
		o.backUp = func(string, Caller) (bool, error) { asked.Add(1); return true, nil }
	})
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsDelete, map[string]string{"host": devbox})
	if h.records.Host(devbox) != nil || asked.Load() != 0 {
		t.Fatalf("asked %d", asked.Load())
	}
}

func TestAnUnlinkedHostHasNoWorkspaceToDelete(t *testing.T) {
	h := newHarness(t)
	h.add()
	if _, err := h.call(MethodHostsDelete, map[string]string{"host": devbox}); err == nil || len(h.provider.deleted) != 0 {
		t.Error("deleted")
	}
}

// Agents' workspace tools (#691 US6). Ports AgentWorkspaceToolsTests.swift.

func (h *harness) agentCall(method string, params any) (any, error) {
	return h.providers.HostSaid(other, MethodHostMachines, rawOf(MachineWorkspaceCall{Agent: "Claude (fix-login)", Method: method,
		Params: rawOf(params)}))
}

func TestAnAgentSeesWorkspacesAndTheirHostsAndNoSecret(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	answer, err := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	listed := answer.(AgentMachines)
	p := listed.Providers[0]
	if p.Name != "DigitalOcean" || !p.CanMake || p.Options == nil {
		t.Errorf("%+v", p)
	}
	for _, w := range p.Workspaces {
		if w.ID == "agents-devbox" && (deref(w.Host) != "devbox" || deref(w.HostState) != "stopped") {
			t.Errorf("%+v", w)
		}
	}
	text := string(rawOf(answer))
	if strings.Contains(text, "hunter2") || strings.Contains(text, "DIGITALOCEAN_TOKEN") {
		t.Error("a secret")
	}
}

func TestAnAgentStartsAHostByItsName(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	out, err := h.agentCall(MethodHostsStart, map[string]string{"host": "devbox"})
	if err != nil || out.(row).ID != devbox || out.(row).State != "starting" {
		t.Fatalf("%v %+v", err, out)
	}
	if _, err := h.agentCall(MethodHostsStart, map[string]string{"host": "nowhere"}); failureOf(err) == nil {
		t.Error("started nowhere")
	}
}

func TestAnAgentMakesAtAProviderByItsName(t *testing.T) {
	h := newHarness(t)
	h.add()
	out, err := h.agentCall(MethodProvidersCreate, map[string]string{"id": "DigitalOcean", "name": "branch-build"})
	if err != nil || out.(ProviderCreated).Workspace.Name != "branch-build" {
		t.Fatalf("%v %+v", err, out)
	}
}

func TestAnAgentCantAskAnythingElse(t *testing.T) {
	h := newHarness(t)
	h.add()
	for _, method := range []string{MethodProvidersAdd, MethodProvidersRemove, "machines/remove", MethodProvidersList} {
		if _, err := h.agentCall(method, map[string]any{}); failureOf(err) == nil || failureOf(err).Code != CodeNotPermitted {
			t.Errorf("%s: %v", method, err)
		}
	}
}

// A stopped workspace is asleep, so its tunnel does not dial it and start it again (#864): from
// the stop until a start.
func TestAStoppedWorkspaceIsAsleepUntilAStart(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	if h.providers.Asleep(devbox) {
		t.Error("a running one is asleep")
	}
	h.must(MethodHostsStop, MachineStop{Host: devbox})
	if !h.providers.Asleep(devbox) {
		t.Error("not asleep while it stops")
	}
	h.router.setOnline(devbox, false)
	h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.CanStart })
	if !h.providers.Asleep(devbox) {
		t.Error("not asleep once stopped")
	}
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	if h.providers.Asleep(devbox) {
		t.Error("asleep while it starts")
	}
	if h.providers.Asleep("nobody") {
		t.Error("a host with no link is asleep")
	}
}

// A removed person's started machine is deleted through its provider, with no backup
// (FR-029, #1763); the host's record is the remover's to take off.
func TestARemovedPersonsMachineIsDeletedThroughItsProvider(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	link := LinkOf(h.records.Host(devbox))
	if link == nil {
		t.Fatal("not linked")
	}
	if err := h.providers.DeleteForRemoval(*link, "devbox", "sam"); err != nil {
		t.Fatal(err)
	}
	h.provider.mu.Lock()
	deleted := slices.Clone(h.provider.deleted)
	h.provider.mu.Unlock()
	if !reflect.DeepEqual(deleted, []string{"agents-devbox"}) {
		t.Errorf("%v", deleted)
	}
}

// #1002, D13, FR-018: a suspended person's started machines are stopped through their
// provider, never deleted, and are not started while the suspension lasts.
func TestASuspendedPersonsMachinesAreStoppedNotDeleted(t *testing.T) {
	h := newHarness(t)
	suspended := false
	h.providers.hooks.OwnerOf = func(host string) string {
		if host == devbox {
			return "kim"
		}
		return "lee"
	}
	h.providers.hooks.Suspended = func(person string) bool { return suspended && person == "kim" }
	id := h.add()
	h.link(id, devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	suspended = true
	h.providers.StopFor("kim", "suspension (Acme Okta)")
	h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.CanStart })
	if _, stops := h.provider.count(); stops != 1 {
		t.Fatalf("stops %d", stops)
	}
	if h.records.Host(devbox) == nil || h.row(devbox).Workspace == nil {
		t.Fatal("the machine or its link went")
	}
	// Not started while suspended; by hand, for use, or again by StopFor.
	_, err := h.call(MethodHostsStart, map[string]string{"host": devbox})
	if f := failureOf(err); f == nil || f.Code != CodeProviderFailed {
		t.Fatalf("%v", err)
	}
	h.providers.StartForUse(devbox, "a kept prompt")
	h.providers.StopFor("kim", "suspension (Acme Okta)")
	if starts, stops := h.provider.count(); starts != 0 || stops != 1 {
		t.Fatalf("starts %d stops %d", starts, stops)
	}
	// Once it ends, the person starts it again by hand.
	suspended = false
	h.must(MethodHostsStart, map[string]string{"host": devbox})
}
