package usersettings

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

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

func TestASecretGoesInAnEnvelopeAndComesBack(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	b := localBook(t, s)
	secrets := map[string]string{"GITHUB_TOKEN": "ghp_" + strings.Repeat("a1", 18), "LINEAR_KEY": "lin_api_s3cret-value"}
	for name, value := range secrets {
		if err := b.SetSecret(ctx, "sam", name, value); err != nil {
			t.Fatal(err)
		}
	}
	got, skipped, err := b.Delivery(ctx, "sam")
	if err != nil || len(skipped) != 0 || len(got.Secrets) != 2 {
		t.Fatalf("%+v %v %v", got, skipped, err)
	}
	for _, secret := range got.Secrets {
		if secrets[string(secret.Name)] != secret.Value {
			t.Fatalf("%s came back as something else", secret.Name)
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
	// Another person has none of them.
	if other, _, _ := b.Delivery(ctx, "kim"); len(other.Secrets) != 0 {
		t.Fatalf("%+v", other)
	}
}

func TestAnEnvelopeMovedToAnotherPersonDoesNotOpen(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	b := localBook(t, s)
	b.SetSecret(ctx, "sam", "TOKEN", "sams-token")
	o, _ := s.Get(ctx, secretKey("sam", "TOKEN"))
	s.Put(ctx, secretKey("kim", "TOKEN"), o.Data, store.Absent)
	got, skipped, err := b.Delivery(ctx, "kim")
	if err != nil || len(got.Secrets) != 0 || len(skipped) != 1 {
		t.Fatalf("%+v %v %v", got, skipped, err)
	}
	// And with another keeper's key, nothing opens.
	other := localBook(t, s)
	if got, skipped, _ := other.Delivery(ctx, "sam"); len(got.Secrets) != 0 || len(skipped) != 1 {
		t.Fatalf("%+v %v", got, skipped)
	}
}

func TestNamesNeverHoldValues(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	b.SetSecret(ctx, "sam", "TOKEN", "the-value")
	rows, _ := b.Names(ctx, "sam")
	raw, _ := json.Marshal(rows)
	if len(rows) != 1 || rows[0].Name != "TOKEN" || strings.Contains(string(raw), "the-value") {
		t.Fatalf("%s", raw)
	}
	if had, _ := b.RemoveSecret(ctx, "sam", "TOKEN"); !had {
		t.Fatal("not removed")
	}
	if rows, _ := b.Names(ctx, "sam"); len(rows) != 0 {
		t.Fatalf("%+v", rows)
	}
	if got, _, _ := b.Delivery(ctx, "sam"); len(got.Secrets) != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestSecretsAreChecked(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	for _, c := range []struct{ name, value string }{
		{"lower", "s3kr1t"}, {"../X", "s3kr1t"}, {"X", ""}, {"X", "two\nlines"}, {"X", strings.Repeat("s3kr1t", MaxSecret)},
	} {
		err := b.SetSecret(ctx, "sam", c.name, c.value)
		if !errors.Is(err, ErrInvalid) || (c.value != "" && strings.Contains(err.Error(), c.value)) {
			t.Fatalf("%q: %v", c.name, err)
		}
	}
	if err := b.SetSecret(ctx, "../kim", "X", "v"); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if err := New(store.NewMemory(), nil, "").SetSecret(ctx, "sam", "X", "v"); !errors.Is(err, ErrNoSealing) {
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

func TestAMachineLeftIsNamedOnTheSecretsItHad(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	b.SetSecret(ctx, "sam", "A", "1")
	b.SetSecret(ctx, "sam", "B", "2")
	b.Sent(ctx, "sam", "box", []string{"A", "B"})
	b.Sent(ctx, "sam", "mac", []string{"A"})
	had, err := b.Left(ctx, "sam", "box", "Sam's box")
	if err != nil || strings.Join(had, ",") != "A,B" {
		t.Fatal(had, err)
	}
	rows, _ := b.Names(ctx, "sam")
	if len(rows) != 2 || len(rows[0].Machines) != 1 || rows[0].Machines[0] != "mac" || len(rows[0].LeftOn) != 1 || rows[0].LeftOn[0].Name != "Sam's box" {
		t.Fatalf("%+v", rows)
	}
	// Set again, the secret is a new one: the machine it was on no longer matters.
	b.SetSecret(ctx, "sam", "A", "3")
	if rows, _ := b.Names(ctx, "sam"); len(rows[0].LeftOn) != 0 || len(rows[0].Machines) != 1 {
		t.Fatalf("%+v", rows)
	}
}

// Copies over one store (#2163): each given the same secrets-key file, as compose.yaml
// mounts it, opens what another sealed; a copy with a key of its own opens nothing.
func TestCopiesWithOneSecretsKeyOpenEachOthersSecrets(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	made := t.TempDir() + "/secrets-key"
	if _, err := kms.LocalKeeper(made); err != nil {
		t.Fatal(err)
	}
	book := func(path string) *Book {
		url, err := kms.LocalKeeper(path)
		if err != nil {
			t.Fatal(err)
		}
		k, err := kms.Keeper(ctx, url)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { k.Close() })
		return New(s, k, url)
	}
	given := func() string {
		data, err := os.ReadFile(made)
		if err != nil {
			t.Fatal(err)
		}
		path := t.TempDir() + "/secrets-key"
		if err := os.WriteFile(path, data, 0o444); err != nil {
			t.Fatal(err)
		}
		return path
	}
	if err := book(given()).SetSecret(ctx, "sam", "LINEAR_KEY", "lin_api_s3cret"); err != nil {
		t.Fatal(err)
	}
	got, skipped, err := book(given()).Delivery(ctx, "sam")
	if err != nil || len(skipped) != 0 || len(got.Secrets) != 1 || got.Secrets[0].Value != "lin_api_s3cret" {
		t.Fatalf("another copy got %+v, skipped %v, %v", got.Secrets, skipped, err)
	}
	if _, skipped, _ := book(t.TempDir()+"/secrets-key").Delivery(ctx, "sam"); len(skipped) != 1 {
		t.Fatalf("a copy with its own key skipped %v", skipped)
	}
}
