package agentsd

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

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
	clock := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	atTime(t, &clock)
	shared := t.TempDir()
	rootA, rootB := t.TempDir(), t.TempDir()
	a, ca := start(t, rootA)
	dir := project(t, ca, 1)
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
	ownDir := project(t, cb, 1)
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

func TestBackupsKeepTheNewestOfThisMachine(t *testing.T) {
	clock := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	atTime(t, &clock)
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
		clock = clock.Add(time.Hour)
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
	clock := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	atTime(t, &clock)
	d, c := start(t, t.TempDir())
	c.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 3})
	d.backupIfDue()
	waitBackups(t, d, 0)
	c.call(t, 2, "backups/configure", map[string]any{"every": "daily", "keep": 3})
	d.backupIfDue()
	waitBackups(t, d, 1)
	clock = clock.Add(23 * time.Hour)
	d.backupIfDue()
	waitBackups(t, d, 1)
	clock = clock.Add(2 * time.Hour)
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
	if n := len(d.listBackups()); n != want {
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
