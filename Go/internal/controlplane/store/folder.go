package store

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Folder is FolderStore: a store in a folder on one machine (contracts/store.md rule 5),
// the host app's single copy, or several copies on one server. A key is a file path; the
// entity tag is the SHA-256 of the file. The paths and the tags are the Swift store's, so
// either can read the other's folder. A write takes an advisory lock on <key>.lock,
// compares, writes a temporary file, syncs it, renames it into place and syncs the
// folder. Folders shared over NFS are not supported: advisory locks there cannot be
// trusted.
//
// Listing is paid for by what changed (#174), not by the size of the store: it walks
// only the folder the prefix names, and keeps each folder's stamp and each file's stamp
// with its tag. A folder whose stamp is unchanged is taken as it was; in one that
// changed, only files whose stamp changed are read and hashed again.
type Folder struct {
	Root  string
	index *folderIndex
	// folders keeps a Delete's removal of empty folders apart from a Put making its folder
	// and opening its lock (#2676): a Put holds it shared, a removal alone.
	folders sync.RWMutex
}

func NewFolder(root string) *Folder { return &Folder{Root: root, index: newFolderIndex()} }

// HashedByListing is how many files listing has read and hashed: for the tests.
func (f *Folder) HashedByListing() int {
	f.index.mu.Lock()
	defer f.index.mu.Unlock()
	return f.index.hashed
}

// file names the file of a key: no "..", no absolute path, no hidden name.
func (f *Folder) file(key string) (string, error) {
	if key == "" || strings.HasPrefix(key, "/") {
		return "", Unavailable("%s is not a key this store keeps", key)
	}
	for _, p := range strings.Split(key, "/") {
		if p == "" || p == "." || p == ".." || strings.HasPrefix(p, ".") {
			return "", Unavailable("%s is not a key this store keeps", key)
		}
	}
	return filepath.Join(f.Root, filepath.FromSlash(key)), nil
}

func (f *Folder) Get(_ context.Context, key string) (*Object, error) {
	p, err := f.file(key)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	// There and not readable (EIO, EACCES) is not absent (#171): absent would have the
	// member forgotten, and a browser delete its key.
	if err != nil {
		return nil, Unavailable("cannot read %s: %v", key, err)
	}
	return &Object{Data: data, ETag: SHA256Tag(data)}, nil
}

func (f *Folder) Put(_ context.Context, key string, data []byte, when Condition) (string, error) {
	p, err := f.file(key)
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(p)
	f.folders.RLock()
	lock, err := makeLock(dir, p)
	f.folders.RUnlock()
	if err != nil {
		return "", Unavailable("cannot lock %s: %v", key, err)
	}
	defer lock.Close()
	if err := flock(lock, syscall.LOCK_EX); err != nil {
		return "", Unavailable("cannot lock %s: %v", key, err)
	}
	defer flock(lock, syscall.LOCK_UN)

	// Only a file that is not there is absent (#206): one there and unreadable is neither
	// overwritten as absent nor taken as some other version.
	if !when.IsAlways() {
		current, err := os.ReadFile(p)
		there := err == nil
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return "", Unavailable("cannot read %s: %v", key, err)
		}
		if when.IsAbsent() && there {
			return "", &ConflictError{key}
		}
		if tag, ok := when.Matching(); ok && (!there || SHA256Tag(current) != tag) {
			return "", &ConflictError{key}
		}
	}
	tmp := filepath.Join(dir, "."+filepath.Base(p)+"."+randomHex(16)+".tmp")
	if err := writeSynced(tmp, data); err != nil {
		os.Remove(tmp)
		return "", Unavailable("cannot write %s: %v", key, err)
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return "", Unavailable("cannot move %s into place: %v", key, err)
	}
	// The rename is kept only once its folder is synced too.
	d, err := os.Open(dir)
	if err != nil {
		return "", Unavailable("cannot sync the folder of %s: %v", key, err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return "", Unavailable("cannot sync the folder of %s: %v", key, err)
	}
	tag := SHA256Tag(data)
	// Known already, so the next listing need not read it back.
	if st, ok := stampOf(p, false); ok {
		f.index.know(key, st, tag, false)
	}
	return tag, nil
}

// makeLock makes the key's folder and opens its lock. Another copy's Delete of the
// folder's last other key may remove the folder, or one above it, while it is made or
// before the lock is opened (#2293, #2676): then it is made again. That fails as not
// there, as there already (MkdirAll's check after its mkdir) or, on macOS, as an invalid
// argument (a file opened in a folder being removed). Once the lock is there, the folder
// is not empty, and stays.
func makeLock(dir, p string) (*os.File, error) {
	for try := 0; ; try++ {
		err := os.MkdirAll(dir, 0o700)
		var lock *os.File
		if err == nil {
			lock, err = os.OpenFile(p+".lock", os.O_CREATE|os.O_RDWR, 0o600)
		}
		gone := errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrExist) || errors.Is(err, syscall.EINVAL)
		if err == nil || !gone || try == 4 {
			return lock, err
		}
	}
}

