package agentsd

import (
	"log"
	"maps"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// MARK: the folder watch (DaemonCore+Workflows watchFolder, #173; #1136)
//
// One watch per live folder, rooted at the folder, and the only one it has: a workflow
// file that arrives on disk (a pull, an agent's own Write) is read again and told, a
// guarded file changed outside the app waits for the person (#502), a folder MCP server
// or plugin is looked at again, a branch tip an agent's worktree is on moving raises
// branch.moved (042 R9), and a file a wait or a trigger watches coming or going raises
// file.added or file.removed (#3795; the drop box is one such place, #3796). The watches follow the folder list: every workflow scan looks at it again.

// fileSettle is how long a file must stay as it is before it counts as arrived.
const fileSettle = 600 * time.Millisecond

// branchSettle is how long git is given to finish writing (a rebase writes many refs)
// before the tips are looked at once.
const branchSettle = time.Second

// watchStamp is enough to tell a file arrived, was replaced, or is still being written.
type watchStamp struct {
	size     int64
	modified time.Time
	file     uint64
}

type folderWatchState struct {
	pwMu      sync.Mutex
	pwSyncMu  sync.Mutex
	pwWatches map[string]*folderWatch
	pwKicked  bool
	pwStopped bool
	// pwBusy is what a watch or its timers is doing now: stopFolderWatches waits for it, so
	// nothing writes into the root after the host is gone.
	pwBusy       sync.WaitGroup
	branchTimers map[string]*time.Timer
	// branchCheckMu makes each checkBranches read and write the tips in one go: two at once
	// (the first seed and a move) let the one that read first write its older tips last, and
	// the move after it was not raised (#1278).
	branchCheckMu sync.Mutex
	// fileMu holds fileWatches, what each folder's file events know (#3795), and fileKicked.
	fileMu      sync.Mutex
	fileWatches map[string]*watchedFiles
	fileKicked  bool
}

// skipWatched is what a folder's watch leaves out (folderWatchExclusions, WatchFilter):
// lane worktrees, build output, and everything under .git but what says where branches
// point (refs/heads, worktrees/<name>, and .git itself for HEAD and packed-refs).
func skipWatched(root, p, name string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return true
	}
	rel = filepath.ToSlash(rel)
	if rel == ".git" {
		return false
	}
	if inside, ok := strings.CutPrefix(rel, ".git/"); ok {
		return !(inside == "refs" || inside == "refs/heads" || strings.HasPrefix(inside, "refs/heads/") ||
			inside == "worktrees" || strings.HasPrefix(inside, "worktrees/") && !strings.Contains(strings.TrimPrefix(inside, "worktrees/"), "/"))
	}
	return rel == ".agents/worktrees" || excludedName(name)
}

// kickFolderWatches has the watches follow the folder list, soon and off the caller.
func (d *Daemon) kickFolderWatches() {
	d.pwMu.Lock()
	if d.pwKicked || d.pwStopped {
		d.pwMu.Unlock()
		return
	}
	d.pwKicked = true
	d.pwMu.Unlock()
	safe.Go("folder watches", func() {
		d.pwMu.Lock()
		d.pwKicked = false
		d.pwMu.Unlock()
		d.syncFolderWatches()
	})
}

// syncFolderWatches watches each live folder not yet watched, and lets go of the ones
// archived, deleted or gone. It is watch work, so stopFolderWatches waits for it: the
// folder list it reads makes your policy's first-start move, which writes into the root
// (#3518).
func (d *Daemon) syncFolderWatches() {
	if !d.pwEnter("") {
		return
	}
	defer d.pwBusy.Done()
	d.pwSyncMu.Lock()
	defer d.pwSyncMu.Unlock()
	live := map[string]bool{}
	for _, p := range d.folders(false) {
		if folder := store.FolderPath(p.Folder.Folder); p.Folder.ArchivedAt == nil && isDir(folder) {
			live[folder] = true
		}
	}
	d.dropGoneBranchTips(live)
	d.pwMu.Lock()
	if d.pwStopped {
		d.pwMu.Unlock()
		return
	}
	if d.pwWatches == nil {
		d.pwWatches = map[string]*folderWatch{}
	}
	var gone []*folderWatch
	var goneFolders []string
	for folder, w := range d.pwWatches {
		if !live[folder] {
			gone = append(gone, w)
			goneFolders = append(goneFolders, folder)
			delete(d.pwWatches, folder)
			d.forgetFolderLocked(folder)
		}
	}
	var fresh []string
	for folder := range live {
		if d.pwWatches[folder] == nil {
			fresh = append(fresh, folder)
		}
	}
	d.pwMu.Unlock()
	for _, w := range gone {
		w.stop()
	}
	if len(goneFolders) > 0 {
		d.forgetWorkflowsTold(goneFolders)
	}
	sort.Strings(fresh)
	started := map[string]*folderWatch{}
	var seeded []string
	for _, folder := range fresh {
		w, err := newFolderWatch(folder, func(paths []string) { d.folderFilesChanged(folder, paths) })
		if err != nil {
			log.Printf("folder watch: %s: %v", folder, err)
			continue
		}
		started[folder] = w
		seeded = append(seeded, folder)
	}
	// After each watch hears: a workflow there before the seed is not news.
	if len(seeded) > 0 {
		d.seedWorkflowsTold(seeded)
	}
	for i, folder := range seeded {
		w := started[folder]
		d.pwMu.Lock()
		if d.pwStopped {
			d.pwMu.Unlock()
			for _, rest := range seeded[i:] {
				started[rest].stop()
			}
			return
		}
		d.pwWatches[folder] = w
		d.pwMu.Unlock()
		// Seed what the tips are now, so the first move after this is a move; one that
		// moved while no host ran is raised now.
		d.scheduleBranchCheck(folder, 0)
		d.followFileGlobs(folder)
	}
}

