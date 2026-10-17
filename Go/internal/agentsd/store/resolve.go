package store

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Resolve is a path with its links followed, as Foundation's resolvingSymlinksInPath
// gives it (#1321): on a Mac a leading /private is taken off again when the path without
// it is the same file, so /tmp/x stays /tmp/x as the window and the Swift host keep it.
func Resolve(path string) (string, error) {
	r, err := filepath.EvalSymlinks(path)
	if err != nil {
		return r, err
	}
	return withoutPrivate(r), nil
}

func withoutPrivate(p string) string {
	if runtime.GOOS != "darwin" || !strings.HasPrefix(p, "/private/") {
		return p
	}
	short := strings.TrimPrefix(p, "/private")
	a, errA := os.Stat(p)
	b, errB := os.Stat(short)
	if errA == nil && errB == nil && os.SameFile(a, b) {
		return short
	}
	return p
}
