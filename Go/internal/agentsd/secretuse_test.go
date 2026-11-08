package agentsd

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// openSecretUse is the one open request for a secret's use, once it is there.
func openSecretUse(t *testing.T, d *Daemon) wire.Request {
	t.Helper()
	var open []wire.Request
	waitFor(t, "the approval", func() bool {
		open = nil
		for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
			if r.Detail.SecretUse != nil {
				open = append(open, r)
			}
		}
		return len(open) == 1
	})
	return open[0]
}

func answerUse(t *testing.T, d *Daemon, r wire.Request, action string) {
	t.Helper()
	if _, err := d.answerSecretUse(r, &wire.RequestSecretUseAnswer{Action: action}, nil); err != nil {
		t.Fatal(err)
	}
}

// fillAsync is fill_secret on its own goroutine, as an agent's held call.
func fillAsync(m *mcpClient, id int) chan browserReply {
	done := make(chan browserReply, 1)
	go func() {
		done <- m.browserTool(id, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "element": "Password field", "target": "e12"})
	}()
	return done
}

func replyOf(t *testing.T, done chan browserReply) browserReply {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(10 * time.Second):
		t.Fatal("the call was never answered")
	}
	return browserReply{}
}

// #4015: a fill of a secret with Ask before use waits on a person, for the field's domain.
// Once fills once; a hold that ends names the request to wait on; deny is an error; always
// is a grant for the domain that a person can take away.
func TestAFlaggedFillWaitsOnAPerson(t *testing.T) {
	was := formHoldLimit
	formHoldLimit = 300 * time.Millisecond
	defer func() { formHoldLimit = was }()
	m, page, d := fillSetUp(t, nil)
	if err := d.saveSecret("GITLAB_PASSWORD", filledValue, true); err != nil {
		t.Fatal(err)
	}

	// Allow once: the held call fills.
	done := fillAsync(m, 2)
	r := openSecretUse(t, d)
	if r.Kind != wire.RequestKindApprove || r.Source != wire.RequestSourceSecretUse || r.Title != "Fill GITLAB_PASSWORD on shop.example.com" ||
		r.Detail.SecretUse.Place != "shop.example.com" || r.Detail.SecretUse.Use != wire.SecretUseFill || r.AskedBy == nil {
		t.Fatalf("%+v", r)
	}
	if b, _ := json.Marshal(r); strings.Contains(string(b), filledValue) {
		t.Fatalf("the request holds the value: %s", b)
	}
	answerUse(t, d, r, secretUseOnce)
	if got := replyOf(t, done); got.IsError || replyText(got) != "GITLAB_PASSWORD filled." || page.value != filledValue {
		t.Fatalf("%+v %q", got, page.value)
	}

	// Once was one use: the next waits, and after the hold names its request.
	page.value = ""
	got := replyOf(t, fillAsync(m, 3))
	r = openSecretUse(t, d)
	if got.IsError || !strings.Contains(replyText(got), `wait_for_event, where: {"request": "`+string(r.ID)+`"}`) || page.value != "" {
		t.Fatalf("%+v %q", got, page.value)
	}
	// A call made again joins the same request; deny fails it.
	done = fillAsync(m, 4)
	time.Sleep(50 * time.Millisecond)
	if again := openSecretUse(t, d); again.ID != r.ID {
		t.Fatalf("asked twice: %s %s", again.ID, r.ID)
	}
	answerUse(t, d, r, secretUseDeny)
	if got := replyOf(t, done); !got.IsError || !strings.Contains(replyText(got), "A person denied the use of GITLAB_PASSWORD at shop.example.com") || page.value != "" {
		t.Fatalf("%+v %q", got, page.value)
	}
	if after := d.request(r.ID); after == nil || after.State != wire.RequestStateAnswered || deref(after.Answer) != "Denied" {
		t.Fatalf("%+v", after)
	}

	// Always: a grant for the domain, and no more asking there.
	done = fillAsync(m, 5)
	answerUse(t, d, openSecretUse(t, d), secretUseAlways)
	if got := replyOf(t, done); got.IsError || page.value != filledValue {
		t.Fatalf("%+v", got)
	}
	grants := d.secretGrants()
	if fmt.Sprint(grants.Grants) != "[{GITLAB_PASSWORD fill shop.example.com}]" {
		t.Fatalf("%+v", grants)
	}
	if v, ok := d.sealedLocalSecret(personalHomeOf(t, d), "GITLAB_PASSWORD"); !ok || v != filledValue {
		t.Fatal("the record with its grant does not open")
	}
	page.value = ""
	if got := m.browserTool(6, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12"}); got.IsError || page.value != filledValue {
		t.Fatalf("%+v", got)
	}
	// Another domain still asks.
	page.site, page.value = "evil.example.net", ""
	if got := replyOf(t, fillAsync(m, 7)); !strings.Contains(replyText(got), "wait_for_event") || page.value != "" {
		t.Fatalf("%+v", got)
	}
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)

	// Taken away, the domain asks again.
	page.site = ""
	grantAs(d, wire.CallSecretsRemoveGrant.Name, "GITLAB_PASSWORD", "fill", "shop.example.com")
	if len(d.secretGrants().Grants) != 0 {
		t.Fatal("the grant is still there")
	}
	if got := replyOf(t, fillAsync(m, 8)); !strings.Contains(replyText(got), "wait_for_event") || page.value != "" {
		t.Fatalf("%+v", got)
	}

	// For this session: every use here, in this session, until it is archived.
	answerUse(t, d, openSecretUse(t, d), secretUseSession)
	for i := range 2 {
		page.value = ""
		if got := m.browserTool(9+i, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12"}); got.IsError || page.value != filledValue {
			t.Fatalf("%d: %+v", i, got)
		}
	}
	d.forgetSessionSecretUses(*r.AskedBy)
	page.value = ""
	if got := replyOf(t, fillAsync(m, 11)); !strings.Contains(replyText(got), "wait_for_event") || page.value != "" {
		t.Fatalf("%+v", got)
	}
}

