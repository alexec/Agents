package store

// StoreConformanceTests.swift and the listing cases of StoreHousekeepingTests.swift,
// ported: every case runs on the memory and the folder stores.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var ctx = context.Background()

func each(t *testing.T, test func(t *testing.T, s Store)) {
	t.Run("memory", func(t *testing.T) { test(t, NewMemory()) })
	t.Run("folder", func(t *testing.T) { test(t, NewFolder(t.TempDir())) })
}

func TestCreateOnlyConflicts(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if _, err := s.Put(ctx, "v1/a.json", []byte("1"), Absent); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("2"), Absent); !IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
		o, _ := s.Get(ctx, "v1/a.json")
		if o == nil || string(o.Data) != "1" {
			t.Fatalf("got %v", o)
		}
	})
}

func TestAStaleMatchingConflicts(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		first, _ := s.Put(ctx, "v1/a.json", []byte("1"), Absent)
		second, err := s.Put(ctx, "v1/a.json", []byte("2"), Matching(first))
		if err != nil || second == first {
			t.Fatalf("second %q first %q err %v", second, first, err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("3"), Matching(first)); !IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
		o, _ := s.Get(ctx, "v1/a.json")
		if o.ETag != second || string(o.Data) != "2" {
			t.Fatalf("tag %q, want %q", o.ETag, second)
		}
	})
}

// Rule 8: an If-Match on a key that is gone is a conflict too.
func TestMatchingAGoneKeyConflicts(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		tag, _ := s.Put(ctx, "v1/a.json", []byte("1"), Absent)
		s.Delete(ctx, "v1/a.json")
		if _, err := s.Put(ctx, "v1/a.json", []byte("2"), Matching(tag)); !IsConflict(err) {
			t.Fatalf("want a conflict, got %v", err)
		}
		if o, err := s.Get(ctx, "v1/a.json"); o != nil || err != nil {
			t.Fatalf("got %v %v", o, err)
		}
	})
}

func TestAlwaysWritesOverAnything(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		s.Put(ctx, "v1/copies/a.json", []byte("1"), Always)
		tag, err := s.Put(ctx, "v1/copies/a.json", []byte("2"), Always)
		if err != nil || tag != SHA256Tag([]byte("2")) {
			t.Fatal(tag, err)
		}
	})
}

func TestListSeesNewKeys(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if l, _ := s.List(ctx, "v1/clients/"); len(l) != 0 {
			t.Fatalf("not empty: %v", l)
		}
		tag, _ := s.Put(ctx, "v1/clients/one.json", []byte("1"), Absent)
		s.Put(ctx, "v1/machines/mac.json", []byte("2"), Absent)
		l, err := s.List(ctx, "v1/clients/")
		if err != nil || len(l) != 1 || l[0] != (Key{"v1/clients/one.json", tag, 1}) {
			t.Fatalf("listed %v %v", l, err)
		}
		if l, _ := s.List(ctx, "v1/"); len(l) != 2 {
			t.Fatalf("listed %v", l)
		}
	})
}

func TestAPrefixInsideAFolderKeepsOnlyItsKeys(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		s.Put(ctx, "v1/codes/ab1.json", []byte("1"), Absent)
		s.Put(ctx, "v1/codes/cd2.json", []byte("2"), Absent)
		s.Put(ctx, "v1/control.json", []byte("3"), Absent)
		if got := keysOf(s, "v1/codes/ab"); !reflect.DeepEqual(got, []string{"v1/codes/ab1.json"}) {
			t.Fatal(got)
		}
		if got := keysOf(s, "v1/"); !reflect.DeepEqual(got, []string{"v1/codes/ab1.json", "v1/codes/cd2.json", "v1/control.json"}) {
			t.Fatal(got)
		}
		if got := keysOf(s, "v1/nothing/"); len(got) != 0 {
			t.Fatal(got)
		}
	})
}

func keysOf(s Store, prefix string) []string {
	l, _ := s.List(ctx, prefix)
	out := []string{}
	for _, k := range l {
		out = append(out, k.Key)
	}
	return out
}

// A spent code is written once however many copies race to use it.
func TestOneOfTwentyRacingCreatesWins(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		var wins atomic.Int32
		var wg sync.WaitGroup
		for n := range 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := s.Put(ctx, "v1/codes/x.spent", []byte(fmt.Sprint(n)), Absent); err == nil {
					wins.Add(1)
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 {
			t.Fatalf("%d winners", wins.Load())
		}
	})
}

// Racing If-Match writes from one version: exactly one wins.
func TestOneOfTwentyRacingUpdatesWins(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		first, _ := s.Put(ctx, "v1/a.json", []byte("0"), Absent)
		var wins atomic.Int32
		var wg sync.WaitGroup
		for n := range 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := s.Put(ctx, "v1/a.json", []byte(fmt.Sprint(n+1)), Matching(first)); err == nil {
					wins.Add(1)
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 {
			t.Fatalf("%d winners", wins.Load())
		}
	})
}