// forgetFolderLocked drops what a folder no longer watched held. Holds pwMu.
func (d *Daemon) forgetFolderLocked(folder string) {
	if t := d.branchTimers[folder]; t != nil {
		t.Stop()
		delete(d.branchTimers, folder)
	}
	d.forgetWatchedFiles(folder)
}

// stopFolderWatches ends every watch, for good: the host is going.
func (d *Daemon) stopFolderWatches() {
	d.pwMu.Lock()
	d.pwStopped = true
	ws := d.pwWatches
	d.pwWatches = nil
	for folder := range ws {
		d.forgetFolderLocked(folder)
	}
	d.pwMu.Unlock()
	for _, w := range ws {
		w.stop()
	}
	d.pwBusy.Wait()
}

// pwEnter starts a piece of watch work, unless the watches are stopped; pwBusy.Done ends it.
// Holds pwMu while it adds, so no work starts once stopFolderWatches waits.
func (d *Daemon) pwEnter(folder string) bool {
	d.pwMu.Lock()
	defer d.pwMu.Unlock()
	if d.pwStopped || folder != "" && d.pwWatches[folder] == nil {
		return false
	}
	d.pwBusy.Add(1)
	return true
}

// folderFilesChanged is DaemonCore.folderFilesChanged: what a folder's watch heard,
// sent where it matters.
func (d *Daemon) folderFilesChanged(folder string, paths []string) {
	if !d.pwEnter(folder) {
		return
	}
	defer d.pwBusy.Done()
	if !isDir(folder) {
		return
	}
	agents := filepath.Join(folder, ".agents")
	workflows := workflowsFolder(folder)
	under := func(p, dir string) bool { return p == dir || strings.HasPrefix(p, dir+string(filepath.Separator)) }
	var branches, rescan, approvals bool
	guarded := map[string]bool{}
	for _, p := range paths {
		if isBranchPath(p) {
			branches = true
		}
		if !under(p, agents) {
			continue
		}
		// A skill a workflow names is approved with it (S20261019-2).
		if p == agents || under(p, workflows) || under(p, filepath.Join(folder, skillsRel)) {
			rescan = true
		}
		for rel := range guardedFiles {
			if p == agents || p == filepath.Join(folder, rel) {
				guarded[rel] = true
			}
		}
		if p == agents || p == filepath.Join(agents, "mcp.json") || under(p, filepath.Join(agents, "plugins")) {
			approvals = true
		}
	}
	d.watchedFilesChanged(folder, paths)
	if branches {
		d.scheduleBranchCheck(folder, branchSettle)
	}
	if rescan {
		d.rescanWorkflows(folder)
	}
	// A change to an app-owned file made outside the app waits for the person (#502); the
	// folder's summary and pins say what it is now.
	for rel := range guarded {
		d.checkGuarded(folder, rel, nil)
	}
	if guarded[".agents/pins.json"] {
		d.pinsChanged(folder)
	}
	// The summary carries the folder's settings and its MCP servers and plugins waiting
	// for approval (#126, #773).
	if guarded[".agents/folder.json"] || approvals {
		d.sendFolder(folder)
	}
}

// rescanWorkflows reads a folder's workflows again and tells each one that came, changed
// or went since it was last told (scheduleWorkflowRescan). What it was last told is
// workflowTold, which only telling moves: a reader's scan in between leaves it (#4750).
func (d *Daemon) rescanWorkflows(folder string) {
	d.workflowMu.Lock()
	d.scanLocked()
	// A copy: tellWorkflow writes the told map under the lock while this ranges (#4839).
	before := maps.Clone(d.workflowTold[folder])
	after := workflowDigests(d.workflowFiles[folder])
	d.workflowMu.Unlock()
	var told []string
	for id, digest := range after {
		if was, ok := before[id]; !ok || was != digest {
			told = append(told, id)
		}
	}
	for id := range before {
		if _, ok := after[id]; !ok {
			told = append(told, id)
		}
	}
	sort.Strings(told)
	for _, id := range told {
		d.tellWorkflow(folder, id)
	}
}

