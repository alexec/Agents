package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// backupPlane is a backup store over a memory store, with hosts a and b of one owner.
func backupPlane(t *testing.T) (*backupStore, *store.Memory, string) {
	t.Helper()
	ctx := context.Background()
	st := store.NewMemory()
	r := records.New(st)
	settings, err := r.SettingsOrMake(ctx, func() records.Settings { return records.Settings{Name: "test"} })
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b"} {
		if err := r.SaveHost(ctx, records.MachineRecord{ID: id, Name: id}); err != nil {
			t.Fatal(err)
		}
	}
	b, err := newBackupStore(st, r, controllink.NewPrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	return b, st, *settings.Owner
}

func raw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// putBackup uploads a backup of parts and commits it, as a host does.
func putBackup(t *testing.T, b *backupStore, host, name string, parts [][]byte, keep int64) (wire.Backup, error) {
	t.Helper()
	var size int64
	for i, p := range parts {
		if _, err := b.said("backups/upload", host, raw(t, wire.BackupStorePart{Name: name, Part: int64(i), Data: p})); err != nil {
			return wire.Backup{}, err
		}
		size += int64(len(p))
	}
	at, _ := time.Parse(backupNameTime, name)
	out, err := b.said("backups/commit", host, raw(t, wire.BackupStoreCommit{Name: name, Parts: int64(len(parts)),
		Machine: host + "-machine", RootID: "root-" + host, MadeAt: wire.DateOf(at), Bytes: size, Agents: 2, Keep: keep}))
	if err != nil {
		return wire.Backup{}, err
	}
	return out.(wire.Backup), nil
}

