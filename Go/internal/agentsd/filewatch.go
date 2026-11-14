package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/bmatcuk/doublestar/v4"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// MARK: file.added and file.removed (#3795)
//
// A wait or a workflow trigger on a file event names the files it watches with paths:
// globs, relative to the folder, ** across folders. The folder's watch hears every change
// in the folder; only a change to a file one of those globs matches is looked at, and only
// one that adds or removes a matching file is written to the event log. So a folder with
// no such wait or trigger writes nothing, and one with them writes only what they watch.
//
// What a folder's matching files are is taken when the globs change (a wait starts, a
// workflow is read or turned on), so a file that appears afterwards is added and one that
// goes is removed. A file written over under the same name fires nothing. A file still
// being written is added once, after it has stayed as it is for fileSettle. Every file
// added (or removed) in one look is one event.

// fileEventPathsLimit is the most paths an event lists; count says how many there were.
const fileEventPathsLimit = 100

// watchedFiles is what one folder's file events know: the globs it was looked at for, the
// matching files that were there, the ones still being written, and the paths to look at.
type watchedFiles struct {
	globs    []string
	seen     map[string]watchStamp
	settling map[string]watchStamp
	pending  map[string]bool
	timer    *time.Timer
}

// isFileEvent is file.added, file.removed or file.*.
func isFileEvent(name string) bool {
	return name == "file.added" || name == "file.removed" || name == "file.*"
}

// fileGlobsWords is why a file event's paths are refused, or "": they are needed, and
// each is a glob relative to the folder.
func fileGlobsWords(p waitPattern) string {
	if !isFileEvent(p.name) {
		return ""
	}
	globs := p.filters["paths"]
	if len(globs) == 0 {
		return p.name + ": Say which files to watch with `paths`, a list of globs relative to the folder, " +
			`for example {"paths": ["reports/*.csv", "docs/**/*.md"]}. Only changes to those files are raised.`
	}
	for _, g := range globs {
		if g == "" || strings.HasPrefix(g, "/") || g == ".." || strings.HasPrefix(g, "../") || strings.Contains(g, "/../") ||
			!doublestar.ValidatePattern(g) {
			return p.name + `: "` + g + `" is not a glob relative to the folder, such as reports/*.csv or **/*.md.`
		}
	}
	return ""
}

// matchesAnyGlob says whether a path relative to the folder matches one of the globs.
func matchesAnyGlob(rel string, globs []string) bool {
	for _, g := range globs {
		if ok, _ := doublestar.Match(g, rel); ok {
			return true
		}
	}
	return false
}

// eventPaths is a file event's paths detail, a JSON list, read back.
func eventPaths(e wire.Event) []string {
	var paths []string
	json.Unmarshal([]byte(e.Details["paths"]), &paths)
	return paths
}

// globsCouldHold says whether a folder (relative, "" for the top) can hold a file one of
// the globs matches, so a walk need not go into the ones that cannot.
func globsCouldHold(dir string, globs []string) bool {
	if dir == "" || dir == "." {
		return len(globs) > 0
	}
	parts := strings.Split(dir, "/")
	for _, g := range globs {
		if strings.Contains(g, "{") {
			return true // a brace may hold a slash: walk it
		}
		segs := strings.Split(g, "/")
		fits := true
		for i, part := range parts {
			if i >= len(segs) {
				fits = false
				break
			}
			if segs[i] == "**" {
				return true
			}
			if ok, _ := doublestar.Match(segs[i], part); !ok {
				fits = false
				break
			}
		}
		if fits && len(segs) > len(parts) {
			return true
		}
	}
	return false
}

// fileGlobs is every glob this folder's running waits and turned-on workflow triggers
// watch, sorted, each once.
func (d *Daemon) fileGlobs(folder string) []string {
	set := map[string]bool{}
	add := func(p waitPattern) {
		if isFileEvent(p.name) {
			for _, g := range p.filters["paths"] {
				set[g] = true
			}
		}
	}
	for _, a := range d.Store.LiveAgents() {
		if w := a.EventWait; w != nil && w.Ending == nil && folderPath(&a) == folder {
			for _, p := range waitPatterns(w) {
				add(p)
			}
		}
	}
	d.workflowMu.Lock()
	for _, f := range d.workflowFiles[folder] {
		if f.wf.Problem != nil || isArchived(f.wf) || isOff(f.wf) || !d.runsHere(f.wf) {
			continue
		}
		for _, t := range f.wf.Triggers {
			if p, ok := triggerPattern(t); ok {
				add(p)
			}
		}
	}
	d.workflowMu.Unlock()
	globs := make([]string, 0, len(set))
	for g := range set {
		globs = append(globs, g)
	}
	sort.Strings(globs)
	return globs
}

