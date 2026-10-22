// Package billing is the hosted service's one paid plan, through Stripe (#2225, spec 1003
// FR-030..FR-035): a Checkout session to upgrade, a customer portal session to manage it,
// and the webhook's signature. Stripe keeps the cards; the service keeps only the customer
// and subscription ids. The service talks to Stripe through Stripe, so the tests use a fake.
package billing

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Stripe is what the service asks of Stripe.
type Stripe interface {
	// Checkout makes a Checkout session for a subscription, and gives its address.
	Checkout(ctx context.Context, c Checkout) (string, error)
	// Portal makes a customer portal session, and gives its address.
	Portal(ctx context.Context, customer, returnURL string) (string, error)
}

// Checkout is an upgrade: the price, the account it is for, and where Stripe sends the
// browser back to.
type Checkout struct {
	Price string
	// The account's id: the session's client_reference_id, and the subscription's
	// metadata, so every event names the account.
	Account string
	// The account's Stripe customer, when it had one before; "" makes a new one.
	Customer              string
	SuccessURL, CancelURL string
}

// API is Stripe's address.
const API = "https://api.stripe.com"

// NewHTTP is Stripe over HTTP with a secret key, at api (API when "").
func NewHTTP(key, api string) Stripe {
	if api == "" {
		api = API
	}
	return &stripeHTTP{key: key, api: strings.TrimSuffix(api, "/"), client: &http.Client{Timeout: 30 * time.Second}}
}

type stripeHTTP struct {
	key, api string
	client   *http.Client
}

func (s *stripeHTTP) Checkout(ctx context.Context, c Checkout) (string, error) {
	form := url.Values{
		"mode":                                 {"subscription"},
		"line_items[0][price]":                 {c.Price},
		"line_items[0][quantity]":              {"1"},
		"client_reference_id":                  {c.Account},
		"subscription_data[metadata][account]": {c.Account},
		"success_url":                          {c.SuccessURL},
		"cancel_url":                           {c.CancelURL},
	}
	if c.Customer != "" {
		form.Set("customer", c.Customer)
	}
	return s.post(ctx, "/v1/checkout/sessions", form)
}

func (s *stripeHTTP) Portal(ctx context.Context, customer, returnURL string) (string, error) {
	return s.post(ctx, "/v1/billing_portal/sessions", url.Values{"customer": {customer}, "return_url": {returnURL}})
}

// post makes a session, and gives its url. An error says Stripe's message, never the key.
func (s *stripeHTTP) post(ctx context.Context, path string, form url.Values) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.api+path, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+s.key)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("stripe %s: %w", path, err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var answer struct {
		URL   string `json:"url"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &answer)
	if res.StatusCode != http.StatusOK || answer.URL == "" {
		message := res.Status
		if answer.Error != nil && answer.Error.Message != "" {
			message = answer.Error.Message
		}
		return "", fmt.Errorf("stripe %s: %s", path, message)
	}
	return answer.URL, nil
}

// Tolerance is how old a webhook's signature may be (FR-033).
const Tolerance = 5 * time.Minute

// ErrSignature is a webhook whose Stripe-Signature is missing, wrong or too old.
var ErrSignature = errors.New("the webhook's signature is wrong or too old")

// Verify checks a webhook's Stripe-Signature header against the endpoint's secret: an
// HMAC-SHA256 of "<t>.<payload>" in one of its v1 values, made within Tolerance of now.
func Verify(payload []byte, header, secret string, now time.Time) error {
	if secret == "" {
		return ErrSignature
	}
	var at int64 = -1
	var signatures [][]byte
	for _, part := range strings.Split(header, ",") {
		k, v, _ := strings.Cut(strings.TrimSpace(part), "=")
		switch k {
		case "t":
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				at = n
			}
		case "v1":
			if b, err := hex.DecodeString(v); err == nil {
				signatures = append(signatures, b)
			}
		}
	}
	if at < 0 || len(signatures) == 0 {
		return ErrSignature
	}
	if d := now.Sub(time.Unix(at, 0)); d > Tolerance || d < -Tolerance {
		return ErrSignature
	}
	want := Sign(payload, secret, time.Unix(at, 0))
	for _, got := range signatures {
		if hmac.Equal(got, want) {
			return nil
		}
	}
	return ErrSignature
}

// Sign is the v1 signature of payload at t, as Stripe makes it.
func Sign(payload []byte, secret string, t time.Time) []byte {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(strconv.FormatInt(t.Unix(), 10) + "."))
	m.Write(payload)
	return m.Sum(nil)
}

// Header is a Stripe-Signature header for payload at t, for tests and the fake.
func Header(payload []byte, secret string, t time.Time) string {
	return "t=" + strconv.FormatInt(t.Unix(), 10) + ",v1=" + hex.EncodeToString(Sign(payload, secret, t))
}

// Event is the part of a webhook's event the service acts on.
type Event struct {
	ID   string `json:"id"`
	Type string `json:"type"`
	Data struct {
		Object Object `json:"object"`
	} `json:"data"`
}

// Object is the fields of a Checkout session or a subscription that the service reads.
type Object struct {
	// The subscription's id, for a subscription.
	ID string `json:"id"`
	// A Checkout session's account.
	ClientReferenceID string `json:"client_reference_id"`
	Customer          string `json:"customer"`
	// A Checkout session's subscription.
	Subscription string `json:"subscription"`
	// A subscription's status: active, trialing, past_due, canceled, unpaid, …
	Status   string            `json:"status"`
	Metadata map[string]string `json:"metadata"`
}

// The events the service acts on (FR-033).
const (
	CheckoutCompleted   = "checkout.session.completed"
	SubscriptionUpdated = "customer.subscription.updated"
	SubscriptionDeleted = "customer.subscription.deleted"
)

// Parse reads an event whose signature Verify passed.
func Parse(payload []byte) (Event, error) {
	var e Event
	if err := json.Unmarshal(payload, &e); err != nil {
		return e, err
	}
	if e.ID == "" || e.Type == "" {
		return e, errors.New("an event with no id or type")
	}
	return e, nil
}

// Paid says whether a subscription's status keeps the paid plan.
func Paid(status string) bool { return status == "active" || status == "trialing" }
