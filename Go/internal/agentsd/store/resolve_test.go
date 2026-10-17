package store

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// A folder under /tmp keeps /tmp, as Foundation keeps it (#1321); one reached through a
// link of its own is still followed.
func TestResolveKeepsTmpAsFoundationDoes(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("/tmp leads to /private/tmp only on a Mac")
	}
	dir, err := os.MkdirTemp("/tmp", "resolve-1321-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	work := filepath.Join(dir, "work")
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := Resolve(work)
	if err != nil || got != work {
		t.Fatalf("Resolve(%s) = %q, %v; want it as it is", work, got, err)
	}
	if got, _ := Resolve("/private" + work); got != work {
		t.Fatalf("Resolve(/private%s) = %q; want %s", work, got, work)
	}
	if u := FolderURL(work); u != PathURL(work) {
		t.Fatalf("FolderURL(%s) = %s", work, u)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(work, link); err != nil {
		t.Fatal(err)
	}
	if got, _ := Resolve(link); got != work {
		t.Fatalf("Resolve(%s) = %q; want %s", link, got, work)
	}
}
