package agentsd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	goruntime "runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// exportOf exports what params names and reads it in parts, as a client does.
func exportOf(t *testing.T, d *Daemon, c *conn, id int, params map[string]any) (wire.AgentsExport, []byte) {
	t.Helper()
	var made wire.AgentsExport
	if err := json.Unmarshal(c.call(t, id, "agents/export", params), &made); err != nil {
		t.Fatal(err)
	}
	var all []byte
	for i := 1; ; i++ {
		var part wire.SendRead
		json.Unmarshal(c.call(t, id*100+i, "agents/exportRead", map[string]any{"id": made.File.ID, "offset": len(all)}), &part)
		all = append(all, part.Data...)
		if part.End {
			break
		}
		if i > 1000 {
			t.Fatal("no end")
		}
	}
	if int64(len(all)) != made.File.Size {
		t.Fatalf("read %d of %d", len(all), made.File.Size)
	}
	if _, err := os.Stat(filepath.Join(d.outgoingFolder(), string(made.File.ID))); !os.IsNotExist(err) {
		t.Fatalf("the export stays in Outgoing after its last part: %v", err)
	}
	return made, all
}

// importInto sends an export in parts and imports it.
func importInto(t *testing.T, c *conn, id int, b []byte, part int) wire.BackupRestoreResult {
	t.Helper()
	upload := store.NewUUID()
	for off := 0; off < len(b); off += part {
		end := min(off+part, len(b))
		c.call(t, id*100+off/part, "agents/importUpload", map[string]any{"upload": upload, "offset": off, "data": b[off:end]})
	}
	var res wire.BackupRestoreResult
	if err := json.Unmarshal(c.call(t, id, "agents/import", map[string]any{"upload": upload}), &res); err != nil {
		t.Fatal(err)
	}
	return res
}

func tarNamesOf(t *testing.T, b []byte) []string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "x.tar.gz")
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return tarNames(t, p)
}

// US3: an agent exported on one machine comes back archived on another, never run there,
// and a second import skips it.
func TestExportAnAgentAndImportItOnAnotherMachine(t *testing.T) {
	atTime(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC))
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	title := "Fix the: build/now"
	session, account := "5b0f6a1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b", "acct"
	one := seeded(t, a, dir, func(x *wire.Agent) {
		x.Title = &title
		x.RuntimeSessionID, x.AccountID = &session, &account
		x.McpServers = []wire.MCPServer{{Name: "tool", Transport: wire.MCPServerTransport{
			Stdio: &wire.MCPServerTransportStdio{Command: "/bin/echo", Args: []string{}, Env: map[string]string{}}}}}
	})
	other := seeded(t, a, dir, nil)
	writeFile(t, a.Store.Loc.Transcript(string(one.ID)), strings.Repeat("{\"line\":\"x\"}\n", 2000))
	writeFile(t, filepath.Join(a.Store.Loc.Root, "usage-history.json"), `{"usage":"A"}`)

	made, b := exportOf(t, a, ca, 2, map[string]any{"agentID": one.ID})
	if made.Agents != 1 || made.Name != "Fix the- build-now 2026-10-22.tar.gz" {
		t.Fatalf("made %+v", made)
	}
	names := tarNamesOf(t, b)
	if names[0] != "manifest.json" || !slices.Contains(names, "agents/"+string(one.ID)+"/transcript.jsonl") ||
		slices.Contains(names, "agents/"+string(other.ID)+"/agent.json") || slices.Contains(names, "usage-history.json") {
		t.Fatalf("the export holds %v", names)
	}

	bd, cb := start(t, t.TempDir())
	if res := importInto(t, cb, 1, b, 4096); res.Restored != 1 || res.Skipped != 0 {
		t.Fatalf("imported %+v", res)
	}
	got := bd.Store.Agent(one.ID)
	if got == nil || got.State != wire.AgentStateArchived || got.MadeInRoot == nil || *got.MadeInRoot != a.Store.RootID ||
		len(got.McpServers) != 0 || got.RuntimeSessionID != nil || got.AccountID != nil {
		t.Fatalf("came back as %+v", got)
	}
	if err := bd.refuseToRun(got); err == nil {
		t.Fatal("an imported agent may run")
	}
	if tr := mustRead(t, bd.Store.Loc.Transcript(string(one.ID))); !bytes.Equal(tr, mustRead(t, a.Store.Loc.Transcript(string(one.ID)))) {
		t.Fatal("the transcript differs")
	}
	if _, err := os.Stat(filepath.Join(bd.Store.Loc.Root, "usage-history.json")); !os.IsNotExist(err) {
		t.Fatalf("an import wrote the usage history: %v", err)
	}
	if entries, _ := os.ReadDir(bd.incomingFolder()); len(entries) != 0 {
		t.Fatalf("the upload stays: %d files", len(entries))
	}
	if res := importInto(t, cb, 2, b, 1<<20); res.Restored != 0 || res.Skipped != 1 {
		t.Fatalf("a second import %+v", res)
	}
}

