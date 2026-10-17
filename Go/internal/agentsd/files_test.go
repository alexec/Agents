package agentsd

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

func anAgentIn(t *testing.T, d *Daemon, folder string) wire.UUID {
	t.Helper()
	a := wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: store.FolderURL(folder), State: wire.AgentStateFinished,
		EndedReason: reason(wire.EndedReasonEndTurn), AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{}}
	if err := d.Store.Save(a); err != nil {
		t.Fatal(err)
	}
	return a.ID
}

func (c *conn) callErr(t *testing.T, id int, method string, params any) string {
	t.Helper()
	p, _ := json.Marshal(params)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	c.in <- string(b)
	for line := range c.out {
		var m message
		json.Unmarshal([]byte(line), &m)
		if string(m.ID) == string(mustJSON(id)) {
			if m.Error == nil {
				t.Fatalf("%s: no error", method)
			}
			return m.Error.Error()
		}
	}
	return ""
}

func TestFilesAreKeptToTheAgentsFolder(t *testing.T) {
	d, c := start(t, t.TempDir())
	work, _ := filepath.EvalSymlinks(t.TempDir())
	os.Mkdir(filepath.Join(work, "sub"), 0o755)
	os.WriteFile(filepath.Join(work, "README.md"), []byte("# hello\n"), 0o644)
	os.WriteFile(filepath.Join(work, "pic.png"), []byte{0x89, 'P', 'N', 'G'}, 0o644)
	outside := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(outside, []byte("no"), 0o644)
	os.Symlink(outside, filepath.Join(work, "link"))
	id := anAgentIn(t, d, work)

	var l wire.DirectoryListing
	json.Unmarshal(c.call(t, 1, "files/list", map[string]any{"agentID": id, "folder": work}), &l)
	var names []string
	for _, e := range l.Entries {
		names = append(names, e.Name)
	}
	if strings.Join(names, " ") != "sub link pic.png README.md" || !l.Entries[0].IsDirectory {
		t.Fatalf("entries %v", names)
	}
	var r wire.FileReading
	json.Unmarshal(c.call(t, 2, "files/read", map[string]any{"agentID": id, "path": filepath.Join(work, "README.md")}), &r)
	if r.Kind != "text" || *r.Text != "# hello\n" {
		t.Fatalf("%+v", r)
	}
	json.Unmarshal(c.call(t, 3, "files/read", map[string]any{"agentID": id, "path": filepath.Join(work, "README.md"), "knownStamp": r.Stamp}), &r)
	if r.Kind != "unchanged" {
		t.Fatalf("kind %s for a file read before", r.Kind)
	}
	json.Unmarshal(c.call(t, 4, "files/read", map[string]any{"agentID": id, "path": filepath.Join(work, "pic.png")}), &r)
	if r.Kind != "image" || len(r.Bytes) != 4 {
		t.Fatalf("image %+v", r)
	}
	if e := c.callErr(t, 5, "files/read", map[string]any{"agentID": id, "path": filepath.Join(work, "link")}); !strings.Contains(e, "outside") {
		t.Fatalf("a link out of the folder: %s", e)
	}
	if e := c.callErr(t, 6, "files/read", map[string]any{"agentID": id, "path": "/etc/passwd"}); !strings.Contains(e, "-32602") {
		t.Fatalf("/etc/passwd: %s", e)
	}
	if e := c.callErr(t, 7, "files/read", map[string]any{"agentID": id, "path": filepath.Join(work, "gone")}); !strings.Contains(e, "-32032") {
		t.Fatalf("gone: %s", e)
	}
}

