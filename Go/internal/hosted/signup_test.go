package hosted

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// madeAccount says whether a sign-in made an account and sent the browser to it.
func madeAccount(res *http.Response) bool {
	to, err := url.Parse(res.Header.Get("Location"))
	return err == nil && res.StatusCode == http.StatusSeeOther && strings.HasSuffix(to.Host, "."+domain)
}

// signInPage signs in and gives the page it ends on, for a sign-in that made no account.
func (b *browser) signInPage(code, invite string) (int, string) {
	b.t.Helper()
	res := b.signInWith(code, invite)
	if madeAccount(res) {
		b.t.Fatalf("%s made an account", code)
	}
	return res.StatusCode, b.last
}

// #2152 US1: an invite link signs one person up, once.
func TestAnInviteLinkSignsUpOnce(t *testing.T) {
	st := store.NewMemory()
	_, browserFor := startWith(t, Config{Store: st, SignUpsPerAddress: 100})
	admin := Admin{Store: st, Domain: domain}
	link, err := admin.Invite(context.Background(), 0)
	if err != nil {
		t.Fatal(err)
	}
	code := strings.TrimPrefix(link, "https://"+domain+"/?invite=")
	if !validInvite(code) {
		t.Fatal(link)
	}
	b := browserFor()
	if _, page := b.get(link); !strings.Contains(page, "/signin?invite="+code) {
		t.Fatal("the page does not carry the invite:", page)
	}
	if res := b.signInWith("u.101.sam.400", code); !madeAccount(res) {
		t.Fatalf("an invited person was not signed up: %d %s", res.StatusCode, res.Header.Get("Location"))
	}
	// Used: the next person goes on the waitlist, and is told why.
	if _, page := browserFor().signInPage("u.102.lee.400", code); !strings.Contains(page, "number 1") || !strings.Contains(page, "used or expired") {
		t.Fatal(page)
	}
	// Expired: the same.
	old, _ := admin.Invite(context.Background(), time.Nanosecond)
	time.Sleep(time.Millisecond)
	if _, page := browserFor().signInPage("u.103.kim.400", strings.TrimPrefix(old, "https://"+domain+"/?invite=")); !strings.Contains(page, "used or expired") {
		t.Fatal(page)
	}
	// An invite does not skip the age rule.
	fresh, _ := admin.Invite(context.Background(), 0)
	if _, page := browserFor().signInPage("u.104.new.3", strings.TrimPrefix(fresh, "https://"+domain+"/?invite=")); !strings.Contains(page, "newer than 30 days") {
		t.Fatal(page)
	}
}

// #2152 US1, US2: with no invite, a person waits; once allowed (admitted), they sign up.
// The allowlist skips the age rule.
func TestTheWaitlistAndTheAllowlist(t *testing.T) {
	st := store.NewMemory()
	_, browserFor := startWith(t, Config{Store: st, SignUpsPerAddress: 100})
	admin := Admin{Store: st, Domain: domain}
	ana := browserFor()
	if _, page := ana.signInPage("u.201.ana.400", ""); !strings.Contains(page, "number 1") || !strings.Contains(page, "by invitation") {
		t.Fatal(page)
	}
	if _, page := browserFor().signInPage("u.202.bo.400", ""); !strings.Contains(page, "number 2") {
		t.Fatal(page)
	}
	// Signing in again keeps the place.
	if _, page := ana.signInPage("u.201.ana.400", ""); !strings.Contains(page, "number 1") {
		t.Fatal(page)
	}
	if list, _ := admin.Waitlist(context.Background()); len(list) != 2 || list[0].GitHub.Login != "ana" {
		t.Fatalf("%+v", list)
	}
	if err := admin.Allow(context.Background(), "ana"); err != nil {
		t.Fatal(err)
	}
	if res := ana.signIn("u.201.ana.400"); !madeAccount(res) {
		t.Fatal("an admitted person was not signed up")
	}
	if list, _ := admin.Waitlist(context.Background()); len(list) != 1 || list[0].GitHub.Login != "bo" {
		t.Fatalf("the account's entry is still on the waitlist: %+v", list)
	}
	// A login on the allowlist skips the age rule.
	must(t, admin.Allow(context.Background(), "Young"))
	if res := browserFor().signIn("u.203.young.2"); !madeAccount(res) {
		t.Fatal("an allowed young account was not signed up")
	}
}

