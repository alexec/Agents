//go:build linux || darwin

package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports what DaemonCore's tests hold of the folder's one watch (#173): a workflow file
// that arrives on disk is told (WorkflowWatchTests), a file arriving in the drop box is
// raised once and what was there before is not (DropboxTests), and a branch an agent's
// worktree is on moving raises branch.moved (EventSourceTests).

// watched is a daemon with folder added as a folder, once its watch is up.
func watched(t *testing.T, folder string) (*Daemon, *conn) {
	t.Helper()
	prepareWatch(t)
	d, c := start(t, t.TempDir())
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	until(t, "the folder's watch", func() bool {
		d.pwMu.Lock()
		defer d.pwMu.Unlock()
		return d.pwWatches[folder] != nil
	})
	return d, c
}

func until(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatalf("%s: not in 5 s", what)
}

func raised(d *Daemon, name string) []wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	var out []wire.Event
	for _, e := range d.eventList {
		if e.Name == name {
			out = append(out, e)
		}
	}
	return out
}

func TestAWorkflowFileOnDiskIsToldAtOnce(t *testing.T) {
	folder := canonical(t.TempDir())
	_, c := watched(t, folder)
	os.MkdirAll(workflowsFolder(folder), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(folder), "pulled.md"), []byte("---\nname: Pulled\non: agent.finished\n---\nGo.\n"), 0o644)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifyWorkflowChanged.Name {
				continue
			}
			var s wire.WorkflowSummary
			json.Unmarshal(m.Params, &s)
			if s.Workflow.WorkflowID == "pulled" {
				if s.AwaitingApproval == nil {
					t.Fatalf("a new file is not waiting for approval: %+v", s)
				}
				// And gone again: workflow/removed.
				os.Remove(filepath.Join(workflowsFolder(folder), "pulled.md"))
				for {
					select {
					case line := <-c.out:
						if strings.Contains(line, wire.NotifyWorkflowRemoved.Name) && strings.Contains(line, `"pulled"`) {
							return
						}
					case <-time.After(5 * time.Second):
						t.Fatal("no workflow/removed")
					}
				}
			}
		case <-deadline:
			t.Fatal("no workflow/changed for a file written on disk")
		}
	}
}

func TestADropboxArrivalIsRaisedOnce(t *testing.T) {
	folder := canonical(t.TempDir())
	box := filepath.Join(folder, ".agents", "dropbox")
	os.MkdirAll(box, 0o755)
	os.WriteFile(filepath.Join(box, "before.txt"), []byte("old"), 0o644)
	d, _ := watched(t, folder)
	os.MkdirAll(filepath.Join(box, "in"), 0o755)
	os.WriteFile(filepath.Join(box, "in", ".partial"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(box, "in", "Report.PDF"), []byte("hello"), 0o644)
	until(t, "dropbox.file_added", func() bool { return len(raised(d, "dropbox.file_added")) > 0 })
	time.Sleep(2 * dropboxSettle)
	got := raised(d, "dropbox.file_added")
	if len(got) != 1 {
		t.Fatalf("%d events: %+v", len(got), got)
	}
	e := got[0]
	if e.Details["name"] != "Report.PDF" || e.Details["folder"] != "in" || e.Details["extension"] != "pdf" || e.Details["size"] != "5" ||
		e.Details["path"] != filepath.Join(box, "in", "Report.PDF") || e.Sentence != "Report.PDF arrived in dropbox/in." {
		t.Fatalf("%+v", e)
	}
}

func TestABranchAnAgentIsOnMovingIsRaised(t *testing.T) {
	folder := repo(t)
	gitIn(t, folder, "branch", "lane")
	gitIn(t, folder, "branch", "nobodys")
	d, _ := watched(t, folder)
	branch := "lane"
	seeded(t, d, folder, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "lane", Root: store.FolderURL(filepath.Join(folder, ".agents", "worktrees", "lane")),
			Branch: &branch, Folder: store.FolderURL(folder)}
	})
	// The first look seeds the tips: nothing is raised for what they are now.
	d.checkBranches(folder)
	until(t, "the tips seeded", func() bool {
		d.eventMu.Lock()
		defer d.eventMu.Unlock()
		return d.eventStateNow.BranchTips[folder]["lane"] != ""
	})
	gitIn(t, folder, "commit", "-q", "--allow-empty", "-m", "second")
	gitIn(t, folder, "branch", "-f", "lane", "main")
	gitIn(t, folder, "branch", "-f", "nobodys", "main")
	until(t, "branch.moved", func() bool { return len(raised(d, "branch.moved")) > 0 })
	time.Sleep(2 * branchSettle)
	got := raised(d, "branch.moved")
	if len(got) != 1 || got[0].Details["branch"] != "lane" || len(got[0].Details["to"]) != 12 || !strings.HasPrefix(got[0].Sentence, "lane moved to ") {
		t.Fatalf("%+v", got)
	}
}

func TestWhatAFolderWatchLeavesOut(t *testing.T) {
	for rel, skipped := range map[string]bool{
		".git": false, ".git/refs": false, ".git/refs/heads": false, ".git/refs/heads/lanes": false,
		".git/worktrees": false, ".git/worktrees/a": false, ".git/worktrees/a/logs": true,
		".git/objects": true, ".git/logs": true, ".git/refs/remotes": true,
		".agents/worktrees": true, ".agents/workflows": false, "node_modules": true, "src": false,
	} {
		if got := skipWatched("/p", filepath.Join("/p", rel), filepath.Base(rel)); got != skipped {
			t.Errorf("%s: skipped %v", rel, got)
		}
	}
}

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}
