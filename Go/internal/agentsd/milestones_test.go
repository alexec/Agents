package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports MilestoneTests: the first agent to run a turn and the first workflow are earned
// once, said to the clients and kept.

func TestMilestonesEarned(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello"}), &id)
	c.until(t, "the first agent earned", func(m string, p json.RawMessage) bool {
		return m == "milestones/changed" && strings.Contains(string(p), `"firstAgent"`)
	})
	dir := folder(t, c, 2)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "tidy.md"), []byte("---\non: agent.finished\n---\nTidy.\n"), 0o644)
	c.call(t, 3, "workflows/list", map[string]any{"folder": store.FolderURL(dir)})
	waitFor(t, "the first workflow", func() bool {
		var m wire.Milestones
		json.Unmarshal(c.call(t, 4, "milestones/state", map[string]any{}), &m)
		return hasMilestone(&m, firstWorkflow) && hasMilestone(&m, firstAgent)
	})
	b, _ := os.ReadFile(d.achievementsPath())
	if strings.Count(string(b), `"firstAgent"`) != 1 {
		t.Fatalf("%s", b)
	}
}

// #1987: a phone or a browser pairs, a question is answered from one, a cloud machine is
// started, and a pull request from the app's branch lands.

func earned(d *Daemon, id string) bool {
	m := d.milestones()
	return hasMilestone(&m, id)
}

func TestADeviceEarnsPairingAndAnsweringAway(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	mac := &Client{Role: RoleControl, conn: newConn(), d: d}
	d.dispatch(mac, message{JSONRPC: "2.0", Method: "milestones/state"})
	d.noteMilestones(mac, "permissions/answer")
	if earned(d, firstPairing) || earned(d, firstRemoteAnswer) {
		t.Fatal("the Mac's own window earned a device's milestone")
	}
	phone := &Client{Role: RoleControl, conn: deviceConn{newConn()}, d: d}
	d.dispatch(phone, message{JSONRPC: "2.0", Method: "milestones/state"})
	if !earned(d, firstPairing) || earned(d, firstRemoteAnswer) {
		t.Fatalf("%+v", d.milestones())
	}
	// A call that failed answered nothing.
	d.dispatch(phone, message{JSONRPC: "2.0", Method: "permissions/answer", Params: json.RawMessage(`{"permissionID":"00000000-0000-0000-0000-000000000000","optionID":"x"}`)})
	if earned(d, firstRemoteAnswer) {
		t.Fatal("a refused answer earned it")
	}
	d.noteMilestones(phone, "elicitations/answer")
	if !earned(d, firstRemoteAnswer) {
		t.Fatalf("%+v", d.milestones())
	}
	b, _ := os.ReadFile(d.achievementsPath())
	if !strings.Contains(string(b), `"firstRemoteAnswer"`) {
		t.Fatalf("%s", b)
	}
}

func TestAPairedDeviceIsBackFilled(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "devices.json"), []byte(`[{"id":"11111111-2222-3333-4444-555555555555","publicKey":"AAAA",`+
		`"name":"Phone","kind":"iPhone","announcedAt":1}]`), 0o644)
	d, _ := start(t, root)
	defer d.Shutdown()
	waitFor(t, "the pairing back-filled", func() bool { return earned(d, firstPairing) })
	for _, e := range d.milestones().Earned {
		if e.ID == firstPairing && !e.At.Time().Equal(time.Date(2001, 1, 1, 0, 0, 1, 0, time.UTC)) {
			t.Fatalf("earned at %v", e.At.Time())
		}
	}
}

func TestACloudMachineStarted(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	listed := `{"providers":[{"id":"p","name":"DigitalOcean","canMake":false,"canDelete":false,"workspaces":[{"name":"box","state":"stopped"}]}]}`
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call := params.(wire.MachineWorkspaceCall)
		if call.Method == hostsStart {
			return json.RawMessage(`{"state":"starting"}`), nil
		}
		return json.RawMessage(listed), nil
	})
	d.checkCloudHosts()
	if earned(d, firstCloudHost) {
		t.Fatal("a stopped workspace earned it")
	}
	listed = strings.Replace(listed, `"stopped"`, `"running"`, 1)
	d.checkCloudHosts()
	if !earned(d, firstCloudHost) {
		t.Fatal("a running workspace did not earn it")
	}

	d2, _ := start(t, t.TempDir())
	defer d2.Shutdown()
	d2.SetControlAsk(func(context.Context, string, any) (json.RawMessage, error) {
		return json.RawMessage(`{"state":"starting"}`), nil
	})
	if _, err := d2.startMachine("", map[string]json.RawMessage{"host": json.RawMessage(`"box"`)}); err != nil {
		t.Fatal(err)
	}
	if !earned(d2, firstCloudHost) {
		t.Fatal("start_machine did not earn it")
	}
}

func TestALandedPullRequestIsCounted(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	day := time.Now().AddDate(0, 0, -2)
	merged := day.UTC().Format(time.RFC3339)
	pulls := `[{"url":"https://github.com/o/r/pull/1","mergedAt":"` + merged + `","headRefName":"agents/fix-1"},` +
		`{"url":"https://github.com/o/r/pull/2","mergedAt":"` + merged + `","headRefName":"someone-else"}]`
	gh := filepath.Join(t.TempDir(), "gh")
	os.WriteFile(gh, []byte("#!/bin/sh\ncat <<'END'\n"+pulls+"\nEND\n"), 0o755)
	findGH = func() string { return gh }
	defer func() { findGH = func() string { return "" } }()
	d.countMergedPRs()
	h := d.timeHistory()
	if r := h.Recap[dayStamp(day)]; r.PrsMerged == nil || *r.PrsMerged != 1 {
		t.Fatalf("%+v", r)
	}
	if r := h.Recap[dayStamp(time.Now())]; r.PrsMerged == nil || *r.PrsMerged != 0 {
		t.Fatalf("today: %+v", r)
	}
	d.checkMilestones()
	if !earned(d, firstLandedPR) {
		t.Fatalf("%+v", d.milestones())
	}
}

func TestMergedByDayCountsTheAppsBranchesOnce(t *testing.T) {
	at := time.Date(2026, 3, 4, 12, 0, 0, 0, time.Local)
	got := mergedByDay([]mergedPull{
		{URL: "a", MergedAt: at, HeadRefName: "agents/one"},
		{URL: "a", MergedAt: at, HeadRefName: "agents/one"},
		{URL: "b", MergedAt: at, HeadRefName: "agents/two"},
		{URL: "c", MergedAt: at, HeadRefName: "main"},
	})
	if got[dayStamp(at)] != 2 || len(got) != 1 {
		t.Fatalf("%v", got)
	}
}
