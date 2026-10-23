package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/wire"
)

func checkLink(t *testing.T, p *plane, host string, sender wire.ChannelSender) wire.ChannelLinkChecked {
	t.Helper()
	params, _ := json.Marshal(sender)
	out, err := p.s.methods.HostSaid(host, "links/check", params)
	if err != nil {
		t.Fatal(err)
	}
	return out.(wire.ChannelLinkChecked)
}

func linkRequests(t *testing.T, s *controllink.Session) []wire.ChannelLinkRequest {
	t.Helper()
	var out []wire.ChannelLinkRequest
	json.Unmarshal(call(t, s, "", "links/requests", nil), &out)
	return out
}

func channelLinks(t *testing.T, s *controllink.Session) []wire.ChannelLink {
	t.Helper()
	var out []wire.ChannelLink
	json.Unmarshal(call(t, s, "", "links/list", nil), &out)
	return out
}

// giveEmail adds a sign-in with an email to a person, as an outside sign-in would.
func giveEmail(t *testing.T, p *plane, user, email string) {
	t.Helper()
	person := p.s.records.Person(user)
	person.SignIns = append(person.SignIns, records.SignIn{Provider: "google", Account: user, Email: email})
	if err := p.s.records.SavePerson(context.Background(), *person); err != nil {
		t.Fatal(err)
	}
}

// US7 AS1 (#1762, FR-037): a message from an identity that is not linked starts nothing,
// and asks its person, who alone approves it. From then on the identity is that person.
func TestAChannelIdentityActsOnlyOnceItsPersonApproves(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	kim := p.invite(owner, "Kim", wire.UserRoleMember)
	giveEmail(t, p, sam.id, "sam@example.com")
	bot := p.machine(sam, "Sam's box")

	slack := wire.ChannelSender{Channel: "Slack", Identity: "T1/U42", Name: new("@sam"), Email: new("Sam@Example.com")}
	if got := checkLink(t, p, bot.member.Host, slack); got.User != nil || got.Refused != nil {
		t.Fatalf("not linked yet, but %+v", got)
	}
	note := waitNote(t, sam.window, "control/linkRequested")
	var asked wire.ChannelLinkRequest
	json.Unmarshal(note.Params, &asked)
	if asked.Channel != "slack" || asked.Identity != "T1/U42" || deref(asked.For) != sam.id {
		t.Fatalf("%+v", asked)
	}
	// A second message asks no second time.
	checkLink(t, p, bot.member.Host, slack)
	if got := linkRequests(t, sam.window); len(got) != 1 {
		t.Fatalf("%+v", got)
	}
	// Nobody else decides it: not Kim, not an admin.
	if got := linkRequests(t, kim.window); len(got) != 0 {
		t.Fatalf("Kim sees %+v", got)
	}
	if got := linkRequests(t, owner); len(got) != 0 {
		t.Fatalf("the admin sees %+v", got)
	}
	for _, s := range []*controllink.Session{kim.window, owner} {
		if e := callError(t, s, "", "links/approve", wire.ChannelLinkDecide{Request: asked.Request}); !strings.Contains(e, "no such request") {
			t.Fatal(e)
		}
	}
	if got := checkLink(t, p, bot.member.Host, slack); got.User != nil {
		t.Fatalf("%+v", got)
	}

	call(t, sam.window, "", "links/approve", wire.ChannelLinkDecide{Request: asked.Request})
	if got := checkLink(t, p, bot.member.Host, slack); deref(got.User) != sam.id || deref(got.UserName) != "Sam" {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, sam.window, "", "links/approve", wire.ChannelLinkDecide{Request: asked.Request}); !strings.Contains(e, "ended") {
		t.Fatal(e)
	}
	if got := channelLinks(t, sam.window); len(got) != 1 || got[0].User != sam.id || got[0].ApprovedBy != sam.id {
		t.Fatalf("%+v", got)
	}
	if got := channelLinks(t, kim.window); len(got) != 0 {
		t.Fatalf("Kim sees %+v", got)
	}
	if got := channelLinks(t, owner); len(got) != 1 {
		t.Fatalf("the admin sees %+v", got)
	}

	// Kim cannot unlink Sam's; Sam can.
	remove := wire.ChannelLinkRemove{Channel: "slack", Identity: "T1/U42"}
	if e := callError(t, kim.window, "", "links/remove", remove); !strings.Contains(e, "no such link") {
		t.Fatal(e)
	}
	call(t, sam.window, "", "links/remove", remove)
	if got := checkLink(t, p, bot.member.Host, slack); got.User != nil {
		t.Fatalf("unlinked, but %+v", got)
	}
}

