// Package usersettings keeps each person's user settings and secrets (#1760, spec 736 US4,
// FR-023–FR-026): what follows the person to every machine of theirs.
//
// Settings are plain records, one per person, which the control plane keeps and sends but
// does not read inside:
//
//	v1/users/<user>/settings.json          wire.UserSettings
//	v1/users/<user>/secrets/<NAME>.json    a secret, sealed (FR-025, SC-007)
//
// Each secret is sealed in an envelope (kms.SealFor): a data key of its own encrypts it,
// and the keeper wraps the data key. The keeper is Google Cloud KMS on a cloud machine, or
// a local key in a 0600 file outside the store on a Mac. The envelope is bound to its key
// in the store, so a record copied to another person's secrets does not open. No value is
// in the store, a log line or an event.
package usersettings

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"gocloud.dev/secrets"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Prefix is where every person's user settings are in the store.
const Prefix = "v1/users/"

// The bounds on what one person keeps, so no person fills the store or a machine's link.
const (
	MaxPart    = 256 << 10
	MaxSecret  = 16 << 10
	MaxSecrets = 200
)

var (
	// ErrNoSealing is user/setSecret on a control plane with no keeper for secrets.
	ErrNoSealing = errors.New("this control plane has no key to seal secrets with")
	// ErrInvalid is a part or a secret that is not what it must be. Its words never hold a
	// secret's value.
	ErrInvalid = errors.New("invalid")
)

