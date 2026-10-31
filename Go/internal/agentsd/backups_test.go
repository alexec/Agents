package agentsd

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// writeFile writes test bytes into an agent's folder or the root.
func writeFile(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func backupsIn(t *testing.T, c *conn, n int) wire.BackupState {
	t.Helper()
	var s wire.BackupState
	if err := json.Unmarshal(c.call(t, n, "backups/state", map[string]any{}), &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestBackupDefaults(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	s := backupsIn(t, c, 1)
	if s.Settings.Every != wire.BackupEveryDaily || s.Settings.Keep != backupKeepDefault || s.Settings.Folder != nil {
		t.Fatalf("defaults %+v", s.Settings)
	}
	if s.Folder != filepath.Join(root, "backups") || len(s.Backups) != 0 || s.Making {
		t.Fatalf("state %+v", s)
	}
	// A file from a later build, with a value this one can't read, keeps backups on.
	writeFile(t, d.backupSettingsPath(), `{"every":"hourly","keep":99,"folder":"relative"}`)
	if s := d.backupSettings(); s.Every != wire.BackupEveryDaily || s.Keep != backupKeepDefault || s.Folder != nil {
		t.Fatalf("unreadable values %+v", s)
	}
	for _, bad := range []map[string]any{{"every": "daily", "keep": 0}, {"every": "daily", "keep": 11},
		{"every": "daily", "keep": 3, "folder": "not/full"}} {
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 9, "method": "backups/configure", "params": bad})
		c.in <- string(b)
		var m message
		for m.ID == nil || string(m.ID) != "9" {
			json.Unmarshal([]byte(<-c.out), &m)
		}
		if m.Error == nil {
			t.Fatalf("%v was taken", bad)
		}
	}
}

// One machine backs up; a second, reading the same folder, restores it: the agents come
// back archived, with their transcripts, and are never run there. Nothing is overwritten.
func TestBackupAndRestoreOnAnotherMachine(t *testing.T) {
	atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	shared := t.TempDir()
	rootA, rootB := t.TempDir(), t.TempDir()
	a, ca := start(t, rootA)
	dir := folder(t, ca, 1)
	ca.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})

	finished := seeded(t, a, dir, nil)
	byUser := wire.AgentArchivedReasonByUser
	archived := seeded(t, a, dir, func(x *wire.Agent) { x.State, x.ArchivedReason = wire.AgentStateArchived, &byUser })
	// The last line is being written: it is left out, not torn.
	writeFile(t, a.Store.Loc.Transcript(string(finished.ID)), "{\"one\":1}\n{\"two\":2}\n{\"thr")
	writeFile(t, filepath.Join(a.Store.Loc.Agent(string(finished.ID)), "said.json"), `{"said":[]}`)
	// Not a file a backup carries.
	writeFile(t, filepath.Join(a.Store.Loc.Agent(string(finished.ID)), "secret.txt"), "no")
	writeFile(t, filepath.Join(rootA, "usage-history.json"), `{"usage":"A"}`)
	writeFile(t, filepath.Join(rootA, "time-history.json"), `{"time":"A"}`)

	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	if made.Agents != 2 || !made.ThisMachine || made.RootID != a.Store.RootID || made.Bytes == 0 {
		t.Fatalf("made %+v", made)
	}
	names := tarNames(t, filepath.Join(shared, a.Store.RootID, "20261020T090000Z.tar.gz"))
	if names[0] != "manifest.json" || slices.Contains(names, "agents/"+string(finished.ID)+"/secret.txt") ||
		!slices.Contains(names, "usage-history.json") {
		t.Fatalf("archive holds %v", names)
	}

	// Machine B already has an agent of its own and its own usage.
	b, cb := start(t, rootB)
	ownDir := folder(t, cb, 1)
	own := seeded(t, b, ownDir, nil)
	writeFile(t, filepath.Join(rootB, "usage-history.json"), `{"usage":"B"}`)
	cb.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": shared})
	list := backupsIn(t, cb, 3).Backups
	if len(list) != 1 || list[0].ThisMachine || list[0].ID != made.ID {
		t.Fatalf("B sees %+v", list)
	}

	var res wire.BackupRestoreResult
	json.Unmarshal(cb.call(t, 4, "backups/restore", map[string]any{"id": made.ID}), &res)
	if res.Restored != 2 || res.Skipped != 0 {
		t.Fatalf("restored %+v", res)
	}
	for _, id := range []wire.UUID{finished.ID, archived.ID} {
		got := b.Store.Agent(id)
		if got == nil || got.State != wire.AgentStateArchived || got.ArchivedAt == nil || got.MadeInRoot == nil ||
			*got.MadeInRoot != a.Store.RootID {
			t.Fatalf("%s came back as %+v", id, got)
		}
		if err := b.refuseToRun(got); err == nil {
			t.Fatalf("%s may run on B", id)
		}
	}
	if tr, _ := os.ReadFile(b.Store.Loc.Transcript(string(finished.ID))); string(tr) != "{\"one\":1}\n{\"two\":2}\n" {
		t.Fatalf("transcript %q", tr)
	}
	if _, err := os.Stat(filepath.Join(b.Store.Loc.Agent(string(finished.ID)), "secret.txt")); !os.IsNotExist(err) {
		t.Fatalf("secret.txt came back: %v", err)
	}
	if u, _ := os.ReadFile(filepath.Join(rootB, "usage-history.json")); string(u) != `{"usage":"B"}` {
		t.Fatalf("B's usage overwritten: %s", u)
	}
	if tm, _ := os.ReadFile(filepath.Join(rootB, "time-history.json")); string(tm) != `{"time":"A"}` {
		t.Fatalf("time history %s", tm)
	}
	if b.Store.Agent(own.ID) == nil {
		t.Fatal("B's own agent went")
	}

	// Again: everything is there already, so nothing is written.
	json.Unmarshal(cb.call(t, 5, "backups/restore", map[string]any{"id": made.ID}), &res)
	if res.Restored != 0 || res.Skipped != 2 {
		t.Fatalf("second restore %+v", res)
	}
	// A restored agent survives B's restart, still never run.
	b.Shutdown()
	b2, _ := start(t, rootB)
	if got := b2.Store.Agent(finished.ID); got == nil || got.State != wire.AgentStateArchived {
		t.Fatalf("after restart %+v", got)
	}
}

