package agentsd

import (
	"encoding/json"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Health signals (#3585, spec 3579-outer-loop): the health stage of the outer loop, as a
// node, so a walk from a crash reaches the release that shipped it, its PRs and the issues
// they fix.
//
//   - Kind health, ref sentry:<org>/<issue id>, from the sentry events server's
//     health.issue_new and health.issue_regressed (#3583).
//   - The health node is seen-in the release the event names: Sentry's version string
//     (1.2.0, v1.2.0, web@1.2.0 or com.example.app@1.2.0+42) matched to the release node of
//     the tag v1.2.0. A regression is seen-in the release it came back in, as a second link.
//   - Which repo: the folder the event is scoped to, when it has a forge repo; its release
//     node is linked whether the tag is found yet or not, as the tag check links its PRs to
//     the same ref later. An event with no folder links only a release the graph knows
//     already, in one folder's repo (or in the one named as the Sentry project, when more
//     than one has the tag).
//   - The health node is also seen-in the deploy that the version's build names, when the
//     graph knows that deploy (#3584): com.example.app@1.2.0+42 is testflight:com.example.app/42.

// kindDeploy is #3584's deploy node.
const kindDeploy = "deploy"

// healthPayload is what health.issue_new and health.issue_regressed say.
type healthPayload struct {
	Org     string `json:"org"`
	Project string `json:"project"`
	Release string `json:"release"`
	Issue   struct {
		ID string `json:"id"`
	} `json:"issue"`
	FirstSeen   string `json:"firstSeen"`
	RegressedAt string `json:"regressedAt"`
}

var semverPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

// sentryVersion is a Sentry release's version tag (v1.2.0), and the package and build it
// names, if any: [<package>@][v]<x.y.z>[+<build>].
func sentryVersion(release string) (tag, pkg, build string, ok bool) {
	rest := strings.TrimSpace(release)
	if i := strings.LastIndex(rest, "@"); i >= 0 {
		pkg, rest = rest[:i], rest[i+1:]
	}
	rest, build, _ = strings.Cut(rest, "+")
	rest = strings.TrimPrefix(rest, "v")
	if !semverPattern.MatchString(rest) {
		return "", "", "", false
	}
	return "v" + rest, pkg, build, true
}

// lineageKnows says whether the graph has the node: a node is in it while a link names it.
func (d *Daemon) lineageKnows(n wire.LineageNode) bool {
	return len(d.lineage().Links(n).Links) > 0
}

// lineageHealthEvent links the health node a health.* event names.
func (d *Daemon) lineageHealthEvent(e wire.Event) {
	var p healthPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Org == "" || p.Issue.ID == "" {
		return
	}
	tag, pkg, build, ok := sentryVersion(p.Release)
	if !ok {
		return
	}
	at := nowFunc()
	when := p.FirstSeen
	if e.Name == "health.issue_regressed" {
		when = p.RegressedAt
	}
	if t, err := time.Parse(time.RFC3339, when); err == nil {
		at = t
	}
	health := wire.LineageNode{Kind: lineage.KindHealth, Ref: "sentry:" + p.Org + "/" + p.Issue.ID}
	scoped := ""
	if e.Scope.Folder != nil {
		scoped = store.FolderPath(e.Scope.Folder.Value)
	}
	d.lineageDo(func() {
		if release, ok := d.healthRelease(scoped, tag, p.Project); ok {
			d.linkAt(health, release, lineage.RelSeenIn, lineage.SourceHealth, at)
		}
		if pkg != "" && build != "" {
			deploy := wire.LineageNode{Kind: kindDeploy, Ref: "testflight:" + pkg + "/" + build}
			if d.lineageKnows(deploy) {
				d.linkAt(health, deploy, lineage.RelSeenIn, lineage.SourceHealth, at)
			}
		}
	})
}

// healthRelease is the release node of tag that a health signal was seen in: in the
// scoped folder's repo, or else the one repo whose release the graph knows.
func (d *Daemon) healthRelease(scoped, tag, project string) (wire.LineageNode, bool) {
	if scoped != "" {
		if repo := d.folderRepo(scoped); repo.forge != "" {
			return repo.release(tag), true
		}
	}
	var found []forgeRepo
	seen := map[forgeRepo]bool{}
	for _, folder := range d.folderPaths() {
		repo := d.folderRepo(folder)
		if repo.forge == "" || seen[repo] {
			continue
		}
		seen[repo] = true
		if d.lineageKnows(repo.release(tag)) {
			found = append(found, repo)
		}
	}
	if len(found) > 1 {
		var named []forgeRepo
		for _, repo := range found {
			if strings.EqualFold(path.Base(repo.path), project) {
				named = append(named, repo)
			}
		}
		found = named
	}
	if len(found) != 1 {
		return wire.LineageNode{}, false
	}
	return found[0].release(tag), true
}
