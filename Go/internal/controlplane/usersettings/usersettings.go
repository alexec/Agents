// Package usersettings keeps each person's user settings and secrets (#1760, spec 736 US4,
// FR-023–FR-026): what follows the person to every machine of theirs.
//
// Settings are plain records, one per person, which the control plane keeps and sends but
// does not read inside:
//
//	v1/users/<user>/settings.json          wire.UserSettings
//	v1/users/<user>/notices.json           the person's notice bucket (#2859)
//	v1/users/<user>/secrets/<NAME>.json    a secret, sealed (FR-025, SC-007)
//
// Each secret is sealed by the person's client, with HPKE, to each of their machines and
// clients (#3397, specs/3397-client-sealing): the record keeps one envelope a recipient,
// and the control plane opens none. The associated data binds the person, the recipient,
// the name and the version, so a record copied to another person's secrets, or an older
// version, does not open. No value is in the store, the control plane's memory, a log line
// or an event.
package usersettings

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"gocloud.dev/secrets"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/noticebucket"
	"github.com/alexec/agents/Go/wire"
)

// Prefix is where every person's user settings are in the store.
const Prefix = "v1/users/"

// The bounds on what one person keeps, so no person fills the store or a machine's link.
const (
	MaxPart    = 256 << 10
	MaxSecret  = 16 << 10
	MaxSecrets = 200
	// MaxRecipients bounds the machines and clients a secret is sealed to (#3397).
	MaxRecipients = 200
)

var (
	// ErrNoSealing is SealFor or OpenFor on a control plane with no keeper for secrets.
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
}

// New is a book over s. keeper seals and opens what other parts of the control plane keep
// (SealFor, OpenFor); a person's own secrets are sealed by their clients and need none.
func New(s store.Store, keeper *secrets.Keeper, keeperURL string) *Book {
	return &Book{store: s, keeper: keeper, keeperURL: keeperURL, now: time.Now}
}

// Sealing says whether this book has a keeper for SealFor and OpenFor.
func (b *Book) Sealing() bool { return b != nil && b.keeper != nil }

// SealFor seals a value with this book's keeper, bound to the store key it is kept at.
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
func noticesKey(user string) string      { return Prefix + user + "/notices.json" }