var secretName = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,63}$`)

// userID is a person's id as it may be in a store key.
var userID = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// Book is every person's user settings and secrets in one store.
type Book struct {
	store     store.Store
	keeper    *secrets.Keeper
	keeperURL string
	now       func() time.Time

	mu sync.Mutex
	// opened keeps each secret's value by its record's tag, so a machine's join does not
	// ask the keeper again for what did not change.
	opened map[string]openedSecret
}

type openedSecret struct {
	tag   string
	value string
}

// New is a book over s. keeper seals and opens the secrets; nil refuses every secret.
func New(s store.Store, keeper *secrets.Keeper, keeperURL string) *Book {
	return &Book{store: s, keeper: keeper, keeperURL: keeperURL, now: time.Now, opened: map[string]openedSecret{}}
}

// Sealing says whether this book can keep secrets.
func (b *Book) Sealing() bool { return b != nil && b.keeper != nil }

// SealFor seals a value with this book's keeper, bound to the store key it is kept at. The
// organisation's route secrets (#999) are sealed with the same keeper as a person's.
func (b *Book) SealFor(ctx context.Context, plaintext, boundTo []byte) (*kms.Sealed, error) {
	if !b.Sealing() {
		return nil, ErrNoSealing
	}
	return kms.SealFor(ctx, b.keeper, b.keeperURL, plaintext, boundTo)
}

// OpenFor opens what SealFor sealed for the same store key.
func (b *Book) OpenFor(ctx context.Context, sealed *kms.Sealed, boundTo []byte) ([]byte, error) {
	if !b.Sealing() {
		return nil, ErrNoSealing
	}
	return kms.OpenFor(ctx, b.keeper, sealed, boundTo)
}

func settingsKey(user string) string { return Prefix + user + "/settings.json" }
func secretsPrefix(user string) string {
	return Prefix + user + "/secrets/"
}
func secretKey(user, name string) string { return secretsPrefix(user) + name + ".json" }

// secretRecord is a secret as stored. Sealed is nil once the secret is removed: the record
// stays, as a tombstone, so a removal is a conditional write like any other.
type secretRecord struct {
	Name     string              `json:"name"`
	Sealed   *kms.Sealed         `json:"sealed,omitempty"`
	Updated  string              `json:"updated"`
	Machines []string            `json:"machines,omitempty"`
	LeftOn   []wire.SecretLeftOn `json:"leftOn,omitempty"`
}

func checkUser(user string) error {
	if !userID.MatchString(user) {
		return fmt.Errorf("%w: no such person", ErrInvalid)
	}
	return nil
}

func (b *Book) stamp() string { return b.now().UTC().Format(time.RFC3339) }

// Settings is a person's user settings, empty when none are kept.
func (b *Book) Settings(ctx context.Context, user string) (wire.UserSettings, error) {
	var out wire.UserSettings
	if err := checkUser(user); err != nil {
		return out, err
	}
	o, err := b.store.Get(ctx, settingsKey(user))
	if err != nil {
		return out, err
	}
	if o != nil {
		if err := json.Unmarshal(o.Data, &out); err != nil {
			return wire.UserSettings{}, fmt.Errorf("%s cannot be read: %w", settingsKey(user), err)
		}
	}
	return out, nil
}

// Forget deletes everything kept for a person: their settings and every sealed secret
// (#2293). For a person removed, so what was theirs does not stay for ever.
func (b *Book) Forget(ctx context.Context, user string) error {
	if err := checkUser(user); err != nil {
		return err
	}
	keys, err := b.store.List(ctx, Prefix+user+"/")
	if err != nil {
		return err
	}
	for _, k := range keys {
		if err := b.store.Delete(ctx, k.Key); err != nil {
			return err
		}
	}
	return nil
}

// kinds is the JSON object shape each person-scoped part must have.
func partKind(part wire.UserSettingsPartName) (string, bool) {
	switch part {
	case wire.UserSettingsPartNameMcpServers, wire.UserSettingsPartNameAgentConfig,
		wire.UserSettingsPartNameRuntimes, wire.UserSettingsPartNameCostLimits:
		return "{", true
	}
	return "", false
}

// SetPart sets one part of a person's settings, or with a null value removes it from the
// user scope. It says whether anything changed.
func (b *Book) SetPart(ctx context.Context, user string, part wire.UserSettingsPartName, value json.RawMessage) (bool, error) {
	if err := checkUser(user); err != nil {
		return false, err
	}
	kind, ok := partKind(part)
	if !ok {
		return false, fmt.Errorf("%w: there is no part called %q", ErrInvalid, part)
	}
	value = json.RawMessage(strings.TrimSpace(string(value)))
	removing := len(value) == 0 || string(value) == "null"
	if !removing {
		if len(value) > MaxPart {
			return false, fmt.Errorf("%w: %s is over %d KB", ErrInvalid, part, MaxPart>>10)
		}
		if !strings.HasPrefix(string(value), kind) || !json.Valid(value) {
			return false, fmt.Errorf("%w: %s must be a JSON %s", ErrInvalid, part, map[string]string{"{": "object", "[": "list"}[kind])
		}
	}
	var parsed wire.JSONValue
	if !removing {
		parsed = canonical(value)
	}
	changed := false
	err := b.change(ctx, settingsKey(user), func(raw []byte) ([]byte, error) {
		var s wire.UserSettings
		if raw != nil {
			if err := json.Unmarshal(raw, &s); err != nil {
				return nil, err
			}
		}
		slot := partOf(&s, part)
		if string(canonical(*slot)) == string(parsed) {
			return nil, nil
		}
		*slot = parsed
		changed = true
		at := b.stamp()
		s.Updated = &at
		return records.Encode(s)
	})
	return changed, err
}

// canonical is a part as one form of its JSON, so the same part set again is no change.
func canonical(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return raw
	}
	b, _ := json.Marshal(v)
	return b
}

func partOf(s *wire.UserSettings, part wire.UserSettingsPartName) *wire.JSONValue {
	switch part {
	case wire.UserSettingsPartNameMcpServers:
		return &s.McpServers
	case wire.UserSettingsPartNameAgentConfig:
		return &s.AgentConfig
	case wire.UserSettingsPartNameRuntimes:
		return &s.Runtimes
	case wire.UserSettingsPartNameCostLimits:
		return &s.CostLimits
	}
	return nil
}

// change writes key as edit makes it from what is there (nil for nothing), on the record
// as it is when written. edit giving nil changes nothing.
func (b *Book) change(ctx context.Context, key string, edit func(raw []byte) ([]byte, error)) error {
	for range 5 {
		o, err := b.store.Get(ctx, key)
		if err != nil {
			return err
		}
		var raw []byte
		when := store.Absent
		if o != nil {
			raw, when = o.Data, store.Matching(o.ETag)
		}
		data, err := edit(raw)
		if err != nil || data == nil {
			return err
		}
		if _, err := b.store.Put(ctx, key, data, when); err == nil {
			return nil
		} else if !store.IsConflict(err) {
			return err
		}
	}
	return fmt.Errorf("%s kept changing; try again", key)
}

// CheckSecret says whether a secret may be kept, with words that never hold its value.
func CheckSecret(name, value string) error {
	if !secretName.MatchString(name) {
		return fmt.Errorf("%w: a secret's name is capital letters, digits and _, such as GITHUB_TOKEN", ErrInvalid)
	}
	if value == "" || len(value) > MaxSecret {
		return fmt.Errorf("%w: a secret is 1 byte to %d KB", ErrInvalid, MaxSecret>>10)
	}
	if strings.ContainsAny(value, "\n\r\x00") {
		return fmt.Errorf("%w: a secret is one line", ErrInvalid)
	}
	return nil
}

// SetSecret seals a secret and keeps it. A secret set again forgets the machines that were
// removed with the old value on them: the person has changed it.
func (b *Book) SetSecret(ctx context.Context, user, name, value string) error {
	if err := checkUser(user); err != nil {
		return err
	}
	if err := CheckSecret(name, value); err != nil {
		return err
	}
	if !b.Sealing() {
		return ErrNoSealing
	}
	key := secretKey(user, name)
	if names, err := b.liveNames(ctx, user); err != nil {
		return err
	} else if len(names) >= MaxSecrets && !slices.Contains(names, name) {
		return fmt.Errorf("%w: a person keeps at most %d secrets", ErrInvalid, MaxSecrets)
	}
	sealed, err := kms.SealFor(ctx, b.keeper, b.keeperURL, []byte(value), []byte(key))
	if err != nil {
		return err
	}
	return b.change(ctx, key, func(raw []byte) ([]byte, error) {
		var r secretRecord
		if raw != nil {
			if err := json.Unmarshal(raw, &r); err != nil {
				return nil, err
			}
		}
		r = secretRecord{Name: name, Sealed: sealed, Updated: b.stamp(), Machines: r.Machines}
		return records.Encode(r)
	})
}

// RemoveSecret removes a secret. It says whether there was one.
func (b *Book) RemoveSecret(ctx context.Context, user, name string) (bool, error) {
	if err := checkUser(user); err != nil {
		return false, err
	}
	if !secretName.MatchString(name) {
		return false, nil
	}
	had := false
	err := b.change(ctx, secretKey(user, name), func(raw []byte) ([]byte, error) {
		if raw == nil {
			return nil, nil
		}
		var r secretRecord
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		if r.Sealed == nil {
			return nil, nil
		}
		had = true
		return records.Encode(secretRecord{Name: name, Updated: b.stamp()})
	})
	return had, err
}

// records is every secret record of a person, removed ones too, with each one's tag.
func (b *Book) secretRecords(ctx context.Context, user string) ([]secretRecord, []string, error) {
	listed, err := b.store.List(ctx, secretsPrefix(user))
	if err != nil {
		return nil, nil, err
	}
	var out []secretRecord
	var tags []string
	for _, k := range listed {
		if !strings.HasSuffix(k.Key, ".json") {
			continue
		}
		o, err := b.store.Get(ctx, k.Key)
		if err != nil {
			return nil, nil, err
		}
		if o == nil {
			continue
		}
		var r secretRecord
		if json.Unmarshal(o.Data, &r) != nil || !secretName.MatchString(r.Name) || secretKey(user, r.Name) != k.Key {
			continue
		}
		out = append(out, r)
		tags = append(tags, o.ETag)
	}
	return out, tags, nil
}

func (b *Book) liveNames(ctx context.Context, user string) ([]string, error) {
	all, _, err := b.secretRecords(ctx, user)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, r := range all {
		if r.Sealed != nil {
			names = append(names, r.Name)
		}
	}
	return names, nil
}

// Names is user/secretNames: each secret's name, when it changed, the machines it went to
// and the removed machines it was on. Never a value.
func (b *Book) Names(ctx context.Context, user string) ([]wire.UserSecretRow, error) {
	if err := checkUser(user); err != nil {
		return nil, err
	}
	all, _, err := b.secretRecords(ctx, user)
	if err != nil {
		return nil, err
	}
	rows := []wire.UserSecretRow{}
	for _, r := range all {
		if r.Sealed == nil {
			continue
		}
		row := wire.UserSecretRow{Name: wire.UserSecretName(r.Name), Updated: r.Updated, Machines: []wire.MachineRef{}, LeftOn: r.LeftOn}
		for _, m := range r.Machines {
			row.Machines = append(row.Machines, wire.MachineRef(m))
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows, nil
}

// Delivery is host/userSettings for a machine of user's: the settings and every secret,
// opened. Only for that user's own machine's link (FR-025). A secret that will not open
// (sealed by another keeper, as after a move) is left out, and named in skipped.
func (b *Book) Delivery(ctx context.Context, user string) (out wire.MachineUserSettings, skipped []string, err error) {
	settings, err := b.Settings(ctx, user)
	if err != nil {
		return out, nil, err
	}
	out = wire.MachineUserSettings{User: user, Settings: settings, Secrets: []wire.UserSecret{}}
	all, tags, err := b.secretRecords(ctx, user)
	if err != nil {
		return out, nil, err
	}
	for i, r := range all {
		if r.Sealed == nil {
			continue
		}
		if !b.Sealing() {
			skipped = append(skipped, r.Name)
			continue
		}
		key := secretKey(user, r.Name)
		b.mu.Lock()
		kept, ok := b.opened[key]
		b.mu.Unlock()
		if !ok || kept.tag != tags[i] {
			plain, err := kms.OpenFor(ctx, b.keeper, r.Sealed, []byte(key))
			if err != nil {
				skipped = append(skipped, r.Name)
				continue
			}
			kept = openedSecret{tag: tags[i], value: string(plain)}
			b.mu.Lock()
			b.opened[key] = kept
			b.mu.Unlock()
		}
		out.Secrets = append(out.Secrets, wire.UserSecret{Name: wire.UserSecretName(r.Name), Value: kept.value})
	}
	return out, skipped, nil
}

// Sent notes that a machine was given these secrets, for user/secretNames and for the
// words when it is removed (FR-026).
func (b *Book) Sent(ctx context.Context, user, host string, names []string) error {
	for _, name := range names {
		err := b.change(ctx, secretKey(user, name), func(raw []byte) ([]byte, error) {
			if raw == nil {
				return nil, nil
			}
			var r secretRecord
			if err := json.Unmarshal(raw, &r); err != nil || r.Sealed == nil || slices.Contains(r.Machines, host) {
				return nil, err
			}
			r.Machines = append(r.Machines, host)
			sort.Strings(r.Machines)
			return records.Encode(r)
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// Left is a machine removed (FR-026): it is struck from every secret it had, which then
// names it in leftOn until the person sets the secret again. It gives the secrets it had.
func (b *Book) Left(ctx context.Context, user, host, hostName string) ([]string, error) {
	if checkUser(user) != nil {
		return nil, nil
	}
	all, _, err := b.secretRecords(ctx, user)
	if err != nil {
		return nil, err
	}
	var had []string
	for _, r := range all {
		if !slices.Contains(r.Machines, host) {
			continue
		}
		name := r.Name
		err := b.change(ctx, secretKey(user, name), func(raw []byte) ([]byte, error) {
			var r secretRecord
			if raw == nil || json.Unmarshal(raw, &r) != nil || !slices.Contains(r.Machines, host) {
				return nil, nil
			}
			r.Machines = slices.DeleteFunc(r.Machines, func(m string) bool { return m == host })
			if r.Sealed != nil {
				r.LeftOn = append(r.LeftOn, wire.SecretLeftOn{Host: wire.MachineRef(host), Name: hostName, At: b.stamp()})
			}
			return records.Encode(r)
		})
		if err != nil {
			return had, err
		}
		if r.Sealed != nil {
			had = append(had, name)
		}
	}
	sort.Strings(had)
	return had, nil
}