func flock(f *os.File, how int) error {
	for {
		err := syscall.Flock(int(f.Fd()), how)
		if err != syscall.EINTR {
			return err
		}
	}
}

func writeSynced(path string, data []byte) error {
	w, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := w.Write(data); err != nil {
		w.Close()
		return err
	}
	if err := w.Sync(); err != nil {
		w.Close()
		return err
	}
	return w.Close()
}

func (f *Folder) Delete(_ context.Context, key string) error {
	p, err := f.file(key)
	if err != nil {
		return err
	}
	os.Remove(p)
	os.Remove(p + ".lock")
	f.index.forget(key)
	f.folders.Lock()
	f.removeEmptyFolders(filepath.Dir(p))
	f.folders.Unlock()
	return nil
}

// removeEmptyFolders removes dir and each folder above it that is empty, up to the root
// (#2293): a key's folder, such as an hour's of v1/usage/hours/, goes with its last key, so
// a List does not walk a folder for each hour there ever was.
func (f *Folder) removeEmptyFolders(dir string) {
	root := filepath.Clean(f.Root)
	for dir = filepath.Clean(dir); strings.HasPrefix(dir, root+string(filepath.Separator)); dir = filepath.Dir(dir) {
		// Only an empty folder goes: one with a key, or a write's lock, stays.
		if os.Remove(dir) != nil {
			return
		}
	}
}

