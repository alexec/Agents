package agentsd

import (
	"bufio"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
)

// folderWatch is FolderWatch on a Mac (#1138): FSEvents, through agents-watch beside this
// binary in Agents Host's Helpers (Host/AgentsWatch), one for each watch. What changed is
// gathered for a quarter of a second and said as the folders it was in (or the paths, for a
// folder's watch), leaving out what the Linux watch leaves out. With no agents-watch (a
// build that carries none) a watch hears nothing, as before, and says so once.
type folderWatch struct {
	root     string
	resolved string
	changed  func([]string)
	// skip is which folders under root are not heard; nil is an agent folder's rule.
	skip func(path, name string) bool
	// files says the paths that changed, not the folders they were in.
	files bool
	cmd   *exec.Cmd
	stdin io.WriteCloser
	once  sync.Once
	done  chan struct{}
}

// watchHelper is agents-watch's path: beside this binary, or a test's own.
var watchHelper = func() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "agents-watch")
}

var missingWatchHelper sync.Once

func newFilesWatch(root string, changed func([]string)) (*folderWatch, error) {
	return startFolderWatch(&folderWatch{root: root, changed: changed}, "files watch")
}

// newFolderWatch is a folder's one watch (#173): every folder but the ones skipWatched
// leaves out, said as the paths that changed.
func newFolderWatch(root string, changed func([]string)) (*folderWatch, error) {
	return startFolderWatch(&folderWatch{root: root, changed: changed, files: true,
		skip: func(p, name string) bool { return skipWatched(root, p, name) }}, "folder watch")
}

func startFolderWatch(w *folderWatch, name string) (*folderWatch, error) {
	w.done = make(chan struct{})
	w.root = filepath.Clean(w.root)
	w.resolved = w.root
	if r, err := filepath.EvalSymlinks(w.root); err == nil {
		w.resolved = r
	}
	helper := watchHelper()
	if fi, err := os.Stat(helper); helper == "" || err != nil || fi.Mode()&0o111 == 0 {
		missingWatchHelper.Do(func() {
			log.Printf("%s: no agents-watch beside agentsd, so changes made outside the app are not heard", name)
		})
		return w, nil
	}
	cmd := exec.Command(helper, w.root)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	w.cmd, w.stdin = cmd, stdin
	ready := make(chan struct{})
	paths := make(chan string, 1024)
	safe.Go(name+" read", func() {
		defer close(paths)
		r := bufio.NewReaderSize(stdout, 64<<10)
		for {
			p, err := r.ReadString(0)
			if len(p) > 1 {
				paths <- strings.TrimSuffix(p, "\x00")
			} else if len(p) == 1 {
				paths <- ""
			}
			if err != nil {
				return
			}
		}
	})
	safe.Go(name, func() { w.gather(paths, ready) })
	// Watching from the moment this returns: a change made at once is heard.
	select {
	case <-ready:
	case <-time.After(2 * time.Second):
		log.Printf("%s: agents-watch did not say it was ready on %s in 2 s", name, w.root)
	}
	return w, nil
}

// gather says what came in each quarter of a second, once. A NUL alone starts a word from
// the helper: "ready" once it watches, "gone" when the root goes.
func (w *folderWatch) gather(paths <-chan string, ready chan struct{}) {
	pending := map[string]bool{}
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	gone := false
	for {
		select {
		case p, ok := <-paths:
			if !ok {
				return
			}
			if p == "" {
				gone = true
				continue
			}
			if gone && p == "ready" {
				close(ready)
				gone = false
				continue
			}
			if gone && p == "gone" {
				// The root itself went (a folder removed): nothing more is heard.
				go w.stop()
				gone = false
				continue
			}
			gone = false
			if here, ok := w.under(p); ok && !w.skipped(here) {
				switch {
				case w.files:
					pending[here] = true
				case here == w.root:
					// The root itself (made, or its own metadata), not the folder it is in.
					pending[w.root] = true
				default:
					pending[filepath.Dir(here)] = true
				}
			}
		case <-tick.C:
			if len(pending) == 0 {
				continue
			}
			out := make([]string, 0, len(pending))
			for p := range pending {
				out = append(out, p)
			}
			sort.Strings(out)
			pending = map[string]bool{}
			w.changed(out)
		case <-w.done:
			return
		}
	}
}

// under is p as a path under the root as it was given (FSEvents says them resolved:
// /tmp is /private/tmp), or false for one outside it.
func (w *folderWatch) under(p string) (string, bool) {
	p = filepath.Clean(p)
	for _, base := range []string{w.resolved, w.root} {
		if p == base {
			return w.root, true
		}
		if rel, ok := strings.CutPrefix(p, base+"/"); ok {
			return filepath.Join(w.root, rel), true
		}
	}
	return "", false
}

// skipped is whether any folder on the way from the root to p is one this watch leaves out,
// by the Linux watch's rules (addTree).
func (w *folderWatch) skipped(p string) bool {
	rel, err := filepath.Rel(w.root, p)
	if err != nil || rel == "." {
		return false
	}
	at := w.root
	for _, name := range strings.Split(rel, string(filepath.Separator)) {
		parent := at
		at = filepath.Join(at, name)
		if w.skip != nil {
			if w.skip(at, name) {
				return true
			}
		} else if excludedName(name) || filepath.Base(parent) == ".agents" && name == "worktrees" {
			return true
		}
	}
	return false
}

func (w *folderWatch) stop() {
	w.once.Do(func() {
		close(w.done)
		if w.cmd != nil {
			w.stdin.Close()
			done := make(chan struct{})
			go func() { w.cmd.Wait(); close(done) }()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				w.cmd.Process.Kill()
			}
		}
	})
}
