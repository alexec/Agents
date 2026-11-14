package controlplane

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// sealedSecretEntries are the audit's user/sealedSecret entries, as the person's window
// lists them.
func sealedSecretEntries(t *testing.T, window *controllink.Session) ([]wire.AuditEntry, string) {
	t.Helper()
	raw := call(t, window, "", "audit/list", wire.AuditQuery{})
	var list wire.AuditList
	json.Unmarshal(raw, &list)
	var out []wire.AuditEntry
	for _, e := range list.Entries {
		if e.Method == wire.CallUserSealedSecret.Name {
			out = append(out, e)
		}
	}
	return out, string(raw)
}

// openSealed is what the person's client does with user/sealedSecret's answer: it opens its
// own copy with its own key.
func openSealed(t *testing.T, user string, member *controllink.ClientMembership, got wire.UserSealedSecret) string {
	t.Helper()
	ad := controllink.UserSecretADAsk(user, controllink.ClientRecipient(member.Client), string(got.Name), got.Version, deref(got.NeedsApproval))
	plain, err := controllink.Open(member.Private, controllink.UserSecretPurpose, ad, got.Sealed)
	if err != nil {
		t.Fatalf("this client's copy does not open: %v", err)
	}
	return string(plain)
}

// #5114 (specs/5112-view-copy-secrets-accounts/wireframes.md, sections 9 and 10): a
// person's own client gets its own sealed copy of a secret, to reveal or copy; each call
// is in the audit with the name and the client, never the value; another person, a client
// with no copy yet and a machine get nothing.
func TestAPersonsClientGetsItsOwnCopyOfASecretWithAnAuditEntry(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	member, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), member: member, window: window}
	box := p.machineSaying(alex, takingHello("MACHINE-20"))
	const value = "ghp_9xT2mQe7LkV0aRz4YpW8cN1sFb3uJd6hab12"
	setSecret(t, alex, "GITHUB_TOKEN", value, 0)

	// A reveal, then a copy from an account: each gives this client's own copy.
	var got wire.UserSealedSecret
	json.Unmarshal(call(t, window, "", "user/sealedSecret",
		wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: wire.UserSealedSecretPurposeReveal}), &got)
	if got.Name != "GITHUB_TOKEN" || got.Version != 1 || openSealed(t, alex.id, member, got) != value {
		t.Fatalf("%+v", got)
	}
	got = wire.UserSealedSecret{}
	json.Unmarshal(call(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN",
		Purpose: wire.UserSealedSecretPurposeCopy,
		Account: &wire.UserSealedSecretAccount{Service: "gitlab.com", Address: new("agentloops@example.com")}}), &got)
	if openSealed(t, alex.id, member, got) != value {
		t.Fatalf("%+v", got)
	}

	// The audit has both, written before the answer: the words, the name and the client,
	// and nowhere the value or its last 4.
	entries, raw := sealedSecretEntries(t, window)
	actions := map[string]bool{}
	for _, e := range entries {
		actions[e.Action] = true
		if deref(e.Target) != "GITHUB_TOKEN" || e.Actor.Client == nil || string(*e.Actor.Client) != member.Client ||
			e.Actor.User != alex.id {
			t.Fatalf("%+v", e)
		}
	}
	if len(entries) != 2 || !actions["Revealed secret GITHUB_TOKEN"] ||
		!actions["Copied secret GITHUB_TOKEN of account gitlab.com (agentloops@example.com)"] {
		t.Fatalf("%v", actions)
	}
	if strings.Contains(raw, value) || strings.Contains(raw, "hab12") {
		t.Fatal("the audit holds the value")
	}

	// No such secret, and a part of a secret that is not a card: refused, and not audited.
	if e := callError(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "NOPE", Purpose: wire.UserSealedSecretPurposeReveal}); !strings.Contains(e, "-32107") {
		t.Fatal(e)
	}
	cvc := wire.UserSealedSecretPartCvc
	if e := callError(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: wire.UserSealedSecretPurposeCopy, Part: &cvc}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	if e := callError(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: "show"}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	if entries, _ := sealedSecretEntries(t, window); len(entries) != 2 {
		t.Fatalf("%+v", entries)
	}

	// A client paired after the secret was set has no copy yet.
	_, later := p.client("Alex's iPad")
	if e := callError(t, later, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: wire.UserSealedSecretPurposeReveal}); !strings.Contains(e, "-32108") {
		t.Fatal(e)
	}

	// Another person, an admin's secret: there is none of theirs by that name.
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	if e := callError(t, sam.window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: wire.UserSealedSecretPurposeReveal}); !strings.Contains(e, "-32107") {
		t.Fatal(e)
	}

	// A machine's link, where the agents are, does not have the method, also through
	// machine/machines; and a call that names no client is refused.
	request := wire.UserSealedSecretRequest{Name: "GITHUB_TOKEN", Purpose: wire.UserSealedSecretPurposeReveal}
	if answer, err := box.uplink.Ask(t.Context(), "user/sealedSecret", request); err == nil {
		t.Fatalf("a machine got %s", answer)
	}
	if answer, err := box.uplink.Ask(t.Context(), "machine/machines", map[string]any{"method": "user/sealedSecret", "params": request}); err == nil &&
		strings.Contains(string(answer), "sealed") {
		t.Fatalf("an agent got %s", answer)
	}
	params, _ := json.Marshal(request)
	if _, err := p.s.methods.Handle("user/sealedSecret", params, Caller{Person: alex.id}); err == nil || !strings.Contains(err.Error(), "-32045") {
		t.Fatal(err)
	}
}