// personalHomeOf is the test's personal home.
func personalHomeOf(t *testing.T, d *Daemon) string {
	t.Helper()
	h := d.personalHome()
	if h == "" {
		t.Fatal("no personal home")
	}
	return h
}

// grantAs calls a grant method as a person's device.
func grantAs(d *Daemon, method, name, use, place string) {
	c := &Client{Role: RoleDevice, conn: newConn(), d: d}
	params, _ := json.Marshal(wire.SecretGrantChange{Grant: wire.SecretGrant{Name: name, Use: wire.SecretUse(use), Place: place}})
	d.dispatch(c, message{JSONRPC: "2.0", Method: method, ID: json.RawMessage(`1`), Params: params})
}

// #4015: set_ci_secret of a flagged secret waits on a person, for the repository.
func TestAFlaggedCISecretWaitsOnAPerson(t *testing.T) {
	was := formHoldLimit
	formHoldLimit = 300 * time.Millisecond
	defer func() { formHoldLimit = was }()
	d, _, gh, _ := forgeDaemon(t)
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/newapp.git"), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	const value = "sntrys_4015-not-real"
	if err := d.saveSecret("SENTRY_TOKEN", value, true); err != nil {
		t.Fatal(err)
	}
	args := ciArgs("name", "SENTRY_AUTH_TOKEN", "secret", "SENTRY_TOKEN")
	got, err := d.setCISecret(a.ID, args)
	r := openSecretUse(t, d)
	if err != nil || !strings.Contains(got, `wait_for_event, where: {"request": "`+string(r.ID)+`"}`) || r.Title != "Set SENTRY_TOKEN as a CI secret in alexec/newapp" {
		t.Fatalf("%q %v %+v", got, err, r)
	}
	gh.mu.Lock()
	wrote := len(gh.wrote)
	gh.mu.Unlock()
	if wrote != 0 {
		t.Fatal("set before a person approved it")
	}
	answerUse(t, d, r, secretUseOnce)
	if got, err := d.setCISecret(a.ID, args); err != nil || !strings.Contains(got, "is set as a CI secret in alexec/newapp") {
		t.Fatalf("%q %v", got, err)
	}
	// Held, and denied.
	done := make(chan error, 1)
	go func() { _, err := d.setCISecret(a.ID, args); done <- err }()
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)
	if err := <-done; err == nil || !strings.Contains(err.Error(), "A person denied the use of SENTRY_TOKEN at alexec/newapp") {
		t.Fatal(err)
	}
	gh.mu.Lock()
	defer gh.mu.Unlock()
	if fmt.Sprint(gh.wrote) != "[secret alexec/newapp SENTRY_AUTH_TOKEN="+value+"]" {
		t.Fatalf("%v", gh.wrote)
	}
}

