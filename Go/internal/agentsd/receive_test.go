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

// Send to ‹host›… (#1123): the first send makes the copy with the branches, the origin and
// the uncommitted changes; a second carries only what the host lacks and replaces the
// first send's changes; the host's own changes or commits stop a send with nothing changed.

func sendGit(t *testing.T, dir string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// macSend is what the window does: has this Mac's host pack the branches, less what the
// receiving host has, then reads each file in parts and uploads it to the receiving host.
func macSend(t *testing.T, c *conn, src string, have []string, changes bool, branches ...string) (map[string]any, int64) {
	t.Helper()
	var pack wire.SendPack
	json.Unmarshal(c.call(t, 900, "folders/sendPack", map[string]any{"folder": store.FolderURL(src), "branches": branches,
		"leavingOut": have, "includeChanges": changes}), &pack)
	relay := func(f *wire.SendFile) *wire.UUID {
		if f == nil {
			return nil
		}
		u := store.NewUUID()
		var offset int64
		for {
			var part wire.SendRead
			json.Unmarshal(c.call(t, 901, "folders/sendRead", map[string]any{"id": f.ID, "offset": offset}), &part)
			c.call(t, 902, "folders/receiveUpload", map[string]any{"upload": u, "offset": offset, "data": part.Data})
			offset += int64(len(part.Data))
			if part.End {
				break
			}
		}
		if offset != f.Size {
			t.Fatalf("relayed %d of %d", offset, f.Size)
		}
		return &u
	}
	var size int64
	if pack.Bundle != nil {
		size = pack.Bundle.Size
	}
	return map[string]any{"bundle": relay(pack.Bundle), "patch": relay(pack.Patch), "branches": pack.Commits}, size
}

func TestSendToHost(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	sendGit(t, src, nil, "remote", "add", "origin", "git@github.com:example/hello.git")
	os.WriteFile(filepath.Join(src, ".gitignore"), []byte("build/\n"), 0o644)
	os.WriteFile(filepath.Join(src, "README.md"), []byte("hello\n"), 0o644)
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "readme")
	sendGit(t, src, nil, "branch", "other")
	os.WriteFile(filepath.Join(src, "README.md"), []byte("hello, changed\n"), 0o644)
	os.WriteFile(filepath.Join(src, "new.txt"), []byte("new\n"), 0o644)
	os.MkdirAll(filepath.Join(src, "build"), 0o755)
	os.WriteFile(filepath.Join(src, "build", "out"), []byte("x"), 0o644)
	head := sendGit(t, src, nil, "rev-parse", "HEAD")

	dest := filepath.Join(canonical(t.TempDir()), "hello")
	var state wire.ReceiveState
	json.Unmarshal(c.call(t, 1, "folders/receiveState", map[string]any{"folder": dest}), &state)
	if state.Exists || state.Repository || len(state.Heads) != 0 {
		t.Fatalf("%+v", state)
	}
	var facts wire.SendFacts
	json.Unmarshal(c.call(t, 2, "folders/sendFacts", map[string]any{"folder": store.FolderURL(src)}), &facts)
	if strings.Join(facts.Branches, ",") != "main,other" || *facts.Current != "main" || !facts.HasChanges ||
		*facts.Origin != "git@github.com:example/hello.git" {
		t.Fatalf("%+v", facts)
	}
	indexBefore := sendGit(t, src, nil, "status", "--porcelain")
	send := func(have []string, changes bool, branches ...string) map[string]any {
		m, _ := macSend(t, c, src, have, changes, branches...)
		m["folder"], m["checkout"], m["origin"] = dest, "main", "git@github.com:example/hello.git"
		return m
	}
	var summary wire.FolderSummary
	json.Unmarshal(c.call(t, 10, "folders/receive", send(nil, true, "main", "other")), &summary)
	if got := sendGit(t, src, nil, "status", "--porcelain"); got != indexBefore {
		t.Fatalf("the Mac's index changed: %q", got)
	}
	if entries, _ := os.ReadDir(d.outgoingFolder()); len(entries) != 0 {
		t.Fatalf("packed files left: %d", len(entries))
	}
	if store.FolderPath(summary.Folder.Folder) != dest {
		t.Fatalf("%+v", summary.Folder)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "README.md")); string(b) != "hello, changed\n" {
		t.Fatalf("readme %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "new.txt")); string(b) != "new\n" {
		t.Fatalf("new %q", b)
	}
	if _, err := os.Stat(filepath.Join(dest, "build")); err == nil {
		t.Fatal("an ignored folder went")
	}
	if got := sendGit(t, dest, nil, "remote", "get-url", "origin"); got != "git@github.com:example/hello.git" {
		t.Fatal(got)
	}
	if got := sendGit(t, dest, nil, "rev-parse", "other"); got != head {
		t.Fatal(got)
	}
	if got := sendGit(t, dest, nil, "for-each-ref", "refs/agents-send"); got != "" {
		t.Fatal(got)
	}
	if entries, _ := os.ReadDir(d.incomingFolder()); len(entries) != 0 {
		t.Fatalf("uploads left: %d", len(entries))
	}

	// The first send's changes are not the host's own: a second send replaces them.
	json.Unmarshal(c.call(t, 20, "folders/receiveState", map[string]any{"folder": dest}), &state)
	if !state.Repository || state.OwnChanges || len(state.Heads) != 2 {
		t.Fatalf("%+v", state)
	}
	sendGit(t, src, nil, "add", "README.md")
	sendGit(t, src, nil, "commit", "-q", "-m", "changed")
	head2 := sendGit(t, src, nil, "rev-parse", "HEAD")
	_, part := macSend(t, c, src, state.Heads, false, "main")
	_, full := macSend(t, c, src, nil, false, "main")
	if part == 0 || part >= full {
		t.Fatalf("the second bundle carries all: %d >= %d", part, full)
	}
	c.call(t, 30, "folders/receive", send(state.Heads, true, "main"))
	if got := sendGit(t, dest, nil, "rev-parse", "HEAD"); got != head2 {
		t.Fatal(got)
	}
	if got := sendGit(t, dest, nil, "status", "--porcelain"); got != "?? new.txt" {
		t.Fatalf("status %q", got)
	}

	// The host's own change stops the next send, with nothing changed.
	os.WriteFile(filepath.Join(dest, "host.txt"), []byte("mine\n"), 0o644)
	json.Unmarshal(c.call(t, 40, "folders/receiveState", map[string]any{"folder": dest}), &state)
	if !state.OwnChanges {
		t.Fatal("the host's change is not its own")
	}
	if msg := c.callErr(t, 50, "folders/receive", send(state.Heads, true, "main")); !strings.Contains(msg, "changes of its own") {
		t.Fatal(msg)
	}
	if _, err := os.Stat(filepath.Join(dest, "host.txt")); err != nil {
		t.Fatal("the host's change was lost")
	}
	os.Remove(filepath.Join(dest, "host.txt"))

	// A commit of the host's own on a sent branch stops it too.
	sendGit(t, dest, nil, "-c", "user.email=h@example.com", "-c", "user.name=H", "commit", "-q", "--allow-empty", "-m", "host")
	hostHead := sendGit(t, dest, nil, "rev-parse", "HEAD")
	os.Remove(filepath.Join(dest, "new.txt"))
	if msg := c.callErr(t, 60, "folders/receive", map[string]any{"folder": dest,
		"branches": []map[string]any{{"name": "main", "commit": head}}, "checkout": "main"}); !strings.Contains(msg, "commits of its own") {
		t.Fatal(msg)
	}
	if got := sendGit(t, dest, nil, "rev-parse", "HEAD"); got != hostHead {
		t.Fatal(got)
	}
}

