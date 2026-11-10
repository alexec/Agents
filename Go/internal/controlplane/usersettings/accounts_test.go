package usersettings

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Settings ▸ You ▸ Accounts (#3967): add puts an account with the same service and address in
// place of the old one, and a value that looks like a secret is refused.
func TestAccounts(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	addr := "agents@example.com"
	free, pro := "Free", "Pro"
	made := time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	edited := made.Add(48 * time.Hour)
	if _, changed, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "gitlab.com", Address: &addr, Plan: &free, Made: new("2026-10-19")}}, made); err != nil || !changed {
		t.Fatal(changed, err)
	}
	listed, _, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "GitLab.com", Address: &addr, Plan: &pro}, {Service: "aws.amazon.com"}}, edited)
	if err != nil || len(listed.Accounts) != 2 || *listed.Accounts[0].Plan != "Pro" {
		t.Fatal(listed, err)
	}
	// The one that took the other's place keeps its made and is edited now; the new one is not
	// edited (#4157).
	if a := listed.Accounts[0]; *a.Made != "2026-10-19" || a.Edited == nil || !a.Edited.Time().Equal(edited) || listed.Accounts[1].Edited != nil {
		t.Fatalf("%+v", listed.Accounts)
	}
	again, _, _ := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "GitLab.com", Address: &addr, Plan: &pro,
		LastOp: &wire.AccountLastOp{What: wire.AccountOperationWhatRead, At: wire.DateOf(edited)}}}, edited.Add(time.Hour))
	if a := again.Accounts[0]; !a.Edited.Time().Equal(edited) || a.LastOp != nil {
		t.Fatalf("no change, no edit, and no lastOp kept: %+v", a)
	}
	if kept, _ := b.Accounts(ctx, "ana"); len(kept.Accounts) != 2 {
		t.Fatal(kept)
	}
	if kept, _ := b.Accounts(ctx, "bo"); kept.Accounts == nil || len(kept.Accounts) != 0 {
		t.Fatal(kept)
	}
	for _, secret := range []string{"glpat-abcdef123456", "4111 1111 1111 1111", "-----BEGIN PRIVATE KEY-----"} {
		notes := secret
		_, _, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "x.com", Notes: &notes}}, made)
		if !errors.Is(err, ErrInvalid) {
			t.Fatal(secret, err)
		}
	}
	if _, err := b.SetPart(ctx, "ana", wire.UserSettingsPartNameAccounts, []byte(`{"accounts":[{"plan":"Free"}]}`)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}

// An Edit… on a client (user/setSettings) is edited as an add is, and keeps no lastOp (#4160).
func TestSetAccountsStampsEdited(t *testing.T) {
	ctx := context.Background()
	b := localBook(t, store.NewMemory())
	at := time.Date(2026, 11, 9, 9, 0, 0, 0, time.UTC)
	b.now = func() time.Time { return at }
	set := func(json string) wire.OutsideAccount {
		t.Helper()
		if _, err := b.SetPart(ctx, "ana", wire.UserSettingsPartNameAccounts, []byte(json)); err != nil {
			t.Fatal(err)
		}
		kept, _ := b.Accounts(ctx, "ana")
		return kept.Accounts[0]
	}
	if a := set(`{"accounts":[{"service":"gitlab.com","plan":"Free","made":"2026-10-19","lastOp":{"what":"read","at":1}}]}`); a.Edited != nil || a.LastOp != nil {
		t.Fatalf("new: %+v", a)
	}
	if a := set(`{"accounts":[{"service":"gitlab.com","plan":"Free","made":"2026-10-19"}]}`); a.Edited != nil {
		t.Fatalf("the same: %+v", a)
	}
	edited := at
	if a := set(`{"accounts":[{"service":"gitlab.com","plan":"Pro"}]}`); a.Edited == nil || !a.Edited.Time().Equal(edited) || *a.Made != "2026-10-19" {
		t.Fatalf("edited: %+v", a)
	}
	at = at.Add(time.Hour)
	if a := set(`{"accounts":[{"service":"gitlab.com","plan":"Pro","made":"2026-10-19","edited":` + jsonDate(edited) + `}]}`); !a.Edited.Time().Equal(edited) {
		t.Fatalf("sent back unchanged: %+v", a)
	}
	if a := set(`{"accounts":[{"service":"gitlab.com","plan":"Team","made":"2026-10-19","edited":` + jsonDate(edited) + `}]}`); !a.Edited.Time().Equal(at) {
		t.Fatalf("edited again: %+v", a)
	}
}

func jsonDate(t time.Time) string {
	raw, _ := json.Marshal(wire.DateOf(t))
	return string(raw)
}