// #2389: an export from folder A, imported from folder B's menu on another machine,
// lands in B, whatever folder A was there; a folder that is no folder is refused.
func TestImportFromAFolderMenuLandsInThatFolder(t *testing.T) {
	a, ca := start(t, t.TempDir())
	folderA := folder(t, ca, 1)
	one := seeded(t, a, folderA, nil)
	two := seeded(t, a, folderA, func(x *wire.Agent) {
		x.Worktree = &wire.AgentWorktree{Name: "w", Root: store.FolderURL(filepath.Join(folderA, "w")), Folder: store.FolderURL(folderA)}
	})
	_, b := exportOf(t, a, ca, 2, map[string]any{"folder": store.FolderURL(folderA)})

	bd, cb := start(t, t.TempDir())
	folderB := folder(t, cb, 1)
	upload := store.NewUUID()
	cb.call(t, 2, "agents/importUpload", map[string]any{"upload": upload, "offset": 0, "data": b})
	var res wire.BackupRestoreResult
	if err := json.Unmarshal(cb.call(t, 3, "agents/import", map[string]any{"upload": upload, "folder": store.FolderURL(folderB)}), &res); err != nil {
		t.Fatal(err)
	}
	if res.Restored != 2 {
		t.Fatalf("imported %+v", res)
	}
	got := bd.agentsOf(folderB)
	if len(got) != 2 || !slices.ContainsFunc(got, func(x wire.Agent) bool { return x.ID == one.ID }) ||
		!slices.ContainsFunc(got, func(x wire.Agent) bool { return x.ID == two.ID && x.Worktree == nil }) {
		t.Fatalf("folder B holds %+v", got)
	}

	upload = store.NewUUID()
	cb.call(t, 4, "agents/importUpload", map[string]any{"upload": upload, "offset": 0, "data": b})
	if msg := cb.callErr(t, 5, "agents/import", map[string]any{"upload": upload, "folder": store.FolderURL(t.TempDir())}); !strings.Contains(msg, "not a folder") {
		t.Fatalf("no folder: %s", msg)
	}
}

// A folder's export holds its agents and no other folder's.
func TestExportAFolder(t *testing.T) {
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	elsewhere := folder(t, ca, 2)
	x, y := seeded(t, a, dir, nil), seeded(t, a, dir, nil)
	z := seeded(t, a, elsewhere, nil)
	made, b := exportOf(t, a, ca, 3, map[string]any{"folder": store.FolderURL(dir)})
	if made.Agents != 2 || !strings.HasPrefix(made.Name, filepath.Base(dir)+" ") {
		t.Fatalf("made %+v", made)
	}
	names := tarNamesOf(t, b)
	for _, id := range []wire.UUID{x.ID, y.ID} {
		if !slices.Contains(names, "agents/"+string(id)+"/agent.json") {
			t.Fatalf("%s left out: %v", id, names)
		}
	}
	if slices.Contains(names, "agents/"+string(z.ID)+"/agent.json") {
		t.Fatal("another folder's agent is in it")
	}

	empty := folder(t, ca, 4)
	if msg := ca.callErr(t, 5, "agents/export", map[string]any{"folder": store.FolderURL(empty)}); !strings.Contains(msg, "no agents") {
		t.Fatalf("empty folder: %s", msg)
	}
	if msg := ca.callErr(t, 6, "agents/export", map[string]any{}); !strings.Contains(msg, "Name an agent") {
		t.Fatalf("nothing named: %s", msg)
	}
	if msg := ca.callErr(t, 7, "agents/exportRead", map[string]any{"id": store.NewUUID(), "offset": 0}); !strings.Contains(msg, "Export again") {
		t.Fatalf("a gone export: %s", msg)
	}
}

// An agent deleted here does not come back from its export, and its own export, imported
// on the machine that made it, is never run there.
func TestImportSkipsAnErasedAgentAndNeverRunsOwnAgents(t *testing.T) {
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	gone := archivedWithSession(t, a, dir, "gone")
	_, b := exportOf(t, a, ca, 2, map[string]any{"folder": store.FolderURL(dir)})
	ca.call(t, 3, "agents/delete", map[string]any{"agentID": gone.ID})
	if res := importInto(t, ca, 4, b, 1<<20); res.Restored != 0 || res.Skipped != 1 || a.Store.Agent(gone.ID) != nil {
		t.Fatalf("imported %+v, back: %v", res, a.Store.Agent(gone.ID) != nil)
	}

	kept := seeded(t, a, dir, nil)
	_, b = exportOf(t, a, ca, 5, map[string]any{"agentID": kept.ID})
	if err := a.Store.Delete(kept.ID); err != nil {
		t.Fatal(err)
	}
	if res := importInto(t, ca, 6, b, 1<<20); res.Restored != 1 {
		t.Fatalf("imported %+v", res)
	}
	got := a.Store.Agent(kept.ID)
	if got == nil || got.MadeInRoot == nil || *got.MadeInRoot != restoredElsewhere {
		t.Fatalf("came back as %+v", got)
	}
	if err := a.refuseToRun(got); err == nil {
		t.Fatal("its own import may run")
	}
}

