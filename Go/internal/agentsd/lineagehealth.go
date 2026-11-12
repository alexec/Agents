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
//   - Kind health, ref betterstack:<incident id>, from the betterstack events server's
//     health.incident_started (#3655): a monitor behind a deployed app's status page that
//     failed. An incident names no version, so it is seen-in the release that was out when
//     it started: of the version tags done in the scoped folder's repo, the highest whose
//     release node's first link is at or before the start. An event with no folder links
//     nothing: a wrong link is worse than a missing one.
//   - Health back into work (#3586): a workflow run that a health.* event started links
//     health started the run's session, and an issue that session works on (the File a bug
//     from Sentry workflow labels its session with the bug it filed or commented on)
//     reports the health signal: a walk from the bug reaches the release and its PRs.

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

// incidentPayload is what health.incident_started and health.incident_resolved say.
type incidentPayload struct {
	Incident struct {
		ID string `json:"id"`
	} `json:"incident"`
	StartedAt string `json:"startedAt"`
}

// incidentOf is a Better Stack event's payload and its health node.
func incidentOf(e wire.Event) (incidentPayload, wire.LineageNode, bool) {
	var p incidentPayload
	if e.Name != "health.incident_started" && e.Name != "health.incident_resolved" ||
		json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Incident.ID == "" {
		return p, wire.LineageNode{}, false
	}
	return p, lineage.NodeOf(lineage.KindHealth, wire.Ref{Provider: "betterstack", Type: "incident", ID: p.Incident.ID}), true
}

// healthNode is the health node a health.* event names, from any health source.
func healthNode(e wire.Event) (wire.LineageNode, bool) {
	if _, n, ok := healthOf(e); ok {
		return n, true
	}
	_, n, ok := incidentOf(e)
	return n, ok
}

// healthOf is a Sentry health.* event's payload and its health node.
func healthOf(e wire.Event) (healthPayload, wire.LineageNode, bool) {
	var p healthPayload
	if e.Name != "health.issue_new" && e.Name != "health.issue_regressed" ||
		json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Org == "" || p.Issue.ID == "" {
		return p, wire.LineageNode{}, false
	}
	return p, lineage.NodeOf(lineage.KindHealth, wire.Ref{Provider: "sentry", Type: "issue", Topic: strings.ToLower(p.Org), ID: p.Issue.ID}), true
}

// lineageHealthStarted links health started session, for the session a health.* event's
// workflow run started.
func (d *Daemon) lineageHealthStarted(e wire.Event, session wire.UUID) {
	if health, ok := healthNode(e); ok {
		d.lineageDo(func() { d.link(health, d.sessionNode(session), lineage.RelStarted, lineage.SourceHelper) })
	}
}

// lineageReportsHealth links issue reports health for each health signal that started the
// session s, which now works on issue. It runs in lineageDo.
func (d *Daemon) lineageReportsHealth(s, issue wire.LineageNode) {
	if issue.Kind != lineage.KindIssue {
		return
	}
	for _, l := range d.lineage().Links(s).Links {
		if l.To == s && l.Rel == lineage.RelStarted && l.From.Kind == lineage.KindHealth {
			d.link(issue, l.From, lineage.RelReports, lineage.SourceAgent)
		}
	}
}

// lineageHealthEvent links the health node a health.* event names.
func (d *Daemon) lineageHealthEvent(e wire.Event) {
	p, health, ok := healthOf(e)
	if !ok {
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
	scoped := ""
	if e.Scope.Folder != nil {
		scoped = store.FolderPath(e.Scope.Folder.Value)
	}
	d.lineageDo(func() {
		if release, ok := d.healthRelease(scoped, tag, p.Project); ok {
			d.linkAt(health, release, lineage.RelSeenIn, lineage.SourceHealth, at)
		}
		if pkg != "" && build != "" {
			deploy := lineage.Full(wire.LineageNode{Kind: kindDeploy, Ref: "testflight:" + pkg + "/" + build}, "")
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

// lineageIncidentEvent links the health node health.incident_started names seen-in the
// release that was out when the incident started.
func (d *Daemon) lineageIncidentEvent(e wire.Event) {
	p, health, ok := incidentOf(e)
	if !ok || e.Name != "health.incident_started" || e.Scope.Folder == nil {
		return
	}
	at, err := time.Parse(time.RFC3339, p.StartedAt)
	if err != nil {
		return
	}
	repo := d.folderRepo(store.FolderPath(e.Scope.Folder.Value))
	if repo.forge == "" {
		return
	}
	d.lineageDo(func() {
		if release, ok := d.releaseOutAt(repo, at); ok {
			d.linkAt(health, release, lineage.RelSeenIn, lineage.SourceHealth, at)
		}
	})
}

// releaseOutAt is the release of repo that was out at at: the highest version tag done
// whose release node's first link is at or before it. It runs in lineageDo.
func (d *Daemon) releaseOutAt(repo forgeRepo, at time.Time) (wire.LineageNode, bool) {
	var tags []string
	done, _ := d.doneReleaseTags(repo)
	for tag := range done {
		if versionTagPattern.MatchString(tag) {
			tags = append(tags, tag)
		}
	}
	sortVersionTags(tags)
	for i := len(tags) - 1; i >= 0; i-- {
		release := repo.release(tags[i])
		links := d.lineage().Links(release).Links
		if len(links) == 0 {
			continue
		}
		first := links[0].At
		for _, l := range links[1:] {
			first = min(first, l.At)
		}
		if !first.Time().After(at) {
			return release, true
		}
	}
	return wire.LineageNode{}, false
}
