package agentsd

import (
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
// an agent can read sealed.json and cannot open it. On Linux the key is a 0600 file; the
// second layer under the control plane's release key comes after this (#4014's stack).
//
// The associated data binds where it is kept, its name and its grants (#4015's "Allow
// always" places), so a record moved or changed by hand does not open. Being sealed is the
// flag: turning it on takes the plain line out, turning it off puts it back.
//
//	~/.agents-secrets/sealed.json   0600, {"v":1,"secrets":{NAME:{sealed,grants,from,setAt}}}
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
}

type sealedSecretsFile struct {
	V       int                     `json:"v"`
	Secrets map[string]sealedValue `json:"secrets,omitempty"`
}

// sealedValue is one flagged value: the nonce then the sealed value and its tag.
type sealedValue struct {
	Sealed []byte `json:"sealed"`
	// Grants are the places a person allowed always (#4015), bound into the associated data.
	Grants []string  `json:"grants,omitempty"`
	From   string    `json:"from,omitempty"`
	SetAt  wire.Date `json:"setAt"`
}

func sealedSecretsPath(home string) string {
	return filepath.Join(home, ".agents-secrets", "sealed.json")
}

// sealedSessionStore is a session's store in the associated data.
func sealedSessionStore(agent wire.UUID) string { return "session:" + string(agent) }

// sealedSecretAD is what each seal binds: the store, the name, the flag and the grants.
func sealedSecretAD(storeName, name string, grants []string) []byte {
	g, _ := json.Marshal(grants)
	return fmt.Appendf(nil, "sealedsecret.v1|%s|%s|ask|%s", storeName, name, g)
}

// sealingKey is this machine's key for its flagged secrets, made from its own key (made
// once, the first time a machine needs it).
func (d *Daemon) sealingKey() ([]byte, error) {
	if d.HostKey == nil {
		return nil, errors.New("this machine has no key to seal with")
	}
	private, err := controllink.HostPrivateKey(d.HostKey)
	if err != nil {
		return nil, err
	}
	return hkdf.Key(sha256.New, private, nil, sealedSecretsInfo, 32)
}

func (d *Daemon) sealSecret(storeName, name, value string, grants []string) (sealedValue, error) {
	key, err := d.sealingKey()
	if err != nil {
		return sealedValue{}, err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return sealedValue{}, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return sealedValue{}, err
	}
	grants = sortedGrants(grants)
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return sealedValue{Sealed: gcm.Seal(nonce, nonce, []byte(value), sealedSecretAD(storeName, name, grants)),
		Grants: grants, SetAt: now()}, nil
}

func (d *Daemon) openSealedSecret(storeName, name string, s sealedValue) (string, error) {
	key, err := d.sealingKey()
	if err != nil {
		return "", err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(s.Sealed) < gcm.NonceSize() {
		return "", errors.New("not a sealed value")
	}
	plain, err := gcm.Open(nil, s.Sealed[:gcm.NonceSize()], s.Sealed[gcm.NonceSize():], sealedSecretAD(storeName, name, s.Grants))
	if err != nil {
		return "", errors.New("it does not open with this machine's key")
	}
	return string(plain), nil
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

// sealedLocalSecret is the value of a flagged secret of this machine, opened.
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

// isSealedSecret is whether name is flagged here, without opening it.
func isSealedSecret(home, name string) bool {
	_, ok := readSealedSecrets(home).Secrets[name]
	return ok
}

// localSecret is what agentsd itself uses for name (fill_secret, set_ci_secret): the
// session's own first (#3548), then a flagged one, then secrets.env. #4015 asks a person
// here before a flagged value is used.
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

// saveSealedSecret keeps value flagged: sealed.json, and out of secrets.env. Grants already
// made for that name are kept: a new value is not a new place.
func (d *Daemon) saveSealedSecret(home, name, value, from string) error {
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	s, err := d.sealSecret(sealedLocal, name, value, f.Secrets[name].Grants)
	if err != nil {
		return fmt.Errorf("it could not be sealed: %w", err)
	}
	s.From = from
	f.Secrets[name] = s
	if err := writeSealedSecrets(home, f); err != nil {
		return errors.New("sealed.json could not be written")
	}
	// The plain line goes after the sealed one is kept: never neither.
	return removePlainSecret(home, name)
}

// removeSealedSecret takes a flagged one out, as the plain line it replaces is.
func (d *Daemon) removeSealedSecret(home, name string) error {
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	if _, ok := f.Secrets[name]; !ok {
		return nil
	}
	delete(f.Secrets, name)
	return writeSealedSecrets(home, f)
}

func removePlainSecret(home, name string) error {
	path := skillcatalog.SecretsPath(home)
	env, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return err
	}
	if !env.IsSet(name) {
		return nil
	}
	env.Remove(name)
	if err := env.Save(path); err != nil {
		return errors.New("secrets.env could not be written")
	}
	return nil
}

// syncUserSealed keeps the flagged secrets of the person's (Settings ▸ You ▸ Secrets) (#4014): each one sent flagged is sealed
// here, one sent plain loses any sealed copy, and one the sync sealed before and no longer
// sends goes. kept are names whose newer version here stays as it is.
func (d *Daemon) syncUserSealed(home string, flagged, plain []wire.UserSecret, kept []string) error {
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	before := len(f.Secrets)
	if f.Secrets == nil {
		f.Secrets = map[string]sealedValue{}
	}
	sent := map[string]bool{}
	changed := false
	for _, s := range flagged {
		name := string(s.Name)
		if !secretNameHere.MatchString(name) {
			continue
		}
		sealed, err := d.sealSecret(sealedLocal, name, s.Value, f.Secrets[name].Grants)
		if err != nil {
			return fmt.Errorf("%s could not be sealed: %w", name, err)
		}
		sealed.From = sealedFromUser
		f.Secrets[name] = sealed
		sent[name] = true
		changed = true
	}
	for _, s := range plain {
		if _, ok := f.Secrets[string(s.Name)]; ok {
			delete(f.Secrets, string(s.Name))
			changed = true
		}
	}
	for name, s := range f.Secrets {
		if s.From == sealedFromUser && !sent[name] && !slices.Contains(kept, name) {
			delete(f.Secrets, name)
			changed = true
		}
	}
	if !changed && before == len(f.Secrets) {
		return nil
	}
	return writeSealedSecrets(home, f)
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
		v, ok := skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).Value(r.Name)
		if !ok {
			if isSealedSecret(home, r.Name) {
				return nil
			}
			return Invalid("%s is not set on this machine.", r.Name)
		}
		if err := d.saveSealedSecret(home, r.Name, v, ""); err != nil {
			return Invalid("%s was not changed: %s", r.Name, err.Error())
		}
		log.Printf("sealed secrets: %s turned on Ask before use", r.Name)
		d.mcpChanged()
		return nil
	}
	v, ok := d.sealedLocalSecret(home, r.Name)
	if !ok {
		if isSealedSecret(home, r.Name) {
			return Invalid("%s does not open on this machine, so it was left as it is.", r.Name)
		}
		return nil
	}
	path := skillcatalog.SecretsPath(home)
	env, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return Invalid("%s was not changed: %s", r.Name, err.Error())
	}
	env.Set(r.Name, v)
	if err := env.Save(path); err != nil {
		return Invalid("%s was not changed: secrets.env could not be written.", r.Name)
	}
	// The plain line is written first: never neither.
	if err := d.removeSealedSecret(home, r.Name); err != nil {
		return Invalid("%s was not changed: sealed.json could not be written.", r.Name)
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
