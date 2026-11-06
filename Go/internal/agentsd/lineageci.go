package agentsd

import (
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// CI runs (#3581, spec 3579-outer-loop): the build stage of the outer loop, as a node.
//
//   - Kind ci-run, ref github:<owner>/<repo>/actions/run/<id> (GitLab:
//     gitlab:<group>/<project>/pipelines/<id>). Not workflow-run: that is an Agents
//     workflow's run.
//   - checks.passed and checks.failed link the run builds its PR. A rerun has the same id,
//     so it is the same node.
//   - run.completed on a version tag (as release.yml on v0.16.0) links the run builds the
//     tag's release, whatever its conclusion: a failed release build is part of the story.
//   - A PR keeps at most ciRunsPerPR active runs: an older run's link ends, and the store's
//     own bounds (KeepEnded, MostLinks) let it go.

// ciRunsPerPR is how many runs a PR keeps active.
const ciRunsPerPR = 20

func (r forgeRepo) ciRun(id int64) wire.LineageNode {
	ref := r.forge + ":" + r.path + "/actions/run/" + strconv.FormatInt(id, 10)
	if r.forge == "gitlab" {
		ref = r.forge + ":" + r.path + "/pipelines/" + strconv.FormatInt(id, 10)
	}
	return wire.LineageNode{Kind: lineage.KindCIRun, Ref: ref}
}

// ciRunPayload is what checks.passed, checks.failed and run.completed say of a run.
type ciRunPayload struct {
	PR struct {
		URL string `json:"url"`
	} `json:"pr"`
	Run struct {
		ID     int64  `json:"id"`
		Branch string `json:"branch"`
		URL    string `json:"url"`
	} `json:"run"`
	CompletedAt string `json:"completedAt"`
}

// lineageCIEvent links the run a checks.* or run.completed event names.
func (d *Daemon) lineageCIEvent(e wire.Event) {
	var p ciRunPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Run.ID <= 0 {
		return
	}
	if e.Name == "run.completed" {
		repo, ok := repoOfRunURL(p.Run.URL)
		if !ok || !versionTagPattern.MatchString(p.Run.Branch) {
			return
		}
		at := nowFunc()
		if t, err := time.Parse(time.RFC3339, p.CompletedAt); err == nil {
			at = t
		}
		run, release := repo.ciRun(p.Run.ID), repo.release(p.Run.Branch)
		d.lineageDo(func() { d.linkAt(run, release, lineage.RelBuilds, lineage.SourceForge, at) })
		return
	}
	repo, n, ok := prOfURL(p.PR.URL)
	if !ok {
		return
	}
	run, pr := repo.ciRun(p.Run.ID), repo.pr(n)
	d.lineageDo(func() {
		d.link(run, pr, lineage.RelBuilds, lineage.SourceForge)
		d.boundCIRuns(pr)
	})
}

// boundCIRuns ends the builds links into pr past the newest ciRunsPerPR.
func (d *Daemon) boundCIRuns(pr wire.LineageNode) {
	kept := 0
	d.endLinks(pr, func(l wire.LineageLink) bool {
		if l.To != pr || l.Rel != lineage.RelBuilds || l.From.Kind != lineage.KindCIRun {
			return false
		}
		kept++
		return kept > ciRunsPerPR
	})
}

// repoOfRunURL is the repo of a GitHub Actions run's web address,
// github.com/<owner>/<repo>/actions/runs/<id>.
func repoOfRunURL(raw string) (forgeRepo, bool) {
	u, err := url.Parse(raw)
	if err != nil {
		return forgeRepo{}, false
	}
	path, _, ok := strings.Cut(strings.Trim(u.Path, "/"), "/actions/runs/")
	if !ok {
		return forgeRepo{}, false
	}
	r := forgeOf(u.Host, path)
	return r, r.forge == "github"
}