// A record in another machine's backup is stamped with that machine's root, whatever it
// says it was made under, and brings no MCP servers. A backup whose manifest names this
// root, but that is not in this machine's folder, is never run here either.
func TestARestoreFromAnotherMachineNeverRunsHere(t *testing.T) {
	atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	shared := t.TempDir()
	a, ca := start(t, t.TempDir())
	b, cb := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	ca.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	bRoot := b.Store.RootID
	agent := seeded(t, a, dir, func(x *wire.Agent) {
		x.MadeInRoot = &bRoot
		x.McpServers = []wire.MCPServer{{Name: "tool", Transport: wire.MCPServerTransport{
			Stdio: &wire.MCPServerTransportStdio{Command: "/bin/echo", Args: []string{}, Env: map[string]string{}}}}}
	})
	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}

	cb.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	var res wire.BackupRestoreResult
	json.Unmarshal(cb.call(t, 2, "backups/restore", map[string]any{"id": made.ID}), &res)
	got := b.Store.Agent(agent.ID)
	if res.Restored != 1 || got == nil || got.MadeInRoot == nil || *got.MadeInRoot != a.Store.RootID || len(got.McpServers) != 0 {
		t.Fatalf("restored %+v as %+v", res, got)
	}
	if err := b.refuseToRun(got); err == nil {
		t.Fatal("it may run on B")
	}

	// The same backup, its manifest now naming C's root, restored on C.
	c, cc := start(t, t.TempDir())
	manifest := filepath.Join(shared, a.Store.RootID, "20261020T090000Z.json")
	raw, _ := os.ReadFile(manifest)
	writeFile(t, manifest, strings.Replace(string(raw), a.Store.RootID, c.Store.RootID, 1))
	cc.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	json.Unmarshal(cc.call(t, 2, "backups/restore", map[string]any{"id": made.ID}), &res)
	got = c.Store.Agent(agent.ID)
	if res.Restored != 1 || got == nil || got.MadeInRoot == nil || *got.MadeInRoot != restoredElsewhere {
		t.Fatalf("on C %+v as %+v", res, got)
	}
	if err := c.refuseToRun(got); err == nil {
		t.Fatal("it may run on C")
	}
}

