package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

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
	// Each says whether it asks before use (#4163): absent is on.
	all[1].AskBeforeUse = new(false)
	if note := accountsNote(all, "", ""); !strings.Contains(note, `"service":"gitlab.com","description":"`+about+`","asksBeforeUse":true`) ||
		!strings.Contains(note, `"service":"aws.amazon.com","description":"No description","asksBeforeUse":false`) {
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
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
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

// #4298: a Replace that comes after the 45 s hold still replaces the account. The call says the
// card is still open, not that the person said no, and the result comes to the agent as a prompt.
func TestALateReplaceStillReplacesTheAccount(t *testing.T) {
	fakeRuntimes(t)
	_, left := formHolds(t)
	left() // the call must outlast its hold
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "sign-up"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	var mu sync.Mutex
	accounts := []wire.OutsideAccount{{Service: "cloudflare.com", Address: new("a@example.com"), Description: new("Scratch"), Plan: new("Free")}}
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallUserSetPolicy.Name {
			return json.RawMessage(`{}`), nil
		}
		call := params.(wire.MachineAccountsCall)
		mu.Lock()
		defer mu.Unlock()
		for _, add := range call.Add {
			accounts[0] = add
		}
		return json.Marshal(wire.OutsideAccounts{Accounts: accounts})
	})
	plan := func() string {
		mu.Lock()
		defer mu.Unlock()
		return *accounts[0].Plan
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	add := map[string]any{"action": "add",
		"account": map[string]any{"service": "cloudflare.com", "address": "a@example.com", "description": "Scratch", "plan": "Pro"}}
	if text, isErr := m.tool(2, "manage_accounts", add); isErr || text != yesStillOpen {
		t.Fatal(text)
	}
	if plan() != "Free" {
		t.Fatal("replaced before the person answered")
	}
	l.closeForms(false) // the turn stops; the card stays
	l.mu.Lock()
	l.inTurn = false
	l.mu.Unlock()
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 1 {
		t.Fatalf("%+v", pending)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	waitFor(t, "the result in its chat", func() bool {
		for _, said := range userMessages(d, a.ID) {
			if strings.HasPrefix(said, "The person answered your card \"Claude (sign-up) wants to replace an account\". Replaced 1.") {
				return true
			}
		}
		return false
	})
	if plan() != "Pro" {
		t.Fatal("a late Replace kept the account as it was")
	}
}

// #4298: a get made again on a request that nobody answered shows the request again, with the
// same id, so the agent's wait on it still holds; one made again at once does not.
func TestAGetMadeAgainShowsItsRequestAgain(t *testing.T) {
	was, wasAlert := formHoldLimit, reAlertInterval
	formHoldLimit, reAlertInterval = 0, time.Hour
	defer func() { formHoldLimit, reAlertInterval = was, wasAlert }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason, a.RuntimeID = wire.AgentStateRunning, nil, "claude" })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	accounts := []wire.OutsideAccount{{Service: "cloudflare.com", Address: new("a@example.com"), Description: new("Scratch")}}
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
	d.SetControlAsk(func(context.Context, string, any) (json.RawMessage, error) {
		return json.Marshal(wire.OutsideAccounts{Accounts: accounts})
	})
	get := func(n int) string {
		text, _ := m.tool(n, "manage_accounts", map[string]any{"action": "get", "id": accountID(accounts[0])})
		return text
	}
	raised := func() (wire.UUID, wire.Date) {
		needs := requestNeeds(d)
		if len(needs) != 1 {
			t.Fatalf("%+v", needs)
		}
		return *needs[0].ID.Request, needs[0].RaisedAt
	}
	if text := get(2); !strings.Contains(text, "Wait with wait_for_event") {
		t.Fatal(text)
	}
	id, first := raised()
	time.Sleep(10 * time.Millisecond)
	get(3)
	if again, at := raised(); again != id || at != first {
		t.Fatalf("raised again at once: %v %v, not %v %v", again, at, id, first)
	}
	reAlertInterval = 0
	if text := get(4); !strings.Contains(text, string(id)) {
		t.Fatal(text)
	}
	if again, at := raised(); again != id || at <= first {
		t.Fatalf("not raised again: %v %v, first %v", again, at, first)
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
	if note := plan.note(false); note != "Added 1. Kept 1 as they were: the person did not say Replace. 1 had no change. " {
		t.Fatal(note)
	}
}

