package hosted

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/hosted/billing"
)

const webhookSecret = "whsec_test"

// fakeStripe keeps what it was asked, and answers with addresses of its own.
type fakeStripe struct {
	mu        sync.Mutex
	checkouts []billing.Checkout
	portals   []string
	fail      bool
}

func (f *fakeStripe) Checkout(_ context.Context, c billing.Checkout) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return "", errors.New("stripe is down")
	}
	f.checkouts = append(f.checkouts, c)
	return "https://checkout.stripe.com/c/pay/cs_test_1", nil
}

func (f *fakeStripe) Portal(_ context.Context, customer, returnURL string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.portals = append(f.portals, customer+" "+returnURL)
	return "https://billing.stripe.com/p/session/bps_1", nil
}

// startBilling is the service with billing on through f, and one account signed up.
func startBilling(t *testing.T, st store.Store, f *fakeStripe) (*Service, *browser, string) {
	t.Helper()
	s, newBrowser := startWith(t, Config{Store: st, SignUp: SignUpOpen, Stripe: f, StripePrice: "price_pro",
		StripeWebhookSecret: webhookSecret})
	b := newBrowser()
	b.signIn("good")
	acc, err := s.accounts.byGitHub(context.Background(), 42)
	if err != nil || acc == nil {
		t.Fatal("no account", err)
	}
	return s, b, acc.ID
}

// event is a webhook's body.
func event(id, kind string, object map[string]any) []byte {
	body, _ := json.Marshal(map[string]any{"id": id, "type": kind, "data": map[string]any{"object": object}})
	return body
}

// deliver posts a webhook signed with secret at at.
func deliver(b *browser, body []byte, secret string, at time.Time) int {
	b.t.Helper()
	req, _ := http.NewRequest(http.MethodPost, "https://"+domain+"/billing/webhook", bytes.NewReader(body))
	req.Header.Set("Stripe-Signature", billing.Header(body, secret, at))
	res, err := b.client.Do(req)
	if err != nil {
		b.t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode
}

func planOf(t *testing.T, s *Service, id string) *Account {
	t.Helper()
	acc, err := s.accounts.get(context.Background(), id)
	if err != nil || acc == nil {
		t.Fatal("no account", err)
	}
	return acc
}

// SC-006: without a Stripe key no billing route answers, and the account page has no
// Upgrade or Manage Billing.
func TestNoStripeKeyIsNoBilling(t *testing.T) {
	s, b := start(t, store.NewMemory())
	b.signIn("good")
	acc, _ := s.accounts.byGitHub(context.Background(), 42)
	_, page := b.get("https://" + domain + "/account")
	if !strings.Contains(page, "Free Plan") || strings.Contains(page, "Upgrade") || strings.Contains(page, "Manage Billing") {
		t.Fatal(page)
	}
	form := url.Values{"token": {s.sessions.form(acc.ID)}}
	for _, path := range []string{"/account/upgrade", "/account/billing", "/billing/webhook"} {
		if res, _ := b.post("https://"+domain+path, form); res.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: %d", path, res.StatusCode)
		}
	}
	body := event("evt_1", billing.CheckoutCompleted, map[string]any{"client_reference_id": acc.ID, "customer": "cus_1"})
	if code := deliver(b, body, webhookSecret, time.Now()); code != http.StatusNotFound {
		t.Fatal(code)
	}
	if planOf(t, s, acc.ID).Plan != "" {
		t.Fatal("a plan was set with billing off")
	}
}