// A v0.11.1 backup names a worktree's folder "project", from before #2617: the restored
// agent gets that folder, not a blank one (#2709).
func TestARestoreOfAnOlderBackupKeepsTheWorktreesFolder(t *testing.T) {
	atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	shared := t.TempDir()
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	ca.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	repo := "file:///Users/old/repo/"
	agent := seeded(t, a, dir, func(x *wire.Agent) {
		// A worktree under a root that is not on the new machine, so git can't say.
		x.Worktree = &wire.AgentWorktree{Name: "w", Root: "file:///Users/old/elsewhere/w/", Folder: wire.URL(repo)}
	})
	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	rewriteArchive(t, filepath.Join(shared, a.Store.RootID, "20261020T090000Z.tar.gz"), func(name string, data []byte) []byte {
		if !strings.HasSuffix(name, "/agent.json") {
			return data
		}
		var record map[string]any
		if err := json.Unmarshal(data, &record); err != nil {
			t.Fatal(err)
		}
		w := record["worktree"].(map[string]any)
		w["project"] = w["folder"]
		delete(w, "folder")
		out, _ := json.Marshal(record)
		return out
	})

	b, cb := start(t, t.TempDir())
	cb.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	var res wire.BackupRestoreResult
	json.Unmarshal(cb.call(t, 2, "backups/restore", map[string]any{"id": made.ID}), &res)
	got := b.Store.Agent(agent.ID)
	if res.Restored != 1 || got == nil || got.Worktree == nil || got.Worktree.Folder != wire.URL(repo) {
		t.Fatalf("restored %+v as %+v", res, got)
	}
	var saved wire.Agent
	raw, _ := os.ReadFile(b.Store.Loc.Record(string(agent.ID)))
	if diskjson.Unmarshal(raw, &saved) != nil || saved.Worktree == nil || saved.Worktree.Folder != wire.URL(repo) {
		t.Fatalf("saved %s", raw)
	}
}

// rewriteArchive passes each file of a backup archive through edit, in place.
func rewriteArchive(t *testing.T, path string, edit func(name string, data []byte) []byte) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	type entry struct {
		h    *tar.Header
		data []byte
	}
	var entries []entry
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		entries = append(entries, entry{h, edit(h.Name, data)})
	}
	f.Close()
	out, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := gzip.NewWriter(out)
	tw := tar.NewWriter(zw)
	for _, e := range entries {
		e.h.Size = int64(len(e.data))
		if err := tw.WriteHeader(e.h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(e.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	zw.Close()
	if err := out.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestBackupsKeepTheNewestOfThisMachine(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	shared := t.TempDir()
	d, c := start(t, t.TempDir())
	c.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	// Another machine's backup in the same folder is never pruned.
	other := filepath.Join(shared, "OTHER-ROOT")
	writeFile(t, filepath.Join(other, "20200101T000000Z.tar.gz"), "x")
	writeFile(t, filepath.Join(other, "20200101T000000Z.json"), `{"format":1,"rootID":"OTHER-ROOT","machine":"Other","madeAt":1,"agents":0}`)
	for range 4 {
		if _, err := d.makeBackup(); err != nil {
			t.Fatal(err)
		}
		clock.add(time.Hour)
	}
	s := backupsIn(t, c, 2)
	if len(s.Backups) != 3 || s.Backups[0].ID != d.Store.RootID+"/20261020T120000Z" ||
		s.Backups[1].ID != d.Store.RootID+"/20261020T110000Z" || s.Backups[2].RootID != "OTHER-ROOT" {
		t.Fatalf("kept %+v", s.Backups)
	}
	// Keeping fewer prunes now.
	c.call(t, 3, "backups/configure", map[string]any{"every": "off", "keep": 1, "folder": shared})
	if s := backupsIn(t, c, 4); len(s.Backups) != 2 {
		t.Fatalf("after keep 1 %+v", s.Backups)
	}
}

func TestBackupIfDueFollowsTheSchedule(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	d, c := start(t, t.TempDir())
	c.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 3})
	d.backupIfDue()
	waitBackups(t, d, 0)
	c.call(t, 2, "backups/configure", map[string]any{"every": "daily", "keep": 3})
	d.backupIfDue()
	waitBackups(t, d, 1)
	clock.add(23 * time.Hour)
	d.backupIfDue()
	waitBackups(t, d, 1)
	clock.add(2 * time.Hour)
	d.backupIfDue()
	waitBackups(t, d, 2)
}

func TestRestoreRefusesAnIDOutsideTheFolder(t *testing.T) {
	_, c := start(t, t.TempDir())
	for i, id := range []string{"../x", "a/../../b", "a", "/etc/passwd", ".hidden/x"} {
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 10 + i, "method": "backups/restore", "params": map[string]any{"id": id}})
		c.in <- string(b)
		var m message
		for m.ID == nil || string(m.ID) != string(mustJSON(10+i)) {
			json.Unmarshal([]byte(<-c.out), &m)
		}
		if m.Error == nil {
			t.Fatalf("%q was taken", id)
		}
	}
}