// A request for an identity no person's email names goes to the admins, who send it on;
// only the person it goes to approves it. A denied identity asks no second time that day.
func TestAnAdminSendsALinkRequestOnAndCannotApproveItForSomeoneElse(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	host := p.machine(sam, "Sam's box").member.Host

	checkLink(t, p, host, wire.ChannelSender{Channel: "discord", Identity: "1234"})
	asked := linkRequests(t, owner)
	if len(asked) != 1 || asked[0].For != nil {
		t.Fatalf("%+v", asked)
	}
	if got := linkRequests(t, sam.window); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, owner, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request}); !strings.Contains(e, "which person") {
		t.Fatal(e)
	}
	call(t, owner, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request, For: &sam.id})
	if got := checkLink(t, p, host, wire.ChannelSender{Channel: "discord", Identity: "1234"}); got.User != nil {
		t.Fatalf("sent on is not linked: %+v", got)
	}
	if got := linkRequests(t, owner); len(got) != 0 {
		t.Fatalf("still the admin's: %+v", got)
	}
	if got := linkRequests(t, sam.window); len(got) != 1 {
		t.Fatalf("%+v", got)
	}
	call(t, sam.window, "", "links/deny", wire.ChannelLinkDecide{Request: asked[0].Request})
	checkLink(t, p, host, wire.ChannelSender{Channel: "discord", Identity: "1234"})
	if got := linkRequests(t, owner); len(got) != 0 {
		t.Fatalf("asked again: %+v", got)
	}
}

// US7 AS2 (#1762, FR-037): a linked email address whose DKIM check fails is refused.
func TestAnEmailMustPassDKIMForItsAddress(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	giveEmail(t, p, sam.id, "sam@example.com")
	host := p.machine(sam, "Sam's box").member.Host

	pass := &wire.ChannelDKIM{Result: "pass", Domain: new("example.com")}
	email := wire.ChannelSender{Channel: "email", Identity: "Sam@Example.com", Dkim: pass}
	checkLink(t, p, host, email)
	asked := linkRequests(t, sam.window)
	if len(asked) != 1 || asked[0].Identity != "sam@example.com" {
		t.Fatalf("%+v", asked)
	}
	call(t, sam.window, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request})
	if got := checkLink(t, p, host, email); deref(got.User) != sam.id {
		t.Fatalf("%+v", got)
	}
	// A subdomain's address signed by its parent is aligned.
	if !dkimPasses("sam@mail.example.com", pass) {
		t.Fatal("a parent domain's signature is aligned")
	}
	for _, dkim := range []*wire.ChannelDKIM{
		nil,
		{Result: "fail", Domain: new("example.com")},
		{Result: "none"},
		{Result: "pass"},
		{Result: "pass", Domain: new("attacker.test")},
		{Result: "pass", Domain: new("ample.com")},
		{Result: "pass", Domain: new("com")},
	} {
		e := email
		e.Dkim = dkim
		got := checkLink(t, p, host, e)
		if got.User != nil || !strings.Contains(deref(got.Refused), "DKIM") {
			t.Fatalf("%+v: %+v", dkim, got)
		}
	}
	// Not an address at all.
	if got := checkLink(t, p, host, wire.ChannelSender{Channel: "email", Identity: "Sam <sam@example.com>", Dkim: pass}); got.User != nil || got.Refused == nil {
		t.Fatalf("%+v", got)
	}
}

