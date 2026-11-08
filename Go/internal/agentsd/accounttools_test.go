package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// manage_accounts' import reads the old registry's snake_case files (#3909, #3967).
func TestOldAccounts(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "gitlab.json"), []byte(`{"service":"gitlab.com","address":"a@example.com","plan":"Free",
		"monthly_cost_usd":0,"card":null,"secret":"~/.agents/secrets/gitlab-token","two_factor":null,"issue":1634,
		"made":"2026-10-19","token_expires":"2027-10-18","notes":"Password in Keychain"}`), 0o600)
	found, err := oldAccounts(dir)
	if err != nil || len(found) != 1 {
		t.Fatal(found, err)
	}
	a := found[0]
	if a.Service != "gitlab.com" || *a.Issue != "#1634" || *a.TokenExpires != "2027-10-18" || a.Card != nil || *a.MonthlyCostUsd != 0 {
		t.Fatalf("%+v", a)
	}
	if _, err := oldAccounts(t.TempDir()); err == nil {
		t.Fatal("no files, no error")
	}
}

func TestAccountsNote(t *testing.T) {
	cost := 5.0
	all := []wire.OutsideAccount{{Service: "gitlab.com", MonthlyCostUsd: &cost}, {Service: "aws.amazon.com", Projects: []string{"Agents"}},
		{Service: "slack.com", Projects: []string{"Other"}}}
	if note := accountsNote(all, "gitlab", "", "list", 0); !strings.Contains(note, "1 accounts") || !strings.Contains(note, "$5 a month") {
		t.Fatal(note)
	}
	if note := accountsNote(all, "", "agents", "list", 0); !strings.Contains(note, "2 accounts") || strings.Contains(note, "slack") {
		t.Fatal(note)
	}
	if note := accountsNote(all, "digitalocean", "", "list", 0); note != "There is no account for digitalocean." {
		t.Fatal(note)
	}
}