// waitBackups waits for a backup being made to end, then counts this machine's.
func waitBackups(t *testing.T, d *Daemon, want int) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		d.backupMu.Lock()
		making := d.backupMaking
		d.backupMu.Unlock()
		if !making {
			break
		}
	}
	if n := len(d.folderBackups()); n != want {
		t.Fatalf("%d backups, want %d", n, want)
	}
}

func tarNames(t *testing.T, path string) []string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	var names []string
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return names
		}
		if err != nil {
			t.Fatal(err)
		}
		names = append(names, h.Name)
	}
}

// fakeStore is the control plane's side of backups.store/1, as far as a host sees it: one
// owner's backups, each host's in its own folder.
type fakeStore struct {
	mu      sync.Mutex
	parts   map[string]map[int64][]byte
	backups []wire.Backup
	uploads int
}

func (f *fakeStore) askFor(host string) askControl {
	return func(_ context.Context, method string, params any) (json.RawMessage, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		b, _ := json.Marshal(params)
		var out any = map[string]any{}
		switch method {
		case "backups/stored":
			list := []wire.Backup{}
			for _, x := range f.backups {
				x.ThisMachine = strings.HasPrefix(x.ID, host+"/")
				list = append(list, x)
			}
			out = wire.BackupStoreList{Backups: list}
		case "backups/upload":
			var p wire.BackupStorePart
			json.Unmarshal(b, &p)
			if f.parts[host+"/"+p.Name] == nil {
				f.parts[host+"/"+p.Name] = map[int64][]byte{}
			}
			f.parts[host+"/"+p.Name][p.Part] = p.Data
			f.uploads++
		case "backups/commit":
			var c wire.BackupStoreCommit
			json.Unmarshal(b, &c)
			if int64(len(f.parts[host+"/"+c.Name])) != c.Parts {
				return nil, &controllink.AskError{Code: -32602, Message: "a part is missing"}
			}
			made := wire.Backup{ID: host + "/" + c.Name, Machine: c.Machine, RootID: c.RootID, MadeAt: c.MadeAt, Bytes: c.Bytes, Agents: c.Agents}
			f.backups = append([]wire.Backup{made}, f.backups...)
			out = made
		case "backups/download":
			var r wire.BackupStorePartRequest
			json.Unmarshal(b, &r)
			data, ok := f.parts[r.ID][r.Part]
			if !ok {
				return nil, &controllink.AskError{Code: -32602, Message: "no such part"}
			}
			out = wire.BackupStorePart{Name: r.ID, Part: r.Part, Data: data}
		default:
			return nil, &controllink.AskError{Code: -32601, Message: "Method not found"}
		}
		return json.Marshal(out)
	}
}

