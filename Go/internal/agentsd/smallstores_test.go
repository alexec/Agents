package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #3652: release-tags.json keeps a repo's newest tags only, and a tag older than those
// is not linked again.
func TestReleaseTagsKeepTheNewest(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	repo := forgeRepo{"github", "alexec/agents"}
	var all []string
	for i := 1; i <= releaseTagsKept+5; i++ {
		tag := fmt.Sprintf("v0.%d.0", i)
		all = append(all, tag)
		d.markReleaseTagDone(repo, tag)
	}
	var f releaseTagsFile
	b, _ := os.ReadFile(d.releaseTagsPath())
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	kept := f.Done["github:alexec/agents"]
	if len(kept) != releaseTagsKept || kept[0] != "v0.6.0" || kept[len(kept)-1] != all[len(all)-1] {
		t.Fatalf("kept %d: %v", len(kept), kept)
	}
	done, floor := d.doneReleaseTags(repo)
	if floor != "v0.6.0" || done["v0.5.0"] {
		t.Fatalf("floor %q, done v0.5.0 %v", floor, done["v0.5.0"])
	}
	asked := 0
	d.releaseTags = func(string) ([]string, error) { return all, nil }
	d.releaseCommitTime = func(context.Context, string, forgeRepo, string) (time.Time, error) {
		asked++
		return time.Time{}, fmt.Errorf("not asked")
	}
	d.checkReleaseTagsForFolder(context.Background(), "/folder", repo)
	if asked != 0 {
		t.Fatalf("asked the forge %d times for tags already done", asked)
	}
}