func TestSendToAFolderInTheWay(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dest := canonical(t.TempDir())
	os.WriteFile(filepath.Join(dest, "x"), []byte("x"), 0o644)
	msg := c.callErr(t, 1, "folders/receive", map[string]any{"folder": dest,
		"branches": []map[string]any{{"name": "main", "commit": strings.Repeat("a", 40)}}, "checkout": "main"})
	if !strings.Contains(msg, "not a Git repository") {
		t.Fatal(msg)
	}
	if msg := c.callErr(t, 2, "folders/receiveUpload", map[string]any{"upload": store.NewUUID(), "offset": 5, "data": []byte("x")}); !strings.Contains(msg, "missing") {
		t.Fatal(msg)
	}
	if msg := c.callErr(t, 3, "folders/receive", map[string]any{"folder": "relative",
		"branches": []map[string]any{{"name": "main", "commit": strings.Repeat("a", 40)}}, "checkout": "main"}); !strings.Contains(msg, "starts with") {
		t.Fatal(msg)
	}
	// A new folder whose commits never arrived is not left behind.
	gone := filepath.Join(dest, "new")
	c.callErr(t, 4, "folders/receive", map[string]any{"folder": gone,
		"branches": []map[string]any{{"name": "main", "commit": strings.Repeat("a", 40)}}, "checkout": "main"})
	if _, err := os.Stat(gone); err == nil {
		t.Fatal("left behind")
	}
}