// A card's reveal and a copy of one of its parts say so in the audit (wireframes, section 9).
func TestACardsPartsSayWhichInTheAudit(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	member, window := p.client("Alex's Mac")
	user := p.s.localOwner()
	var recipients wire.SealRecipients
	json.Unmarshal(call(t, window, "", "user/secretRecipients", nil), &recipients)
	card := wire.UserSecretKindCard
	set := wire.UserSecretSet{Name: "SHOP_CARD", Kind: &card, Version: 1, NeedsApproval: new(true), Values: map[string]wire.SealedEnvelope{}}
	const value = `{"number":"4242424242424242","expiry":"09/28","cvc":"123","name":"Ada Example","zip":"94110"}`
	for _, r := range recipients.Recipients {
		e, err := controllink.Seal(r.PublicKey, controllink.UserSecretPurpose, controllink.UserSecretADAsk(user, r.ID, "SHOP_CARD", 1, true), []byte(value))
		if err != nil {
			t.Fatal(err)
		}
		set.Values[r.ID] = e
	}
	call(t, window, "", "user/setSecret", set)

	var got wire.UserSealedSecret
	json.Unmarshal(call(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "SHOP_CARD", Purpose: wire.UserSealedSecretPurposeReveal}), &got)
	if deref(got.Kind) != card || !deref(got.NeedsApproval) || openSealed(t, user, member, got) != value {
		t.Fatalf("%+v", got)
	}
	cvc := wire.UserSealedSecretPartCvc
	call(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "SHOP_CARD", Purpose: wire.UserSealedSecretPurposeCopy, Part: &cvc})
	// A part is for a copy only: a reveal shows them all.
	if e := callError(t, window, "", "user/sealedSecret", wire.UserSealedSecretRequest{Name: "SHOP_CARD", Purpose: wire.UserSealedSecretPurposeReveal, Part: &cvc}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	entries, raw := sealedSecretEntries(t, window)
	actions := map[string]bool{}
	for _, e := range entries {
		actions[e.Action] = true
	}
	if len(entries) != 2 || !actions["Revealed card SHOP_CARD"] || !actions["Copied the CVC of card SHOP_CARD"] {
		t.Fatalf("%v", actions)
	}
	if strings.Contains(raw, "4242") || strings.Contains(raw, "94110") {
		t.Fatal("the audit holds the value")
	}
}
