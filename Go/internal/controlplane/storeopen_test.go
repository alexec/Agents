package controlplane

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/records"
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

// A store with both folders is left as it is.
func TestAStoreWithBothMachineFoldersIsLeft(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	root := t.TempDir()
	folder := store.NewFolder(root)
	folder.Put(ctx, "v1/hosts/old.json", []byte("old"), store.Absent)
	folder.Put(ctx, "v1/machines/mac.json", []byte("new"), store.Absent)
	if _, err := OpenStore("file://"+root+"/", os.Getenv, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "v1", "hosts", "old.json")); err != nil {
		t.Fatal("v1/hosts moved", err)
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
