package controlplane

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Backups of servers in the control plane's store (#1815). A server is the only copy of
// its agents and transcripts, and a cloud machine that is deleted takes them with it, so
// it backs up here: the organisation's folder or bucket, under its owner's prefix. A
// backup can be hundreds of MB, so it comes in parts, one JSON-RPC call each:
//
//	v1/backups/<owner>/<host>/<name>/<part>.part   at most backupPartMost bytes, sealed
//	v1/backups/<owner>/<host>/<name>.json          written last, once every part is there
//
// A host writes only in its own folder: the control plane names the folder from the
// host's proof, the host only the backup's name. A list reads only the .json files. Every
// host of the same owner lists and restores every backup of the owner's, so a new server
// restores a deleted one's.
//
// The store holds no transcript in clear: each part is sealed with AES-256-GCM, under the
// backups' own random key, bound to the part's own key in the store. That key is kept at
// v1/backups.key, sealed with the control key (which a cloud control plane keeps sealed
// by its KMS), so a store copy and a store backup carry it. A rotation of the control key
// seals it again with the new key (H20261031-1): it never seals a part, so no part has to
// be sealed again. A part from before it was sealed with a key made from the control key,
// and still opens with the current or the previous one.
//
// Bounded: the newest Keep of each host's (1–10, the host's own setting), parts left by a
// backup cut off are deleted after a day, and the backups of a host that was removed go
// once its newest is backupOrphanAge old.

const (
	backupsPrefix   = "v1/backups/"
	backupPartMost  = 8 << 20
	backupPartsMost = 1024
	backupKeepMost  = 10
	backupOrphanAge = 90 * 24 * time.Hour
	backupStrayAge  = 24 * time.Hour
	backupNameTime  = "20060102T150405Z"
	backupKeyInfo   = "agents backups v1"
	backupDataKey   = "v1/backups.key"
	backupDataInfo  = "agents backups data key v1"
)