// A link is listed under its own path, not its target's (#1265); the folder's own links are resolved.
func TestBrowseListsALinkUnderItsOwnPath(t *testing.T) {
	_, c := start(t, t.TempDir())
	real, _ := filepath.EvalSymlinks(t.TempDir())
	os.WriteFile(filepath.Join(real, "AGENTS.md"), []byte("# hi\n"), 0o644)
	os.Mkdir(filepath.Join(real, "docs"), 0o755)
	os.Symlink(filepath.Join(real, "AGENTS.md"), filepath.Join(real, "CLAUDE.md"))
	os.Symlink(filepath.Join(real, "docs"), filepath.Join(real, "notes"))
	via := filepath.Join(t.TempDir(), "via")
	os.Symlink(real, via)

	var l wire.DirectoryListing
	json.Unmarshal(c.call(t, 1, "files/browse", map[string]any{"path": via}), &l)
	if l.URL != store.FolderURL(real)+"/" {
		t.Fatalf("folder %s", l.URL)
	}
	got := map[string]string{}
	for _, e := range l.Entries {
		got[e.Name] = string(e.URL)
	}
	want := map[string]string{
		"docs": string(store.PathURL(filepath.Join(real, "docs"))) + "/", "notes": string(store.PathURL(filepath.Join(real, "notes"))) + "/",
		"AGENTS.md": string(store.PathURL(filepath.Join(real, "AGENTS.md"))), "CLAUDE.md": string(store.PathURL(filepath.Join(real, "CLAUDE.md"))),
	}
	for n, u := range want {
		if got[n] != u {
			t.Fatalf("%s: %s, want %s", n, got[n], u)
		}
	}
	if len(l.Entries) != 4 || !l.Entries[0].IsDirectory || !l.Entries[1].IsDirectory {
		t.Fatalf("entries %+v", l.Entries)
	}
}

func TestAWatchSaysWhichFoldersChanged(t *testing.T) {
	prepareWatch(t)
	d, c := start(t, t.TempDir())
	work, _ := filepath.EvalSymlinks(t.TempDir())
	os.MkdirAll(filepath.Join(work, "src"), 0o755)
	os.MkdirAll(filepath.Join(work, "node_modules", "x"), 0o755)
	id := anAgentIn(t, d, work)
	c.call(t, 1, "files/watch", map[string]any{"agentID": id, "folder": work})
	os.WriteFile(filepath.Join(work, "node_modules", "x", "ignored.js"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(work, "src", "main.go"), []byte("package main"), 0o644)
	c.until(t, "files/changed for src", func(method string, p json.RawMessage) bool {
		var n wire.FilesChangedNotification
		if method != "files/changed" || json.Unmarshal(p, &n) != nil {
			return false
		}
		for _, f := range n.Folders {
			if strings.Contains(f, "node_modules") {
				t.Fatalf("a build folder was heard: %v", n.Folders)
			}
		}
		return n.AgentID == id && len(n.Folders) == 1 && n.Folders[0] == filepath.Join(work, "src")
	})
	c.call(t, 2, "files/unwatch", map[string]any{"agentID": id, "folder": work})
	d.mu.Lock()
	left := len(d.watches)
	d.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d watches left after the last unwatch", left)
	}
}

func TestATerminal(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	work, _ := filepath.EvalSymlinks(t.TempDir())
	id := anAgentIn(t, d, work)
	c.call(t, 1, "shell/attach", map[string]any{"agentID": id, "shell": 0, "rows": 24, "cols": 80})
	in := base64.StdEncoding.EncodeToString([]byte("echo hello-$((40+2)) && pwd\n"))
	c.call(t, 2, "shell/input", map[string]any{"agentID": id, "shell": 0, "bytes": in})
	var seen strings.Builder
	c.until(t, "the shell's output", func(method string, p json.RawMessage) bool {
		var o struct {
			Bytes []byte `json:"bytes"`
		}
		if method == "shell/output" && json.Unmarshal(p, &o) == nil {
			seen.Write(o.Bytes)
		}
		return strings.Contains(seen.String(), "hello-42") && strings.Contains(seen.String(), work)
	})
	c.call(t, 3, "shell/close", map[string]any{"agentID": id, "shell": 0})
	c.until(t, "released", func(method string, p json.RawMessage) bool {
		return method == "shell/stateChanged" && strings.Contains(string(p), "released")
	})
}