// A file that is not an export is refused, and a backup imported brings its agents but
// none of its root files: not the history, not the erased list.
func TestImportRefusesWhatIsNotAnExport(t *testing.T) {
	atTime(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC))
	a, ca := start(t, t.TempDir())
	upload := store.NewUUID()
	ca.call(t, 1, "agents/importUpload", map[string]any{"upload": upload, "offset": 0, "data": []byte("not a tar.gz")})
	if msg := ca.callErr(t, 2, "agents/import", map[string]any{"upload": upload}); !strings.Contains(msg, "not an export") {
		t.Fatalf("junk: %s", msg)
	}

	shared := t.TempDir()
	ca.call(t, 3, "backups/configure", map[string]any{"every": "off", "keep": 2, "folder": shared})
	dir := folder(t, ca, 4)
	agent := seeded(t, a, dir, nil)
	writeFile(t, filepath.Join(a.Store.Loc.Root, "usage-history.json"), `{"usage":"A"}`)
	writeFile(t, filepath.Join(a.Store.Loc.Root, erasedFile), `{"`+string(store.NewUUID())+`":"2026-10-22T09:00:00Z"}`)
	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	archive, _, _ := a.backupPaths(made.ID)
	b, c := start(t, t.TempDir())
	if res := importInto(t, c, 5, mustRead(t, archive), 1<<20); res.Restored != 1 || b.Store.Agent(agent.ID) == nil {
		t.Fatalf("imported %+v", res)
	}
	for _, f := range []string{"usage-history.json", erasedFile} {
		if _, err := os.Stat(filepath.Join(b.Store.Loc.Root, f)); !os.IsNotExist(err) {
			t.Fatalf("an import wrote %s: %v", f, err)
		}
	}
}

func TestExportFileName(t *testing.T) {
	for in, want := range map[string]string{
		"":                       "Agents",
		"  ..  ":                 "Agents",
		"a/b\\c:d":               "a-b-c-d",
		"line\nbreak\ttab":       "line-break-tab",
		strings.Repeat("é", 100): strings.Repeat("é", exportNameMost),
	} {
		if got := exportFileName(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

// #2428: export and import stream an agent's files, so a big transcript is never held in
// memory whole; a torn last line is still left out.
func TestExportAndImportStreamABigTranscript(t *testing.T) {
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	one := seeded(t, a, dir, nil)
	const size = 64 << 20
	line := strings.Repeat("x", 1023) + "\n"
	f, err := os.Create(a.Store.Loc.Transcript(string(one.ID)))
	if err != nil {
		t.Fatal(err)
	}
	for range size / len(line) {
		f.WriteString(line)
	}
	f.WriteString(`{"torn":`)
	f.Close()

	path := filepath.Join(t.TempDir(), "x.tar.gz")
	m := backupManifest{Format: backupFormat, RootID: a.Store.RootID, MadeAt: wire.DateOf(time.Now())}
	exported := allocatedBy(func() {
		if err := a.writeBackupArchive(path, &m, []wire.Agent{one}, false); err != nil {
			t.Fatal(err)
		}
	})
	bd, _ := start(t, t.TempDir())
	var res wire.BackupRestoreResult
	imported := allocatedBy(func() {
		if res, err = bd.restoreArchive(path, a.Store.RootID, false, false, ""); err != nil {
			t.Fatal(err)
		}
	})
	t.Logf("a %d MB transcript: export allocates %d KB, import %d KB", size>>20, exported>>10, imported>>10)
	if res.Restored != 1 {
		t.Fatalf("imported %+v", res)
	}
	fi, err := os.Stat(bd.Store.Loc.Transcript(string(one.ID)))
	if err != nil || fi.Size() != size/int64(len(line))*int64(len(line)) {
		t.Fatalf("the transcript came back as %v, %v", fi, err)
	}
	if exported > size/4 || imported > size/4 {
		t.Fatalf("export allocates %d bytes and import %d for a %d byte transcript", exported, imported, size)
	}
	if left, _ := filepath.Glob(filepath.Join(bd.Store.Loc.Root, ".restore-*")); len(left) != 0 {
		t.Fatalf("staging stays: %v", left)
	}
}

// allocatedBy is how many bytes of heap do allocates.
func allocatedBy(do func()) uint64 {
	var before, after goruntime.MemStats
	goruntime.ReadMemStats(&before)
	do()
	goruntime.ReadMemStats(&after)
	return after.TotalAlloc - before.TotalAlloc
}