// fileStamp is a regular file's stamp, or false for anything else or nothing.
func fileStamp(p string) (watchStamp, bool) {
	info, err := os.Lstat(p)
	if err != nil || !info.Mode().IsRegular() {
		return watchStamp{}, false
	}
	var file uint64
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		file = uint64(st.Ino)
	}
	return watchStamp{size: info.Size(), modified: info.ModTime(), file: file}, true
}

// walkWatched is every file under dir (absolute) that one of the globs matches, by its path
// relative to the folder, leaving out what the folder's watch leaves out and .git.
func walkWatched(folder, dir string, globs []string) map[string]watchStamp {
	files := map[string]watchStamp{}
	filepath.WalkDir(dir, func(p string, e os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, rerr := filepath.Rel(folder, p)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if e.IsDir() {
			if p != folder && (e.Name() == ".git" || skipWatched(folder, p, e.Name()) || !globsCouldHold(rel, globs)) {
				return filepath.SkipDir
			}
			return nil
		}
		if !matchesAnyGlob(rel, globs) {
			return nil
		}
		if stamp, ok := fileStamp(p); ok {
			files[rel] = stamp
		}
		return nil
	})
	return files
}

// kickFileWatches has every folder's file events follow their globs, soon and off the
// caller: a workflow was read again or turned on or off.
func (d *Daemon) kickFileWatches() {
	d.fileMu.Lock()
	if d.fileKicked {
		d.fileMu.Unlock()
		return
	}
	d.fileKicked = true
	d.fileMu.Unlock()
	safe.Go("file watches", func() {
		if !d.pwEnter("") {
			return
		}
		defer d.pwBusy.Done()
		d.fileMu.Lock()
		d.fileKicked = false
		d.fileMu.Unlock()
		for _, p := range d.folders(false) {
			if p.Folder.ArchivedAt == nil {
				d.followFileGlobs(store.FolderPath(p.Folder.Folder))
			}
		}
	})
}

// followFileGlobs looks at a folder's matching files again when its globs changed, so what is
// there now is not raised as added; with no globs it forgets them.
func (d *Daemon) followFileGlobs(folder string) {
	globs := d.fileGlobs(folder)
	d.fileMu.Lock()
	st := d.fileWatches[folder]
	if st != nil && strings.Join(st.globs, "\x00") == strings.Join(globs, "\x00") {
		d.fileMu.Unlock()
		return
	}
	if len(globs) == 0 {
		if st != nil && st.timer != nil {
			st.timer.Stop()
		}
		delete(d.fileWatches, folder)
		d.fileMu.Unlock()
		return
	}
	d.fileMu.Unlock()
	if !isDir(folder) {
		return
	}
	seen := walkWatched(folder, folder, globs)
	d.fileMu.Lock()
	defer d.fileMu.Unlock()
	if d.fileWatches == nil {
		d.fileWatches = map[string]*watchedFiles{}
	}
	if st = d.fileWatches[folder]; st == nil {
		st = &watchedFiles{settling: map[string]watchStamp{}, pending: map[string]bool{}}
		d.fileWatches[folder] = st
	}
	st.globs, st.seen = globs, seen
}

// forgetWatchedFiles drops what a folder's file events knew: it is no longer watched.
func (d *Daemon) forgetWatchedFiles(folder string) {
	d.fileMu.Lock()
	defer d.fileMu.Unlock()
	if st := d.fileWatches[folder]; st != nil && st.timer != nil {
		st.timer.Stop()
	}
	delete(d.fileWatches, folder)
}

