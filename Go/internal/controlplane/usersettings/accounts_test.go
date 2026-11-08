package usersettings

import (
	"context"
	"errors"
	"testing"

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
	if _, changed, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "gitlab.com", Address: &addr, Plan: &free}}); err != nil || !changed {
		t.Fatal(changed, err)
	}
	listed, _, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "GitLab.com", Address: &addr, Plan: &pro}, {Service: "aws.amazon.com"}})
	if err != nil || len(listed.Accounts) != 2 || *listed.Accounts[0].Plan != "Pro" {
		t.Fatal(listed, err)
	}
	if kept, _ := b.Accounts(ctx, "ana"); len(kept.Accounts) != 2 {
		t.Fatal(kept)
	}
	if kept, _ := b.Accounts(ctx, "bo"); kept.Accounts == nil || len(kept.Accounts) != 0 {
		t.Fatal(kept)
	}
	for _, secret := range []string{"glpat-abcdef123456", "4111 1111 1111 1111", "-----BEGIN PRIVATE KEY-----"} {
		notes := secret
		_, _, err := b.AddAccounts(ctx, "ana", []wire.OutsideAccount{{Service: "x.com", Notes: &notes}})
		if !errors.Is(err, ErrInvalid) {
			t.Fatal(secret, err)
		}
	}
	if _, err := b.SetPart(ctx, "ana", wire.UserSettingsPartNameAccounts, []byte(`{"accounts":[{"plan":"Free"}]}`)); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}
