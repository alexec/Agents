package agentsd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// Git, run as the Swift host runs it (GitWorktrees.git, GitChanges.run): no optional
// locks, a deadline, output trimmed, and git's own words when it refuses.

const gitOutputLimit = 16 << 20

type gitError struct{ message string }

func (e *gitError) Error() string { return e.message }

func gitDeadline(args []string) time.Duration {
	if len(args) >= 2 && args[0] == "worktree" {
		switch args[1] {
		case "add":
			return 120 * time.Second
		case "remove":
			return 300 * time.Second
		}
	}
	if len(args) >= 1 && (args[0] == "fetch" || args[0] == "apply" || args[0] == "add" || args[0] == "bundle" || args[0] == "diff") {
		return 600 * time.Second // a sent repository (#1123) can be large
	}
	return 30 * time.Second
}

// gitLocks keeps the worktree commands of one folder to one at a time (OneAtATime).
var gitLocks sync.Map

// git runs git in dir and is its output, trimmed of newlines.
func git(dir string, args ...string) (string, error) {
	out, err := gitRaw(dir, nil, args...)
	return strings.Trim(string(out), "\n"), err
}

func gitRaw(dir string, stdin []byte, args ...string) ([]byte, error) {
	return gitRawEnv(dir, nil, stdin, args...)
}

// gitRawEnv is gitRaw with more of the environment, such as GIT_INDEX_FILE.
func gitRawEnv(dir string, env []string, stdin []byte, args ...string) ([]byte, error) {
	if len(args) > 0 && args[0] == "worktree" && (len(args) < 2 || args[1] != "list") {
		m, _ := gitLocks.LoadOrStore(filepath.Clean(dir), &sync.Mutex{})
		m.(*sync.Mutex).Lock()
		defer m.(*sync.Mutex).Unlock()
	}
	deadline := gitDeadline(args)
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(append(os.Environ(), "GIT_OPTIONAL_LOCKS=0"), env...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errOut bytes.Buffer
	cmd.Stdout = &limited{w: &out, n: gitOutputLimit}
	cmd.Stderr = &errOut
	err := cmd.Run()
	if errors.Is(err, exec.ErrNotFound) {
		return nil, &gitError{"Git is not installed on this Mac."}
	}
	if ctx.Err() != nil {
		msg := fmt.Sprintf("git %s was stopped after %s with no end in sight, so nothing else waits on it now.",
			strings.Join(args[:min(2, len(args))], " "), deadline)
		if args[0] == "worktree" {
			msg += " If it left a half-made worktree, `git worktree prune` clears it."
		}
		return out.Bytes(), &gitError{msg}
	}
	if err != nil {
		msg := strings.TrimSpace(errOut.String())
		if msg == "" {
			msg = "git " + args[0] + " failed."
		}
		return out.Bytes(), &gitError{msg}
	}
	return out.Bytes(), nil
}

// gitTo runs git in dir with its output written to w, with no limit: a patch to send (#1123).
func gitTo(dir string, w io.Writer, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), gitDeadline(args))
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0")
	var errOut bytes.Buffer
	cmd.Stdout = w
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(errOut.String()); msg != "" {
			return &gitError{msg}
		}
		return &gitError{"git " + args[0] + " failed."}
	}
	return nil
}

type limited struct {
	w *bytes.Buffer
	n int
}

func (l *limited) Write(b []byte) (int, error) {
	if room := l.n - l.w.Len(); room > 0 {
		l.w.Write(b[:min(len(b), room)])
	}
	return len(b), nil
}

type repository struct{ toplevel, commonDir, prefix string }

func (r repository) worktreesFolder() string {
	return filepath.Join(r.toplevel, ".agents", "worktrees")
}

// repositoryOf is GitWorktrees.repository: the checkout dir is in, or false.
func repositoryOf(dir string) (repository, bool) {
	out, err := git(dir, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--show-prefix")
	if err != nil {
		return repository{}, false
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		return repository{}, false
	}
	r := repository{toplevel: lines[0], commonDir: lines[1]}
	if len(lines) > 2 {
		r.prefix = strings.TrimSuffix(lines[2], "/")
	}
	return r, true
}

type worktreeEntry struct {
	root, head, branch       string
	detached, bare, prunable bool
}

// worktreeList is `git worktree list --porcelain`, bare entries left out.
func worktreeList(dir string) ([]worktreeEntry, error) {
	out, err := git(dir, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	var all []worktreeEntry
	var cur *worktreeEntry
	for _, l := range strings.Split(out+"\n", "\n") {
		k, v, _ := strings.Cut(l, " ")
		switch k {
		case "worktree":
			all = append(all, worktreeEntry{root: v})
			cur = &all[len(all)-1]
		case "HEAD":
			cur.head = v
		case "branch":
			cur.branch = strings.TrimPrefix(v, "refs/heads/")
		case "detached":
			cur.detached = true
		case "bare":
			cur.bare = true
		case "prunable":
			cur.prunable = true
		}
	}
	var out2 []worktreeEntry
	for _, e := range all {
		if !e.bare {
			out2 = append(out2, e)
		}
	}
	return out2, nil
}

// canonical is a folder's path as folders compare them, for one that may not be there:
// the links of the deepest part that is there resolved.
func canonical(path string) string {
	path = filepath.Clean(path)
	rest := ""
	for p := path; ; p = filepath.Dir(p) {
		if r, err := store.Resolve(p); err == nil {
			return filepath.Join(r, rest)
		}
		if p == "/" || p == "." {
			return path
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
}
