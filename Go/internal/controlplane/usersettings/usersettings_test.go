package usersettings

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func localBook(t *testing.T, s store.Store) *Book {
	t.Helper()
	key := make([]byte, 32)
	rand.Read(key)
	url := "base64key://" + base64.URLEncoding.EncodeToString(key)
	k, err := kms.Keeper(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { k.Close() })
	return New(s, k, url)
}

// everyObject is every object in the store, by key.
func everyObject(t *testing.T, s store.Store) map[string][]byte {
	t.Helper()
	listed, err := s.List(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]byte{}
	for _, k := range listed {
		o, _ := s.Get(context.Background(), k.Key)
		out[k.Key] = o.Data
	}
	return out
}

// recipient is a machine or a client a test seals a secret to, with its own key.
type recipient struct {
	id      string
	private []byte
	public  []byte
}

func newRecipient(t *testing.T, id string) recipient {
	t.Helper()
	private := controllink.NewPrivateKey()
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return recipient{id: id, private: private, public: public}
}

// sealed is what a person's client sends (#3397): a secret sealed to each recipient.
func sealed(t *testing.T, user, name string, version int64, value string, to ...recipient) wire.UserSecretSet {
	t.Helper()
	out := wire.UserSecretSet{Name: wire.UserSecretName(name), Version: version, Values: map[string]wire.SealedEnvelope{}}
	for _, r := range to {
		e, err := controllink.Seal(r.public, controllink.UserSecretPurpose, controllink.UserSecretAD(user, r.id, name, version), []byte(value))
		if err != nil {
			t.Fatal(err)
		}
		out.Values[r.id] = e
	}
	return out
}

func allowing(to ...recipient) map[string]bool {
	out := map[string]bool{}
	for _, r := range to {
		out[r.id] = true
	}
	return out
}

// opens is what a machine does with its copy.
func opens(t *testing.T, r recipient, user string, s wire.SealedUserSecret) (string, error) {
	t.Helper()
	plain, err := controllink.Open(r.private, controllink.UserSecretPurpose, controllink.UserSecretAD(user, r.id, string(s.Name), s.Version), s.Sealed)
	return string(plain), err
}

// #3397: a book with no keeper keeps a person's secrets as their client sealed them; each
// machine gets its own copy, which opens only with its key; one with no copy waits; the
// store holds no value.
func TestASecretIsKeptAsEnvelopesNothingHereOpens(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	b := New(s, nil, "")
	box, mac, other := newRecipient(t, "m:box"), newRecipient(t, "c:MAC"), newRecipient(t, "m:other")
	secrets := map[string]string{"GITHUB_TOKEN": "ghp_" + strings.Repeat("a1", 18), "LINEAR_KEY": "lin_api_s3cret-value"}
	for name, value := range secrets {
		if err := b.SetSecret(ctx, "sam", sealed(t, "sam", name, 1, value, box, mac), allowing(box, mac, other)); err != nil {
			t.Fatal(err)
		}
	}
	got, waiting, err := b.Delivery(ctx, "sam", box.id)
	if err != nil || len(waiting) != 0 || len(got.Secrets) != 2 {
		t.Fatalf("%+v %v %v", got, waiting, err)
	}
	for _, secret := range got.Secrets {
		if value, err := opens(t, box, "sam", secret); err != nil || secrets[string(secret.Name)] != value {
			t.Fatalf("%s came back as something else: %v", secret.Name, err)
		}
		if _, err := opens(t, other, "sam", secret); err == nil {
			t.Fatal("another machine's key opens it")
		}
	}
	// SC-007: no file under the prefix holds a secret, nor its base64, nor any part of it.
	for key, data := range everyObject(t, s) {
		for _, value := range secrets {
			for _, form := range []string{value, base64.StdEncoding.EncodeToString([]byte(value)), value[:12]} {
				if bytes.Contains(data, []byte(form)) {
					t.Fatalf("%s holds a secret", key)
				}
			}
		}
	}
	// A machine with no copy waits for both; another person has none of them.
	if got, waiting, _ := b.Delivery(ctx, "sam", other.id); len(got.Secrets) != 0 || strings.Join(waiting, ",") != "GITHUB_TOKEN|1,LINEAR_KEY|1" {
		t.Fatalf("%+v %v", got, waiting)
	}
	if got, _, _ := b.Delivery(ctx, "kim", box.id); len(got.Secrets) != 0 {
		t.Fatalf("%+v", got)
	}
	// The person's client seals it for the machine that waits: sealing/work names it.
	items, lacks, err := b.Work(ctx, "sam", mac.id, []wire.SealRecipient{{ID: box.id}, {ID: other.id}, {ID: mac.id}})
	if err != nil || len(items) != 2 || len(lacks) != 0 || len(items[0].Missing) != 1 || items[0].Missing[0].ID != other.id {
		t.Fatalf("%+v %v %v", items, lacks, err)
	}
	for _, item := range items {
		value, err := opens(t, mac, "sam", wire.SealedUserSecret{Name: wire.UserSecretName(item.ID), Version: item.Version, Sealed: item.Mine["value"]})
		if err != nil {
			t.Fatal(err)
		}
		again := sealed(t, "sam", item.ID, item.Version, value, other)
		if added, err := b.AddSealed(ctx, "sam", item.ID, item.Version, again.Values, allowing(box, mac, other)); err != nil || !added {
			t.Fatal(added, err)
		}
		// At an older version, or for one that is not a recipient now, nothing is added.
		if added, _ := b.AddSealed(ctx, "sam", item.ID, item.Version+1, again.Values, allowing(box, mac, other)); added {
			t.Fatal("added at another version")
		}
	}
	if got, waiting, _ := b.Delivery(ctx, "sam", other.id); len(got.Secrets) != 2 || len(waiting) != 0 {
		t.Fatalf("%+v %v", got, waiting)
	}
	// A client with no copy says so, for the person's other clients to seal it.
	if _, lacks, _ := b.Work(ctx, "sam", "c:PHONE", nil); len(lacks) != 2 {
		t.Fatal(lacks)
	}
}

