package store

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// WriteAtomically writes data whole, as StoreCoding.writeAtomically does: to a temporary
// file beside it, synced, then renamed into place, so a crash leaves the old file or the
// new one and never a torn one.
func WriteAtomically(file string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(file)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b := make([]byte, 16)
	rand.Read(b)
	tmp := filepath.Join(dir, "."+filepath.Base(file)+"."+hex.EncodeToString(b)+".tmp")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, file)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// SetAsidesKept is how many set-aside copies of one file are kept, of each kind (#2292).
const SetAsidesKept = 3

// TrimSetAsides deletes all but the newest SetAsidesKept copies of a file that a read set
// aside as <name>.unreadable-<time> or <name>.corrupt-<time> (#2292): each is a whole
// copy, and a file that is unreadable again and again would fill the disk.
func TrimSetAsides(file string) {
	for _, kind := range []string{".unreadable-", ".corrupt-"} {
		matches, _ := filepath.Glob(globEscape(file) + kind + "*")
		at := func(p string) int64 {
			n, _ := strconv.ParseInt(strings.TrimPrefix(p, file+kind), 10, 64)
			return n
		}
		sort.SliceStable(matches, func(i, j int) bool {
			if a, b := at(matches[i]), at(matches[j]); a != b {
				return a > b
			}
			return matches[i] > matches[j]
		})
		for _, p := range matches[min(len(matches), SetAsidesKept):] {
			os.Remove(p)
		}
	}
}

// globEscape is a path with the glob's own characters taken as they are.
func globEscape(p string) string {
	r := strings.NewReplacer(`\`, `\\`, `*`, `\*`, `?`, `\?`, `[`, `\[`)
	return r.Replace(p)
}