// US6: Upgrade makes a Checkout session for Pro with the account's id; the signed event
// puts it on Pro once, however often it comes; Manage Billing goes to the portal; the end
// of the subscription puts it on Free and deletes nothing.
func TestUpgradeAndTheWebhook(t *testing.T) {
	st := store.NewMemory()
	f := &fakeStripe{}
	s, b, id := startBilling(t, st, f)
	_, page := b.get("https://" + domain + "/account")
	if !strings.Contains(page, ">Upgrade<") || strings.Contains(page, "Manage Billing") {
		t.Fatal(page)
	}
	form := url.Values{"token": {s.sessions.form(id)}}
	// Another site's form, with no token, is not an upgrade.
	if res, _ := b.post("https://"+domain+"/account/upgrade", nil); res.Header.Get("Location") != "/" || len(f.checkouts) != 0 {
		t.Fatal("an upgrade with no token")
	}
	res, _ := b.post("https://"+domain+"/account/upgrade", form)
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "https://checkout.stripe.com/c/pay/cs_test_1" {
		t.Fatalf("%d %s", res.StatusCode, res.Header.Get("Location"))
	}
	if csp := res.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "form-action 'self' https://checkout.stripe.com") {
		t.Fatal(csp)
	}
	want := billing.Checkout{Price: "price_pro", Account: id, SuccessURL: "https://" + domain + "/account?upgraded=1",
		CancelURL: "https://" + domain + "/account"}
	if len(f.checkouts) != 1 || f.checkouts[0] != want {
		t.Fatalf("%+v", f.checkouts)
	}
	// Back before the event: the page says so.
	if _, page := b.get("https://" + domain + "/account?upgraded=1"); !strings.Contains(page, "Stripe is confirming") {
		t.Fatal(page)
	}

	completed := event("evt_1", billing.CheckoutCompleted, map[string]any{"client_reference_id": id,
		"customer": "cus_1", "subscription": "sub_1"})
	// A bad signature, and an old one, change nothing (SC-007).
	if code := deliver(b, completed, "whsec_other", time.Now()); code != http.StatusBadRequest {
		t.Fatal(code)
	}
	if code := deliver(b, completed, webhookSecret, time.Now().Add(-6*time.Minute)); code != http.StatusBadRequest {
		t.Fatal(code)
	}
	if planOf(t, s, id).Plan != "" {
		t.Fatal("a refused event changed the plan")
	}
	if code := deliver(b, completed, webhookSecret, time.Now()); code != http.StatusOK {
		t.Fatal(code)
	}
	acc := planOf(t, s, id)
	if acc.Plan != PlanPro || acc.StripeCustomer != "cus_1" || acc.StripeSubscription != "sub_1" {
		t.Fatalf("%+v", acc)
	}
	// The same event again is not acted on again: the operator's Free stays.
	if err := (Admin{Store: st}).SetPlan(context.Background(), id, PlanFree); err != nil {
		t.Fatal(err)
	}
	if code := deliver(b, completed, webhookSecret, time.Now()); code != http.StatusOK {
		t.Fatal(code)
	}
	if planOf(t, s, id).Plan != PlanFree {
		t.Fatal("an event was acted on twice")
	}
	if err := (Admin{Store: st}).SetPlan(context.Background(), id, PlanPro); err != nil {
		t.Fatal(err)
	}

	_, page = b.get("https://" + domain + "/account")
	if !strings.Contains(page, "Pro Plan") || strings.Contains(page, ">Upgrade<") || !strings.Contains(page, "Manage Billing") {
		t.Fatal(page)
	}
	res, _ = b.post("https://"+domain+"/account/billing", form)
	if res.Header.Get("Location") != "https://billing.stripe.com/p/session/bps_1" ||
		len(f.portals) != 1 || f.portals[0] != "cus_1 https://"+domain+"/account" {
		t.Fatalf("%s %v", res.Header.Get("Location"), f.portals)
	}

	// A payment that fails for good: Free. Paid again: Pro.
	sub := func(evt, kind, status string) []byte {
		return event(evt, kind, map[string]any{"id": "sub_1", "customer": "cus_1", "status": status,
			"metadata": map[string]string{"account": id}})
	}
	deliver(b, sub("evt_2", billing.SubscriptionUpdated, "unpaid"), webhookSecret, time.Now())
	if planOf(t, s, id).Plan != PlanFree {
		t.Fatal("unpaid kept Pro")
	}
	deliver(b, sub("evt_3", billing.SubscriptionUpdated, "active"), webhookSecret, time.Now())
	if planOf(t, s, id).Plan != PlanPro {
		t.Fatal("active is not Pro")
	}
	// The subscription ends, found by its customer: Free, and the account's store is whole.
	before, _ := st.List(context.Background(), "accounts/"+id+"/")
	ended := event("evt_4", billing.SubscriptionDeleted, map[string]any{"id": "sub_1", "customer": "cus_1", "status": "canceled"})
	if code := deliver(b, ended, webhookSecret, time.Now()); code != http.StatusOK {
		t.Fatal(code)
	}
	acc = planOf(t, s, id)
	if acc.Plan != PlanFree || acc.StripeCustomer != "cus_1" {
		t.Fatalf("%+v", acc)
	}
	if after, _ := st.List(context.Background(), "accounts/"+id+"/"); len(after) != len(before) || len(before) == 0 {
		t.Fatalf("records deleted: %d then %d", len(before), len(after))
	}
	// Upgrading again uses the same customer.
	b.post("https://"+domain+"/account/upgrade", form)
	if len(f.checkouts) != 2 || f.checkouts[1].Customer != "cus_1" {
		t.Fatalf("%+v", f.checkouts)
	}
}

