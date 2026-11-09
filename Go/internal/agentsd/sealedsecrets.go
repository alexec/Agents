package agentsd

import (
	"cmp"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Ask before use (#4014, the spike #4013): a secret with the flag on is kept sealed, and only
// agentsd opens it, for its own uses (fill_secret, set_ci_secret). Its value is never in
// secrets.env, a session's file, an agent's environment or a tool's reply: every session runs
// as the same user, so a value in one session's process or file is every session's.
//
// It is sealed with AES-256-GCM under a key made from this machine's key with HKDF. On a Mac
// that key is in a Keychain item only agentsd's signature reads (controllink.HostKeyFor), so
// an agent can read sealed.json and cannot open it. On Linux the key is a 0600 file an agent
// can read, so the value is first sealed to the release key that only the control plane
// keeps (#4058, secretrelease), and that layer then to the machine's key: it opens only once
// the control plane released its key for a person's signed approval (secretrelease.go). A
// Linux machine with no control plane keeps no flagged value.
//
// The associated data binds where it is kept, its name, the flag and its grants (#4015's
// "Allow always" places), so a record moved or changed by hand does not open. Turning the
// flag on or off seals the record again, with the other flag.
//
// The store also keeps secrets with the flag off (#4176, the spike #4168): the machine's
// seal only, with no release layer on Linux, so one opens with no approval and a Linux
// machine with no control plane keeps it. agentsd opens them once each time the store
// changes and keeps the values in its memory (plainStoreSecrets). Since #4177 every write
// goes to the store, and agentsd moves a secrets.env it finds at start (MoveSecretsFile);
// the readers read one not moved yet after the store.
//
//	~/.agents-secrets/sealed.json   0600, {"v":1,"secrets":{NAME:{sealed,grants,noAsk,from,setAt}}}
//	sessions/<agent>.json           a session's flagged secret, its "sealed" in place of "value"

const (
	sealedSecretsInfo    = "com.alexecollins.agents.sealedsecret.v1"
	sealedSecretsVersion = 1
	// sealedFromUser is a secret of the person's (Settings ▸ You ▸ Secrets) sent with the flag on: the person's client
	// sealed the flag, and the sync owns the record.
	sealedFromUser = "user"
	// sealedLocal names this machine's store in the associated data (sealedSessionStore a
	// session's).
	sealedLocal = "local"
)

type sealedSecretsState struct {
	sealedSecretsMu sync.Mutex
	releaseState
	plainStoreMu sync.Mutex
	plainStore   plainStoreCache
}

// plainStoreCache is the store's values with the flag off, opened, for the sealed.json they
// came from.
type plainStoreCache struct {
	home   string
	info   os.FileInfo
	values map[string]string
	// failed is when this machine's key last did not read: tried again after plainStoreRetry.
	failed time.Time
}

// plainStoreRetry is how long a store whose key did not read is left before agentsd tries
// the key again: a read that waits on a Keychain prompt takes seconds (#4045).
const plainStoreRetry = time.Minute

// machineKeyError is this machine's key that does not read (#4045, a changed signature on a
// Mac): every secret in sealed.json then stops, flag on or off, and each says so the same way.
type machineKeyError struct{ err error }

func (e machineKeyError) Error() string {
	return "this machine's key for its secrets does not read, so no secret kept in sealed.json opens until it does (" + e.err.Error() + ")"
}

func (e machineKeyError) Unwrap() error { return e.err }

type sealedSecretsFile struct {
	V       int                    `json:"v"`
	Secrets map[string]sealedValue `json:"secrets,omitempty"`
}

// sealedValue is one flagged value: the nonce then the sealed value and its tag.
type sealedValue struct {
	Sealed []byte `json:"sealed"`
	// Grants are the places a person allowed always (#4015), bound into the associated data.
	Grants []string `json:"grants,omitempty"`
	// Release says what the machine's key seals is the value's release layer (#4058), not
	// the value: it opens only with the key the control plane releases.
	Release bool `json:"release,omitempty"`
	// NoAsk is the flag off (#4176): it opens with no approval, and has no grants and no
	// release layer.
	NoAsk bool      `json:"noAsk,omitempty"`
	From  string    `json:"from,omitempty"`
	SetAt wire.Date `json:"setAt"`
}

func sealedSecretsPath(home string) string {
	return filepath.Join(home, ".agents-secrets", "sealed.json")
}

// sealedSessionStore is a session's store in the associated data.
func sealedSessionStore(agent wire.UUID) string { return "session:" + string(agent) }

// sealedSecretAD is what each seal binds: the store, the name, the flag, the grants and
// whether it holds a release layer.
func sealedSecretAD(storeName, name string, grants []string, release, noAsk bool) []byte {
	g, _ := json.Marshal(grants)
	flag := "ask"
	if noAsk {
		flag = "noask"
	}
	ad := fmt.Appendf(nil, "sealedsecret.v1|%s|%s|%s|%s", storeName, name, flag, g)
	if release {
		ad = append(ad, "|release"...)
	}
	return ad
}

// sealingKey is this machine's key for its flagged secrets, made from its own key (made
// once, the first time a machine needs it).
func (d *Daemon) sealingKey() ([]byte, error) {
	if d.HostKey == nil {
		return nil, errors.New("this machine has no key to seal with")
	}
	private, err := controllink.HostPrivateKey(d.HostKey)
	if err != nil {
		return nil, machineKeyError{err}
	}
	return hkdf.Key(sha256.New, private, nil, sealedSecretsInfo, 32)
}

// sealSecret seals value: to the machine's key, and on Linux first to the release key.
func (d *Daemon) sealSecret(storeName, name, value string, grants []string) (sealedValue, error) {
	plain := []byte(value)
	release := d.releaseLayerOn()
	if release {
		layer, err := d.sealReleaseLayer(storeName, name, value)
		if err != nil {
			return sealedValue{}, err
		}
		plain, _ = json.Marshal(layer)
	}
	return d.sealOuter(storeName, name, plain, grants, release, false)
}

// sealPlainSecret seals a value with the flag off (#4176): to the machine's key only, on
// Linux too, so it opens with no approval and needs no control plane.
func (d *Daemon) sealPlainSecret(storeName, name, value string) (sealedValue, error) {
	return d.sealOuter(storeName, name, []byte(value), nil, false, true)
}

// sealOuter is the seal to the machine's key, of the value or of its release layer.
func (d *Daemon) sealOuter(storeName, name string, plain []byte, grants []string, release, noAsk bool) (sealedValue, error) {
	gcm, err := d.sealingGCM()
	if err != nil {
		return sealedValue{}, err
	}
	grants = sortedGrants(grants)
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return sealedValue{Sealed: gcm.Seal(nonce, nonce, plain, sealedSecretAD(storeName, name, grants, release, noAsk)),
		Grants: grants, Release: release, NoAsk: noAsk, SetAt: now()}, nil
}

func (d *Daemon) sealingGCM() (cipher.AEAD, error) {
	key, err := d.sealingKey()
	if err != nil {
		return nil, err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// openOuter opens the seal to the machine's key: the value, or its release layer. It says
// the record is whole (its grants are the ones sealed) without the value on Linux.
func (d *Daemon) openOuter(storeName, name string, s sealedValue) ([]byte, error) {
	gcm, err := d.sealingGCM()
	if err != nil {
		return nil, err
	}
	return openOuterWith(gcm, storeName, name, s)
}

func openOuterWith(gcm cipher.AEAD, storeName, name string, s sealedValue) ([]byte, error) {
	if len(s.Sealed) < gcm.NonceSize() {
		return nil, errors.New("not a sealed value")
	}
	plain, err := gcm.Open(nil, s.Sealed[:gcm.NonceSize()], s.Sealed[gcm.NonceSize():], sealedSecretAD(storeName, name, s.Grants, s.Release, s.NoAsk))
	if err != nil {
		return nil, errors.New("it does not open with this machine's key")
	}
	return plain, nil
}

// openSealedSecret is the value. A value with a release layer opens only once a person's
// signed approval released its key in this run of agentsd (releaseSealed).
func (d *Daemon) openSealedSecret(storeName, name string, s sealedValue) (string, error) {
	plain, err := d.openOuter(storeName, name, s)
	if err != nil {
		return "", err
	}
	if !s.Release {
		return string(plain), nil
	}
	if v, ok := d.releasedValue(storeName, name, plain); ok {
		return v, nil
	}
	return "", errNotReleased
}

// regrant seals a record again with other grants: on Linux its release layer as it is, so
// a grant changes with no release.
func (d *Daemon) regrant(storeName, name string, s sealedValue, grants []string) (sealedValue, error) {
	plain, err := d.openOuter(storeName, name, s)
	if err != nil {
		return sealedValue{}, err
	}
	defer clear(plain)
	return d.sealOuter(storeName, name, plain, grants, s.Release, s.NoAsk)
}

func sortedGrants(g []string) []string {
	if len(g) == 0 {
		return nil
	}
	out := slices.Clone(g)
	sort.Strings(out)
	return slices.Compact(out)
}

// readSealedSecrets is sealed.json; missing or unreadable reads as nothing.
func readSealedSecrets(home string) sealedSecretsFile {
	f := sealedSecretsFile{V: sealedSecretsVersion}
	if b, err := os.ReadFile(sealedSecretsPath(home)); err == nil {
		json.Unmarshal(b, &f)
	}
	return f
}

func writeSealedSecrets(home string, f sealedSecretsFile) error {
	p := sealedSecretsPath(home)
	if len(f.Secrets) == 0 {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	f.V = sealedSecretsVersion
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return store.WriteAtomically(p, b, 0o600)
}

// sealedLocalSecret is the value of a secret in this machine's store, opened: flag on or off.
func (d *Daemon) sealedLocalSecret(home, name string) (string, bool) {
	s, ok := readSealedSecrets(home).Secrets[name]
	if !ok {
		return "", false
	}
	v, err := d.openSealedSecret(sealedLocal, name, s)
	if err != nil {
		log.Printf("sealed secrets: %s: %v", name, err)
		return "", false
	}
	return v, true
}

// secretIsSealed is whether the name an agent uses is flagged: its session's own, else this
// machine's.
func (d *Daemon) secretIsSealed(agent wire.UUID, name string) bool {
	if v, ok := d.readSessionSecrets(agent).Secrets[name]; ok {
		return v.Sealed != nil
	}
	home := d.personalHome()
	return home != "" && isSealedSecret(home, name)
}

// isSealedSecret is whether name has Ask before use here, without opening it. A record in
// the store with the flag off (#4176) is not.
func isSealedSecret(home, name string) bool {
	s, ok := readSealedSecrets(home).Secrets[name]
	return ok && !s.NoAsk
}

// secretIsSet is whether name is set here: in the store, flag on or off, or in secrets.env.
func secretIsSet(home, name string) bool {
	if _, ok := readSealedSecrets(home).Secrets[name]; ok {
		return true
	}
	return skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).IsSet(name)
}

// plainSecrets is what is set with the flag off, for reading: secrets.env, with the store's
// values over it (#4176).
func (d *Daemon) plainSecrets(home string) skillcatalog.Secrets {
	s := skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home))
	for name, v := range d.plainStoreSecrets(home) {
		s.Set(name, v)
	}
	return s
}

// plainStoreSecrets is the store's values with the flag off, opened once each time
// sealed.json changes and kept in agentsd's memory, which it makes private first. Not to be
// changed. When this machine's key does not read, it is empty, with one error for every
// secret in the log, and the key is tried again after plainStoreRetry.
func (d *Daemon) plainStoreSecrets(home string) map[string]string {
	info, err := os.Stat(sealedSecretsPath(home))
	if err != nil {
		info = nil
	}
	d.plainStoreMu.Lock()
	defer d.plainStoreMu.Unlock()
	c := &d.plainStore
	same := c.home == home && sameFileStamp(c.info, info)
	if same && (c.failed.IsZero() || time.Since(c.failed) < plainStoreRetry) {
		return c.values
	}
	wasFailing := same && !c.failed.IsZero()
	*c = plainStoreCache{home: home, info: info}
	var names []string
	f := readSealedSecrets(home)
	for name, s := range f.Secrets {
		if s.NoAsk {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return nil
	}
	gcm, err := d.sealingGCM()
	if err != nil {
		c.failed = time.Now()
		if !wasFailing {
			log.Printf("sealed secrets: %v; %d secrets with Ask before use off are not set until then", err, len(names))
		}
		return nil
	}
	d.keepMemoryPrivateOnce()
	c.values = make(map[string]string, len(names))
	for _, name := range names {
		plain, err := openOuterWith(gcm, sealedLocal, name, f.Secrets[name])
		if err != nil {
			log.Printf("sealed secrets: %s: %v", name, err)
			continue
		}
		c.values[name] = string(plain)
	}
	return c.values
}

// sameFileStamp is whether two looks at a file see the same one: a store written again is
// a new file (store.WriteAtomically), or a new size or time.
func sameFileStamp(a, b os.FileInfo) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

// localSecret is what agentsd itself uses for name (fill_secret, set_ci_secret): the
// session's own first (#3548), then the store's (flag on or off, #4176), then secrets.env.
// #4015 asks a person here before a flagged value is used.
func (d *Daemon) localSecret(agent wire.UUID, name string) (value string, ok, expired bool) {
	if v, has, exp := d.sessionSecret(agent, name); has {
		return v, true, false
	} else if exp {
		expired = true
	}
	home := d.personalHome()
	if home == "" {
		return "", false, expired
	}
	if v, has := d.sealedLocalSecret(home, name); has {
		return v, true, expired
	}
	v, ok := skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).Value(name)
	return v, ok, expired
}

// saveSealedSecret keeps value in sealed.json, the only place for a person's secrets (#4177),
// and out of any secrets.env not moved yet: flagged when ask, else with the flag off (#4176). Grants already made for that name are kept: a new value is not
// a new place.
func (d *Daemon) saveSealedSecret(home, name, value, from string, ask bool) error {
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	var s sealedValue
	var err error
	if ask {
		s, err = d.sealSecret(sealedLocal, name, value, f.Secrets[name].Grants)
	} else {
		s, err = d.sealPlainSecret(sealedLocal, name, value)
	}
	if err != nil {
		return fmt.Errorf("it could not be sealed: %w", err)
	}
	s.From = from
	f.Secrets[name] = s
	if err := writeSealedSecrets(home, f); err != nil {
		return errors.New("sealed.json could not be written")
	}
	// The plain line goes after the sealed one is kept: never neither.
	return removePlainSecrets(home, name)
}

// setPlainSecrets keeps each of values in sealed.json with the flag off (#4177), in one
// write, and takes their lines out of any secrets.env. A name kept with the flag on stays
// flagged, with its grants, and takes the new value: a write that is not the flag's own
// never turns Ask before use off.
func (d *Daemon) setPlainSecrets(home string, values map[string]string, from string) error {
	if len(values) == 0 {
		return nil
	}
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	names := make([]string, 0, len(values))
	for name, value := range values {
		var s sealedValue
		var err error
		had, ok := f.Secrets[name]
		if ok && !had.NoAsk {
			s, err = d.sealSecret(sealedLocal, name, value, had.Grants)
		} else {
			s, err = d.sealPlainSecret(sealedLocal, name, value)
		}
		if err != nil {
			return fmt.Errorf("%s could not be sealed: %w", name, err)
		}
		s.From = cmp.Or(from, had.From)
		f.Secrets[name] = s
		names = append(names, name)
	}
	if err := writeSealedSecrets(home, f); err != nil {
		return errors.New("sealed.json could not be written")
	}
	return removePlainSecrets(home, names...)
}

// forgetPlainSecret takes out name with the flag off: its record in sealed.json and any line
// in secrets.env. One with the flag on stays.
func (d *Daemon) forgetPlainSecret(home, name string) error {
	d.sealedSecretsMu.Lock()
	f := readSealedSecrets(home)
	var err error
	if s, ok := f.Secrets[name]; ok && s.NoAsk {
		delete(f.Secrets, name)
		if writeSealedSecrets(home, f) != nil {
			err = errors.New("sealed.json could not be written")
		}
	}
	d.sealedSecretsMu.Unlock()
	if err != nil {
		return err
	}
	return removePlainSecrets(home, name)
}

// MoveSecretsFile moves a secrets.env it finds into sealed.json, at each start (#4177, the
// spike #4168's answer 5): each line is sealed with the flag off, the store is written
// safely, and then the file goes. A name the store keeps already keeps the store's record,
// which every reader read first (#4176). A start that stops between the two writes does the
// move again, with the same result. The file is left as it is when it does not read or this
// machine's key does not, and the readers still read it until the next start moves it.
func (d *Daemon) MoveSecretsFile() {
	home := d.personalHome()
	if home == "" {
		return
	}
	path := skillcatalog.SecretsPath(home)
	if _, err := os.Lstat(path); err != nil {
		return
	}
	n, err := d.moveSecretsFile(home, path)
	if err != nil {
		log.Printf("sealed secrets: %s was not moved into sealed.json: %v", path, err)
		return
	}
	log.Printf("sealed secrets: moved %d secrets from %s into sealed.json, and removed the file", n, path)
	d.mcpChanged()
}

func (d *Daemon) moveSecretsFile(home, path string) (int, error) {
	env, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return 0, err
	}
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	moved := 0
	for _, name := range env.Names() {
		if _, kept := f.Secrets[name]; kept {
			continue
		}
		value, _ := env.Value(name)
		s, err := d.sealPlainSecret(sealedLocal, name, value)
		if err != nil {
			return 0, fmt.Errorf("%s could not be sealed: %w", name, err)
		}
		f.Secrets[name] = s
		moved++
	}
	if moved > 0 {
		if err := writeSealedSecrets(home, f); err != nil {
			return 0, errors.New("sealed.json could not be written")
		}
	}
	// The file goes after the store is kept: never neither.
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return 0, err
	}
	return moved, nil
}