// A record copied to another person's secrets does not open on that person's machine:
// the associated data names the person.
func TestAnEnvelopeMovedToAnotherPersonDoesNotOpen(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	b := New(s, nil, "")
	box := newRecipient(t, "m:box")
	b.SetSecret(ctx, "sam", sealed(t, "sam", "TOKEN", 1, "sams-token", box), allowing(box))
	o, _ := s.Get(ctx, secretKey("sam", "TOKEN"))
	s.Put(ctx, secretKey("kim", "TOKEN"), o.Data, store.Absent)
	got, _, err := b.Delivery(ctx, "kim", box.id)
	if err != nil || len(got.Secrets) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := opens(t, box, "kim", got.Secrets[0]); err == nil {
		t.Fatal("sam's secret opens as kim's")
	}
}

func TestNamesNeverHoldValues(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box, spare := newRecipient(t, "m:box"), newRecipient(t, "m:spare")
	b.SetSecret(ctx, "sam", sealed(t, "sam", "TOKEN", 1, "the-value", box), allowing(box, spare))
	rows, _ := b.Names(ctx, "sam", []string{box.id, spare.id})
	raw, _ := json.Marshal(rows)
	if len(rows) != 1 || rows[0].Name != "TOKEN" || deref(rows[0].Version) != 1 || len(rows[0].Waiting) != 1 || rows[0].Waiting[0] != "spare" ||
		strings.Contains(string(raw), "the-value") {
		t.Fatalf("%s", raw)
	}
	if had, _ := b.RemoveSecret(ctx, "sam", "TOKEN"); !had {
		t.Fatal("not removed")
	}
	if rows, _ := b.Names(ctx, "sam", nil); len(rows) != 0 {
		t.Fatalf("%+v", rows)
	}
	if got, _, _ := b.Delivery(ctx, "sam", box.id); len(got.Secrets) != 0 {
		t.Fatalf("%+v", got)
	}
	// Set again after its removal, it takes the next version.
	if err := b.SetSecret(ctx, "sam", sealed(t, "sam", "TOKEN", 1, "again", box), allowing(box)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if err := b.SetSecret(ctx, "sam", sealed(t, "sam", "TOKEN", 2, "again", box), allowing(box)); err != nil {
		t.Fatal(err)
	}
}

func deref[T any](p *T) T {
	var zero T
	if p == nil {
		return zero
	}
	return *p
}

func kinded(set wire.UserSecretSet, kind wire.UserSecretKind) wire.UserSecretSet {
	set.Kind = &kind
	return set
}

// #3531: a card's kind is kept with its name, so the clients draw it as a card, and a
// plain value set again over it is plain.
func TestACardsKindIsKeptWithItsName(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box := newRecipient(t, "m:box")
	card := `{"number":"4111111111111111","expiry":"12/30","cvc":"123","name":"Sam Lee","zip":"94110"}`
	if err := b.SetSecret(ctx, "sam", kinded(sealed(t, "sam", "SHOP_CARD", 1, card, box), wire.UserSecretKindCard), allowing(box)); err != nil {
		t.Fatal(err)
	}
	rows, err := b.Names(ctx, "sam", nil)
	if err != nil || len(rows) != 1 || rows[0].Kind == nil || *rows[0].Kind != wire.UserSecretKindCard {
		t.Fatalf("%+v %v", rows, err)
	}
	if err := b.SetSecret(ctx, "sam", sealed(t, "sam", "SHOP_CARD", 2, "plain", box), allowing(box)); err != nil {
		t.Fatal(err)
	}
	if rows, _ := b.Names(ctx, "sam", nil); rows[0].Kind != nil {
		t.Fatalf("still a card: %+v", rows[0])
	}
}

func TestSecretsAreChecked(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box := newRecipient(t, "m:box")
	for _, c := range []struct {
		name string
		set  wire.UserSecretSet
	}{
		{"lower", sealed(t, "sam", "lower", 1, "s3kr1t", box)},
		{"../X", sealed(t, "sam", "../X", 1, "s3kr1t", box)},
		{"no envelope", sealed(t, "sam", "X", 1, "s3kr1t")},
		{"too long", sealed(t, "sam", "X", 1, strings.Repeat("s3kr1t", MaxSecret), box)},
		{"no version", sealed(t, "sam", "X", 0, "s3kr1t", box)},
		{"to nobody of theirs", sealed(t, "sam", "X", 1, "s3kr1t", newRecipient(t, "m:kims"))},
		{"an unknown kind", kinded(sealed(t, "sam", "X", 1, "s3kr1t", box), "bank")},
	} {
		err := b.SetSecret(ctx, "sam", c.set, allowing(box))
		if !errors.Is(err, ErrInvalid) || strings.Contains(err.Error(), "s3kr1t") {
			t.Fatalf("%s: %v", c.name, err)
		}
	}
	if err := b.SetSecret(ctx, "../kim", sealed(t, "../kim", "X", 1, "v", box), allowing(box)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}

func TestPartsAreKeptWithoutBeingRead(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	servers := json.RawMessage(`{"github":{"url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_TOKEN}"}}}`)
	if changed, err := b.SetPart(ctx, "sam", wire.UserSettingsPartNameMcpServers, servers); err != nil || !changed {
		t.Fatal(changed, err)
	}
	if changed, _ := b.SetPart(ctx, "sam", wire.UserSettingsPartNameMcpServers, servers); changed {
		t.Fatal("the same part again is a change")
	}
	if _, err := b.SetPart(ctx, "sam", wire.UserSettingsPartName("resources"), json.RawMessage(`[]`)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if _, err := b.SetPart(ctx, "sam", "theme", json.RawMessage(`{}`)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	got, _ := b.Settings(ctx, "sam")
	if got.McpServers == nil || got.Updated == nil {
		t.Fatalf("%+v", got)
	}
	b.SetPart(ctx, "sam", wire.UserSettingsPartNameMcpServers, json.RawMessage(`null`))
	if got, _ := b.Settings(ctx, "sam"); got.McpServers != nil {
		t.Fatalf("%+v", got)
	}
}

// The largest delivery the bounds on parts and secrets allow fits one frame on a machine's
// link, with room to spare (#2730): each part and each secret as long as it may be, of
// what JSON writes longest.
func TestTheLargestDeliveryFitsAMachinesLink(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	box := newRecipient(t, "m:box")
	long := func(n int) string { return strings.Repeat("<", n) }
	for _, part := range []wire.UserSettingsPartName{wire.UserSettingsPartNameMcpServers, wire.UserSettingsPartNameAgentConfig,
		wire.UserSettingsPartNameRuntimes, wire.UserSettingsPartNameCostLimits} {
		value := json.RawMessage(`{"x":"` + long(MaxPart-8) + `"}`)
		if _, err := b.SetPart(ctx, "sam", part, value); err != nil {
			t.Fatal(err)
		}
	}
	for i := range MaxSecrets {
		name := fmt.Sprintf("SECRET_%d", i)
		if err := b.SetSecret(ctx, "sam", sealed(t, "sam", name, 1, long(MaxSecret), box), allowing(box)); err != nil {
			t.Fatal(err)
		}
	}
	delivery, waiting, err := b.Delivery(ctx, "sam", box.id)
	if err != nil || len(waiting) > 0 || len(delivery.Secrets) != MaxSecrets {
		t.Fatal(len(delivery.Secrets), waiting, err)
	}
	encoded, _ := json.Marshal(delivery)
	if len(encoded) > controllink.MaxMessage/2 {
		t.Fatalf("the largest delivery is %d MB, too near the %d MB a machine's link takes", len(encoded)>>20, controllink.MaxMessage>>20)
	}
}

func TestAMachineLeftIsNamedOnTheSecretsItHad(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box := newRecipient(t, "m:box")
	b.SetSecret(ctx, "sam", sealed(t, "sam", "A", 1, "1", box), allowing(box))
	b.SetSecret(ctx, "sam", sealed(t, "sam", "B", 1, "2", box), allowing(box))
	b.Sent(ctx, "sam", "box", []string{"A", "B"})
	b.Sent(ctx, "sam", "mac", []string{"A"})
	had, err := b.Left(ctx, "sam", "box", "Sam's box")
	if err != nil || strings.Join(had, ",") != "A,B" {
		t.Fatal(had, err)
	}
	rows, _ := b.Names(ctx, "sam", nil)
	if len(rows) != 2 || len(rows[0].Machines) != 1 || rows[0].Machines[0] != "mac" || len(rows[0].LeftOn) != 1 || rows[0].LeftOn[0].Name != "Sam's box" {
		t.Fatalf("%+v", rows)
	}
	// Set again, the secret is a new one: the machine it was on no longer matters.
	b.SetSecret(ctx, "sam", sealed(t, "sam", "A", 2, "3", box), allowing(box))
	if rows, _ := b.Names(ctx, "sam", nil); len(rows[0].LeftOn) != 0 || len(rows[0].Machines) != 1 {
		t.Fatalf("%+v", rows)
	}
}

// One bucket for the person (#2859): two machines take from the same notices, with the
// limits of the person's notifications part, kept in the store so a restart keeps it.
func TestEveryMachineTakesFromThePersonsOneBucket(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	b := localBook(t, s)
	at := time.Unix(1_000_000, 0)
	b.now = func() time.Time { return at }
	if changed, err := b.SetNoticeLimits(ctx, "sam", wire.NoticeLimits{Burst: 2, CooldownMinutes: 10}); err != nil || !changed {
		t.Fatal(changed, err)
	}
	// The machine says 5, from before the part came to it: the part decides.
	machine := wire.NoticeLimits{Burst: 5, CooldownMinutes: 1}
	// The third is another copy of the control plane, or this one after a restart.
	other := New(s, nil, "")
	other.now = b.now
	for i, book := range []*Book{b, b, other} {
		got, err := book.TakeNotice(ctx, "sam", machine)
		if want := i < 2; err != nil || got.Sent != want {
			t.Fatalf("notice %d: %+v %v", i, got, err)
		}
	}
	got, _ := b.TakeNotice(ctx, "sam", machine)
	if got.Sent || !got.NextAt.Time().Equal(at.Add(10*time.Minute)) {
		t.Fatalf("in the cool-down: %+v", got)
	}
	// Another person has a bucket of their own.
	if got, _ := b.TakeNotice(ctx, "kim", machine); !got.Sent || got.Left != 4 {
		t.Fatalf("kim: %+v", got)
	}
	// A machine's limits are kept within the bounds.
	b.SetNoticeLimits(ctx, "sam", wire.NoticeLimits{Burst: 500, CooldownMinutes: 0})
	settings, _ := b.Settings(ctx, "sam")
	var kept wire.NoticeLimits
	if json.Unmarshal(settings.Notifications, &kept); kept != (wire.NoticeLimits{Burst: 20, CooldownMinutes: 10}) {
		t.Fatal(string(settings.Notifications))
	}
}

// #4014: Ask before use goes where the client said, on the row and in each machine's copy.
// The control plane changes nothing in it: a machine opens a copy only with the flag its
// client sealed (agentsd's TestYourSetupsFlagIsSealed).
func TestAskBeforeUseIsCarriedAsTheClientSaidIt(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box := newRecipient(t, "m:box")
	set := wire.UserSecretSet{Name: "SHOP_PASSWORD", Version: 1, Values: map[string]wire.SealedEnvelope{}, NeedsApproval: new(true)}
	e, err := controllink.Seal(box.public, controllink.UserSecretPurpose, controllink.UserSecretADAsk("sam", box.id, "SHOP_PASSWORD", 1, true), []byte("hunter2"))
	if err != nil {
		t.Fatal(err)
	}
	set.Values[box.id] = e
	if err := b.SetSecret(ctx, "sam", set, allowing(box)); err != nil {
		t.Fatal(err)
	}
	rows, err := b.Names(ctx, "sam", nil)
	if err != nil || len(rows) != 1 || rows[0].NeedsApproval == nil || !*rows[0].NeedsApproval {
		t.Fatalf("%+v %v", rows, err)
	}
	got, _, err := b.Delivery(ctx, "sam", box.id)
	if err != nil || len(got.Secrets) != 1 || got.Secrets[0].NeedsApproval == nil || !*got.Secrets[0].NeedsApproval {
		t.Fatalf("%+v %v", got, err)
	}
	s := got.Secrets[0]
	if _, err := opens(t, box, "sam", s); err == nil {
		t.Fatal("a flagged copy opened without its flag")
	}
	if plain, err := controllink.Open(box.private, controllink.UserSecretPurpose, controllink.UserSecretADAsk("sam", box.id, "SHOP_PASSWORD", 1, true), s.Sealed); err != nil || string(plain) != "hunter2" {
		t.Fatal(err)
	}
	// A new machine waits for a client to seal it a copy: the work says |ask, or the copy
	// would not open there (#4016).
	items, _, err := b.Work(ctx, "sam", box.id, []wire.SealRecipient{{ID: "m:new"}})
	if err != nil || len(items) != 1 || items[0].NeedsApproval == nil || !*items[0].NeedsApproval {
		t.Fatalf("%+v %v", items, err)
	}
}

// #4167: a secret's description is kept beside its name, in clear, and goes to the clients'
// rows, to each machine with its copy, and to a machine with no copy yet as one it waits for.
func TestASecretsDescriptionIsKeptBesideItsName(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box, other := newRecipient(t, "m:box"), newRecipient(t, "m:other")
	set := sealed(t, "sam", "GITHUB_TOKEN", 1, "hunter2", box)
	set.Description = new("  A token for alexec/Agents: contents, read and write.  ")
	if err := b.SetSecret(ctx, "sam", set, allowing(box)); err != nil {
		t.Fatal(err)
	}
	const want = "A token for alexec/Agents: contents, read and write."
	rows, err := b.Names(ctx, "sam", nil)
	if err != nil || len(rows) != 1 || rows[0].Description == nil || *rows[0].Description != want {
		t.Fatalf("%+v %v", rows, err)
	}
	got, _, err := b.Delivery(ctx, "sam", box.id)
	if err != nil || len(got.Secrets) != 1 || got.Secrets[0].Description == nil || *got.Secrets[0].Description != want || len(got.Waiting) != 0 {
		t.Fatalf("%+v %v", got, err)
	}
	got, _, err = b.Delivery(ctx, "sam", other.id)
	if err != nil || len(got.Secrets) != 0 || len(got.Waiting) != 1 || got.Waiting[0].Name != "GITHUB_TOKEN" ||
		got.Waiting[0].Description == nil || *got.Waiting[0].Description != want {
		t.Fatalf("%+v %v", got, err)
	}
	// Set again with none, it has none.
	if err := b.SetSecret(ctx, "sam", sealed(t, "sam", "GITHUB_TOKEN", 2, "hunter3", box), allowing(box)); err != nil {
		t.Fatal(err)
	}
	if rows, _ := b.Names(ctx, "sam", nil); rows[0].Description != nil {
		t.Fatalf("still described: %+v", rows[0])
	}
}

// #4167: a description is not sealed, so one that looks like a value, or is more than a line
// or two, is refused.
func TestASecretsDescriptionThatLooksLikeAValueIsRefused(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory(), nil, "")
	box := newRecipient(t, "m:box")
	for _, d := range []string{"the token is ghp_abcdefghijklmnopqrstuvwxyz0123456789", "card 4111 1111 1111 1111",
		"two\nlines", strings.Repeat("a", MaxSecretDescription+1)} {
		set := sealed(t, "sam", "GITHUB_TOKEN", 1, "hunter2", box)
		set.Description = new(d)
		if err := b.SetSecret(ctx, "sam", set, allowing(box)); !errors.Is(err, ErrInvalid) {
			t.Errorf("%q: %v", d, err)
		}
	}
}
