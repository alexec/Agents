package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Folder is FolderStore: a key is a file path under Root, its tag the SHA-256 of the
// file, the same layout and tags as the Swift store, so either can read the other's
// folder. A write takes an advisory lock on <key>.lock, compares, writes a temporary
// file, syncs it, renames it into place and syncs the folder.
//
// gocloud.dev's fileblob is not used: it has IfNotExist but no If-Match (stage 1 report).
type Folder struct {
	Root string
	mu   sync.Mutex
	// What listing knows of each file, so an unchanged one is not hashed again (#174).
	known map[string]stamped
}

type stamped struct {
	ino   uint64
	size  int64
	mtime time.Time
	etag  string
}

func NewFolder(root string) *Folder { return &Folder{Root: root, known: map[string]stamped{}} }

func (f *Folder) path(key string) (string, error) {
	parts := strings.Split(key, "/")
	if key == "" || strings.HasPrefix(key, "/") {
		return "", unavailable("%s is not a key this store keeps", key)
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || strings.HasPrefix(p, ".") {
			return "", unavailable("%s is not a key this store keeps", key)
		}
	}
	return filepath.Join(f.Root, filepath.FromSlash(key)), nil
}

func (f *Folder) Get(_ context.Context, key string) (*Object, error) {
	p, err := f.path(key)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	// There and unreadable is not absent (#171).
	if err != nil {
		return nil, unavailable("cannot read %s: %v", key, err)
	}
	return &Object{Data: data, ETag: SHA256Tag(data)}, nil
}

func (f *Folder) Put(_ context.Context, key string, data []byte, when Condition) (string, error) {
	p, err := f.path(key)
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", unavailable("cannot make %s: %v", dir, err)
	}
	lock, err := os.OpenFile(p+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return "", unavailable("cannot lock %s: %v", key, err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return "", unavailable("cannot lock %s: %v", key, err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	if !when.IsAlways() {
		current, err := os.ReadFile(p)
		there := err == nil
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return "", unavailable("cannot read %s: %v", key, err)
		}
		if when.IsAbsent() && there {
			return "", &ConflictError{key}
		}
		if tag, ok := when.Matching(); ok && (!there || SHA256Tag(current) != tag) {
			return "", &ConflictError{key}
		}
	}
	b := make([]byte, 8)
	rand.Read(b)
	tmp := filepath.Join(dir, "."+filepath.Base(p)+"."+hex.EncodeToString(b)+".tmp")
	if err := writeSynced(tmp, data); err != nil {
		os.Remove(tmp)
		return "", unavailable("cannot write %s: %v", key, err)
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return "", unavailable("cannot move %s into place: %v", key, err)
	}
	d, err := os.Open(dir)
	if err != nil {
		return "", unavailable("cannot sync the folder of %s: %v", key, err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return "", unavailable("cannot sync the folder of %s: %v", key, err)
	}
	return SHA256Tag(data), nil
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
	p, err := f.path(key)
	if err != nil {
		return err
	}
	os.Remove(p)
	os.Remove(p + ".lock")
	f.mu.Lock()
	delete(f.known, key)
	f.mu.Unlock()
	return nil
}

// List walks only the folder the prefix names (v1/clients/ walks v1/clients; v1/codes/ab
// walks v1/codes and keeps keys starting ab), reading a file again only if its stamp moved.
func (f *Folder) List(_ context.Context, prefix string) ([]Key, error) {
	dir := prefix
	if !strings.HasSuffix(prefix, "/") && prefix != "" {
		if i := strings.LastIndex(prefix, "/"); i >= 0 {
			dir = prefix[:i]
		} else {
			dir = ""
		}
	}
	start := filepath.Join(f.Root, filepath.FromSlash(strings.TrimSuffix(dir, "/")))
	var out []Key
	err := filepath.WalkDir(start, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return nil
		}
		name := d.Name()
		if path != start && strings.HasPrefix(name, ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || !d.Type().IsRegular() || strings.HasSuffix(name, ".lock") {
			return nil
		}
		rel, _ := filepath.Rel(f.Root, path)
		key := filepath.ToSlash(rel)
		if !strings.HasPrefix(key, prefix) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		st := stamped{size: info.Size(), mtime: info.ModTime()}
		if sys, ok := info.Sys().(*syscall.Stat_t); ok {
			st.ino = uint64(sys.Ino)
		}
		f.mu.Lock()
		held, ok := f.known[key]
		f.mu.Unlock()
		// A stamp changed within the clock's grain of now could change again unseen.
		if ok && held.ino == st.ino && held.size == st.size && held.mtime.Equal(st.mtime) && time.Since(st.mtime) > 2*time.Second {
			out = append(out, Key{key, held.etag})
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			// Listed all the same, with a tag that is no hash (#206).
			out = append(out, Key{key, `"unreadable"`})
			return nil
		}
		st.etag = SHA256Tag(data)
		f.mu.Lock()
		f.known[key] = st
		f.mu.Unlock()
		out = append(out, Key{key, st.etag})
		return nil
	})
	if err != nil {
		return nil, unavailable("cannot list %s: %v", prefix, err)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