// removePlainSecrets takes names out of a secrets.env that has not been moved yet.
func removePlainSecrets(home string, names ...string) error {
	path := skillcatalog.SecretsPath(home)
	env, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return err
	}
	if !slices.ContainsFunc(names, env.IsSet) {
		return nil
	}
	for _, name := range names {
		env.Remove(name)
	}
	if err := env.Save(path); err != nil {
		return errors.New("secrets.env could not be written")
	}
	return nil
}

// syncUserSecrets keeps the secrets of the person's (Settings ▸ You ▸ Secrets) in sealed.json
// (#4014, #4177): each one sent is sealed here, flagged or with the flag off as sent, and
// one the control plane sent before (before) or the sync sealed before, and no longer sends,
// goes. kept are names whose newer version here stays as it is. A secret the person set here
// by hand, under a name the control plane never sent, is left alone. It gives the names now
// from the control plane.
func (d *Daemon) syncUserSecrets(home string, plain, flagged []wire.UserSecret, before, kept []string) ([]string, error) {
	if len(plain) == 0 && len(flagged) == 0 && len(before) == 0 && len(kept) == 0 {
		return []string{}, nil
	}
	if home == "" {
		return nil, errors.New("this machine has no personal home")
	}
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	names := []string{}
	sent := map[string]bool{}
	seal := func(s wire.UserSecret, ask bool) error {
		name := string(s.Name)
		if !secretNameHere.MatchString(name) || strings.ContainsAny(s.Value, "\n\r\x00") {
			return nil
		}
		var sealed sealedValue
		var err error
		if ask {
			sealed, err = d.sealSecret(sealedLocal, name, s.Value, f.Secrets[name].Grants)
		} else {
			sealed, err = d.sealPlainSecret(sealedLocal, name, s.Value)
		}
		if err != nil {
			return fmt.Errorf("%s could not be sealed: %w", name, err)
		}
		sealed.From = sealedFromUser
		f.Secrets[name] = sealed
		sent[name] = true
		names = append(names, name)
		return nil
	}
	for _, s := range plain {
		if err := seal(s, false); err != nil {
			return nil, err
		}
	}
	for _, s := range flagged {
		if err := seal(s, true); err != nil {
			return nil, err
		}
	}
	for _, name := range kept {
		if !sent[name] {
			sent[name] = true
			names = append(names, name)
		}
	}
	gone := slices.Clone(before)
	for name, s := range f.Secrets {
		if s.From == sealedFromUser {
			gone = append(gone, name)
		}
	}
	for _, name := range gone {
		if !sent[name] {
			delete(f.Secrets, name)
		}
	}
	if err := writeSealedSecrets(home, f); err != nil {
		return nil, errors.New("sealed.json could not be written")
	}
	// The plain lines go after the sealed ones are kept: never neither.
	if err := removePlainSecrets(home, append(names, before...)...); err != nil {
		return nil, err
	}
	sort.Strings(names)
	return names, nil
}

