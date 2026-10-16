package providers

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Workspace providers on the control plane (#691): adding one, linking a host to its
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
	if s.ID != id || s.Name != "DigitalOcean" || s.Preset != "doctl" {
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
	h.provider.set("It isn’t a workspace provider: it has no workspace_stop tool.", "", 0)
	_, err := h.call(MethodProvidersAdd, map[string]any{"name": "DigitalOcean", "kind": "commands", "commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || f.Code != CodeInvalidParams || f.Message != "It isn’t a workspace provider: it has no workspace_stop tool." {
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
	if s := again.Summaries(); len(s) != 1 || s[0].ID != id {
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
	waiting := h.waitFor("starting", devbox, 5, func(r row) bool { return r.Workspace.Phase == "connecting" })
	if waiting.Workspace.Phase != "connecting" {
		t.Errorf("phase %q", waiting.Workspace.Phase)
	}
	if starts, _ := h.provider.count(); starts != 1 {
		t.Errorf("starts %d", starts)
	}
	h.router.setOnline(devbox, true)
	online := h.waitFor("online", devbox, 5, func(r row) bool { return r.Workspace.Phase == "" })
	if online.Workspace.WorkspaceState != "running" || !online.Workspace.CanStop || online.Workspace.Problem != "" {
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
	h.waitFor("starting", devbox, 5, func(r row) bool { return r.Workspace.Phase == "connecting" })
	if starts, _ := h.provider.count(); starts != 1 {
		t.Errorf("starts %d", starts)
	}
}

func TestAFailedStartSaysWhyAndOffersStartAgain(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "Error: droplet is locked", 0)
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.Problem != "" })
	if r.Workspace.Problem != "Couldn’t start devbox: Error: droplet is locked" || !r.Workspace.CanStart {
		t.Errorf("%+v", r.Workspace)
	}
}

func TestAHostThatDoesNotConnectIsStartedOverSSHThenGivenUp(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter, o.timing.GiveUp = 100*time.Millisecond, 2*time.Second
	})
	h.link(h.add(), devbox, "agents-devbox")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return r.Workspace.Problem != "" })
	if !reflect.DeepEqual(h.ssh.all(), []string{"alex@127.0.0.1 -p 2222"}) {
		t.Errorf("ssh %v", h.ssh.all())
	}
	if r.Workspace.Problem != "devbox didn’t connect in 2 seconds." || !r.Workspace.CanStart {
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
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return r.Workspace.Problem != "" })
	want := "devbox started, but its agentsd didn’t connect, and starting it over ssh failed. " +
		"Its host key isn’t in your known_hosts. Check and trust it with “ssh alex@127.0.0.1 -p 2222”, then start it again."
	if r.Workspace.Problem != want || !r.Workspace.CanStart {
		t.Errorf("%q", r.Workspace.Problem)
	}
}

func TestWithoutTheProvidersSSHItStartsOverTheInstallsDestination(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.timing.SSHAfter, o.timing.GiveUp = 100*time.Millisecond, 2*time.Second
		o.workspaces = []WorkspaceInfo{{ID: "cs-1", Name: "cs-1", State: "stopped"}}
		o.installedOver = "cs.cs-1.main"
	})
	h.link(h.add(), devbox, "cs-1")
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	r := h.waitFor("offline", devbox, 15, func(r row) bool { return r.Workspace.Problem != "" })
	if !reflect.DeepEqual(h.ssh.all(), []string{"cs.cs-1.main"}) || r.Workspace.Problem != "devbox didn’t connect in 2 seconds." {
		t.Errorf("%v %q", h.ssh.all(), r.Workspace.Problem)
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
	stopping := h.must(MethodHostsStop, HostStop{Host: devbox}).(row)
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

func TestStopWhileAgentsWorkIsAskedFirst(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "scratch-1")
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, HostStatus{Idle: false, Running: []string{"Claude (fix-login)", "Codex (docs)"}})
	_, err := h.call(MethodHostsStop, HostStop{Host: devbox})
	f := failureOf(err)
	if f == nil || f.Code != CodeAgentsWorking || f.Message != "Stop devbox? Claude (fix-login) and Codex (docs) are working there." ||
		string(f.Data) != `{"running":["Claude (fix-login)","Codex (docs)"]}` {
		t.Fatalf("%v", err)
	}
	yes := true
	if r := h.must(MethodHostsStop, HostStop{Host: devbox, ConfirmRunning: &yes}).(row); r.State != "stopping" {
		t.Errorf("%+v", r)
	}
}

func TestStopWhileStartingIsRefusedNotDropped(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "", 300*time.Millisecond)
	h.must(MethodHostsStart, map[string]string{"host": devbox})
	_, err := h.call(MethodHostsStop, HostStop{Host: devbox})
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
	h.waitFor("starting", devbox, 5, func(r row) bool { return r.Workspace.Phase == "connecting" })
	h.router.setOnline(devbox, true)
	h.waitFor("online", devbox, 5, func(r row) bool { return r.Workspace.Phase == "" && r.Workspace.CanStop })
	if r := h.must(MethodHostsStop, HostStop{Host: devbox}).(row); r.State != "stopping" {
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
	h.must(MethodHostsSetOptions, HostWorkspaceOptions{Host: devbox, StopWhenIdleMinutes: &minutes})
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, HostStatus{Idle: true, Running: []string{}})
	if !eventually(t, func() bool { _, stops := h.provider.count(); return stops == 1 }) {
		t.Fatal("not stopped")
	}
	h.router.setOnline(devbox, false)
	r := h.waitFor("stopped", devbox, 5, func(r row) bool { return r.Workspace.StoppedBy != "" })
	if r.Workspace.StoppedBy != "Stopped by Agents after 2 minutes idle" {
		t.Errorf("%q", r.Workspace.StoppedBy)
	}
}

