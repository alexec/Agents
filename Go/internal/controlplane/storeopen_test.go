package controlplane

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/s3store"
	"github.com/alexec/agents/Go/internal/controlplane/s3store/s3fake"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A store of a build before #2316 keeps machines in v1/hosts: it opens with them (#2662).
func TestAnOldStoreOpensWithItsMachines(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	root := t.TempDir()
	// A real record, where a build before #2316 kept it.
	if err := records.New(store.NewFolder(root)).SaveHost(ctx, records.MachineRecord{ID: "mac", Name: "Mac"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(root, "v1", "machines"), filepath.Join(root, "v1", "hosts")); err != nil {
		t.Fatal(err)
	}
	st, err := OpenStore("file://"+root+"/", os.Getenv, nil)
	if err != nil {
		t.Fatal(err)
	}
	r := records.New(st)
	if err := r.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if r.Host("mac") == nil {
		t.Fatal("machine mac is not listed", r.Hosts())
	}
	if _, err := os.Stat(filepath.Join(root, "v1", "hosts")); !os.IsNotExist(err) {
		t.Fatal("v1/hosts is still there", err)
	}
}

// A store with both folders, as a rolling handover leaves when an old copy writes a
// machine after the move (H20261027-3), gets the old one's machines too. A machine in
// both keeps its v1/machines record.
func TestAStoreWithBothMachineFoldersGetsTheOldMachines(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	root := t.TempDir()
	folder := store.NewFolder(root)
	folder.Put(ctx, "v1/hosts/old.json", []byte("old"), store.Absent)
	folder.Put(ctx, "v1/hosts/mac.json", []byte("stale"), store.Absent)
	folder.Put(ctx, "v1/machines/mac.json", []byte("new"), store.Absent)
	st, err := OpenStore("file://"+root+"/", os.Getenv, nil)
	if err != nil {
		t.Fatal(err)
	}
	if o, _ := st.Get(ctx, "v1/machines/old.json"); o == nil || string(o.Data) != "old" {
		t.Fatal("machine old did not land in v1/machines", o)
	}
	if o, _ := st.Get(ctx, "v1/machines/mac.json"); o == nil || string(o.Data) != "new" {
		t.Fatal("machine mac was overwritten", o)
	}
	if left, _ := st.List(ctx, records.OldMachinesPrefix); len(left) != 0 {
		t.Fatal("v1/hosts still has", left)
	}
}

// oldBucket is a bucket of a build before #2316, with machine mac under v1/hosts, and
// the environment that opens it.
func oldBucket(t *testing.T) (string, func(string) string) {
	t.Helper()
	ctx := context.Background()
	server := httptest.NewServer(s3fake.New("test"))
	t.Cleanup(server.Close)
	env := map[string]string{
		"AGENTS_STORE_ENDPOINT":   server.URL,
		"AGENTS_STORE_PATH_STYLE": "1",
		"AWS_ACCESS_KEY_ID":       "test",
		"AWS_SECRET_ACCESS_KEY":   "secret",
	}
	get := func(k string) string { return env[k] }
	const text = "s3://test/conf"
	bucket, err := s3store.Open(text, get)
	if err != nil {
		t.Fatal(err)
	}
	// A real record, where a build before #2316 kept it.
	memory := store.NewMemory()
	if err := records.New(memory).SaveHost(ctx, records.MachineRecord{ID: "mac", Name: "Mac"}); err != nil {
		t.Fatal(err)
	}
	record, _ := memory.Get(ctx, records.MachinesPrefix+"mac.json")
	if _, err := bucket.Put(ctx, records.OldMachinesPrefix+"mac.json", record.Data, store.Absent); err != nil {
		t.Fatal(err)
	}
	return text, get
}

// A bucket of a build before #2316 opens with its machines (H20261027-1).
func TestAnOldBucketOpensWithItsMachines(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	text, env := oldBucket(t)
	st, err := OpenStore(text, env, nil)
	if err != nil {
		t.Fatal(err)
	}
	r := records.New(st)
	if err := r.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if r.Host("mac") == nil {
		t.Fatal("machine mac is not listed", r.Hosts())
	}
	if left, _ := st.List(ctx, records.OldMachinesPrefix); len(left) != 0 {
		t.Fatal("v1/hosts still has", left)
	}
}

// Copies that open one old bucket at the same time all open, and the machine is moved
// once: each write is create-only.
func TestCopiesOpeningAnOldBucketTogetherAllOpen(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	text, env := oldBucket(t)
	var wg sync.WaitGroup
	errs := make([]error, 8)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = OpenStore(text, env, nil)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	st, _ := OpenStore(text, env, nil)
	if keys, _ := st.List(ctx, records.MachinesPrefix); len(keys) != 1 {
		t.Fatal("v1/machines has", keys)
	}
	if left, _ := st.List(ctx, records.OldMachinesPrefix); len(left) != 0 {
		t.Fatal("v1/hosts still has", left)
	}
}

// A copy of an old store, as a restore of an old backup makes, puts its machines in
// v1/machines (#2662).
func TestACopyOfAnOldStoreMovesItsMachines(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	from, to := store.NewFolder(t.TempDir()), store.NewFolder(t.TempDir())
	from.Put(ctx, "v1/hosts/mac.json", []byte("mac"), store.Absent)
	if copied, _, err := BackupStore(ctx, from, to); err != nil || copied != 1 {
		t.Fatal(copied, err)
	}
	if o, _ := to.Get(ctx, "v1/machines/mac.json"); o == nil || string(o.Data) != "mac" {
		t.Fatal("the machine did not land in v1/machines")
	}
	if o, _ := to.Get(ctx, "v1/hosts/mac.json"); o != nil {
		t.Fatal("the machine landed in v1/hosts")
	}
}