// List walks the folder the prefix names, or the one it ends in: v1/clients/ walks
// v1/clients, v1/codes/ab walks v1/codes and keeps the keys starting ab.
func (f *Folder) List(_ context.Context, prefix string) ([]Key, error) {
	parts := strings.FieldsFunc(prefix, func(r rune) bool { return r == '/' })
	if !strings.HasSuffix(prefix, "/") && prefix != "" && len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	var keys []Key
	f.walk(strings.Join(parts, "/"), &keys)
	out := []Key{}
	for _, k := range keys {
		if strings.HasPrefix(k.Key, prefix) {
			out = append(out, k)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

// RemoveLeftovers removes what a copy that stopped mid-write left behind, and probes it
// never deleted: temporary files, probe keys and locks with no key beside them, all
// older than before. It returns how many went. Run by the sweep (#174), never on a hot
// path: it visits every folder.
func (f *Folder) RemoveLeftovers(before time.Time) int {
	removed := 0
	filepath.WalkDir(f.Root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == f.Root || !d.Type().IsRegular() {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.ModTime().Before(before) {
			return nil
		}
		rel, _ := filepath.Rel(f.Root, p)
		rel = filepath.ToSlash(rel)
		name := d.Name()
		leftover := false
		switch {
		case strings.HasPrefix(name, ".") && strings.HasSuffix(name, ".tmp"):
			leftover = true
		case strings.HasPrefix(rel, "probe/"):
			leftover = true
		case strings.HasSuffix(name, ".lock"):
			// Only a lock nobody holds: one held is a write under way.
			if _, err := os.Lstat(strings.TrimSuffix(p, ".lock")); err == nil {
				return nil
			}
			l, err := os.OpenFile(p, os.O_RDWR, 0)
			if err != nil {
				return nil
			}
			defer l.Close()
			leftover = syscall.Flock(int(l.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil
		}
		if leftover && os.Remove(p) == nil {
			removed++
			f.index.forget(rel)
		}
		return nil
	})
	return removed
}

// walk lists one folder and those under it, from what is known where nothing changed.
func (f *Folder) walk(folder string, keys *[]Key) {
	p := f.Root
	if folder != "" {
		p = filepath.Join(f.Root, filepath.FromSlash(folder))
	}
	// The root may be a link (a temporary folder is); nothing under it is followed.
	st, ok := stampOf(p, folder == "")
	if !ok || !st.isDir {
		f.index.forgetFolder(folder)
		return
	}
	l, known := f.index.listing(folder)
	if !known || l.stamp != st || !l.settled {
		l = f.scan(folder, p, st)
	}
	for _, e := range l.files {
		*keys = append(*keys, Key{join(folder, e.name), e.etag, e.size})
	}
	for _, name := range l.folders {
		f.walk(join(folder, name), keys)
	}
}

// scan reads a folder that changed: its entries again, and a file only if its stamp
// moved.
func (f *Folder) scan(folder, p string, st stamp) listing {
	entries, _ := os.ReadDir(p)
	l := listing{stamp: st}
	unreadable := false
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".lock") {
			continue
		}
		key := join(folder, name)
		file := filepath.Join(p, name)
		// Not followed: a link could lead out of the store.
		entry, ok := stampOf(file, false)
		if !ok {
			continue
		}
		switch {
		case entry.isDir:
			l.folders = append(l.folders, name)
		case entry.isFile:
			if tag, ok := f.index.etag(key, entry); ok {
				l.files = append(l.files, named{name, tag, entry.size})
			} else if data, err := os.ReadFile(file); err == nil {
				tag := SHA256Tag(data)
				f.index.know(key, entry, tag, true)
				l.files = append(l.files, named{name, tag, int64(len(data))})
			} else {
				// There and unreadable (EACCES, EIO) is listed all the same (#206): left
				// out, its member would be refused as unknown and a browser delete its
				// key. The tag is no file's hash, so whoever lists it reads it, fails, and
				// keeps what they held. It is not remembered: it is tried again.
				unreadable = true
				l.files = append(l.files, named{name, unreadableTag(entry), entry.size})
			}
		}
	}
	// A folder changed within the clock's grain of now could change again with the same
	// time; it is scanned again next time rather than trusted. So is one holding a file
	// that could not be read: a chmod changes neither stamp.
	l.settled = st.mtime.Before(time.Now().Add(-2*time.Second)) && !unreadable
	f.index.keep(folder, l)
	return l
}

func join(folder, name string) string {
	if folder == "" {
		return name
	}
	return folder + "/" + name
}

// unreadableTag is what a file listed and not readable is tagged with: never a hash, so
// never matched. The same words as Swift's.
func unreadableTag(s stamp) string {
	return fmt.Sprintf(`"unreadable-%d-%d-%d.%d"`, s.ino, s.size, s.mtime.Unix(), s.mtime.Nanosecond())
}

// stamp is StoreStamp: what a file or folder is, as lstat says, enough to tell it
// changed without reading it.
type stamp struct {
	ino    uint64
	size   int64
	mtime  time.Time
	isDir  bool
	isFile bool
}

func stampOf(p string, following bool) (stamp, bool) {
	stat := os.Lstat
	if following {
		stat = os.Stat
	}
	info, err := stat(p)
	if err != nil {
		return stamp{}, false
	}
	s := stamp{size: info.Size(), mtime: info.ModTime(), isDir: info.IsDir(), isFile: info.Mode().IsRegular()}
	if sys, ok := info.Sys().(*syscall.Stat_t); ok {
		s.ino = uint64(sys.Ino)
	}
	return s, true
}

type named struct {
	name, etag string
	size       int64
}

type listing struct {
	stamp stamp
	// Changed long enough ago that the same stamp means the same entries.
	settled bool
	files   []named
	folders []string
}

type knownFile struct {
	stamp stamp
	etag  string
}

// folderIndex is FolderIndex: what a folder store knows of its files between listings
// (#174), by folder.
type folderIndex struct {
	mu      sync.Mutex
	files   map[string]map[string]knownFile
	folders map[string]listing
	hashed  int
}

func newFolderIndex() *folderIndex {
	return &folderIndex{files: map[string]map[string]knownFile{}, folders: map[string]listing{}}
}

func split(key string) (string, string) {
	return strings.TrimSuffix(path.Dir(key), "."), path.Base(key)
}

func (x *folderIndex) etag(key string, s stamp) (string, bool) {
	folder, name := split(key)
	x.mu.Lock()
	defer x.mu.Unlock()
	k, ok := x.files[folder][name]
	if !ok || k.stamp != s {
		return "", false
	}
	return k.etag, true
}

func (x *folderIndex) know(key string, s stamp, etag string, hashed bool) {
	folder, name := split(key)
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.files[folder] == nil {
		x.files[folder] = map[string]knownFile{}
	}
	x.files[folder][name] = knownFile{s, etag}
	if hashed {
		x.hashed++
	}
}

func (x *folderIndex) forget(key string) {
	folder, name := split(key)
	x.mu.Lock()
	defer x.mu.Unlock()
	delete(x.files[folder], name)
}

func (x *folderIndex) listing(folder string) (listing, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	l, ok := x.folders[folder]
	return l, ok
}

// keep holds a folder scanned again; files no longer in it are forgotten.
func (x *folderIndex) keep(folder string, l listing) {
	present := map[string]bool{}
	for _, e := range l.files {
		present[e.name] = true
	}
	x.mu.Lock()
	defer x.mu.Unlock()
	x.folders[folder] = l
	for name := range x.files[folder] {
		if !present[name] {
			delete(x.files[folder], name)
		}
	}
}

// forgetFolder forgets a folder that is gone, and everything under it.
func (x *folderIndex) forgetFolder(folder string) {
	inside := folder + "/"
	x.mu.Lock()
	defer x.mu.Unlock()
	for k := range x.folders {
		if k == folder || strings.HasPrefix(k, inside) {
			delete(x.folders, k)
		}
	}
	for k := range x.files {
		if k == folder || strings.HasPrefix(k, inside) {
			delete(x.files, k)
		}
	}
}
