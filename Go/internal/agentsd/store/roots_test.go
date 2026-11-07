package store

import (
	"os"
	"path/filepath"
	"testing"
)

// scratchRoots is a scratch home, and where a root's own folders go under it.
func scratchRoots(t *testing.T) [2]string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("XDG_STATE_HOME", "")
	return rootsFolders(home, os.Getenv)
}

func ownLocations(roots [2]string, root string) Locations {
	return Locations{Root: root, Cache: filepath.Join(roots[0], ownName(root)), Logs: filepath.Join(roots[1], ownName(root))}
}

// A root that is gone loses its own cache and log folders; one that is there, one on a
// disk that is not attached and one from before the mark keep theirs (#3746).
func TestSweepRemovesTheFoldersOfAGoneRoot(t *testing.T) {
	roots := scratchRoots(t)
	parent := t.TempDir()
	kept, gone := filepath.Join(parent, "Kept"), filepath.Join(parent, "Gone")
	unattached := filepath.Join(parent, "NoDisk", "Root")
	for _, root := range []string{kept, gone} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, root := range []string{kept, gone, unattached} {
		if err := MarkOwnFolders(ownLocations(roots, root)); err != nil {
			t.Fatal(err)
		}
	}
	unmarked := filepath.Join(roots[0], "Old-12345678")
	os.MkdirAll(unmarked, 0o755)
	if err := os.RemoveAll(gone); err != nil {
		t.Fatal(err)
	}
	removed := SweepGoneRoots()
	if len(removed) != 2 {
		t.Fatalf("removed %v", removed)
	}
	for _, dir := range []string{ownLocations(roots, gone).Cache, ownLocations(roots, gone).Logs} {
		if _, err := os.Stat(dir); !os.IsNotExist(err) {
			t.Errorf("%s is still here", dir)
		}
	}
	for _, dir := range []string{ownLocations(roots, kept).Cache, ownLocations(roots, kept).Logs,
		ownLocations(roots, unattached).Cache, unmarked} {
		if _, err := os.Stat(dir); err != nil {
			t.Errorf("%s went: %v", dir, err)
		}
	}
}

// A mark that names a root another folder is for removes nothing.
func TestSweepKeepsAFolderWhoseMarkIsNotItsOwn(t *testing.T) {
	roots := scratchRoots(t)
	gone := filepath.Join(t.TempDir(), "Gone")
	other := filepath.Join(roots[0], "Other-00000000")
	os.MkdirAll(other, 0o755)
	os.WriteFile(filepath.Join(other, RootMark), []byte(gone), 0o600)
	if removed := SweepGoneRoots(); len(removed) != 0 {
		t.Fatalf("removed %v", removed)
	}
}

// Only a root with folders of its own is marked: a temporary root's are inside it.
func TestMarkOnlyARootsOwnFolders(t *testing.T) {
	root := t.TempDir()
	l := Locations{Root: root, Cache: filepath.Join(root, "cache"), Logs: filepath.Join(root, "logs")}
	if l.OwnsFolders() {
		t.Fatal("a temporary root owns no folders under roots/")
	}
	MarkOwnFolders(l)
	if _, err := os.Stat(l.Cache); !os.IsNotExist(err) {
		t.Fatalf("%v", err)
	}
}