func TestTheProbePassesAndLeavesNothing(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if err := Probe(ctx, s, "test"); err != nil {
			t.Fatal(err)
		}
		if got := keysOf(s, "probe/"); len(got) != 0 {
			t.Fatal(got)
		}
	})
}

type careless struct{ *Memory }

func (c careless) Put(ctx context.Context, key string, data []byte, _ Condition) (string, error) {
	return c.Memory.Put(ctx, key, append(data, []byte(randomHex(4))...), Always)
}

func TestTheProbeRefusesAStoreThatIgnoresConditions(t *testing.T) {
	if err := Probe(ctx, careless{NewMemory()}, "test"); err == nil {
		t.Fatal("the probe let a careless store through")
	}
}

func TestADownStoreIsUnavailable(t *testing.T) {
	m := NewMemory()
	m.SetDown(true)
	var u *UnavailableError
	if _, err := m.Get(ctx, "v1/a.json"); !errors.As(err, &u) {
		t.Fatal(err)
	}
}

// The folder store's files are the Swift store's: the same paths and the same tags, so
// either reads the other's folder.
func TestTheFolderIsTheSwiftLayout(t *testing.T) {
	root := t.TempDir()
	f := NewFolder(root)
	tag, _ := f.Put(ctx, "v1/a.json", []byte("hello"), Absent)
	if tag != `"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"` {
		t.Fatal(tag)
	}
	data, err := os.ReadFile(filepath.Join(root, "v1", "a.json"))
	if err != nil || string(data) != "hello" {
		t.Fatal(string(data), err)
	}
	// A file another writer put there is read with its hash as its tag.
	os.MkdirAll(filepath.Join(root, "v1", "machines"), 0o700)
	os.WriteFile(filepath.Join(root, "v1", "machines", "mac.json"), []byte("hello"), 0o600)
	o, _ := f.Get(ctx, "v1/machines/mac.json")
	if o == nil || o.ETag != tag {
		t.Fatal(o)
	}
}

func TestAKeyOutsideTheFolderIsRefused(t *testing.T) {
	f := NewFolder(t.TempDir())
	for _, key := range []string{"", "/etc/passwd", "v1/../x", "v1//x", "v1/.hidden", "./x"} {
		if _, err := f.Put(ctx, key, []byte("x"), Always); err == nil {
			t.Fatalf("%q was written", key)
		}
	}
}

// StoreHousekeepingTests.onlyChangedRecordsAreReadAgain.
func TestOnlyChangedRecordsAreReadAgain(t *testing.T) {
	root := t.TempDir()
	writer := NewFolder(root)
	for n := range 40 {
		writer.Put(ctx, fmt.Sprintf("v1/clients/%02d.json", n), []byte(fmt.Sprint(n)), Absent)
	}
	// Elsewhere in the store, never read by a listing of clients.
	for n := range 30 {
		writer.Put(ctx, fmt.Sprintf("v1/events/2026-01-01/%d.json", n), []byte("{}"), Absent)
	}
	if writer.HashedByListing() != 0 {
		t.Fatal(writer.HashedByListing())
	}

	// Another copy on the same folder reads each record once.
	reader := NewFolder(root)
	first, _ := reader.List(ctx, "v1/clients/")
	if len(first) != 40 || reader.HashedByListing() != 40 {
		t.Fatal(len(first), reader.HashedByListing())
	}
	for _, e := range first[:3] {
		if o, _ := reader.Get(ctx, e.Key); o.ETag != e.ETag {
			t.Fatal(e)
		}
	}

	// Again, unchanged: nothing read, whether the folder has settled or not.
	reader.List(ctx, "v1/clients/")
	then := time.Now().Add(-time.Minute)
	os.Chtimes(filepath.Join(root, "v1", "clients"), then, then)
	reader.List(ctx, "v1/clients/")
	reader.List(ctx, "v1/clients/")
	if reader.HashedByListing() != 40 {
		t.Fatal(reader.HashedByListing())
	}

	// One changed by the other copy: that one alone, with its new tag.
	key := "v1/clients/05.json"
	held, _ := writer.Get(ctx, key)
	tag, err := writer.Put(ctx, key, []byte("renamed"), Matching(held.ETag))
	if err != nil {
		t.Fatal(err)
	}
	after, _ := reader.List(ctx, "v1/clients/")
	if reader.HashedByListing() != 41 || after[5] != (Key{key, tag, int64(len("renamed"))}) {
		t.Fatal(reader.HashedByListing(), after[5])
	}

	// One deleted: gone from the listing, and nothing read for it.
	writer.Delete(ctx, "v1/clients/00.json")
	fewer, _ := reader.List(ctx, "v1/clients/")
	if len(fewer) != 39 || reader.HashedByListing() != 41 {
		t.Fatal(len(fewer), reader.HashedByListing())
	}
}