// An old subscription's end does not end a newer one, and an event for an account that
// is gone is ignored.
func TestStaleAndOrphanEvents(t *testing.T) {
	st := store.NewMemory()
	s, b, id := startBilling(t, st, &fakeStripe{})
	deliver(b, event("evt_1", billing.CheckoutCompleted, map[string]any{"client_reference_id": id,
		"customer": "cus_1", "subscription": "sub_2"}), webhookSecret, time.Now())
	deliver(b, event("evt_2", billing.SubscriptionDeleted, map[string]any{"id": "sub_1", "customer": "cus_1"}), webhookSecret, time.Now())
	if planOf(t, s, id).Plan != PlanPro {
		t.Fatal("an old subscription's end ended the new one")
	}
	if code := deliver(b, event("evt_3", billing.CheckoutCompleted, map[string]any{"client_reference_id": "zzzzzzzzzz",
		"customer": "cus_9"}), webhookSecret, time.Now()); code != http.StatusOK {
		t.Fatal(code)
	}
	if o, _ := st.Get(context.Background(), accountKey("zzzzzzzzzz")); o != nil {
		t.Fatal("an event made an account")
	}
	if code := deliver(b, event("../x", billing.CheckoutCompleted, nil), webhookSecret, time.Now()); code != http.StatusBadRequest {
		t.Fatal(code)
	}
}

// The events acted on are kept 30 days, then swept.
func TestStripeEventsAreSwept(t *testing.T) {
	st := store.NewMemory()
	now := time.Now()
	s, b, id := startBilling(t, st, &fakeStripe{})
	deliver(b, event("evt_1", billing.CheckoutCompleted, map[string]any{"client_reference_id": id, "customer": "cus_1"}),
		webhookSecret, now)
	s.cfg.Now = func() time.Time { return now.Add(29 * 24 * time.Hour) }
	s.sweepStripeEvents(context.Background())
	if o, _ := st.Get(context.Background(), stripeEventKey("evt_1")); o == nil {
		t.Fatal("swept too soon")
	}
	s.cfg.Now = func() time.Time { return now.Add(31 * 24 * time.Hour) }
	s.mu.Lock()
	s.stripeSwept = time.Time{}
	s.mu.Unlock()
	s.sweepStripeEvents(context.Background())
	if o, _ := st.Get(context.Background(), stripeEventKey("evt_1")); o != nil {
		t.Fatal("not swept")
	}
}

// A key with no price or webhook secret does not start.
func TestBillingNeedsItsSettings(t *testing.T) {
	_, err := New(context.Background(), Config{Store: store.NewMemory(), Keeper: "base64key://" + strings.Repeat("A", 43) + "=",
		Domain: domain, StripeKey: "sk_test_x"})
	if err == nil || !strings.Contains(err.Error(), "AGENTS_HOSTED_STRIPE_PRICE") {
		t.Fatal(err)
	}
}

// Stripe down: the account page says so, and nothing changes.
func TestUpgradeWhenStripeIsDown(t *testing.T) {
	s, b, id := startBilling(t, store.NewMemory(), &fakeStripe{fail: true})
	res, page := b.post("https://"+domain+"/account/upgrade", url.Values{"token": {s.sessions.form(id)}})
	if res.StatusCode != http.StatusOK || !strings.Contains(page, "Stripe could not be reached") {
		t.Fatalf("%d %s", res.StatusCode, page)
	}
}
