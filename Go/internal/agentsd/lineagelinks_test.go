package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// active is a node's active links as "from rel to (source)".
func active(d *Daemon, n wire.LineageNode) map[string]bool {
	d.lineageSettle(5 * time.Second)
	out := map[string]bool{}
	for _, l := range d.lineage().Links(n).Links {
		if l.EndedAt == nil {
			out[l.From.Ref+" "+l.Rel+" "+l.To.Ref+" ("+l.Source+")"] = true
		}
	}
	return out
}

func wantLinks(t *testing.T, got map[string]bool, want ...string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for _, w := range want {
		if !got[w] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

// #2349: a start label, a label added and taken off, a helper's parent and an archive each
// make or end the session's links.
func TestLineageFromLabelsHelpersAndArchive(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	parent := seeded(t, d, folder, nil)
	child := seeded(t, d, folder, func(a *wire.Agent) {
		a.StartedByAgent = &parent.ID
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}, {Value: "ENG-4", Owner: wire.SessionLabelOwnerPerson}, {Value: "lane"}}
	})
	d.noteLineage(nil, child)
	s, p := sessionNode(child.ID), sessionNode(parent.ID)
	wantLinks(t, active(d, s),
		p.Ref+" started "+s.Ref+" (helper)",
		s.Ref+" works-on github:alexec/agents#12 (start)",
		s.Ref+" works-on linear:ENG-4 (start)")

	if _, err := d.setSessionLabels(child.ID, map[string]json.RawMessage{"add": json.RawMessage(`["P#40"]`)}); err != nil {
		t.Fatal(err)
	}
	d.change(child.ID, func(a *wire.Agent) {
		var kept []wire.SessionLabel
		for _, l := range a.Labels {
			if l.Value != "#12" {
				kept = append(kept, l)
			}
		}
		a.Labels = kept
	})
	wantLinks(t, active(d, s),
		p.Ref+" started "+s.Ref+" (helper)",
		s.Ref+" works-on linear:ENG-4 (start)",
		s.Ref+" works-on github:alexec/agents#40 (agent)")

	if err := d.archive(child.ID); err != nil {
		t.Fatal(err)
	}
	// Archived, its own links end; what started it stays a fact, as its parent's.
	wantLinks(t, active(d, s), p.Ref+" started "+s.Ref+" (helper)")
}

// #2349: a workflow's session is started by its run, and the run is part of its workflow.
func TestLineageFromAWorkflowRun(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	a := seeded(t, d, folder, nil)
	run, wf := store.NewUUID(), "fix-failed-checks"
	d.change(a.ID, func(a *wire.Agent) { a.StartedByRun, a.StartedByWorkflow = &run, &wf })
	r := wire.LineageNode{Kind: "workflow-run", Ref: "run:" + string(run)}
	wantLinks(t, active(d, r),
		r.Ref+" started "+sessionNode(a.ID).Ref+" (helper)",
		r.Ref+" part-of workflow:"+folder+"/fix-failed-checks (helper)")
}

// #2349: pr.opened links every session on its branch, in its repo, and the issues its body
// closes; pr.closed ends them all, as a PR closed without a merge fixed nothing.
func TestLineageFromPREvents(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder, other := t.TempDir(), t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}, other: {"github", "someone/else"}}
	branch := "agents/7-fix"
	onBranch := func(f string) wire.Agent {
		return seeded(t, d, f, func(a *wire.Agent) {
			a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(f)}
		})
	}
	first, second, elsewhere := onBranch(folder), onBranch(folder), onBranch(other)
	event := func(name string) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":9,"branch":"agents/7-fix",` +
			`"url":"https://github.com/alexec/Agents/pull/9","fixes":["#7","Other/Repo#3"]}}`}}
	}
	d.lineageEvent(event("pr.opened"))
	pr := wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#9"}
	wantLinks(t, active(d, pr),
		sessionNode(first.ID).Ref+" opens "+pr.Ref+" (branch)",
		sessionNode(second.ID).Ref+" opens "+pr.Ref+" (branch)",
		pr.Ref+" fixes github:alexec/agents#7 (pr-body)",
		pr.Ref+" fixes github:other/repo#3 (pr-body)")
	if got := active(d, sessionNode(elsewhere.ID)); len(got) != 0 {
		t.Fatalf("a session in another repo: %v", got)
	}

	d.lineageEvent(event("pr.closed"))
	wantLinks(t, active(d, pr))
}

// #2349: pr.merged ends the sessions' links to the PR and keeps what it fixed.
func TestLineageWhenAPRMerges(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"gitlab", "group/sub/project"}}
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "P#5", Owner: wire.SessionLabelOwnerAgent}}
	})
	d.noteLineage(nil, a)
	d.lineageEvent(wire.Event{Name: "pr.merged", Details: map[string]string{"payload": `{"pr":{"number":5,` +
		`"url":"https://gitlab.example.com/group/sub/project/-/merge_requests/5","fixes":["#2"]}}`}})
	wantLinks(t, active(d, wire.LineageNode{Kind: "pr", Ref: "gitlab:group/sub/project!5"}),
		"gitlab:group/sub/project!5 fixes gitlab:group/sub/project#2 (pr-body)")
}

func TestPROfURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://github.com/alexec/Agents/pull/12":                 "github:alexec/agents#12",
		"https://github.com/alexec/Agents/pull/12/files":           "github:alexec/agents#12",
		"https://gitlab.com/group/project/-/merge_requests/3":      "gitlab:group/project!3",
		"https://gitlab.example.com/a/b/c/-/merge_requests/4#note": "gitlab:a/b/c!4",
		"https://github.com/alexec/Agents/issues/12":               "",
		"https://example.com/o/r/pull/1":                           "",
		"https://github.com/o/r/pull/x":                            "",
	} {
		repo, n, ok := prOfURL(raw)
		got := ""
		if ok {
			got = repo.pr(n).Ref
		}
		if got != want {
			t.Errorf("%s: got %q, want %q", raw, got, want)
		}
	}
}
