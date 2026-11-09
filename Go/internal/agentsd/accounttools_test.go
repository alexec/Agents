package agentsd

import (
	"encoding/json"
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
	address, about := "agents@example.com", "The agents' own gitlab.com account, for the integration tests."
	all := []wire.OutsideAccount{{Service: "gitlab.com", Address: &address, Description: &about, MonthlyCostUsd: &cost},
		{Service: "aws.amazon.com", Projects: []string{"Agents"}}, {Service: "slack.com", Projects: []string{"Other"}}}
	note := accountsNote(all, "gitlab", "", "list", 0)
	if !strings.Contains(note, "1 accounts") || !strings.Contains(note, `"id":"`+accountID(all[0])+`"`) || !strings.Contains(note, about) {
		t.Fatal(note)
	}
	// list shows no address, plan, cost, secret, card or notes (#4164).
	if strings.Contains(note, address) || strings.Contains(note, "$5") || strings.Contains(note, "monthlyCostUsd") {
		t.Fatal(note)
	}
	if note := accountsNote(all, "", "agents", "list", 0); !strings.Contains(note, "2 accounts") || strings.Contains(note, "slack") ||
		!strings.Contains(note, noDescription) {
		t.Fatal(note)
	}
	if note := accountsNote(all, "digitalocean", "", "list", 0); note != "There is no account for digitalocean." {
		t.Fatal(note)
	}
}

// get gives the whole account by the id that list gives, which stays the same for the same
// service and address (#4164).
func TestAccountNote(t *testing.T) {
	address := "agents@example.com"
	all := []wire.OutsideAccount{{Service: "gitlab.com"}, {Service: "gitlab.com", Address: &address}}
	if accountID(all[0]) == accountID(all[1]) || len(accountID(all[0])) != 8 {
		t.Fatal(accountID(all[0]), accountID(all[1]))
	}
	upper := "AGENTS@example.com"
	if accountID(wire.OutsideAccount{Service: "GitLab.com", Address: &upper}) != accountID(all[1]) {
		t.Fatal("the id follows the case of the service or address")
	}
	note, err := accountNote(all, strings.ToUpper(accountID(all[1])))
	if err != nil || !strings.Contains(note, address) || !strings.Contains(note, `"id":"`+accountID(all[1])+`"`) {
		t.Fatal(note, err)
	}
	if _, err := accountNote(all, "nothing"); err == nil {
		t.Fatal("no account, no error")
	}
}

// add needs a description (#4164).
func TestManageAccountsAddNeedsADescription(t *testing.T) {
	d := &Daemon{}
	_, err := d.manageAccounts("", map[string]json.RawMessage{"action": json.RawMessage(`"add"`),
		"account": json.RawMessage(`{"service":"gitlab.com"}`)})
	if err == nil || !strings.Contains(err.Error(), "description") {
		t.Fatal(err)
	}
}