// Bring back from ‹host›… (#1473): the host's commits come back to the Mac's branches,
// forward only, also where a branch is checked out; the host's uncommitted changes come
// back only when asked; the Mac's own changes or commits stop it with nothing changed.
func TestBringBackFromHost(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	os.WriteFile(filepath.Join(src, "README.md"), []byte("hello\n"), 0o644)
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "readme")
	dest := filepath.Join(canonical(t.TempDir()), "hello")
	m, _ := macSend(t, c, src, nil, false, "main")
	m["folder"], m["checkout"] = dest, "main"
	c.call(t, 1, "folders/receive", m)

	// Work on the host: a commit on main, a new branch and a change not committed.
	host := []string{"GIT_AUTHOR_NAME=H", "GIT_AUTHOR_EMAIL=h@example.com", "GIT_COMMITTER_NAME=H", "GIT_COMMITTER_EMAIL=h@example.com"}
	os.WriteFile(filepath.Join(dest, "README.md"), []byte("hello from the host\n"), 0o644)
	sendGit(t, dest, host, "commit", "-q", "-am", "host work")
	sendGit(t, dest, host, "branch", "other")
	hostHead := sendGit(t, dest, nil, "rev-parse", "HEAD")
	os.WriteFile(filepath.Join(dest, "wip.txt"), []byte("not committed\n"), 0o644)

	macHeads := func() []string {
		var s wire.ReceiveState
		json.Unmarshal(c.call(t, 2, "folders/receiveState", map[string]any{"folder": src}), &s)
		return s.Heads
	}
	back := func(changes bool, branches ...string) map[string]any {
		m, _ := macSend(t, c, dest, macHeads(), changes, branches...)
		m["folder"] = store.FolderURL(src)
		if changes {
			m["patchOn"] = "main"
		}
		return m
	}
	var done wire.BringBack
	json.Unmarshal(c.call(t, 10, "folders/bringBack", back(false, "main", "other")), &done)
	if strings.Join(done.Moved, ",") != "main,other" || done.Applied {
		t.Fatalf("%+v", done)
	}
	if got := sendGit(t, src, nil, "rev-parse", "main", "other"); got != hostHead+"\n"+hostHead {
		t.Fatal(got)
	}
	if b, _ := os.ReadFile(filepath.Join(src, "README.md")); string(b) != "hello from the host\n" {
		t.Fatalf("readme %q", b)
	}
	if got := sendGit(t, src, nil, "status", "--porcelain"); got != "" {
		t.Fatalf("status %q", got)
	}
	if got := sendGit(t, src, nil, "for-each-ref", "refs/agents-back"); got != "" {
		t.Fatal(got)
	}

	// Again, with the uncommitted changes: nothing moves, the patch applies.
	json.Unmarshal(c.call(t, 20, "folders/bringBack", back(true, "main")), &done)
	if len(done.Moved) != 0 || !done.Applied {
		t.Fatalf("%+v", done)
	}
	if b, _ := os.ReadFile(filepath.Join(src, "wip.txt")); string(b) != "not committed\n" {
		t.Fatalf("wip %q", b)
	}

	// The Mac's own change, where main is checked out, stops the next one.
	sendGit(t, dest, host, "commit", "-q", "--allow-empty", "-m", "more host work")
	macHead := sendGit(t, src, nil, "rev-parse", "HEAD")
	if msg := c.callErr(t, 30, "folders/bringBack", back(false, "main")); !strings.Contains(msg, "uncommitted changes") {
		t.Fatal(msg)
	}
	if got := sendGit(t, src, nil, "rev-parse", "HEAD"); got != macHead {
		t.Fatal(got)
	}
	if _, err := os.Stat(filepath.Join(src, "wip.txt")); err != nil {
		t.Fatal("the Mac's change was lost")
	}

	// A commit of the Mac's own on main stops it too.
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "mac work")
	macHead = sendGit(t, src, nil, "rev-parse", "HEAD")
	if msg := c.callErr(t, 40, "folders/bringBack", back(false, "main")); !strings.Contains(msg, "commits of its own") {
		t.Fatal(msg)
	}
	if got := sendGit(t, src, nil, "rev-parse", "HEAD"); got != macHead {
		t.Fatal(got)
	}
	if entries, _ := os.ReadDir(d.incomingFolder()); len(entries) != 0 {
		t.Fatalf("uploads left: %d", len(entries))
	}
}