// #2152 US2: at the cap, even an allowed person waits, at the front.
func TestTheCapPutsAllowedPeopleAtTheFront(t *testing.T) {
	st := store.NewMemory()
	_, browserFor := startWith(t, Config{Store: st, MaxAccounts: 1})
	admin := Admin{Store: st, Domain: domain}
	must(t, admin.Allow(context.Background(), "first"))
	must(t, admin.Allow(context.Background(), "second"))
	if res := browserFor().signIn("u.301.first.400"); !madeAccount(res) {
		t.Fatal("the first allowed person was not signed up")
	}
	browserFor().signInPage("u.302.stranger.400", "")
	if _, page := browserFor().signInPage("u.303.second.400", ""); !strings.Contains(page, "number 1") || !strings.Contains(page, "as many accounts") {
		t.Fatal(page)
	}
	if n, _ := (&accounts{store: st}).count(context.Background()); n != 1 {
		t.Fatalf("%d accounts past a cap of 1", n)
	}
}

// #2152 US2, US4: a blocked GitHub user gets nothing, and their account is suspended.
func TestABlockedUserGetsNothing(t *testing.T) {
	st := store.NewMemory()
	_, browserFor := startWith(t, Config{Store: st, SignUp: SignUpOpen})
	admin := Admin{Store: st, Domain: domain}
	if res := browserFor().signIn("u.401.spam.400"); !madeAccount(res) {
		t.Fatal("not signed up")
	}
	if id, err := admin.Block(context.Background(), "spam", "Spam"); err != nil || id != 401 {
		t.Fatal(id, err)
	}
	list, _ := admin.Accounts(context.Background())
	if len(list) != 1 || list[0].Suspended == nil {
		t.Fatalf("%+v", list)
	}
	if _, err := admin.Block(context.Background(), "402", ""); err != nil {
		t.Fatal(err)
	}
	code, page := browserFor().signInPage("u.402.other.400", "")
	if code != http.StatusForbidden || !strings.Contains(page, "not open to this GitHub account") {
		t.Fatal(code, page)
	}
	if list, _ := admin.Waitlist(context.Background()); len(list) != 0 {
		t.Fatalf("a blocked user is on the waitlist: %+v", list)
	}
}

// #2152 US3, SC-002: 3 sign-ups an hour from one address, 30 in all; signing in to an
// account is never limited.
func TestSignUpRates(t *testing.T) {
	st := store.NewMemory()
	now := &clock{now: time.Now()}
	s, browserFor := startWith(t, Config{Store: st, SignUp: SignUpOpen, Now: now.Now})
	for i := range 3 {
		if res := browserFor().signIn("u." + itoa(500+i) + ".p" + itoa(i) + ".400"); !madeAccount(res) {
			t.Fatalf("sign-up %d refused", i)
		}
	}
	code, page := browserFor().signInPage("u.599.fourth.400", "")
	if code != http.StatusTooManyRequests || !strings.Contains(page, "Too many sign-ups") {
		t.Fatal(code, page)
	}
	// One who has an account signs in, however many sign-ups there were.
	if res := browserFor().signIn("u.500.p0.400"); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"))
	}
	// In all: 200 from 20 addresses make at most 30 (3 above, 27 more).
	made := 0
	for i := range 200 {
		user := GitHubID{ID: int64(1000 + i), Login: "x" + itoa(i), Created: now.Now().Add(-400 * 24 * time.Hour)}
		if got := s.gate(context.Background(), "198.51.100."+itoa(i%20), user, ""); got.account != nil {
			made++
		}
	}
	if made != 27 {
		t.Fatalf("%d made in the hour, want 27", made)
	}
	now.add(time.Hour + time.Second)
	if got := s.gate(context.Background(), "203.0.113.1", GitHubID{ID: 2000, Login: "later", Created: now.Now().Add(-400 * 24 * time.Hour)}, ""); got.account == nil {
		t.Fatalf("refused an hour later: %+v", got)
	}
}

