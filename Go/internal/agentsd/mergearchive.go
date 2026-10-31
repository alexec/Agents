package agentsd

import (
	"encoding/json"
	"log"
	"sort"
	"strconv"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Archive a session when its pull request merges (#2886), as Parallel Code and Solenta do.
// Folder Settings ▸ General's switch, HelperLimits.archiveWhenMerged, is on unless the
// person said not. While a folder has a session in a worktree on a branch, this host hears
// pr.merged from every server there that offers it (the github and gitlab servers), with no
// arguments, so a workflow on pr.merged shares the subscription. A merged pull request from
// a session's branch archives that session when its turn has ended (Done or Stopped) and
// its worktree has nothing uncommitted. Any other session gets a line in its chat instead:
// one working, waiting, or asking the person is not put away under them.

const mergedEventName = "pr.merged"

// mergeNotedLimit is the most merges kept as said; past it they start again.
const mergeNotedLimit = 1000

type mergeArchiveBook struct {
	mergeMu sync.Mutex
	// mergeNoted is each session told its pull request merged, by "<agent>|<pr>": a merge
	// heard by two subscriptions is said once.
	mergeNoted map[string]bool
}

// archivesWhenMerged is HelperLimits.archiveWhenMerged: true unless the person said not.
func (d *Daemon) archivesWhenMerged(folder string) bool {
	m, err := d.approvedConfig(folder)
	if err != nil {
		return true
	}
	v, ok := m["helperLimits"]
	if !ok {
		return true
	}
	var l wire.HelperLimits
	if b, _ := json.Marshal(v); json.Unmarshal(b, &l) != nil || l.ArchiveWhenMerged == nil {
		return true
	}
	return *l.ArchiveWhenMerged
}

// onMergedBranch is whether a is a session in a worktree on a branch, not archived.
func onMergedBranch(a *wire.Agent) bool {
	return a.State != wire.AgentStateArchived && a.Worktree != nil && a.Worktree.Branch != nil && *a.Worktree.Branch != ""
}

// mergeArchiveFolders is each folder with the switch on and a session in a worktree on a
// branch now, sorted.
func (d *Daemon) mergeArchiveFolders() []string {
	seen := map[string]bool{}
	var out []string
	for _, a := range d.Store.Agents() {
		if !onMergedBranch(&a) {
			continue
		}
		f := folderPath(&a)
		if seen[f] {
			continue
		}
		seen[f] = true
		if d.archivesWhenMerged(f) {
			out = append(out, f)
		}
	}
	sort.Strings(out)
	return out
}

// addMergeArchives adds the pr.merged subscriptions the switch holds, beside the workflows'
// and the waits'.
func (d *Daemon) addMergeArchives(wanted map[string]*mcpSubscription, servers func(folder string) map[string]found) {
	t := mcpTrigger{event: mergedEventName, arguments: map[string]json.RawMessage{}}
	for _, folder := range d.mergeArchiveFolders() {
		here := servers(folder)
		names := make([]string, 0, len(here))
		for n := range here {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, name := range names {
			f := here[name]
			if f.problem != "" {
				continue
			}
			for _, def := range d.mcpEventListing(f.server).events {
				if def.Name != mergedEventName || !def.offersPoll() {
					continue
				}
				if len(def.InputSchema) > 0 && jsonSchemaProblem(mustRaw(t.arguments), def.InputSchema, name) != "" {
					continue
				}
				key := t.subscriptionKey(name)
				id := mcpRecordKey(folder, key)
				if s := wanted[id]; s != nil {
					s.archives = true
					continue
				}
				wanted[id] = &mcpSubscription{id: id, key: key, folder: folder, server: name, event: def.Name,
					arguments: t.arguments, archives: true, pool: f.server.pool(), filled: f.server.filled,
					cwd: f.server.cwd, fingerprint: def.wireText() + "\n" + f.server.entry}
			}
		}
	}
}

// mergedPR is what a pr.merged event says of its pull request.
type mergedPR struct {
	PR struct {
		Number int64  `json:"number"`
		Branch string `json:"branch"`
	} `json:"pr"`
}

// archiveMergedSessions settles every session on the branch a raised pr.merged event says
// merged, in the event's folder, when the switch is on there.
func (d *Daemon) archiveMergedSessions(e wire.Event) {
	if e.Name != mergedEventName || e.Scope.Folder == nil || e.Details["server"] == "" {
		return
	}
	var p mergedPR
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.PR.Branch == "" {
		return
	}
	folder := store.FolderPath(e.Scope.Folder.Value)
	if !d.archivesWhenMerged(folder) {
		return
	}
	for _, a := range d.Store.Agents() {
		if onMergedBranch(&a) && *a.Worktree.Branch == p.PR.Branch && folderPath(&a) == folder {
			d.settleMerged(a, p.PR.Number)
		}
	}
}

// mayArchiveMerged is whether a session whose pull request merged is put away now: its
// turn ended (Done or Stopped, nothing queued) and nothing uncommitted in its worktree.
func mayArchiveMerged(a *wire.Agent) bool {
	if g := Group(a); g != "finished" && g != "stopped" || len(a.QueuedPrompts) > 0 {
		return false
	}
	root := store.FolderPath(a.Worktree.Root)
	return !isDir(root) || porcelainCount(root) == 0
}

// settleMerged archives a, or says in its chat that its pull request merged.
func (d *Daemon) settleMerged(a wire.Agent, number int64) {
	pr := "Its pull request"
	if number > 0 {
		pr += " #" + strconv.FormatInt(number, 10)
	}
	if mayArchiveMerged(&a) {
		d.record(a.ID, runtimeNote(pr+" merged, so it was archived, as this folder's settings say."))
		if err := d.archiveBy(a.ID, wire.AgentArchivedReasonByAgent); err != nil {
			return
		}
		log.Printf("archive when merged: %s archived", a.ID)
		return
	}
	key := string(a.ID) + "|" + strconv.FormatInt(number, 10)
	d.mergeMu.Lock()
	if d.mergeNoted == nil || len(d.mergeNoted) >= mergeNotedLimit {
		d.mergeNoted = map[string]bool{}
	}
	told := d.mergeNoted[key]
	d.mergeNoted[key] = true
	d.mergeMu.Unlock()
	if !told {
		d.record(a.ID, runtimeNote(pr+" merged. It was not archived, as it is not done or its worktree has uncommitted changes."))
	}
}
