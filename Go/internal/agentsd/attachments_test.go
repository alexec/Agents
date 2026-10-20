package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAttachmentsAreWrittenWholeAndBound(t *testing.T) {
	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	atTime(t, &clock)
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
		os.Chtimes(path, clock, clock)
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

	// Past seven days, an attachment no transcript names goes; one that is named stays.
	// Put in place, not written: each write bounds the folder at once.
	place := func(name string, age time.Duration) string {
		path := filepath.Join(filepath.Dir(first), name)
		os.WriteFile(path, []byte(strings.Repeat("x", 10)), 0o600)
		at := clock.Add(-age)
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
	day := clock.Add(-25 * time.Hour)
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

// A project can commit .agents/attachments, or .agents, as a link to a folder outside
// it. The sweep deletes nothing there, and a write puts nothing there.
func TestAttachmentsRefuseALinkedFolder(t *testing.T) {
	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	atTime(t, &clock)
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
			old := clock.Add(-30 * 24 * time.Hour)
			os.Chtimes(victim, old, old)
			if linked == attachmentsFolder {
				os.Mkdir(filepath.Join(root, ".agents"), 0o700)
			}
			if err := os.Symlink(outside, filepath.Join(root, linked)); err != nil {
				t.Fatal(err)
			}

			d.sweepAttachments()
			if _, err := os.Stat(victim); err != nil {
				t.Fatal("the sweep deleted a file outside the project")
			}
			if path, err := d.writeAttachment(root, "a.png", []byte("x")); err == nil {
				t.Fatalf("wrote %s through the link", path)
			}
			if entries, _ := os.ReadDir(filepath.Dir(victim)); len(entries) != 1 {
				t.Fatalf("%d files outside the project", len(entries))
			}
		})
	}
}