// #2152 US3: at the most copies, the one idle longest stops; with none idle, the request
// is refused.
func TestTheMostCopies(t *testing.T) {
	s, _, now, ids := idleService(t, 2)
	s.cfg.MaxCopies = 2
	acc, _, _ := s.accounts.make(context.Background(), GitHubID{ID: 3000, Login: "third"})
	now.add(time.Minute)
	open(t, s, ids[1])
	open(t, s, acc.ID)
	if n := s.running(); n != 2 {
		t.Fatalf("%d running, want 2", n)
	}
	s.mu.Lock()
	_, first := s.copies[ids[0]]
	s.mu.Unlock()
	if first {
		t.Fatal("the copy idle longest was not the one stopped")
	}
	// Both in use: no room.
	a, _ := s.copyFor(context.Background(), ids[1])
	b, _ := s.copyFor(context.Background(), acc.ID)
	req := httptest.NewRequest(http.MethodGet, "https://"+ids[0]+"."+domain+"/readyz", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "full") {
		t.Fatal(w.Code, w.Body.String())
	}
	s.done(a)
	s.done(b)
}

// #2152 US3: new certificates stay under the hour's and the week's caps; a name allowed
// once is allowed again without counting.
func TestTheCertificateCaps(t *testing.T) {
	s, _, now, ids := idleService(t, 0)
	s.cfg.CertsPerHour, s.cfg.CertsPerWeek = 2, 3
	for i := range 4 {
		acc, _, _ := s.accounts.make(context.Background(), GitHubID{ID: int64(4000 + i), Login: "c"})
		ids = append(ids, acc.ID)
	}
	ask := func(id string) int {
		w := httptest.NewRecorder()
		s.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "https://"+domain+"/v1/tls-allowed?domain="+id+"."+domain, nil))
		return w.Code
	}
	for i, want := range []int{200, 200, 404} {
		if got := ask(ids[i]); got != want {
			t.Fatalf("name %d: %d, want %d", i, got, want)
		}
	}
	if ask(ids[0]) != 200 {
		t.Fatal("a name allowed before was refused")
	}
	now.add(time.Hour + time.Minute)
	if ask(ids[2]) != 200 {
		t.Fatal("refused an hour later")
	}
	if ask(ids[3]) != 404 {
		t.Fatal("allowed past the week's cap")
	}
}

// #2152 US4, SC-003: a suspended account's copy stops within a sweep, its address refuses,
// and its page says why; unsuspended, it starts again.
func TestSuspendAnAccount(t *testing.T) {
	st := store.NewMemory()
	s, browserFor := startWith(t, Config{Store: st, SignUp: SignUpOpen})
	b := browserFor()
	to, _ := url.Parse(b.signIn("good").Header.Get("Location"))
	id := strings.TrimSuffix(to.Host, "."+domain)
	if res, _ := b.get("https://" + id + "." + domain + "/readyz"); res.StatusCode != http.StatusOK {
		t.Fatal(res.StatusCode)
	}
	admin := Admin{Store: st, Domain: domain}
	if err := admin.Suspend(context.Background(), id, "Spam from its agents"); err != nil {
		t.Fatal(err)
	}
	s.sweepSuspended(context.Background())
	res, text := b.get("https://" + id + "." + domain + "/readyz")
	if res.StatusCode != http.StatusForbidden || res.Header.Get("Agents-Refusal") != "suspended" || !strings.Contains(text, "suspended") {
		t.Fatal(res.StatusCode, text)
	}
	if _, page := b.get("https://" + domain + "/account"); !strings.Contains(page, "suspended: Spam from its agents") || strings.Contains(page, "Open in This Browser") {
		t.Fatal(page)
	}
	// A suspended name keeps its certificate, so the refusal is served over TLS.
	if res, _ := b.get("https://" + domain + "/v1/tls-allowed?domain=" + id + "." + domain); res.StatusCode != http.StatusOK {
		t.Fatal(res.StatusCode)
	}
	if err := admin.Unsuspend(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if res, _ := b.get("https://" + id + "." + domain + "/readyz"); res.StatusCode != http.StatusOK {
		t.Fatal(res.StatusCode)
	}
	if err := admin.Suspend(context.Background(), "abcdefghij", "x"); err == nil {
		t.Fatal("suspended an account that is not there")
	}
}

// Closed: nobody new signs up or waits.
func TestClosedSignUp(t *testing.T) {
	st := store.NewMemory()
	_, browserFor := startWith(t, Config{Store: st, SignUp: SignUpClosed})
	if code, page := browserFor().signInPage("u.601.ana.400", ""); code != http.StatusServiceUnavailable || !strings.Contains(page, "not open yet") {
		t.Fatal(code, page)
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