// An abandoned send (#1531): what it left in Outgoing and Incoming goes once nothing has
// touched it for transferLimit, at the next send; a send that refuses removes its uploads.
func TestAbandonedSendIsSwept(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	pack := func(id int) {
		c.call(t, id, "folders/sendPack", map[string]any{"folder": store.FolderURL(src), "branches": []string{"main"}})
	}
	upload := func(id int) {
		c.call(t, id, "folders/receiveUpload", map[string]any{"upload": store.NewUUID(), "offset": 0, "data": []byte("part")})
	}
	count := func(folder string) int {
		entries, _ := os.ReadDir(folder)
		return len(entries)
	}
	age := func(folder string, by time.Duration) {
		entries, _ := os.ReadDir(folder)
		for _, e := range entries {
			then := time.Now().Add(-by)
			os.Chtimes(filepath.Join(folder, e.Name()), then, then)
		}
	}

	// Started and abandoned; within the limit, a second send leaves the first alone.
	pack(1)
	upload(2)
	age(d.outgoingFolder(), transferLimit/2)
	age(d.incomingFolder(), transferLimit/2)
	pack(3)
	upload(4)
	if count(d.outgoingFolder()) != 2 || count(d.incomingFolder()) != 2 {
		t.Fatalf("outgoing %d, incoming %d", count(d.outgoingFolder()), count(d.incomingFolder()))
	}
	// Past the limit, the next send removes what nothing touched.
	age(d.outgoingFolder(), transferLimit+time.Minute)
	age(d.incomingFolder(), transferLimit+time.Minute)
	pack(5)
	upload(6)
	if count(d.outgoingFolder()) != 1 || count(d.incomingFolder()) != 1 {
		t.Fatalf("outgoing %d, incoming %d", count(d.outgoingFolder()), count(d.incomingFolder()))
	}

	// A part read keeps a slow send's file.
	slow := store.NewUUID()
	os.WriteFile(filepath.Join(d.outgoingFolder(), string(slow)), make([]byte, sendPartSize+1), 0o600)
	age(d.outgoingFolder(), transferLimit+time.Minute)
	c.call(t, 7, "folders/sendRead", map[string]any{"id": slow, "offset": 0})
	pack(8)
	if _, err := os.Stat(filepath.Join(d.outgoingFolder(), string(slow))); err != nil {
		t.Fatal("a send that goes on lost its file")
	}

	// A receive or a bring back that refuses at its first check removes its uploads.
	for i, refused := range []map[string]any{
		{"method": "folders/receive", "folder": "relative", "checkout": "main"},
		{"method": "folders/bringBack", "folder": store.FolderURL(t.TempDir())},
	} {
		u := store.NewUUID()
		c.call(t, 20+i*2, "folders/receiveUpload", map[string]any{"upload": u, "offset": 0, "data": []byte("x")})
		params := map[string]any{"bundle": u, "branches": []map[string]any{{"name": "main", "commit": strings.Repeat("a", 40)}}}
		for k, v := range refused {
			if k != "method" {
				params[k] = v
			}
		}
		c.callErr(t, 21+i*2, refused["method"].(string), params)
		if _, err := os.Stat(filepath.Join(d.incomingFolder(), string(u))); err == nil {
			t.Fatalf("%s left its upload", refused["method"])
		}
	}
}
