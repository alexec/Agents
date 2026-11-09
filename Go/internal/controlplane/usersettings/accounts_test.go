package usersettings

import (
	"context"
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