// A server backs up to the control plane's store in parts, waiting when asked to, and
// leaves no archive behind; a new server of the same person lists it and restores it.
func TestBackupToTheControlPlaneAndRestoreOnANewServer(t *testing.T) {
	atTime(t, time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC))
	was := backupPartBytes
	backupPartBytes = 512
	t.Cleanup(func() { backupPartBytes = was })
	fake := &fakeStore{parts: map[string]map[int64][]byte{}}

	rootA, rootB := t.TempDir(), t.TempDir()
	a, ca := start(t, rootA)
	if s := backupsIn(t, ca, 1); s.CanUseControl == nil || *s.CanUseControl {
		t.Fatalf("a host on no control plane can use one: %+v", s)
	}
	a.SetControlAsk(fake.askFor("a"))
	dir := folder(t, ca, 2)
	ca.call(t, 3, "backups/configure", map[string]any{"every": "off", "keep": 2, "target": "control"})
	agent := seeded(t, a, dir, nil)
	writeFile(t, a.Store.Loc.Transcript(string(agent.ID)), strings.Repeat("{\"line\":\"a turn of the conversation\"}\n", 100))

	var s wire.BackupState
	json.Unmarshal(ca.call(t, 4, "backups/make", map[string]any{"wait": true}), &s)
	if s.Making || s.LastError != nil || len(s.Backups) != 1 || !s.Backups[0].ThisMachine || s.Backups[0].Agents != 1 ||
		s.Settings.Target == nil || *s.Settings.Target != wire.BackupTargetControl || s.CanUseControl == nil || !*s.CanUseControl {
		t.Fatalf("after a backup and wait: %+v", s)
	}
	if fake.uploads < 2 {
		t.Fatalf("%d parts went up", fake.uploads)
	}
	if _, err := os.Stat(a.uploadFolder()); !os.IsNotExist(err) {
		t.Fatalf("the archive was left here: %v", err)
	}
	if _, err := os.Stat(filepath.Join(rootA, "backups")); !os.IsNotExist(err) {
		t.Fatalf("a backup went to the folder too: %v", err)
	}

	b, cb := start(t, rootB)
	b.SetControlAsk(fake.askFor("b"))
	cb.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 3, "target": "control"})
	list := backupsIn(t, cb, 2).Backups
	if len(list) != 1 || list[0].ThisMachine || list[0].ID != s.Backups[0].ID {
		t.Fatalf("b lists %+v", list)
	}
	var res wire.BackupRestoreResult
	json.Unmarshal(cb.call(t, 3, "backups/restore", map[string]any{"id": list[0].ID}), &res)
	if res.Restored != 1 {
		t.Fatalf("restored %+v", res)
	}
	got := b.Store.Agent(agent.ID)
	if got == nil || got.State != wire.AgentStateArchived || got.MadeInRoot == nil || *got.MadeInRoot != a.Store.RootID {
		t.Fatalf("came back as %+v", got)
	}
	if tr, _ := os.ReadFile(b.Store.Loc.Transcript(string(agent.ID))); strings.Count(string(tr), "\n") != 100 {
		t.Fatalf("transcript of %d lines", strings.Count(string(tr), "\n"))
	}
	if _, err := os.Stat(filepath.Join(rootB, "backups-download")); !os.IsNotExist(err) {
		t.Fatalf("the download was left here: %v", err)
	}

	// A control plane that refuses says so in the state, and the backup is not listed.
	b.SetControlAsk(func(context.Context, string, any) (json.RawMessage, error) {
		return nil, &controllink.AskError{Code: -32601, Message: "Method not found"}
	})
	if s := backupsIn(t, cb, 4); s.LastError == nil || !strings.Contains(*s.LastError, "Method not found") || len(s.Backups) != 0 {
		t.Fatalf("refused: %+v", s)
	}
}

// The default folder is on the disk it backs up, and the state says so (#2139); a synced
// folder and a folder on another disk are not. A backup in a folder on another volume
// restores on a new machine.
func TestABackupFolderOnTheSameDiskIsSaid(t *testing.T) {
	atTime(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC))
	root := t.TempDir()
	a, ca := start(t, root)
	if s := backupsIn(t, ca, 1); s.SameDisk == nil || !*s.SameDisk {
		t.Fatalf("the default folder in the data folder: %+v", s.SameDisk)
	}
	synced := filepath.Join(root, "Users", "sam", "Library", "CloudStorage", "Dropbox", "Agents backups")
	ca.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": synced})
	if s := backupsIn(t, ca, 3); s.SameDisk != nil {
		t.Fatalf("a synced folder said to be on the same disk")
	}
	// Another volume: tmpfs where there is one (Linux), else a stand-in for the device.
	other := ""
	if info, err := os.Stat("/dev/shm"); err == nil && info.IsDir() {
		if made, err := os.MkdirTemp("/dev/shm", "agents-backups-"); err == nil {
			dev, _ := deviceOf(made)
			if mine, _ := deviceOf(root); mine != dev {
				other = made
			}
			t.Cleanup(func() { os.RemoveAll(made) })
		}
	}
	if other == "" {
		other = t.TempDir()
		was := sameDevice
		sameDevice = func(a, b string) bool { return !strings.HasPrefix(a, other) && was(a, b) }
		t.Cleanup(func() { sameDevice = was })
	}
	ca.call(t, 4, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": other})
	if s := backupsIn(t, ca, 5); s.SameDisk != nil {
		t.Fatalf("a folder on another disk said to be on the same disk")
	}
	dir := folder(t, ca, 6)
	agent := seeded(t, a, dir, nil)
	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	// The disk is lost: a new machine reads the other volume.
	b, cb := start(t, t.TempDir())
	cb.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": other})
	var res wire.BackupRestoreResult
	json.Unmarshal(cb.call(t, 2, "backups/restore", map[string]any{"id": made.ID}), &res)
	if res.Restored != 1 || b.Store.Agent(agent.ID) == nil {
		t.Fatalf("restored %+v", res)
	}
}