// setNeedsApproval is secrets/setNeedsApproval: a person's client turns the flag on or off.
// Only the control and device roles reach it (askBeforeUseAllowed).
func (d *Daemon) setNeedsApproval(r wire.SecretNeedsApprovalRequest) error {
	if !secretAskName.MatchString(r.Name) {
		return Invalid("A secret's name is letters, digits and underscores, e.g. GITLAB_PASSWORD.")
	}
	if r.AgentID != nil && *r.AgentID != "" {
		return d.setSessionNeedsApproval(*r.AgentID, r.Name, r.NeedsApproval)
	}
	home := d.personalHome()
	if home == "" {
		return Invalid("This machine has no personal home to keep secrets in.")
	}
	if d.isUserSecret(r.Name) {
		return Invalid("%s comes from Settings ▸ You ▸ Secrets: change Ask before use there, where your client seals it.", r.Name)
	}
	if r.NeedsApproval {
		v, ok := d.plainSecrets(home).Value(r.Name)
		if !ok {
			if isSealedSecret(home, r.Name) {
				return nil
			}
			return Invalid("%s is not set on this machine.", r.Name)
		}
		if err := d.saveSealedSecret(home, r.Name, v, "", true); err != nil {
			return Invalid("%s was not changed: %s", r.Name, err.Error())
		}
		log.Printf("sealed secrets: %s turned on Ask before use", r.Name)
		d.mcpChanged()
		return nil
	}
	if s, ok := readSealedSecrets(home).Secrets[r.Name]; ok && s.NoAsk {
		return nil
	}
	v, ok := d.sealedLocalSecret(home, r.Name)
	if !ok {
		if s, sealed := readSealedSecrets(home).Secrets[r.Name]; sealed && s.Release {
			return Invalid("%s was left as it is: on this machine it opens only for a use a person approved on one of their devices. Approve a use first, or set its value again with Ask before use off.", r.Name)
		}
		if isSealedSecret(home, r.Name) {
			return Invalid("%s does not open on this machine, so it was left as it is.", r.Name)
		}
		return nil
	}
	if err := d.saveSealedSecret(home, r.Name, v, "", false); err != nil {
		return Invalid("%s was not changed: %s", r.Name, err.Error())
	}
	log.Printf("sealed secrets: %s turned off Ask before use", r.Name)
	d.mcpChanged()
	return nil
}

// isUserSecret is whether name is a secret of the person's (Settings ▸ You ▸ Secrets): its flag is its client's to seal.
func (d *Daemon) isUserSecret(name string) bool {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	return slices.Contains(d.userMarkLocked().Secrets, name)
}

// askBeforeUseAllowed is whether a caller may choose the flag: a person's own client.
// An agent's write always turns it on (#4014).
func askBeforeUseAllowed(c *Client) bool {
	if c == nil {
		return true
	}
	return c.Role == RoleControl || c.Role == RoleDevice
}

func (d *Daemon) registerSealedSecrets() {
	On(d, wire.CallSecretsSetNeedsApproval, func(_ context.Context, c *Client, r wire.SecretNeedsApprovalRequest) (wire.Empty, error) {
		if !askBeforeUseAllowed(c) {
			return wire.Empty{}, &Error{Code: CodeNotPermitted, Message: "Only a person's own client changes Ask before use."}
		}
		r.Name = strings.TrimSpace(r.Name)
		return wire.Empty{}, d.setNeedsApproval(r)
	})
}