func storedList(t *testing.T, b *backupStore, host string) []wire.Backup {
	t.Helper()
	out, err := b.said("backups/stored", host, raw(t, wire.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	return out.(wire.BackupStoreList).Backups
}

func TestBackupsGoUpInPartsAndComeBackOnAnotherHost(t *testing.T) {
	t.Parallel()
	b, st, owner := backupPlane(t)
	one, two := bytes.Repeat([]byte("transcript "), 1000), []byte("the last part")
	made, err := putBackup(t, b, "a", "20261020T120000Z", [][]byte{one, two}, 3)
	if err != nil {
		t.Fatal(err)
	}
	if made.ID != "a/20261020T120000Z" || !made.ThisMachine || made.RootID != "root-a" {
		t.Fatalf("made %+v", made)
	}
	// Under the owner's folder, and never in clear.
	keys, _ := st.List(context.Background(), backupsPrefix)
	for _, k := range keys {
		if !strings.HasPrefix(k.Key, backupsPrefix+owner+"/a/") {
			t.Fatalf("key %s is outside the owner's and the host's folder", k.Key)
		}
		o, _ := st.Get(context.Background(), k.Key)
		if strings.HasSuffix(k.Key, ".part") && bytes.Contains(o.Data, []byte("transcript")) {
			t.Fatalf("part %s is in clear", k.Key)
		}
	}
	// Host b, another machine of the same person, lists it as another's and reads it back.
	listed := storedList(t, b, "b")
	if len(listed) != 1 || listed[0].ThisMachine || listed[0].Machine != "a-machine" || listed[0].Bytes != int64(len(one)+len(two)) {
		t.Fatalf("b lists %+v", listed)
	}
	var back []byte
	for part := int64(0); part < 2; part++ {
		out, err := b.said("backups/download", "b", raw(t, wire.BackupStorePartRequest{ID: made.ID, Part: part}))
		if err != nil {
			t.Fatal(err)
		}
		back = append(back, out.(wire.BackupStorePart).Data...)
	}
	if !bytes.Equal(back, append(append([]byte{}, one...), two...)) {
		t.Fatal("the backup came back changed")
	}
	if _, err := b.said("backups/download", "b", raw(t, wire.BackupStorePartRequest{ID: made.ID, Part: 2})); err == nil {
		t.Fatal("a part past the last was given")
	}
	// A part moved to another key does not open: each is bound to its own.
	o, _ := st.Get(context.Background(), partKey(b.hostFolder(owner, "a"), "20261020T120000Z", 0))
	st.Put(context.Background(), partKey(b.hostFolder(owner, "a"), "20261020T120000Z", 1), o.Data, store.Always)
	if _, err := b.said("backups/download", "b", raw(t, wire.BackupStorePartRequest{ID: made.ID, Part: 1})); err == nil {
		t.Fatal("a part under another key opened")
	}
}

func TestBackupsRefuseWhatIsNotAHostsOwn(t *testing.T) {
	t.Parallel()
	b, _, _ := backupPlane(t)
	for _, bad := range []wire.BackupStorePart{
		{Name: "../b/20261020T120000Z", Part: 0, Data: []byte("x")},
		{Name: "20261020T120000Z", Part: -1, Data: []byte("x")},
		{Name: "20261020T120000Z", Part: backupPartsMost, Data: []byte("x")},
		{Name: "20261020T120000Z", Part: 0, Data: nil},
		{Name: "20261020T120000Z", Part: 0, Data: make([]byte, backupPartMost+1)},
	} {
		if _, err := b.said("backups/upload", "a", raw(t, bad)); err == nil {
			t.Fatalf("upload %q part %d of %d bytes was taken", bad.Name, bad.Part, len(bad.Data))
		}
	}
	// A commit with a part missing writes nothing.
	if _, err := putBackup(t, b, "a", "20261020T120000Z", nil, 3); err == nil {
		t.Fatal("a backup of no parts was committed")
	}
	b.said("backups/upload", "a", raw(t, wire.BackupStorePart{Name: "20261020T130000Z", Part: 1, Data: []byte("x")}))
	if _, err := b.said("backups/commit", "a", raw(t, wire.BackupStoreCommit{Name: "20261020T130000Z", Parts: 2, Keep: 3})); err == nil {
		t.Fatal("a backup with part 0 missing was committed")
	}
	if n := len(storedList(t, b, "a")); n != 0 {
		t.Fatalf("%d listed", n)
	}
	// A complete backup takes no more parts.
	if _, err := putBackup(t, b, "a", "20261020T140000Z", [][]byte{[]byte("x")}, 3); err != nil {
		t.Fatal(err)
	}
	if _, err := b.said("backups/upload", "a", raw(t, wire.BackupStorePart{Name: "20261020T140000Z", Part: 0, Data: []byte("y")})); err == nil {
		t.Fatal("a complete backup was written over")
	}
	if _, err := b.said("backups/download", "b", raw(t, wire.BackupStorePartRequest{ID: "../a/20261020T140000Z", Part: 0})); err == nil {
		t.Fatal("an id outside the owner's folder was read")
	}
}

func TestBackupsKeepTheNewestOfEachHost(t *testing.T) {
	t.Parallel()
	b, st, owner := backupPlane(t)
	b.now = func() time.Time { return time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC) }
	for _, name := range []string{"20261018T120000Z", "20261019T120000Z"} {
		if _, err := putBackup(t, b, "b", name, [][]byte{[]byte("b")}, 3); err != nil {
			t.Fatal(err)
		}
	}
	// A backup cut off two days ago, and one under way now.
	b.said("backups/upload", "a", raw(t, wire.BackupStorePart{Name: "20261018T000000Z", Part: 0, Data: []byte("cut off")}))
	b.said("backups/upload", "a", raw(t, wire.BackupStorePart{Name: "20261020T115900Z", Part: 0, Data: []byte("under way")}))
	for _, name := range []string{"20261019T010000Z", "20261019T020000Z", "20261019T030000Z"} {
		if _, err := putBackup(t, b, "a", name, [][]byte{[]byte("a")}, 2); err != nil {
			t.Fatal(err)
		}
	}
	var mine, others []string
	for _, l := range storedList(t, b, "a") {
		if l.ThisMachine {
			mine = append(mine, l.ID)
		} else {
			others = append(others, l.ID)
		}
	}
	if strings.Join(mine, " ") != "a/20261019T030000Z a/20261019T020000Z" || len(others) != 2 {
		t.Fatalf("kept %v and %v", mine, others)
	}
	keys, _ := st.List(context.Background(), b.hostFolder(owner, "a"))
	var names []string
	for _, k := range keys {
		names = append(names, strings.TrimPrefix(k.Key, b.hostFolder(owner, "a")))
	}
	got := strings.Join(names, " ")
	if strings.Contains(got, "20261019T010000Z") || strings.Contains(got, "20261018T000000Z") || !strings.Contains(got, "20261020T115900Z/00000.part") {
		t.Fatalf("a's folder holds %s", got)
	}
	// A removed host's backups stay while they are recent, so a new server can restore
	// them, and go once its newest is old.
	b.records.RemoveHost(context.Background(), "b")
	putBackup(t, b, "a", "20261019T040000Z", [][]byte{[]byte("a")}, 2)
	if n := len(storedList(t, b, "a")); n != 4 {
		t.Fatalf("%d listed with b removed a day ago", n)
	}
	b.now = func() time.Time { return time.Date(2027, 2, 1, 0, 0, 0, 0, time.UTC) }
	putBackup(t, b, "a", "20261019T050000Z", [][]byte{[]byte("a")}, 2)
	for _, l := range storedList(t, b, "a") {
		if !l.ThisMachine {
			t.Fatalf("removed b's old backup %s is kept", l.ID)
		}
	}
}

// #2293: when no host of an owner is left to back up, the sweep's daily pass still prunes
// their removed hosts' old backups and a cut-off backup's parts.
func TestTheSweepPrunesBackupsNoHostPrunes(t *testing.T) {
	t.Parallel()
	b, st, owner := backupPlane(t)
	b.now = func() time.Time { return time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC) }
	if _, err := putBackup(t, b, "b", "20261019T120000Z", [][]byte{[]byte("b")}, 3); err != nil {
		t.Fatal(err)
	}
	b.said("backups/upload", "a", raw(t, wire.BackupStorePart{Name: "20261018T000000Z", Part: 0, Data: []byte("cut off")}))
	b.records.RemoveHost(context.Background(), "a")
	b.records.RemoveHost(context.Background(), "b")
	// Recent: kept, for a new server to restore.
	if err := b.pruneOrphans(context.Background()); err != nil {
		t.Fatal(err)
	}
	if keys, _ := st.List(context.Background(), b.hostFolder(owner, "b")); len(keys) != 2 {
		t.Fatalf("b's recent backup went: %v", keys)
	}
	if keys, _ := st.List(context.Background(), b.hostFolder(owner, "a")); len(keys) != 0 {
		t.Fatalf("a's cut-off part stayed: %v", keys)
	}
	b.now = func() time.Time { return time.Date(2027, 2, 1, 0, 0, 0, 0, time.UTC) }
	b.pruneOrphans(context.Background())
	if keys, _ := st.List(context.Background(), backupsPrefix); len(keys) != 0 {
		t.Fatalf("left %v", keys)
	}
}