func TestBusyAgainCancelsTheIdleCount(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) { o.timing.IdleMinute = 30 * time.Millisecond })
	h.link(h.add(), devbox, "scratch-1")
	one := 1
	h.must(MethodHostsSetOptions, HostWorkspaceOptions{Host: devbox, StopWhenIdleMinutes: &one})
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, HostStatus{Idle: true, Running: []string{}})
	h.providers.Heard(devbox, HostStatus{Idle: false, Running: []string{"Claude (x)"}})
	time.Sleep(100 * time.Millisecond)
	if _, stops := h.provider.count(); stops != 0 {
		t.Error("stopped while busy")
	}
}

func TestAHostsScheduleIsKeptOnItsLinkAndWakesIt(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	due := time.Now().Add(3 * time.Minute)
	h.providers.Heard(devbox, HostStatus{Idle: true, Running: []string{}, Schedule: &HostSchedule{At: refDate(due), Workflow: "nightly"}})
	link := LinkOf(h.records.Host(devbox))
	if link.Schedule == nil || link.Schedule.Workflow != "nightly" || !sameTime(link.Schedule.At, &due) {
		t.Fatalf("%+v", link.Schedule)
	}
	r := h.row(devbox)
	if r.Workspace.NextWorkflow != "nightly" || r.Workspace.WakeAt == nil || r.Workspace.TellsSchedule == nil || !*r.Workspace.TellsSchedule {
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

func TestAHostRecordWithALinkReadsAndWritesAsSwiftDoes(t *testing.T) {
	old := `{"id":"devbox01","name":"devbox","reach":{"dialOut":{}},"platform":"","version":"","installed":false,"rev":1}`
	var h records.HostRecord
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
	ws := &HostWorkspace{HostState: "stopped"}
	if Overlay(map[string]any{"state": "offline"}, false, ws)["state"] != "stopped" {
		t.Error("not laid over")
	}
	if Overlay(map[string]any{"state": "online"}, true, ws)["state"] != "online" {
		t.Error("laid over an online host")
	}
	if Overlay(map[string]any{"state": "online"}, true, &HostWorkspace{HostState: "stopping"})["state"] != "stopping" {
		t.Error("stopping not shown")
	}
	if OfflineRefusal(ws).Message != "That host is stopped. Start it to reach it." || OfflineRefusal(nil).Message != "That host is offline." {
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
	if !(WorkspaceInfo{Name: "devstack-d7539e59"}).MayBe("cws.devstack-d7539e59") || (WorkspaceInfo{Name: "dev"}).MayBe("devstack") {
		t.Error("mayBe")
	}
}

// Making workspaces (#691 US5). Ports MakingWorkspacesTests.swift.

func (h *harness) create(name string, clones []string) (ProviderCreated, error) {
	provider := h.must(MethodProvidersList, nil).(map[string]any)["providers"].([]ProviderSummary)[0].ID
	out, err := h.call(MethodProvidersCreate, ProviderCreate{ID: provider, Name: name, Options: map[string]any{"size": "big"}, Clones: clones})
	if err != nil {
		return ProviderCreated{}, err
	}
	return out.(ProviderCreated), nil
}

func TestTheFormComesFromTheProvidersOptions(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	options := h.must(MethodProvidersOptions, map[string]string{"id": id}).(ProviderOptions)
	if get(get(get(options.Schema, "properties"), "size"), "title") != "Size" {
		t.Errorf("%v", options.Schema)
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

func TestANewWorkspaceClonesItsProjectsOnceItJoins(t *testing.T) {
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
		if d.method != MethodProjectsClone || d.host != "build004" || d.client != h.caller.Client {
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

func TestOneThatCantRunTheFirstBootIsLeftToAddOverSSH(t *testing.T) {
	h := newHarness(t)
	h.add()
	h.provider.firstBootRuns = false
	made, err := h.create("build-3", nil)
	if err != nil || made.Joining || made.Workspace.SSH != "root@10.0.0.9" {
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

func TestAnUnlinkedHostHasNoWorkspaceToDelete(t *testing.T) {
	h := newHarness(t)
	h.add()
	if _, err := h.call(MethodHostsDelete, map[string]string{"host": devbox}); err == nil || len(h.provider.deleted) != 0 {
		t.Error("deleted")
	}
}

// Agents' workspace tools (#691 US6). Ports AgentWorkspaceToolsTests.swift.

func (h *harness) agentCall(method string, params any) (any, error) {
	return h.providers.HostSaid(other, MethodHostWorkspaces, rawOf(HostWorkspaceCall{Agent: "Claude (fix-login)", Method: method,
		Params: rawOf(params)}))
}

func TestAnAgentSeesWorkspacesAndTheirHostsAndNoSecret(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	answer, err := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	listed := answer.(AgentWorkspaces)
	p := listed.Providers[0]
	if p.Name != "DigitalOcean" || !p.CanMake || p.Options == nil {
		t.Errorf("%+v", p)
	}
	for _, w := range p.Workspaces {
		if w.ID == "agents-devbox" && (w.Host != "devbox" || w.HostState != "stopped") {
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
	for _, method := range []string{MethodProvidersAdd, MethodProvidersRemove, "hosts/remove", MethodProvidersList} {
		if _, err := h.agentCall(method, map[string]any{}); failureOf(err) == nil || failureOf(err).Code != CodeNotPermitted {
			t.Errorf("%s: %v", method, err)
		}
	}
}