// secretRecord is a secret as stored. Sealed is nil once the secret is removed: the record
// stays, as a tombstone, so a removal is a conditional write like any other.
type secretRecord struct {
	Name    string `json:"name"`
	Version int64  `json:"version,omitempty"`
	// Kind is what the value holds, such as a card (#3531); empty for a plain value. It is
	// not secret: the clients draw a card's row and its sheet from it.
	Kind string `json:"kind,omitempty"`
	// Sealed is each recipient's envelope (m:<machine> or c:<client>), as the person's
	// client sealed it (#3397). Nothing here opens one.
	Sealed   map[string]wire.SealedEnvelope `json:"sealed,omitempty"`
	Updated  string                         `json:"updated"`
	Machines []string                       `json:"machines,omitempty"`
	LeftOn   []wire.SecretLeftOn            `json:"leftOn,omitempty"`
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
	// A record kept before #2703 can hold the machines' agent configuration files, which
	// nothing reads now and which can be more than a machine's link takes (#2730).
	out.AgentConfigFiles = nil
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
		wire.UserSettingsPartNameRuntimes, wire.UserSettingsPartNameCostLimits, wire.UserSettingsPartNameNotifications:
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
		s.AgentConfigFiles = nil
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
	case wire.UserSettingsPartNameNotifications:
		return &s.Notifications
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

// SetPolicy is the part policy as the keeper sends it (user/setPolicy, #2957, research
// R11): stored unchanged, kept only when its revision is higher than the one already there.
// The control plane can read the layer (no secret in it) but does not sign or change it;
// only HostSaid's caller check (the sender is the layer's own keeper) guards who may call
// this. It says whether anything changed.
func (b *Book) SetPolicy(ctx context.Context, user string, signed wire.SignedYourPolicy) (bool, error) {
	if err := checkUser(user); err != nil {
		return false, err
	}
	value, err := json.Marshal(signed)
	if err != nil {
		return false, fmt.Errorf("%w: policy is not a signed policy", ErrInvalid)
	}
	if len(value) > MaxPart {
		return false, fmt.Errorf("%w: policy is over %d KB", ErrInvalid, MaxPart>>10)
	}
	decoded, err := base64.StdEncoding.DecodeString(signed.Policy)
	if err != nil {
		return false, fmt.Errorf("%w: policy is not base64", ErrInvalid)
	}
	var next wire.YourPolicy
	if json.Unmarshal(decoded, &next) != nil || next.Revision < 1 {
		return false, fmt.Errorf("%w: policy is not a YourPolicy", ErrInvalid)
	}
	changed := false
	err = b.change(ctx, settingsKey(user), func(raw []byte) ([]byte, error) {
		var s wire.UserSettings
		if raw != nil {
			if err := json.Unmarshal(raw, &s); err != nil {
				return nil, err
			}
		}
		s.AgentConfigFiles = nil
		var current wire.YourPolicy
		if partSent(s.Policy) {
			var currentSigned wire.SignedYourPolicy
			if json.Unmarshal(s.Policy, &currentSigned) == nil {
				if decoded, err := base64.StdEncoding.DecodeString(currentSigned.Policy); err == nil {
					json.Unmarshal(decoded, &current)
				}
			}
		}
		if next.Revision <= current.Revision {
			return nil, nil // not newer: kept, silently (the keeper may resend the same layer)
		}
		s.Policy = value
		changed = true
		at := b.stamp()
		s.Updated = &at
		return records.Encode(s)
	})
	return changed, err
}

// SetNoticeLimits is the notifications part as a machine of the person's sends it
// (user/setNoticeLimits), within the bounds. It says whether anything changed.
func (b *Book) SetNoticeLimits(ctx context.Context, user string, limits wire.NoticeLimits) (bool, error) {
	burst, cooldown := noticebucket.Limits(limits.Burst, limits.CooldownMinutes)
	value, _ := json.Marshal(wire.NoticeLimits{Burst: int64(burst), CooldownMinutes: cooldown.Minutes()})
	return b.SetPart(ctx, user, wire.UserSettingsPartNameNotifications, value)
}

// TakeNotice is notices/take: one notice from the person's one bucket, which every
// machine of theirs shares (#2859). The person's notifications part decides the limits;
// without one, the machine's own (given).
func (b *Book) TakeNotice(ctx context.Context, user string, given wire.NoticeLimits) (wire.NoticeTaken, error) {
	var out wire.NoticeTaken
	if err := checkUser(user); err != nil {
		return out, err
	}
	settings, err := b.Settings(ctx, user)
	if err != nil {
		return out, err
	}
	limits := given
	if partSent(settings.Notifications) {
		var kept wire.NoticeLimits
		if json.Unmarshal(settings.Notifications, &kept) == nil {
			limits = kept
		}
	}
	burst, cooldown := noticebucket.Limits(limits.Burst, limits.CooldownMinutes)
	err = b.change(ctx, noticesKey(user), func(raw []byte) ([]byte, error) {
		var bucket noticebucket.Bucket
		if raw != nil {
			// A record that will not read is a full bucket, not a person who can be told nothing.
			json.Unmarshal(raw, &bucket)
		}
		left, next, ok := bucket.Take(b.now(), burst, cooldown)
		out = wire.NoticeTaken{Sent: ok, Left: int64(left), NextAt: wire.DateOf(next)}
		return records.Encode(bucket)
	})
	return out, err
}

func partSent(v wire.JSONValue) bool { return len(v) > 0 && string(v) != "null" }

// CheckName says whether a secret's name may be kept. Its value is sealed by the person's
// client (#3397): the client checks it, and only its envelopes' sizes are checked here.
func CheckName(name string) error {
	if !secretName.MatchString(name) {
		return fmt.Errorf("%w: a secret's name is capital letters, digits and _, such as GITHUB_TOKEN", ErrInvalid)
	}
	return nil
}

// checkEnvelopes bounds a secret's envelopes: at least one, at most MaxRecipients, each the
// size a value of at most MaxSecret seals to.
func checkEnvelopes(values map[string]wire.SealedEnvelope) error {
	if len(values) == 0 {
		return fmt.Errorf("%w: seal the secret to at least one machine or app", ErrInvalid)
	}
	if len(values) > MaxRecipients {
		return fmt.Errorf("%w: a secret is sealed to at most %d machines and apps", ErrInvalid, MaxRecipients)
	}
	for _, e := range values {
		if len(e.Encapsulated) != 65 || len(e.Ciphertext) < 17 || len(e.Ciphertext) > MaxSecret+16 {
			return fmt.Errorf("%w: a secret is 1 byte to %d KB", ErrInvalid, MaxSecret>>10)
		}
	}
	return nil
}

// SetSecret keeps a secret as the person's client sealed it, at a version above the kept
// one, a removed one's too, to the recipients allowed names. A client sets the kept one plus
// one, or for a name it has none of, the time in milliseconds: above a removed one's, which
// it cannot see. A secret set again forgets
// the machines that were removed with the old value on them: the person has changed it.
func (b *Book) SetSecret(ctx context.Context, user string, set wire.UserSecretSet, allowed map[string]bool) error {
	if err := checkUser(user); err != nil {
		return err
	}
	name := string(set.Name)
	if err := CheckName(name); err != nil {
		return err
	}
	if err := checkEnvelopes(set.Values); err != nil {
		return err
	}
	if set.Kind != nil && *set.Kind != wire.UserSecretKindCard {
		return fmt.Errorf("%w: a secret's kind is card, or left out", ErrInvalid)
	}
	key := secretKey(user, name)
	if names, err := b.liveNames(ctx, user); err != nil {
		return err
	} else if len(names) >= MaxSecrets && !slices.Contains(names, name) {
		return fmt.Errorf("%w: a person keeps at most %d secrets", ErrInvalid, MaxSecrets)
	}
	sealed := map[string]wire.SealedEnvelope{}
	for recipient, e := range set.Values {
		if allowed[recipient] {
			sealed[recipient] = e
		}
	}
	if len(sealed) == 0 {
		return fmt.Errorf("%w: none of the machines or apps it was sealed to is yours now; try again", ErrInvalid)
	}
	return b.change(ctx, key, func(raw []byte) ([]byte, error) {
		var r secretRecord
		if raw != nil {
			if err := json.Unmarshal(raw, &r); err != nil {
				return nil, err
			}
		}
		if set.Version <= r.Version {
			return nil, fmt.Errorf("%w: the secret changed in another app; load it again, then set it", ErrInvalid)
		}
		var kind string
		if set.Kind != nil {
			kind = string(*set.Kind)
		}
		r = secretRecord{Name: name, Version: set.Version, Kind: kind, Sealed: sealed, Updated: b.stamp(), Machines: r.Machines}
		return records.Encode(r)
	})
}

// AddSealed keeps the copies a client sealed for a secret's recipients that had none, at
// its current version, and drops those that are no longer recipients. It says whether one
// was added.
func (b *Book) AddSealed(ctx context.Context, user, name string, version int64, values map[string]wire.SealedEnvelope,
	allowed map[string]bool) (bool, error) {
	if err := checkUser(user); err != nil {
		return false, err
	}
	if CheckName(name) != nil || len(values) == 0 {
		return false, nil
	}
	if err := checkEnvelopes(values); err != nil {
		return false, err
	}
	added := false
	err := b.change(ctx, secretKey(user, name), func(raw []byte) ([]byte, error) {
		added = false
		var r secretRecord
		if raw == nil || json.Unmarshal(raw, &r) != nil || r.Sealed == nil || r.Version != version {
			return nil, nil
		}
		next := map[string]wire.SealedEnvelope{}
		for recipient, e := range r.Sealed {
			if allowed[recipient] {
				next[recipient] = e
			}
		}
		for recipient, e := range values {
			if _, ok := next[recipient]; ok || !allowed[recipient] {
				continue
			}
			next[recipient] = e
			added = true
		}
		if !added {
			return nil, nil
		}
		r.Sealed = next
		return records.Encode(r)
	})
	return added, err
}

// RemoveSecret removes a secret. It says whether there was one. The tombstone keeps the
// version, so a secret set again under the name takes the next one.
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
		return records.Encode(secretRecord{Name: name, Version: r.Version, Updated: b.stamp()})
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

// Names is user/secretNames: each secret's name, its version, when it changed, the
// machines it went to, the removed machines it was on, and which of machines (the person's
// that take secrets, as recipients) wait for a copy. Never a value.
func (b *Book) Names(ctx context.Context, user string, machines []string) ([]wire.UserSecretRow, error) {
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
		version := r.Version
		row := wire.UserSecretRow{Name: wire.UserSecretName(r.Name), Version: &version, Updated: r.Updated, Machines: []wire.MachineRef{},
			LeftOn: r.LeftOn}
		if r.Kind != "" {
			kind := wire.UserSecretKind(r.Kind)
			row.Kind = &kind
		}
		for _, m := range r.Machines {
			row.Machines = append(row.Machines, wire.MachineRef(m))
		}
		for _, recipient := range machines {
			if _, ok := r.Sealed[recipient]; !ok {
				row.Waiting = append(row.Waiting, wire.MachineRef(strings.TrimPrefix(recipient, "m:")))
			}
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows, nil
}

// Work is sealing/work's part for a person's client (#3397): each secret the client has a
// copy of that one of recipients has not, with those recipients; and the asks for the
// secrets this client has no copy of, for the person's other clients.
func (b *Book) Work(ctx context.Context, user, client string, recipients []wire.SealRecipient) ([]wire.SealingItem, []string, error) {
	if checkUser(user) != nil {
		return nil, nil, nil
	}
	all, _, err := b.secretRecords(ctx, user)
	if err != nil {
		return nil, nil, err
	}
	var items []wire.SealingItem
	var lacks []string
	for _, r := range all {
		if r.Sealed == nil {
			continue
		}
		mine, ok := r.Sealed[client]
		if !ok {
			lacks = append(lacks, fmt.Sprintf("secret|%s|%s|%d|%s", user, r.Name, r.Version, client))
			continue
		}
		missing := []wire.SealRecipient{}
		for _, recipient := range recipients {
			if _, ok := r.Sealed[recipient.ID]; !ok {
				missing = append(missing, recipient)
			}
		}
		if len(missing) > 0 {
			u := user
			items = append(items, wire.SealingItem{Item: wire.SealingItemKindUserSecret, ID: r.Name, User: &u, Version: r.Version,
				Mine: map[string]wire.SealedEnvelope{"value": mine}, Missing: missing})
		}
	}
	return items, lacks, nil
}

// Delivery is machine/userSettings for a machine of user's: the settings, and each secret as
// the person's client sealed it to recipient, the machine. Only for that user's own
// machine's link (FR-025). A secret with no copy for it is left out, and named in waiting
// as <name>|<version>.
// Nothing here opens a secret.
func (b *Book) Delivery(ctx context.Context, user, recipient string) (out wire.MachineUserSettings, waiting []string, err error) {
	settings, err := b.Settings(ctx, user)
	if err != nil {
		return out, nil, err
	}
	out = wire.MachineUserSettings{User: user, Settings: settings, Secrets: []wire.SealedUserSecret{}}
	if recipient == "" {
		return out, nil, nil
	}
	all, _, err := b.secretRecords(ctx, user)
	if err != nil {
		return out, nil, err
	}
	for _, r := range all {
		if r.Sealed == nil {
			continue
		}
		e, ok := r.Sealed[recipient]
		if !ok {
			waiting = append(waiting, fmt.Sprintf("%s|%d", r.Name, r.Version))
			continue
		}
		out.Secrets = append(out.Secrets, wire.SealedUserSecret{Name: wire.UserSecretName(r.Name), Version: r.Version, Sealed: e})
	}
	return out, waiting, nil
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
