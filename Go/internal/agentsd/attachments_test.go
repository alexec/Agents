package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

func TestAttachmentsAreWrittenWholeAndBound(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	root, err := d.agentFolder(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	write := func(name string, size int) string {
		t.Helper()
		path, err := d.writeAttachment(root, name, []byte(strings.Repeat("x", size)))
		if err != nil {
			t.Fatal(err)
		}
		os.Chtimes(path, clock.now(), clock.now())
		return path
	}
	exists := func(path string) bool { _, err := os.Stat(path); return err == nil }

	// Written whole: no temporary file is left beside it.
	first := write("a.png", 10)
	if b, _ := os.ReadFile(first); len(b) != 10 {
		t.Fatal(len(b))
	}
	if entries, _ := os.ReadDir(filepath.Dir(first)); len(entries) != 1 {
		t.Fatalf("%d files", len(entries))
	}

	// Past seven days, an attachment no transcript names goes at the sweep; one that is
	// named stays. Put in place, not written: each write bounds the folder by size at once.
	place := func(name string, age time.Duration) string {
		path := filepath.Join(filepath.Dir(first), name)
		os.WriteFile(path, []byte(strings.Repeat("x", 10)), 0o600)
		at := clock.now().Add(-age)
		os.Chtimes(path, at, at)
		return path
	}
	named := place("0A1B2C3D-named.png", 8*24*time.Hour)
	unnamed := place("4E5F6A7B-unnamed.png", 8*24*time.Hour)
	young := place("8C9D0E1F-young.png", 6*24*time.Hour)
	// The name straddles the first piece the scan reads, as a Swift client escapes it.
	key := attachmentKey(named)
	tail := `{"text":"look at ` + strings.ReplaceAll(named, "/", `\/`) + `"}` + "\n"
	transcript := strings.Repeat("y", 1<<20-4-strings.Index(tail, key)) + tail
	if strings.Index(transcript, key) != 1<<20-4 {
		t.Fatal("the key does not straddle the piece")
	}
	if err := os.WriteFile(d.Store.Loc.Transcript(string(a.ID)), []byte(transcript), 0o600); err != nil {
		t.Fatal(err)
	}
	tmpOld := filepath.Join(filepath.Dir(first), ".cut.png.ab.tmp")
	tmpNew := filepath.Join(filepath.Dir(first), ".going.png.cd.tmp")
	for _, p := range []string{tmpOld, tmpNew} {
		os.WriteFile(p, []byte("x"), 0o600)
	}
	day := clock.now().Add(-25 * time.Hour)
	os.Chtimes(tmpOld, day, day)
	d.sweepAttachments()
	if exists(unnamed) || exists(tmpOld) {
		t.Fatal("an old attachment or a cut-off write was kept")
	}
	for _, p := range []string{first, named, young, tmpNew} {
		if !exists(p) {
			t.Fatalf("%s was deleted", filepath.Base(p))
		}
	}

	// Over the folder's size, the oldest go first, named or not; the new one stays.
	old := attachmentFolderBytes
	attachmentFolderBytes = 25
	t.Cleanup(func() { attachmentFolderBytes = old })
	newest := write("big.png", 30)
	if !exists(newest) || exists(named) || exists(young) || exists(first) {
		t.Fatalf("by size: newest %v named %v young %v first %v", exists(newest), exists(named), exists(young), exists(first))
	}
}

// A write reads no transcript (#1651): it applies only the size bound, and the sweep
// looks for the names. The sweep remembers which agent names an old file it keeps, so
// the next sweep does not look again, until that agent goes.
func TestAttachmentWritesReadNoTranscript(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	cwd := t.TempDir()
	a := seeded(t, d, cwd, nil)
	b := seeded(t, d, cwd, nil)
	root, err := d.agentFolder(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	dir, err := attachmentsDir(root, true)
	if err != nil {
		t.Fatal(err)
	}
	exists := func(path string) bool { _, err := os.Stat(path); return err == nil }
	place := func(name string) string {
		path := filepath.Join(dir, name)
		os.WriteFile(path, []byte("x"), 0o600)
		at := clock.now().Add(-8 * 24 * time.Hour)
		os.Chtimes(path, at, at)
		return path
	}
	named := place("0A1B2C3D-named.png")
	unnamed := place("4E5F6A7B-unnamed.png")
	transcript := func(id wire.UUID, text string) {
		t.Helper()
		if err := os.WriteFile(d.Store.Loc.Transcript(string(id)), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	transcript(a.ID, `{"text":"look at `+named+`"}`+"\n")
	transcript(b.ID, `{"text":"nothing"}`+"\n")

	if _, err := d.writeAttachment(root, "new.png", []byte("x")); err != nil {
		t.Fatal(err)
	}
	if !exists(unnamed) || !exists(named) {
		t.Fatal("a write deleted an old attachment: it looked in the transcripts")
	}
	d.sweepAttachments()
	if exists(unnamed) || !exists(named) {
		t.Fatalf("sweep: unnamed %v named %v", exists(unnamed), exists(named))
	}

	// A transcript only grows; this one is emptied only to show the sweep does not read
	// it again for a file it found named.
	transcript(a.ID, "")
	d.sweepAttachments()
	if !exists(named) {
		t.Fatal("the second sweep looked again for a file it found named")
	}

	// The agent that names it goes: the sweep looks again, and no other agent names it.
	if err := d.Store.Delete(a.ID); err != nil {
		t.Fatal(err)
	}
	d.sweepAttachments()
	if exists(named) {
		t.Fatal("an old file named only by a deleted agent was kept")
	}
	d.namedMu.Lock()
	defer d.namedMu.Unlock()
	if len(d.namedBy[root]) != 0 {
		t.Fatalf("the book keeps %d deleted files", len(d.namedBy[root]))
	}
}

// A folder can commit .agents/attachments, or .agents, as a link to a folder outside
// it. The sweep deletes nothing there, and a write puts nothing there.
func TestAttachmentsRefuseALinkedFolder(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	for _, linked := range []string{".agents", attachmentsFolder} {
		t.Run(linked, func(t *testing.T) {
			d, _ := start(t, t.TempDir())
			defer d.Shutdown()
			a := seeded(t, d, t.TempDir(), nil)
			root, err := d.agentFolder(a.ID)
			if err != nil {
				t.Fatal(err)
			}
			outside := t.TempDir()
			victim := filepath.Join(outside, "4E5F6A7B-old.png")
			if linked == ".agents" {
				os.Mkdir(filepath.Join(outside, "attachments"), 0o700)
				victim = filepath.Join(outside, "attachments", "4E5F6A7B-old.png")
			}
			os.WriteFile(victim, []byte("x"), 0o600)
			old := clock.now().Add(-30 * 24 * time.Hour)
			os.Chtimes(victim, old, old)
			if linked == attachmentsFolder {
				os.Mkdir(filepath.Join(root, ".agents"), 0o700)
			}
			if err := os.Symlink(outside, filepath.Join(root, linked)); err != nil {
				t.Fatal(err)
			}

			d.sweepAttachments()
			if _, err := os.Stat(victim); err != nil {
				t.Fatal("the sweep deleted a file outside the folder")
			}
			if path, err := d.writeAttachment(root, "a.png", []byte("x")); err == nil {
				t.Fatalf("wrote %s through the link", path)
			}
			if entries, _ := os.ReadDir(filepath.Dir(victim)); len(entries) != 1 {
				t.Fatalf("%d files outside the folder", len(entries))
			}
		})
	}
}