// #206: a file there and unreadable is listed with a tag that is no hash, and reading
// it is unavailable, not absent.
func TestAnUnreadableFileIsListedNotDropped(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads every file")
	}
	root := t.TempDir()
	f := NewFolder(root)
	f.Put(ctx, "v1/clients/a.json", []byte("1"), Absent)
	p := filepath.Join(root, "v1", "clients", "a.json")
	os.Chmod(p, 0)
	defer os.Chmod(p, 0o600)
	l, _ := NewFolder(root).List(ctx, "v1/clients/")
	if len(l) != 1 || l[0].ETag[:12] != `"unreadable-` {
		t.Fatal(l)
	}
	if o, err := f.Get(ctx, "v1/clients/a.json"); o != nil || err == nil {
		t.Fatal(o, err)
	}
	if _, err := f.Put(ctx, "v1/clients/a.json", []byte("2"), Absent); IsConflict(err) || err == nil {
		t.Fatal(err)
	}
}

func TestLeftoversGoAndLiveFilesStay(t *testing.T) {
	root := t.TempDir()
	f := NewFolder(root)
	f.Put(ctx, "v1/clients/a.json", []byte("1"), Absent)
	old := time.Now().Add(-2 * time.Hour)
	leftovers := []string{"v1/clients/.b.json.1234.tmp", "probe/x-1", "v1/clients/gone.json.lock"}
	for _, l := range leftovers {
		p := filepath.Join(root, filepath.FromSlash(l))
		os.MkdirAll(filepath.Dir(p), 0o700)
		os.WriteFile(p, nil, 0o600)
		os.Chtimes(p, old, old)
	}
	for _, l := range []string{"v1/clients/a.json", "v1/clients/a.json.lock"} {
		os.Chtimes(filepath.Join(root, filepath.FromSlash(l)), old, old)
	}
	if n := f.RemoveLeftovers(time.Now().Add(-time.Hour)); n != 3 {
		t.Fatal(n)
	}
	for _, l := range leftovers {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(l))); err == nil {
			t.Fatal(l, "is still there")
		}
	}
	if o, _ := f.Get(ctx, "v1/clients/a.json"); o == nil {
		t.Fatal("the record went")
	}
	if _, err := os.Stat(filepath.Join(root, "v1", "clients", "a.json.lock")); err != nil {
		t.Fatal("a record's lock went")
	}
}

// #2293: a key's folder goes with its last key, up to the root, so an hour's folder of
// usage does not stay for ever; a folder with another key stays.
func TestAFolderGoesWithItsLastKey(t *testing.T) {
	root := t.TempDir()
	f := NewFolder(root)
	f.Put(ctx, "v1/usage/hours/2026-10-21T10/a.json", []byte("{}"), Absent)
	f.Put(ctx, "v1/usage/hours/2026-10-21T11/a.json", []byte("{}"), Absent)
	f.Put(ctx, "v1/usage/hours/2026-10-21T11/b.json", []byte("{}"), Absent)
	f.Delete(ctx, "v1/usage/hours/2026-10-21T10/a.json")
	if _, err := os.Stat(filepath.Join(root, "v1/usage/hours/2026-10-21T10")); !os.IsNotExist(err) {
		t.Fatal("the empty hour's folder stayed")
	}
	f.Delete(ctx, "v1/usage/hours/2026-10-21T11/a.json")
	if _, err := os.Stat(filepath.Join(root, "v1/usage/hours/2026-10-21T11/b.json")); err != nil {
		t.Fatal("a folder with a key went")
	}
	f.Delete(ctx, "v1/usage/hours/2026-10-21T11/b.json")
	if _, err := os.Stat(filepath.Join(root, "v1")); !os.IsNotExist(err) {
		t.Fatal("the empty folders above stayed")
	}
	if _, err := os.Stat(root); err != nil {
		t.Fatal("the root went")
	}
}

// Writes into a folder while its last key is deleted all land.
func TestWritesRaceTheFolderGoing(t *testing.T) {
	f := NewFolder(t.TempDir())
	var wg sync.WaitGroup
	errs := make(chan error, 400)
	for n := range 200 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			key := fmt.Sprintf("v1/h/%d/a.json", n%5)
			if _, err := f.Put(ctx, key, []byte("{}"), Always); err != nil {
				errs <- err
			}
		}()
		go func() {
			defer wg.Done()
			f.Delete(ctx, fmt.Sprintf("v1/h/%d/b.json", n%5))
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}