// #4015: only a person's own clients answer a secret's use and change its grants.
func TestOnlyAPersonApprovesASecretsUse(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if err := d.saveSecret("GITLAB_PASSWORD", "sealed-value", true); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{wire.CallRequestsAnswer.Name, wire.CallSecretsAddGrant.Name, wire.CallSecretsRemoveGrant.Name, wire.CallSecretsGrants.Name} {
		if RoleAgent.Allows(method) {
			t.Errorf("an agent's connection may call %s", method)
		}
	}
	params := `{"grant":{"name":"GITLAB_PASSWORD","use":"fill","place":"gitlab.com"}}`
	helper := &Client{Role: RoleAgent, conn: newConn(), d: d}
	d.dispatch(helper, message{JSONRPC: "2.0", Method: wire.CallSecretsAddGrant.Name, ID: json.RawMessage(`1`), Params: json.RawMessage(params)})
	if len(d.secretGrants().Grants) != 0 {
		t.Fatal("an agent's connection added a grant")
	}
	person := &Client{Role: RoleControl, conn: newConn(), d: d}
	d.dispatch(person, message{JSONRPC: "2.0", Method: wire.CallSecretsAddGrant.Name, ID: json.RawMessage(`2`), Params: json.RawMessage(params)})
	if fmt.Sprint(d.secretGrants().Grants) != "[{GITLAB_PASSWORD fill gitlab.com}]" {
		t.Fatalf("%+v", d.secretGrants())
	}
	// A plain secret has no grants to add.
	if err := d.changeGrant("NOT_FLAGGED", wire.SecretUseFill, "gitlab.com", true); err == nil {
		t.Fatal("a grant for a secret with no Ask before use")
	}
}

// requestNeeds is the needs posted for requests: a secret's use, for its banner.
func requestNeeds(d *Daemon) []wire.Need {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	if d.raisedAt == nil {
		d.raisedAt, d.raisedNeed = map[string]wire.Date{}, map[string]wire.NeedID{}
	}
	var out []wire.Need
	for _, n := range d.needs() {
		if n.ID.Request != nil {
			out = append(out, n)
		}
	}
	return out
}

// #4017: a secret's use waiting on a person is posted, so a phone answers it from its
// banner: the secret's name and the place, never the value, and the row's four answers.
// Answered, it goes.
func TestASecretUseIsPostedWithItsAnswers(t *testing.T) {
	was := formHoldLimit
	formHoldLimit = 300 * time.Millisecond
	defer func() { formHoldLimit = was }()
	m, _, d := fillSetUp(t, nil)
	if err := d.saveSecret("GITLAB_PASSWORD", filledValue, true); err != nil {
		t.Fatal(err)
	}
	done := fillAsync(m, 2)
	r := openSecretUse(t, d)
	needs := requestNeeds(d)
	if len(needs) != 1 || *needs[0].ID.Request != r.ID || needs[0].Kind != wire.NeedKindRequest || needs[0].AgentID == nil ||
		*needs[0].AgentID != *r.AskedBy || needs[0].Headline.H3 != "Wants to use GITLAB_PASSWORD on shop.example.com" {
		t.Fatalf("%+v", needs)
	}
	var answers []string
	for _, a := range needs[0].Headline.Answers {
		answers = append(answers, a.ID+"="+a.Title+fmt.Sprint(a.IsDestructive))
	}
	if strings.Join(answers, ", ") != "once=Allow Oncefalse, session=Allow for This Sessionfalse, always=Allow Alwaysfalse, deny=Denytrue" {
		t.Fatal(answers)
	}
	if b, _ := json.Marshal(needs); strings.Contains(string(b), filledValue) {
		t.Fatalf("the need holds the value: %s", b)
	}
	answerUse(t, d, r, secretUseOnce)
	replyOf(t, done)
	if needs := requestNeeds(d); len(needs) != 0 {
		t.Fatalf("still posted: %+v", needs)
	}
}

// A session's own secret has no Allow always on its banner, as on its row.
func TestASessionSecretsBannerHasNoAllowAlways(t *testing.T) {
	yes := true
	var ids []string
	for _, a := range secretUseAnswers(wire.RequestSecretUse{Name: "X", Use: wire.SecretUseCi, Place: "o/r", SessionOnly: &yes}) {
		ids = append(ids, a.ID)
	}
	if strings.Join(ids, ",") != "once,session,deny" {
		t.Fatal(ids)
	}
	if got := secretUseWanted(wire.RequestSecretUse{Name: "X", Use: wire.SecretUseCi, Place: "o/r"}); got != "Wants to use X as a CI secret in o/r" {
		t.Fatal(got)
	}
}
