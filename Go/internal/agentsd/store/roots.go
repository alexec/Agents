package store

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// A root that is neither temporary nor the ordinary one has cache and log folders of its
// own, roots/<name>-<hash> (#1030). The hash cannot be read back, so each of them keeps
// its root's path in RootMark, and a sweep removes the ones whose root is gone (#3746).

// RootMark is the file in a root's own cache or log folder that names the root.
const RootMark = "root-path"

// OwnsFolders is whether l's cache and log folders are its own, under roots/.
func (l Locations) OwnsFolders() bool {
	return filepath.Base(filepath.Dir(l.Cache)) == "roots" && filepath.Base(l.Cache) == ownName(l.Root)
}

// MarkOwnFolders writes l's root into RootMark in its own cache and log folders, made if
// they are not there. Nothing is done for a root with none.
func MarkOwnFolders(l Locations) error {
	if !l.OwnsFolders() {
		return nil
	}
	var errs []error
	for _, dir := range []string{l.Cache, l.Logs} {
		mark := filepath.Join(dir, RootMark)
		if data, err := os.ReadFile(mark); err == nil && string(data) == l.Root {
			continue
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			errs = append(errs, err)
			continue
		}
		errs = append(errs, WriteAtomically(mark, []byte(l.Root), 0o600))
	}
	return errors.Join(errs...)
}

// SweepGoneRoots removes each root's own cache and log folder whose RootMark names a root
// that is gone, and says which it removed. A folder with no mark (from a build before
// #3746) is kept: its root cannot be known. So is one whose root's parent folder is gone
// too, as on a disk that is not attached now, and one whose name is not its mark's.
func SweepGoneRoots() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var removed []string
	for _, roots := range rootsFolders(home, os.Getenv) {
		entries, _ := os.ReadDir(roots)
		for _, e := range entries {
			dir := filepath.Join(roots, e.Name())
			if e.IsDir() && rootIsGone(dir) && os.RemoveAll(dir) == nil {
				removed = append(removed, dir)
			}
		}
	}
	return removed
}

func rootIsGone(dir string) bool {
	data, err := os.ReadFile(filepath.Join(dir, RootMark))
	if err != nil {
		return false
	}
	root := strings.TrimSpace(string(data))
	if !filepath.IsAbs(root) || filepath.Clean(root) != root || ownName(root) != filepath.Base(dir) {
		return false
	}
	if _, err := os.Lstat(root); !errors.Is(err, fs.ErrNotExist) {
		return false
	}
	_, err = os.Stat(filepath.Dir(root))
	return err == nil
}