// #3652: a workflow's state is marked when its file goes, kept when it comes back, and
// dropped 30 days after it went.
func TestWorkflowStatesGoThirtyDaysAfterTheirFile(t *testing.T) {
	clock := atTime(t, time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	d.workflowMu.Lock()
	r := d.recordsLocked()
	r.States = append(r.States,
		workflowState{Folder: store.FolderURL(dir), WorkflowID: "here"},
		workflowState{Folder: store.FolderURL(dir), WorkflowID: "gone"})
	d.workflowFiles = map[string]map[string]*workflowFile{dir: {"here": {}}}
	d.workflowMu.Unlock()
	state := func(id string) *workflowState {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		if st := d.stateLocked(dir, id, false); st != nil {
			c := *st
			return &c
		}
		return nil
	}

	d.sweepGoneWorkflowStates(clock.now())
	if st := state("gone"); st == nil || st.GoneSince == nil || *st.GoneSince != wire.DateOf(clock.now()) {
		t.Fatalf("gone: %+v", st)
	}
	if st := state("here"); st == nil || st.GoneSince != nil {
		t.Fatalf("here: %+v", st)
	}

	// Back within 30 days: kept, and no longer gone.
	clock.add(29 * 24 * time.Hour)
	d.workflowMu.Lock()
	d.workflowFiles[dir]["gone"] = &workflowFile{}
	d.workflowMu.Unlock()
	d.sweepGoneWorkflowStates(clock.now())
	if st := state("gone"); st == nil || st.GoneSince != nil {
		t.Fatalf("back: %+v", st)
	}

	// Gone again, for 30 days: dropped, and so from workflows.json.
	d.workflowMu.Lock()
	delete(d.workflowFiles[dir], "gone")
	d.workflowMu.Unlock()
	d.sweepGoneWorkflowStates(clock.now())
	clock.add(30 * 24 * time.Hour)
	d.sweepGoneWorkflowStates(clock.now())
	if st := state("gone"); st != nil {
		t.Fatalf("kept: %+v", st)
	}
	b, _ := os.ReadFile(d.workflowsPath())
	if strings.Contains(string(b), `"gone"`) || !strings.Contains(string(b), `"here"`) {
		t.Fatalf("workflows.json: %s", b)
	}
}

// #3652: the approvals and review files let go of a folder that is gone, and keep one on
// disk and one this host still lists.
func TestApprovalsLetGoOfFoldersThatAreGone(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	listed := folder(t, c, 1)
	onDisk := t.TempDir()
	gone := filepath.Join(t.TempDir(), "gone")
	root := d.Store.Loc.Root
	os.WriteFile(filepath.Join(root, "mcp-approvals.json"), []byte(`{"approvalsBegan":1,"approved":{`+
		`"`+onDisk+`|.agents/mcp.json|a":"x","`+gone+`|.agents/mcp.json|b":"x","`+listed+`|.agents/mcp.json|c":"x"},`+
		`"views":{"user|s|ui://v":"show:h","`+gone+`|s|ui://v":"show:h"}}`), 0o644)
	os.WriteFile(filepath.Join(root, "plugin-approvals.json"), []byte(`{"approvalsBegan":1,"approved":{`+
		`"`+onDisk+`/.agents/plugins/p":"x","`+gone+`/.agents/plugins/p":"x"},"denied":{"`+gone+`/.agents/plugins/q":"y"}}`), 0o644)
	os.WriteFile(filepath.Join(root, "review-dismissals.json"), []byte(`{"`+onDisk+`":["u1"],"`+gone+`":["u2"]}`), 0o644)
	os.WriteFile(filepath.Join(root, "review-opened.json"), []byte(`{"`+gone+`":["u3"]}`), 0o644)
	d.mcpMu.Lock()
	d.mcpLoaded = false
	d.mcpMu.Unlock()
	d.reviewMu.Lock()
	d.dismissedLoaded, d.openedLoaded = false, false
	d.reviewMu.Unlock()

	d.sweepSmallStores(time.Now())

	for name, want := range map[string][]string{
		"mcp-approvals.json":     {onDisk + "|.agents/mcp.json|a", listed + "|.agents/mcp.json|c", "user|s|ui://v"},
		"plugin-approvals.json":  {onDisk + "/.agents/plugins/p"},
		"review-dismissals.json": {onDisk},
	} {
		b, _ := os.ReadFile(filepath.Join(root, name))
		if strings.Contains(string(b), gone) {
			t.Errorf("%s keeps the gone folder: %s", name, b)
		}
		for _, w := range want {
			if !strings.Contains(string(b), w) {
				t.Errorf("%s lost %s: %s", name, w, b)
			}
		}
	}
	if b, _ := os.ReadFile(filepath.Join(root, "review-opened.json")); strings.Contains(string(b), gone) {
		t.Errorf("review-opened.json: %s", b)
	}
}

// #3652: a device not seen for 90 days is forgotten; one seen since is kept.
func TestDevicesNotSeenForNinetyDaysAreForgotten(t *testing.T) {
	d, _ := startDevices(t)
	defer d.Shutdown()
	at := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	date := func(ago time.Duration) string { return fmt.Sprint(float64(wire.DateOf(at.Add(-ago)))) }
	old := "AAAAAAAA-2222-3333-4444-555555555555"
	os.WriteFile(d.devicesFile(), []byte(`[`+
		`{"id":"`+old+`","publicKey":"AQE=","name":"Old","kind":"iPad","announcedAt":`+date(200*24*time.Hour)+`,"lastSeenAt":`+date(91*24*time.Hour)+`},`+
		`{"id":"`+phone+`","publicKey":"AQE=","name":"Phone","kind":"iPhone","announcedAt":`+date(200*24*time.Hour)+`,"lastSeenAt":`+date(89*24*time.Hour)+`}]`), 0o644)
	d.devMu.Lock()
	d.devLoaded, d.devRecords = false, nil
	d.devMu.Unlock()

	d.sweepUnseenDevices(at)

	b, _ := os.ReadFile(d.devicesFile())
	if strings.Contains(string(b), old) || !strings.Contains(string(b), phone) {
		t.Fatalf("devices.json: %s", b)
	}
	if got := d.listDevices(); len(got) != 1 || string(got[0].ID) != phone {
		t.Fatalf("devices: %+v", got)
	}
}
