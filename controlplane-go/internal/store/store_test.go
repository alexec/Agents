package store

// StoreConformanceTests.swift, ported: the memory and folder stores always, and a bucket
// when AGENTS_TEST_S3 names one (./minio.sh up; eval "$(./minio.sh env)").

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func kinds(t *testing.T) map[string]func() Store {
	k := map[string]func() Store{
		"memory": func() Store { return NewMemory() },
		"folder": func() Store { return NewFolder(t.TempDir()) },
	}
	if addr := os.Getenv("AGENTS_TEST_S3"); addr != "" {
		k["bucket"] = func() Store {
			b := make([]byte, 4)
			rand.Read(b)
			s, err := Open(context.Background(), strings.TrimSuffix(addr, "/")+"/conf-"+hex.EncodeToString(b))
			if err != nil {
				t.Fatal(err)
			}
			return s
		}
	}
	return k
}

func each(t *testing.T, test func(t *testing.T, s Store)) {
	for name, make := range kinds(t) {
		t.Run(name, func(t *testing.T) { test(t, make()) })
	}
}

var ctx = context.Background()

func TestCreateOnlyConflicts(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if _, err := s.Put(ctx, "v1/a.json", []byte("1"), Absent); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Put(ctx, "v1/a.json", []byte("2"), Absent); !IsConflict(err) {
			t.Fatalf("want conflict, got %v", err)
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
			t.Fatalf("want conflict, got %v", err)
		}
		o, _ := s.Get(ctx, "v1/a.json")
		if o.ETag != second {
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
			t.Fatalf("want conflict, got %v", err)
		}
	})
}

func TestListSeesNewKeys(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if l, _ := s.List(ctx, "v1/clients/"); len(l) != 0 {
			t.Fatalf("not empty: %v", l)
		}
		tag, _ := s.Put(ctx, "v1/clients/one.json", []byte("1"), Absent)
		s.Put(ctx, "v1/hosts/mac.json", []byte("2"), Absent)
		l, err := s.List(ctx, "v1/clients/")
		if err != nil || len(l) != 1 || l[0] != (Key{"v1/clients/one.json", tag}) {
			t.Fatalf("listed %v %v", l, err)
		}
		if l, _ := s.List(ctx, "v1/"); len(l) != 2 {
			t.Fatalf("listed %v", l)
		}
	})
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

func TestTheProbePasses(t *testing.T) {
	each(t, func(t *testing.T, s Store) {
		if err := Probe(ctx, s, "test"); err != nil {
			t.Fatal(err)
		}
	})
}

type careless struct{ Memory }

func (c *careless) Put(_ context.Context, key string, data []byte, _ Condition) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	b := make([]byte, 8)
	rand.Read(b)
	tag := hex.EncodeToString(b)
	c.objects[key] = Object{data, tag}
	return tag, nil
}

func TestTheProbeRefusesAStoreThatIgnoresConditions(t *testing.T) {
	c := &careless{Memory{objects: map[string]Object{}}}
	if err := Probe(ctx, c, "test"); err == nil {
		t.Fatal("the probe let a careless store through")
	}
}

// The folder store's files are the Swift store's: same paths, same tags.
func TestFolderTagIsSHA256(t *testing.T) {
	f := NewFolder(t.TempDir())
	tag, _ := f.Put(ctx, "v1/a.json", []byte("hello"), Absent)
	if tag != `"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"` {
		t.Fatal(tag)
	}
}