// workflowDigests is each workflow's digest, by id.
func workflowDigests(files map[string]*workflowFile) map[string]string {
	out := make(map[string]string, len(files))
	for id, f := range files {
		out[id] = f.digest
	}
	return out
}

// seedWorkflowsTold takes what newly watched folders' workflows are now as told: a file
// there before the watch is not news, one that comes after it is. Never holds pwMu, as
// scanLocked takes it.
func (d *Daemon) seedWorkflowsTold(folders []string) {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	d.scanLocked()
	if d.workflowTold == nil {
		d.workflowTold = map[string]map[string]string{}
	}
	for _, folder := range folders {
		d.workflowTold[folder] = workflowDigests(d.workflowFiles[folder])
	}
}

// forgetWorkflowsTold drops what folders no longer watched were told. Never holds pwMu.
func (d *Daemon) forgetWorkflowsTold(folders []string) {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	for _, folder := range folders {
		delete(d.workflowTold, folder)
	}
}

// MARK: branch.moved (DaemonCore+EventSources, 042 R9)

// isBranchPath is DaemonCore.isBranchPath: a branch tip, or what a worktree has checked out.
func isBranchPath(p string) bool {
	p = filepath.ToSlash(p)
	return strings.Contains(p, "/.git/refs/heads") || strings.HasSuffix(p, "/.git/packed-refs") ||
		strings.HasSuffix(p, "/.git/HEAD") || strings.Contains(p, "/.git/worktrees/") && strings.HasSuffix(p, "/HEAD")
}

// scheduleBranchCheck looks at a folder's tips after delay, once however many refs moved.
func (d *Daemon) scheduleBranchCheck(folder string, delay time.Duration) {
	if !isDir(filepath.Join(folder, ".git")) {
		return
	}
	d.pwMu.Lock()
	defer d.pwMu.Unlock()
	if d.pwStopped {
		return
	}
	if d.branchTimers == nil {
		d.branchTimers = map[string]*time.Timer{}
	}
	if t := d.branchTimers[folder]; t != nil {
		t.Stop()
	}
	d.branchTimers[folder] = time.AfterFunc(delay, func() { d.checkBranches(folder) })
}

// checkBranches is DaemonCore.checkBranches: the tips of the branches the folder's agents'
// worktrees are on, against those last seen, with one branch.moved for each that moved.
// The first look at a folder only seeds them. Not the default branch (#702): the host's
// copy of it moves only on a pull.
func (d *Daemon) checkBranches(folder string) {
	if !d.pwEnter("") {
		return
	}
	defer d.pwBusy.Done()
	d.branchCheckMu.Lock()
	defer d.branchCheckMu.Unlock()
	watched := map[string]bool{}
	for _, a := range d.liveAgentsOf(folder) {
		if a.State != wire.AgentStateArchived && a.Worktree != nil && a.Worktree.Branch != nil {
			watched[*a.Worktree.Branch] = true
		}
	}
	tips := map[string]string{}
	if out, err := git(folder, "for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			if name, tip, ok := strings.Cut(line, " "); ok && watched[name] {
				tips[name] = tip
			}
		}
	} else {
		return
	}
	d.eventMu.Lock()
	if d.eventStateNow.BranchTips == nil {
		d.eventStateNow.BranchTips = map[string]map[string]string{}
	}
	before, seen := d.eventStateNow.BranchTips[folder]
	// Written only when it moved: at start every folder is looked at (#204).
	if seen && sameDetails(before, tips) {
		d.eventMu.Unlock()
		return
	}
	d.eventStateNow.BranchTips[folder] = tips
	d.saveEventStateLocked()
	d.eventMu.Unlock()
	if !seen {
		return
	}
	names := make([]string, 0, len(tips))
	for name := range tips {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		old, ok := before[name]
		tip := tips[name]
		if !ok || old == tip {
			continue
		}
		d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: folderScope(folder),
			Sentence: name + " moved to " + short(tip, 7) + ".",
			Details:  map[string]string{"branch": name, "from": short(old, 12), "to": short(tip, 12)}})
	}
}

// dropGoneBranchTips forgets the branch tips of each folder that is no longer a live
// folder (#2292), so events-state.json does not keep every folder there ever was. One
// that comes back is looked at afresh, as at the first start.
func (d *Daemon) dropGoneBranchTips(live map[string]bool) {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	if dropGone(d.eventStateNow.BranchTips, live) {
		d.saveEventStateLocked()
	}
}

// dropGone deletes the tips of each folder live does not name, and says whether any went.
func dropGone(tips map[string]map[string]string, live map[string]bool) bool {
	gone := false
	for folder := range tips {
		if !live[folder] {
			delete(tips, folder)
			gone = true
		}
	}
	return gone
}

func short(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// saveFolders writes folders.json, and has the watches follow what it now says.
func (d *Daemon) saveFolders(ps []wire.Folder) error {
	err := d.Store.SaveFolders(ps)
	d.kickFolderWatches()
	return err
}