var backupName = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z$`)

// storedBackup is a backup's .json in the store.
type storedBackup struct {
	Host    string    `json:"host"`
	Name    string    `json:"name"`
	Parts   int64     `json:"parts"`
	Machine string    `json:"machine"`
	RootID  string    `json:"rootID"`
	MadeAt  wire.Date `json:"madeAt"`
	Bytes   int64     `json:"bytes"`
	Agents  int64     `json:"agents"`
}

type backupStore struct {
	store   store.Store
	records *records.Records
	keys    func() controlKeys
	now     func() time.Time
	sealMu  sync.Mutex
	seal    cipher.AEAD // the backups' key, once read or made
}

// storedDataKey is v1/backups.key: the backups' key, sealed with the current control key
// and, for previousKeyKept after a rotation, with the previous one.
type storedDataKey struct {
	Sealed []sealedDataKey `json:"sealed"`
}

type sealedDataKey struct {
	ControlKey []byte `json:"controlKey"` // the public key whose private key seals it
	Data       []byte `json:"data"`
}

func newBackupStore(s store.Store, r *records.Records, keys func() controlKeys) *backupStore {
	return &backupStore{store: s, records: r, keys: keys, now: time.Now}
}

// sealWith is AES-256-GCM under a key made from secret for info.
func sealWith(secret []byte, info string) (cipher.AEAD, error) {
	key, err := hkdf.Key(sha256.New, secret, nil, info, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// dataKey is the backups' key: read from the store, or made when there is none and create
// is set (else nil). It is sealed again with the current control key when it is not yet,
// and only the seals of the current and the previous control keys are kept.
func (b *backupStore) dataKey(ctx context.Context, create bool) (cipher.AEAD, error) {
	b.sealMu.Lock()
	defer b.sealMu.Unlock()
	if b.seal != nil {
		return b.seal, nil
	}
	keys := b.keys()
	for range 3 {
		o, err := b.store.Get(ctx, backupDataKey)
		if err != nil {
			return nil, err
		}
		var (
			key  []byte
			held storedDataKey
			when = store.Absent
		)
		if o == nil {
			if !create {
				return nil, nil
			}
			key = make32()
		} else {
			if err := json.Unmarshal(o.Data, &held); err != nil {
				return nil, fmt.Errorf("the backups' key is unreadable: %w", err)
			}
			if key = openDataKey(held, keys); key == nil {
				return nil, errors.New("the backups' key opens with neither this control plane's key nor the previous one")
			}
			when = store.Matching(o.ETag)
		}
		if next, changed, err := sealDataKey(held, key, keys); err != nil {
			return nil, err
		} else if changed {
			data, _ := json.MarshalIndent(next, "", "  ")
			if _, err := b.store.Put(ctx, backupDataKey, data, when); store.IsConflict(err) {
				continue
			} else if err != nil {
				return nil, err
			}
		}
		seal, err := sealWith(key, backupDataInfo)
		if err != nil {
			return nil, err
		}
		b.seal = seal
		return seal, nil
	}
	return nil, errors.New("the backups' key kept changing under this copy")
}

// keepDataKey seals the backups' key with the control key as it is now, after a
// rotation or at start. A store with no backups' key yet is left without one.
func (b *backupStore) keepDataKey(ctx context.Context) error {
	b.sealMu.Lock()
	b.seal = nil
	b.sealMu.Unlock()
	_, err := b.dataKey(ctx, false)
	return err
}

func make32() []byte {
	key := make([]byte, 32)
	rand.Read(key)
	return key
}

// dataKeyAD binds a seal of the backups' key to its place and to the control key.
func dataKeyAD(public []byte) []byte { return append([]byte(backupDataKey+"\x00"), public...) }

// openDataKey opens the backups' key with the current control key, else the previous one.
func openDataKey(held storedDataKey, keys controlKeys) []byte {
	for _, k := range [][2][]byte{{keys.private, keys.public}, {keys.previousPrivate, keys.previousPublic}} {
		if k[0] == nil {
			continue
		}
		seal, err := sealWith(k[0], backupDataInfo)
		if err != nil {
			continue
		}
		for _, s := range held.Sealed {
			if !bytes.Equal(s.ControlKey, k[1]) || len(s.Data) < seal.NonceSize() {
				continue
			}
			n := seal.NonceSize()
			if key, err := seal.Open(nil, s.Data[:n], s.Data[n:], dataKeyAD(k[1])); err == nil {
				return key
			}
		}
	}
	return nil
}

// sealDataKey is held with key sealed by the current control key, and with only the seals
// of the current and the previous keys. changed says it differs from held.
func sealDataKey(held storedDataKey, key []byte, keys controlKeys) (storedDataKey, bool, error) {
	next := storedDataKey{}
	for _, s := range held.Sealed {
		if bytes.Equal(s.ControlKey, keys.public) {
			next.Sealed = append([]sealedDataKey{s}, next.Sealed...)
		} else if keys.previousPublic != nil && bytes.Equal(s.ControlKey, keys.previousPublic) {
			next.Sealed = append(next.Sealed, s)
		}
	}
	if len(next.Sealed) == 0 || !bytes.Equal(next.Sealed[0].ControlKey, keys.public) {
		seal, err := sealWith(keys.private, backupDataInfo)
		if err != nil {
			return held, false, err
		}
		nonce := make([]byte, seal.NonceSize())
		rand.Read(nonce)
		mine := sealedDataKey{ControlKey: keys.public, Data: seal.Seal(nonce, nonce, key, dataKeyAD(keys.public))}
		next.Sealed = append([]sealedDataKey{mine}, next.Sealed...)
	}
	changed := len(next.Sealed) != len(held.Sealed) || !bytes.Equal(next.Sealed[0].ControlKey, held.Sealed[0].ControlKey)
	return next, changed, nil
}

// owner is the folder of the host's owner: the host's record's, else the control plane's.
func (b *backupStore) owner(host string) (string, error) {
	if h := b.records.Host(host); h != nil && h.Owner != nil && *h.Owner != "" {
		return *h.Owner, nil
	}
	if s := b.records.Settings(); s != nil && s.Owner != nil && *s.Owner != "" {
		return *s.Owner, nil
	}
	return "", fail(notPermitted, "This control plane has no owner yet, so it keeps no backups.")
}

func (b *backupStore) hostFolder(owner, host string) string {
	return backupsPrefix + owner + "/" + host + "/"
}

func partKey(folder, name string, part int64) string {
	return fmt.Sprintf("%s%s/%05d.part", folder, name, part)
}

func (b *backupStore) said(method string, host string, params json.RawMessage) (any, error) {
	ctx := context.Background()
	owner, err := b.owner(host)
	if err != nil {
		return nil, err
	}
	if !backupFolderName(host) || !backupFolderName(owner) {
		return nil, fail(notPermitted, "This host's id can't name a folder of the store.")
	}
	switch method {
	case "backups/stored":
		return b.list(ctx, owner, host)
	case "backups/upload":
		p, err := require[wire.BackupStorePart](params, "BackupStorePart")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, b.upload(ctx, owner, host, p)
	case "backups/commit":
		c, err := require[wire.BackupStoreCommit](params, "BackupStoreCommit")
		if err != nil {
			return nil, err
		}
		return b.commit(ctx, owner, host, c)
	case "backups/download":
		r, err := require[wire.BackupStorePartRequest](params, "BackupStorePartRequest")
		if err != nil {
			return nil, err
		}
		return b.download(ctx, owner, r)
	}
	return nil, notFound(method)
}

func (b *backupStore) upload(ctx context.Context, owner, host string, p wire.BackupStorePart) error {
	if !backupName.MatchString(p.Name) {
		return fail(invalidParams, "%q is not a backup's name.", p.Name)
	}
	if p.Part < 0 || p.Part >= backupPartsMost {
		return fail(invalidParams, "A backup has at most %d parts.", backupPartsMost)
	}
	if len(p.Data) == 0 || len(p.Data) > backupPartMost {
		return fail(invalidParams, "A part is 1 byte to %d MiB.", backupPartMost>>20)
	}
	folder := b.hostFolder(owner, host)
	if o, err := b.store.Get(ctx, folder+p.Name+".json"); err != nil {
		return err
	} else if o != nil {
		return fail(invalidParams, "The backup %s is complete already.", p.Name)
	}
	seal, err := b.dataKey(ctx, true)
	if err != nil {
		return err
	}
	key := partKey(folder, p.Name, p.Part)
	nonce := make([]byte, seal.NonceSize())
	rand.Read(nonce)
	_, err = b.store.Put(ctx, key, seal.Seal(nonce, nonce, p.Data, []byte(key)), store.Always)
	return err
}

// openPart opens a part with the backups' key, else, for a part from before it, with the
// key made from the current control key or the previous one.
func (b *backupStore) openPart(ctx context.Context, key string, sealed []byte) ([]byte, error) {
	seals := []cipher.AEAD{}
	if seal, err := b.dataKey(ctx, false); err == nil && seal != nil {
		seals = append(seals, seal)
	}
	keys := b.keys()
	for _, control := range [][]byte{keys.private, keys.previousPrivate} {
		if control == nil {
			continue
		}
		if seal, err := sealWith(control, backupKeyInfo); err == nil {
			seals = append(seals, seal)
		}
	}
	for _, seal := range seals {
		n := seal.NonceSize()
		if len(sealed) < n {
			continue
		}
		if data, err := seal.Open(nil, sealed[:n], sealed[n:], []byte(key)); err == nil {
			return data, nil
		}
	}
	return nil, errors.New("no key opens it")
}

// commit writes the backup's .json once every part is there, then keeps the newest keep
// of this host's backups.
func (b *backupStore) commit(ctx context.Context, owner, host string, c wire.BackupStoreCommit) (wire.Backup, error) {
	if !backupName.MatchString(c.Name) {
		return wire.Backup{}, fail(invalidParams, "%q is not a backup's name.", c.Name)
	}
	if c.Parts < 1 || c.Parts > backupPartsMost {
		return wire.Backup{}, fail(invalidParams, "A backup has 1 to %d parts.", backupPartsMost)
	}
	if c.Keep < 1 || c.Keep > backupKeepMost {
		return wire.Backup{}, fail(invalidParams, "Keep 1 to %d backups.", backupKeepMost)
	}
	folder := b.hostFolder(owner, host)
	keys, err := b.store.List(ctx, folder+c.Name+"/")
	if err != nil {
		return wire.Backup{}, err
	}
	there := map[string]bool{}
	for _, k := range keys {
		there[k.Key] = true
	}
	for part := range c.Parts {
		if !there[partKey(folder, c.Name, part)] {
			return wire.Backup{}, fail(invalidParams, "Part %d of the backup %s is not here.", part, c.Name)
		}
	}
	record := storedBackup{Host: host, Name: c.Name, Parts: c.Parts, Machine: c.Machine, RootID: c.RootID,
		MadeAt: c.MadeAt, Bytes: c.Bytes, Agents: c.Agents}
	data, _ := json.MarshalIndent(record, "", "  ")
	if _, err := b.store.Put(ctx, folder+c.Name+".json", data, store.Absent); err != nil && !store.IsConflict(err) {
		return wire.Backup{}, err
	}
	b.prune(ctx, owner, host, c.Keep)
	return record.wire(host), nil
}

func (r storedBackup) wire(caller string) wire.Backup {
	return wire.Backup{ID: r.Host + "/" + r.Name, Machine: r.Machine, RootID: r.RootID, MadeAt: r.MadeAt, Bytes: r.Bytes,
		Agents: r.Agents, ThisMachine: r.Host == caller}
}

// hostBackups is one host's folder: its backups' names (those with a .json), and the
// keys of the parts of each name.
type hostBackups struct {
	complete []string
	parts    map[string][]string
}

func (b *backupStore) scan(ctx context.Context, owner string) (map[string]*hostBackups, error) {
	prefix := backupsPrefix + owner + "/"
	keys, err := b.store.List(ctx, prefix)
	if err != nil {
		return nil, err
	}
	out := map[string]*hostBackups{}
	for _, k := range keys {
		rest := strings.TrimPrefix(k.Key, prefix)
		host, rest, ok := strings.Cut(rest, "/")
		if !ok {
			continue
		}
		h := out[host]
		if h == nil {
			h = &hostBackups{parts: map[string][]string{}}
			out[host] = h
		}
		if name, ok := strings.CutSuffix(rest, ".json"); ok && backupName.MatchString(name) {
			h.complete = append(h.complete, name)
		} else if name, _, ok := strings.Cut(rest, "/"); ok && backupName.MatchString(name) {
			h.parts[name] = append(h.parts[name], k.Key)
		}
	}
	for _, h := range out {
		sort.Strings(h.complete)
	}
	return out, nil
}

// list is every complete backup of the owner's machines, newest first.
func (b *backupStore) list(ctx context.Context, owner, caller string) (wire.BackupStoreList, error) {
	out := wire.BackupStoreList{Backups: []wire.Backup{}}
	hosts, err := b.scan(ctx, owner)
	if err != nil {
		return out, err
	}
	for host, h := range hosts {
		for _, name := range h.complete {
			if r, ok := b.read(ctx, b.hostFolder(owner, host)+name+".json"); ok {
				out.Backups = append(out.Backups, r.wire(caller))
			}
		}
	}
	sort.Slice(out.Backups, func(i, j int) bool {
		if out.Backups[i].MadeAt != out.Backups[j].MadeAt {
			return out.Backups[i].MadeAt > out.Backups[j].MadeAt
		}
		return out.Backups[i].ID > out.Backups[j].ID
	})
	return out, nil
}

func (b *backupStore) read(ctx context.Context, key string) (storedBackup, bool) {
	o, err := b.store.Get(ctx, key)
	if err != nil || o == nil {
		return storedBackup{}, false
	}
	var r storedBackup
	if json.Unmarshal(o.Data, &r) != nil || r.Parts < 1 || r.Parts > backupPartsMost {
		return storedBackup{}, false
	}
	return r, true
}

func (b *backupStore) download(ctx context.Context, owner string, r wire.BackupStorePartRequest) (wire.BackupStorePart, error) {
	host, name, ok := strings.Cut(r.ID, "/")
	if !ok || !backupName.MatchString(name) || !backupFolderName(host) {
		return wire.BackupStorePart{}, fail(invalidParams, "There is no backup %s.", r.ID)
	}
	folder := b.hostFolder(owner, host)
	record, ok := b.read(ctx, folder+name+".json")
	if !ok {
		return wire.BackupStorePart{}, fail(invalidParams, "There is no backup %s.", r.ID)
	}
	if r.Part < 0 || r.Part >= record.Parts {
		return wire.BackupStorePart{}, fail(invalidParams, "The backup %s has %d parts.", r.ID, record.Parts)
	}
	key := partKey(folder, name, r.Part)
	o, err := b.store.Get(ctx, key)
	if err != nil {
		return wire.BackupStorePart{}, err
	}
	if o == nil {
		return wire.BackupStorePart{}, fail(invalidParams, "Part %d of the backup %s is missing.", r.Part, r.ID)
	}
	data, err := b.openPart(ctx, key, o.Data)
	if err != nil {
		return wire.BackupStorePart{}, fail(internalError, "Part %d of the backup %s does not open with this control plane's key.", r.Part, r.ID)
	}
	return wire.BackupStorePart{Name: name, Part: r.Part, Data: data}, nil
}

// prune keeps the newest keep of the host's backups; deletes parts a cut-off backup left
// a day ago; and deletes the backups of a removed host once its newest is old. The .json
// goes first, so a backup half deleted is never listed.
func (b *backupStore) prune(ctx context.Context, owner, host string, keep int64) {
	hosts, err := b.scan(ctx, owner)
	if err != nil {
		return
	}
	now := b.now()
	for id, h := range hosts {
		folder := b.hostFolder(owner, id)
		drop := []string{}
		switch {
		case id == host:
			if n := len(h.complete) - int(keep); n > 0 {
				drop = h.complete[:n]
			}
		case b.records.Host(id) == nil && len(h.complete) > 0 && b.older(h.complete[len(h.complete)-1], now, backupOrphanAge):
			drop = h.complete
		}
		for _, name := range drop {
			b.store.Delete(ctx, folder+name+".json")
			for _, k := range h.parts[name] {
				b.store.Delete(ctx, k)
			}
			delete(h.parts, name)
		}
		for name, keys := range h.parts {
			if !contains(h.complete, name) && b.older(name, now, backupStrayAge) {
				for _, k := range keys {
					b.store.Delete(ctx, k)
				}
			}
		}
	}
}

// pruneOrphans prunes each owner's backups, as a backup of one of their hosts does, for
// the owners none of whose hosts backs up any more (#2293): the backups of a removed host
// go once old, and parts a cut-off backup left go after a day. Run by the sweep once a day:
// it lists every backup.
func (b *backupStore) pruneOrphans(ctx context.Context) error {
	keys, err := b.store.List(ctx, backupsPrefix)
	if err != nil {
		return err
	}
	owners := map[string]bool{}
	for _, k := range keys {
		if owner, _, ok := strings.Cut(strings.TrimPrefix(k.Key, backupsPrefix), "/"); ok && backupFolderName(owner) {
			owners[owner] = true
		}
	}
	for owner := range owners {
		b.prune(ctx, owner, "", 0)
	}
	return nil
}

// backupFolderName is an id that is one folder of a key: a host's or an owner's.
func backupFolderName(id string) bool {
	return id != "" && !strings.HasPrefix(id, ".") && !strings.ContainsAny(id, `/\`)
}

func (b *backupStore) older(name string, now time.Time, age time.Duration) bool {
	at, err := time.Parse(backupNameTime, name)
	return err == nil && now.Sub(at) > age
}