// watchedFilesChanged is what the folder's watch heard, narrowed to the files the globs match:
// those are looked at in a moment, and the rest dropped.
func (d *Daemon) watchedFilesChanged(folder string, paths []string) {
	d.fileMu.Lock()
	st := d.fileWatches[folder]
	if st == nil {
		d.fileMu.Unlock()
		return
	}
	globs := st.globs
	seen := make([]string, 0, len(st.seen))
	for rel := range st.seen {
		seen = append(seen, rel)
	}
	d.fileMu.Unlock()
	found := map[string]bool{}
	for _, p := range paths {
		rel, err := filepath.Rel(folder, p)
		if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}
		rel = filepath.ToSlash(rel)
		if rel == ".git" || strings.HasPrefix(rel, ".git/") {
			continue
		}
		info, err := os.Lstat(p)
		switch {
		case err != nil:
			// Gone: it, and every file seen under it (a folder removed or moved away).
			if matchesAnyGlob(rel, globs) {
				found[rel] = true
			}
			for _, s := range seen {
				if strings.HasPrefix(s, rel+"/") {
					found[s] = true
				}
			}
		case info.IsDir():
			// A folder made or moved in says only its own path: what is in it.
			if globsCouldHold(rel, globs) && !skipWatched(folder, p, info.Name()) {
				for s := range walkWatched(folder, p, globs) {
					found[s] = true
				}
			}
			for _, s := range seen {
				if strings.HasPrefix(s, rel+"/") {
					found[s] = true
				}
			}
		case matchesAnyGlob(rel, globs):
			found[rel] = true
		}
	}
	if len(found) == 0 {
		return
	}
	d.fileMu.Lock()
	defer d.fileMu.Unlock()
	if st = d.fileWatches[folder]; st == nil {
		return
	}
	for rel := range found {
		st.pending[rel] = true
	}
	d.scheduleFileCheckLocked(folder, st)
}

// scheduleFileCheckLocked looks in a moment, unless a look is already due. Holds fileMu.
func (d *Daemon) scheduleFileCheckLocked(folder string, st *watchedFiles) {
	if st.timer != nil {
		return
	}
	st.timer = time.AfterFunc(fileSettle, func() { d.checkWatchedFiles(folder) })
}

// checkWatchedFiles is one look at the paths heard since the last: a matching file that
// is gone is removed; one that is new is added once it is as the last look found it, and
// until then it is settling and looked at again. One event says every file of each.
func (d *Daemon) checkWatchedFiles(folder string) {
	if !d.pwEnter("") {
		return
	}
	defer d.pwBusy.Done()
	d.fileMu.Lock()
	st := d.fileWatches[folder]
	if st == nil {
		d.fileMu.Unlock()
		return
	}
	st.timer = nil
	pending := st.pending
	st.pending = map[string]bool{}
	d.fileMu.Unlock()
	stamps := map[string]watchStamp{}
	for rel := range pending {
		if stamp, ok := fileStamp(filepath.Join(folder, filepath.FromSlash(rel))); ok {
			stamps[rel] = stamp
		}
	}
	d.fileMu.Lock()
	if d.fileWatches[folder] != st {
		d.fileMu.Unlock()
		return
	}
	var added, removed []string
	for rel := range pending {
		stamp, here := stamps[rel]
		_, was := st.seen[rel]
		switch {
		case !here:
			delete(st.settling, rel)
			if was {
				delete(st.seen, rel)
				removed = append(removed, rel)
			}
		case was:
			// Written over under the same name: nothing to say.
			st.seen[rel] = stamp
		case st.settling[rel] == stamp:
			delete(st.settling, rel)
			st.seen[rel] = stamp
			added = append(added, rel)
		default:
			st.settling[rel] = stamp
			st.pending[rel] = true
		}
	}
	if len(st.pending) > 0 {
		d.scheduleFileCheckLocked(folder, st)
	}
	d.fileMu.Unlock()
	// A wait that ended since leaves its globs behind: only what is watched now is raised.
	globs := d.fileGlobs(folder)
	d.raiseFileEvent(folder, "file.removed", "removed", removed, globs)
	d.raiseFileEvent(folder, "file.added", "added", added, globs)
}

func (d *Daemon) raiseFileEvent(folder, name, verb string, paths, globs []string) {
	var watched []string
	for _, rel := range paths {
		if matchesAnyGlob(rel, globs) {
			watched = append(watched, rel)
		}
	}
	if len(watched) == 0 {
		return
	}
	sort.Strings(watched)
	listed := watched
	if len(listed) > fileEventPathsLimit {
		listed = listed[:fileEventPathsLimit]
	}
	list, _ := json.Marshal(listed)
	sentence := watched[0] + " was " + verb + "."
	if n := len(watched); n == 2 {
		sentence = watched[0] + " and 1 more file were " + verb + "."
	} else if n > 2 {
		sentence = watched[0] + " and " + strconv.Itoa(n-1) + " more files were " + verb + "."
	}
	d.raise(wire.EventDraft{Name: name, At: now(), Scope: folderScope(folder), Sentence: sentence,
		Details: map[string]string{"paths": string(list), "count": strconv.Itoa(len(watched))}})
}