// A removed person's links go, and a bot is never linked.
func TestARemovedPersonsLinksGo(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	host := p.machine(sam, "Sam's box").member.Host
	slack := wire.ChannelSender{Channel: "slack", Identity: "U1"}
	checkLink(t, p, host, slack)
	asked := linkRequests(t, owner)
	if e := callError(t, owner, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request, For: new("nobody")}); !strings.Contains(e, "no such person") {
		t.Fatal(e)
	}
	call(t, owner, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request, For: &sam.id})
	call(t, sam.window, "", "links/approve", wire.ChannelLinkDecide{Request: asked[0].Request})
	if got := checkLink(t, p, host, slack); deref(got.User) != sam.id {
		t.Fatalf("%+v", got)
	}
	call(t, owner, "", "people/remove", wire.PersonRequest{User: sam.id})
	if got := channelLinks(t, owner); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
}

// Malformed senders name no one.
func TestASenderThatNamesNoOneIsRefused(t *testing.T) {
	t.Parallel()
	for _, s := range []wire.ChannelSender{
		{Channel: "", Identity: "U1"},
		{Channel: "slack", Identity: " "},
		{Channel: "../people", Identity: "U1"},
		{Channel: "slack", Identity: strings.Repeat("x", 400)},
	} {
		if _, ok := plainSender(s); ok {
			t.Fatalf("%+v", s)
		}
	}
}

// requestReads is a store that counts its reads of link requests.
type requestReads struct {
	store.Store
	reads atomic.Int64
}

func (s *requestReads) Get(ctx context.Context, key string) (*store.Object, error) {
	if strings.HasPrefix(key, linkRequestsPrefix) {
		s.reads.Add(1)
	}
	return s.Store.Get(ctx, key)
}

func (s *requestReads) List(ctx context.Context, prefix string) ([]store.Key, error) {
	if strings.HasPrefix(prefix, linkRequestsPrefix) {
		s.reads.Add(1)
	}
	return s.Store.List(ctx, prefix)
}

// #2060: with as many requests waiting as may wait, a burst of messages from senders not
// linked reads no request: what was read is used again until a request changes.
func TestABurstOfStrangersReadsTheRequestsOnce(t *testing.T) {
	t.Parallel()
	st := &requestReads{Store: store.NewMemory()}
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	box := p.machine(sam, "Sam's box")
	for n := range linksOpen {
		checkLink(t, p, box.member.Host, wire.ChannelSender{Channel: "slack", Identity: "U-" + itoa(n)})
	}
	if got := len(linkRequests(t, owner)); got != linksOpen {
		t.Fatalf("%d requests wait", got)
	}
	st.reads.Store(0)
	for n := range 100 {
		checkLink(t, p, box.member.Host, wire.ChannelSender{Channel: "slack", Identity: "SPAM-" + itoa(n)})
	}
	if got := st.reads.Load(); got != 0 {
		t.Fatalf("100 strangers read link requests %d times", got)
	}
	// A request decided is read again.
	requests := linkRequests(t, owner)
	call(t, owner, "", "links/deny", wire.ChannelLinkDecide{Request: requests[0].Request})
	if got := len(linkRequests(t, owner)); got != linksOpen-1 {
		t.Fatalf("%d requests wait after one was denied", got)
	}
}

// #2293: a removed person's settings, sealed secrets and saved report views go with them;
// another person's stay.
func TestARemovedPersonsRecordsGo(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	ctx := context.Background()
	keys := func(user string) []string {
		return []string{usersettings.Prefix + user + "/settings.json", usersettings.Prefix + user + "/secrets/TOKEN.json",
			reportViewsKey(user)}
	}
	for _, user := range []string{sam.id, "someone-else"} {
		for _, k := range keys(user) {
			st.Put(ctx, k, []byte("{}"), store.Always)
		}
	}
	call(t, owner, "", "people/remove", wire.PersonRequest{User: sam.id})
	for _, k := range keys(sam.id) {
		if o, _ := st.Get(ctx, k); o != nil {
			t.Fatalf("%s stayed", k)
		}
	}
	for _, k := range keys("someone-else") {
		if o, _ := st.Get(ctx, k); o == nil {
			t.Fatalf("%s went", k)
		}
	}
}
