package billing

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// FR-033: a signature made with the secret within five minutes passes; any other does not.
func TestVerify(t *testing.T) {
	body := []byte(`{"id":"evt_1"}`)
	now := time.Unix(1_800_000_000, 0)
	good := Header(body, "whsec_a", now)
	if err := Verify(body, good, "whsec_a", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	// Stripe sends a v1 per secret while one is rolled: any one may match.
	if err := Verify(body, good+",v1=00ff,v0=abc", "whsec_a", now); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		body           []byte
		header, secret string
		at             time.Time
	}{
		"other secret":    {body, good, "whsec_b", now},
		"changed body":    {[]byte(`{"id":"evt_2"}`), good, "whsec_a", now},
		"too old":         {body, good, "whsec_a", now.Add(6 * time.Minute)},
		"from the future": {body, good, "whsec_a", now.Add(-6 * time.Minute)},
		"no header":       {body, "", "whsec_a", now},
		"no v1":           {body, strings.Split(good, ",")[0], "whsec_a", now},
		"no secret":       {body, Header(body, "", now), "", now},
	} {
		if err := Verify(c.body, c.header, c.secret, c.at); !errors.Is(err, ErrSignature) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// Checkout and the portal are asked of Stripe with the key and the fields FR-032 and
// FR-034 name; Stripe's error comes back in its words, without the key.
func TestStripeHTTP(t *testing.T) {
	var forms []map[string]string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk_test_1" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"message":"Invalid API Key provided"}}`))
			return
		}
		_ = r.ParseForm()
		got := map[string]string{"path": r.URL.Path}
		for k := range r.PostForm {
			got[k] = r.PostForm.Get(k)
		}
		forms = append(forms, got)
		if got["customer"] == "cus_gone" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"No such customer: 'cus_gone'"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"cs_1","url":"https://checkout.stripe.com/c/pay/cs_1"}`))
	}))
	defer api.Close()
	s := NewHTTP("sk_test_1", api.URL)
	ctx := context.Background()
	to, err := s.Checkout(ctx, Checkout{Price: "price_1", Account: "abcdefghij", SuccessURL: "https://x/account?upgraded=1",
		CancelURL: "https://x/account"})
	if err != nil || to != "https://checkout.stripe.com/c/pay/cs_1" {
		t.Fatal(to, err)
	}
	want := map[string]string{"path": "/v1/checkout/sessions", "mode": "subscription", "line_items[0][price]": "price_1",
		"line_items[0][quantity]": "1", "client_reference_id": "abcdefghij",
		"subscription_data[metadata][account]": "abcdefghij", "success_url": "https://x/account?upgraded=1",
		"cancel_url": "https://x/account"}
	if len(forms) != 1 || len(forms[0]) != len(want) {
		t.Fatal(forms)
	}
	for k, v := range want {
		if forms[0][k] != v {
			t.Fatalf("%s: %q", k, forms[0][k])
		}
	}
	if _, err := s.Portal(ctx, "cus_1", "https://x/account"); err != nil {
		t.Fatal(err)
	}
	if f := forms[1]; f["path"] != "/v1/billing_portal/sessions" || f["customer"] != "cus_1" || f["return_url"] != "https://x/account" {
		t.Fatal(f)
	}
	if _, err := s.Portal(ctx, "cus_gone", "https://x/account"); err == nil || !strings.Contains(err.Error(), "No such customer") {
		t.Fatal(err)
	}
	if _, err := NewHTTP("sk_test_wrong", api.URL).Portal(ctx, "cus_1", "x"); err == nil ||
		!strings.Contains(err.Error(), "Invalid API Key") || strings.Contains(err.Error(), "sk_test_wrong") {
		t.Fatal(err)
	}
}

func TestParse(t *testing.T) {
	e, err := Parse([]byte(`{"id":"evt_1","type":"customer.subscription.updated","data":{"object":{"id":"sub_1","customer":"cus_1","status":"past_due","metadata":{"account":"abcdefghij"}}}}`))
	if err != nil || e.Data.Object.Metadata["account"] != "abcdefghij" || Paid(e.Data.Object.Status) {
		t.Fatal(e, err)
	}
	if _, err := Parse([]byte(`{"type":"x"}`)); err == nil {
		t.Fatal("an event with no id")
	}
}
