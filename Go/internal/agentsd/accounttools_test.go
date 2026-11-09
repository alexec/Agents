package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
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
	note := accountsNote(all, "gitlab", "")
	if !strings.Contains(note, "1 accounts") || !strings.Contains(note, `"id":"`+accountID(all[0])+`"`) || !strings.Contains(note, about) {
		t.Fatal(note)
	}
	// list shows no address, plan, cost, secret, card or notes (#4164).
	if strings.Contains(note, address) || strings.Contains(note, "$5") || strings.Contains(note, "monthlyCostUsd") {
		t.Fatal(note)
	}
	if note := accountsNote(all, "", "agents"); !strings.Contains(note, "2 accounts") || strings.Contains(note, "slack") ||
		!strings.Contains(note, noDescription) {
		t.Fatal(note)
	}
	if note := accountsNote(all, "digitalocean", ""); note != "There is no account for digitalocean." {
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

// An add that would replace an account waits for the person's yes; a new one, or one with no
// change, goes in at once (#4001).
func TestAddingAnAccountAsksBeforeReplacing(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "sign-up"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	var mu sync.Mutex
	var accounts []wire.OutsideAccount
	writes := 0
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallUserSetPolicy.Name {
			return json.RawMessage(`{}`), nil
		}
		call := params.(wire.MachineAccountsCall)
		mu.Lock()
		defer mu.Unlock()
		if len(call.Add) > 0 {
			writes++
		}
		for _, add := range call.Add {
			if i := slices.IndexFunc(accounts, func(h wire.OutsideAccount) bool { return h.Service == add.Service }); i >= 0 {
				accounts[i] = add
			} else {
				accounts = append(accounts, add)
			}
		}
		return json.Marshal(wire.OutsideAccounts{Accounts: accounts})
	})
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()

	add := func(id int, plan string) chan string {
		answered := make(chan string, 1)
		go func() {
			text, _ := m.tool(id, "manage_accounts", map[string]any{"action": "add",
				"account": map[string]any{"service": "gitlab.com", "address": "a@example.com", "description": "Agents CI", "plan": plan}})
			answered <- text
		}()
		return answered
	}
	if text := <-add(2, "Free"); !strings.HasPrefix(text, "Added 1. 1 accounts") {
		t.Fatal(text)
	}
	if text := <-add(3, "Free"); !strings.HasPrefix(text, "1 had no change. 1 accounts") || writes != 1 {
		t.Fatal(text, writes)
	}

	for i, answer := range []string{"no", "yes"} {
		answered := add(4+i, "Pro")
		var pending []wire.ElicitationRequest
		waitFor(t, "the card", func() bool {
			json.Unmarshal(c.call(t, 10+2*i, "elicitations/pending", nil), &pending)
			return len(pending) == 1
		})
		if f := pending[0].Mode.Form.Value; *pending[0].Message != "Claude (sign-up) wants to replace an account" ||
			*f.Properties[0].Title != "Replace this account?\n\ngitlab.com (a@example.com)\n- plan: Free → Pro" {
			t.Fatalf("%+v", pending[0])
		}
		c.call(t, 11+2*i, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": answer}})
		text := <-answered
		mu.Lock()
		plan := *accounts[0].Plan
		mu.Unlock()
		if answer == "no" && (!strings.HasPrefix(text, "Kept 1 as they were") || plan != "Free") {
			t.Fatal(text, plan)
		}
		if answer == "yes" && (!strings.HasPrefix(text, "Replaced 1.") || plan != "Pro") {
			t.Fatal(text, plan)
		}
	}
}

func TestPlanAccounts(t *testing.T) {
	have := []wire.OutsideAccount{{Service: "gitlab.com", Address: new("a@example.com"), Plan: new("Free"), Notes: new("Keychain")}}
	plan := planAccounts(have, []wire.OutsideAccount{
		{Service: "GitLab.com", Address: new("A@example.com"), Plan: new("Free")},
		{Service: "gitlab.com", Address: new("b@example.com")},
		{Service: "gitlab.com", Address: new("a@example.com"), Plan: new("Free"), Notes: new("Keychain")}})
	if len(plan.added) != 1 || plan.same != 1 || len(plan.changed) != 1 {
		t.Fatalf("%+v", plan)
	}
	if got := strings.Join(plan.changed[0].fields, "; "); got != "service: gitlab.com → GitLab.com; address: a@example.com → A@example.com; notes: Keychain → (none)" {
		t.Fatal(got)
	}
	if note := plan.note(false); note != "Added 1. Kept 1 as they were: the person said not to replace them. 1 had no change. " {
		t.Fatal(note)
	}
}