// manage_accounts records each read and change of an account (#4157): an event, an operation
// for the control plane's audit, and the account's last operation, which a later read of its
// secret moves on. A list with no service reads no account.
func TestManageAccountsRecordsEachOperation(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason, a.RuntimeID = wire.AgentStateRunning, nil, "claude" })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	var mu sync.Mutex
	var accounts []wire.OutsideAccount
	var ops [][]wire.AccountOperation
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, ok := params.(wire.MachineAccountsCall)
		if !ok {
			return json.RawMessage(`{}`), nil
		}
		mu.Lock()
		defer mu.Unlock()
		accounts = append(accounts, call.Add...)
		if len(call.Ops) > 0 {
			ops = append(ops, call.Ops)
		}
		return json.Marshal(wire.OutsideAccounts{Accounts: accounts})
	})
	told := func() [][]wire.AccountOperation {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(ops)
	}
	events := func(name string) []wire.Event {
		d.eventMu.Lock()
		defer d.eventMu.Unlock()
		var out []wire.Event
		for _, e := range d.eventList {
			if e.Name == name {
				out = append(out, e)
			}
		}
		return out
	}

	m.tool(2, "manage_accounts", map[string]any{"action": "add",
		"account": map[string]any{"service": "gitlab.com", "address": "a@example.com", "description": "Agents CI", "secret": "GITLAB_TOKEN"}})
	changed := events("account.changed")
	if len(changed) != 1 || changed[0].Details["change"] != "added" || changed[0].Details["service"] != "gitlab.com" ||
		changed[0].Details["address"] != "a@example.com" || changed[0].Details["agent"] != string(a.ID) || changed[0].Details["machine"] == "" {
		t.Fatalf("%+v", changed)
	}
	if got := told(); len(got) != 1 || got[0][0].What != wire.AccountOperationWhatAdded || *got[0][0].Address != "a@example.com" {
		t.Fatalf("%+v", got)
	}

	m.tool(3, "manage_accounts", map[string]any{"action": "list"})
	if len(events("account.read")) != 0 || len(told()) != 1 {
		t.Fatal("a list with no service read an account")
	}
	m.tool(4, "manage_accounts", map[string]any{"action": "list", "service": "gitlab"})
	if read := events("account.read"); len(read) != 1 || read[0].Details["service"] != "gitlab.com" || len(told()) != 2 ||
		told()[1][0].What != wire.AccountOperationWhatRead {
		t.Fatalf("%+v %+v", read, told())
	}

	mu.Lock()
	gitlab := accountID(accounts[0])
	accounts[0].AskBeforeUse = new(false) // as a person turns it off: get does not wait (#4163)
	mu.Unlock()
	var got wire.OutsideAccount
	get := func(id int) {
		t.Helper()
		text, _ := m.tool(id, "manage_accounts", map[string]any{"action": "get", "id": gitlab})
		got = wire.OutsideAccount{}
		if err := json.Unmarshal([]byte(text), &got); err != nil || got.LastOp == nil {
			t.Fatal(text, err)
		}
	}
	get(5)
	if got.LastOp.What != wire.AccountOperationWhatRead || len(told()) != 3 {
		t.Fatalf("%+v", got.LastOp)
	}

	// A read of its secret, later than the account's own, is its last operation.
	later := wire.DateOf(nowFunc().Add(time.Hour))
	d.raise(wire.EventDraft{Name: "secret.read", At: later, Scope: macScope(), Sentence: "A secret was read.",
		Details: map[string]string{"name": "GITLAB_TOKEN", "use": "fill", "place": "gitlab.com"}})
	d.raise(wire.EventDraft{Name: "secret.read", At: later + 60, Scope: macScope(), Sentence: "A secret was read.",
		Details: map[string]string{"name": "OTHER_TOKEN"}})
	get(6)
	if got.LastOp.What != wire.AccountOperationWhatRead || got.LastOp.At != later {
		t.Fatalf("%+v, not %v", got.LastOp, later)
	}

	// The record is kept on disk, for the next start.
	raw, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, "account-ops.json"))
	if err != nil || !strings.Contains(string(raw), "GITLAB_TOKEN") || strings.Contains(string(raw), "Agents CI") {
		t.Fatal(string(raw), err)
	}
}

// The record keeps the newest accountOpsMost of each kind.
func TestTrimOldest(t *testing.T) {
	m := map[string]wire.Date{}
	for i := range accountOpsMost + 3 {
		m[strconv.Itoa(i)] = wire.Date(i)
	}
	trimOldest(m, func(at wire.Date) wire.Date { return at })
	if _, ok := m["2"]; len(m) != accountOpsMost || ok || m["3"] != 3 {
		t.Fatal(len(m))
	}
}

// #4163: an account an agent adds asks before use, and the agent cannot turn it off; a get of it
// waits on a person, with a secret's answers. Deny is an error; once reads once; always turns
// the account's Ask before use off, so the next get does not wait.
func TestAGetOfAnAccountThatAsksWaitsOnAPerson(t *testing.T) {
	answered, left := formHolds(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason, a.RuntimeID = wire.AgentStateRunning, nil, "claude" })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	var mu sync.Mutex
	var accounts []wire.OutsideAccount
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, ok := params.(wire.MachineAccountsCall)
		if !ok {
			return json.RawMessage(`{}`), nil
		}
		mu.Lock()
		defer mu.Unlock()
		for _, add := range call.Add {
			if i := slices.IndexFunc(accounts, func(h wire.OutsideAccount) bool { return accountID(h) == accountID(add) }); i >= 0 {
				accounts[i] = add
			} else {
				accounts = append(accounts, add)
			}
		}
		return json.Marshal(wire.OutsideAccounts{Accounts: accounts})
	})
	stored := func() wire.OutsideAccount {
		mu.Lock()
		defer mu.Unlock()
		return accounts[0]
	}

	m.tool(2, "manage_accounts", map[string]any{"action": "add",
		"account": map[string]any{"service": "gitlab.com", "address": "a@example.com", "description": "Agents CI", "askBeforeUse": false}})
	if !accountAsks(stored()) {
		t.Fatal("an agent turned Ask before use off")
	}
	if text, _ := m.tool(3, "manage_accounts", map[string]any{"action": "list"}); !strings.Contains(text, `"asksBeforeUse":true`) {
		t.Fatal(text)
	}
	id := accountID(stored())
	get := func(n int) string {
		text, _ := m.tool(n, "manage_accounts", map[string]any{"action": "get", "id": id})
		return text
	}

	// The hold ends: the answer names the request, and says nothing of the account but its name.
	left()
	if text := get(4); !strings.Contains(text, "Wait with wait_for_event") || strings.Contains(text, "Agents CI") {
		t.Fatal(text)
	}
	r := openSecretUse(t, d)
	if u := r.Detail.SecretUse; r.Kind != wire.RequestKindApprove || u.Use != wire.SecretUseAccount || u.Place != id ||
		u.Name != "gitlab.com (a@example.com)" || u.Call == nil || *u.Call != "get" {
		t.Fatalf("%+v %+v", r, u)
	}
	if needs := requestNeeds(d); len(needs) != 1 || len(needs[0].Headline.Answers) != 4 ||
		needs[0].Headline.H3 != "Wants to read the account gitlab.com (a@example.com)" {
		t.Fatalf("%+v", needs)
	}

	// Deny: the held call fails with words that say so.
	answered()
	denied := make(chan string, 1)
	go func() {
		text, failed := m.tool(5, "manage_accounts", map[string]any{"action": "get", "id": id})
		if !failed {
			text = "not failed: " + text
		}
		denied <- text
	}()
	waitFor(t, "the held call", func() bool {
		d.secretUseMu.Lock()
		defer d.secretUseMu.Unlock()
		return len(d.secretUseHeld) == 1
	})
	answerUse(t, d, r, secretUseDeny)
	if text := <-denied; !strings.HasPrefix(text, "A person denied") {
		t.Fatal(text)
	}

	// Once: this get, and no other.
	done := make(chan string, 1)
	go func() { done <- get(6) }()
	answerUse(t, d, openSecretUse(t, d), secretUseOnce)
	if text := <-done; !strings.Contains(text, "Agents CI") {
		t.Fatal(text)
	}
	left()
	if text := get(7); !strings.Contains(text, "Wait with wait_for_event") {
		t.Fatal("once allowed a second get:", text)
	}

	// Always: Ask before use goes off in the person's settings.
	answerUse(t, d, openSecretUse(t, d), secretUseAlways)
	if accountAsks(stored()) {
		t.Fatal("always left Ask before use on")
	}
	if text := get(8); !strings.Contains(text, "Agents CI") {
		t.Fatal(text)
	}

	// A replace keeps the account's own Ask before use.
	off := stored()
	plan := planAccounts([]wire.OutsideAccount{off}, []wire.OutsideAccount{{Service: "gitlab.com", Address: off.Address, Plan: new("Pro")}})
	if len(plan.changed) != 1 || plan.changed[0].to.AskBeforeUse == nil || *plan.changed[0].to.AskBeforeUse {
		t.Fatalf("%+v", plan)
	}
}

// manage_accounts asks machine/accounts only of a control plane that said machine.accounts/1
// (#4100): an older one, or one that has not answered machine/hello yet, is asked nothing.
func TestAskAccountsNeedsTheCapability(t *testing.T) {
	d := &Daemon{}
	asked := 0
	ask := askControl(func(_ context.Context, method string, _ any) (json.RawMessage, error) {
		asked++
		return json.RawMessage(`{"accounts":[{"service":"gitlab.com"}]}`), nil
	})
	d.askControl.Store(&ask)
	for _, list := range [][]string{nil, {}, {wire.CapMachine1, wire.CapUser2}} {
		d.SetControlCapabilities(func() []string { return list })
		_, err := d.askAccounts(wire.MachineAccountsCall{})
		if err == nil || !strings.Contains(err.Error(), "the control plane needs an update to do this") || asked != 0 {
			t.Fatalf("%v: %v, asked %d", list, err, asked)
		}
	}
	d.SetControlCapabilities(func() []string { return []string{wire.CapMachineAccounts1} })
	listed, err := d.askAccounts(wire.MachineAccountsCall{})
	if err != nil || asked != 1 || len(listed.Accounts) != 1 {
		t.Fatal(listed, err, asked)
	}
}
