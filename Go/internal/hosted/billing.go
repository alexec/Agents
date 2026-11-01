package hosted

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/hosted/billing"
)

// Billing (#2225, spec 1003 FR-030..FR-035): with a Stripe key, the account page has
// Upgrade (a Checkout session for Pro) and Manage Billing (Stripe's customer portal), and
// Stripe's webhook puts the account on Pro or Free. Without a key, none of these routes
// answers. Stripe keeps the cards; the account keeps the customer and subscription ids.
//
//	/account/upgrade   POST: to Stripe Checkout for Pro
//	/account/billing   POST: to Stripe's customer portal
//	/billing/webhook   POST: Stripe's events, signed

// How long an event acted on is kept, so a retry of it is not acted on again.
const stripeEventLife = 30 * 24 * time.Hour

func stripeEventKey(id string) string { return hostedPrefix + "v1/stripe/" + id + ".json" }

func (s *Service) billingOn() bool { return s.stripe != nil }

// upgrade sends the browser to a Checkout session for Pro.
func (s *Service) upgrade(w http.ResponseWriter, r *http.Request, account string) {
	acc, err := s.accounts.get(r.Context(), account)
	if err != nil || acc == nil {
		http.Redirect(w, r, "/account", http.StatusSeeOther)
		return
	}
	if acc.Plan == PlanPro {
		http.Redirect(w, r, "/account", http.StatusSeeOther)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	// Pro's storage must fit beside every other plan's (#3121).
	if room, err := s.roomFor(ctx, plans[PlanPro].Storage-PlanOf(acc).Storage); err != nil || !room {
		if err != nil {
			s.log(acc.ID + ": upgrade: " + err.Error())
		}
		s.metrics.refused("upgrade_full")
		s.accountPage(w, r, account, "Agents has no room for more Pro plans just now. Try Upgrade again another day.")
		return
	}
	back := "https://" + s.cfg.Domain + "/account"
	to, err := s.stripe.Checkout(ctx, billing.Checkout{Price: s.cfg.StripePrice, Account: acc.ID,
		Customer: acc.StripeCustomer, SuccessURL: back + "?upgraded=1", CancelURL: back})
	if err != nil {
		s.log(acc.ID + ": checkout: " + err.Error())
		s.accountPage(w, r, account, "Stripe could not be reached just now. Try Upgrade again in a moment.")
		return
	}
	http.Redirect(w, r, to, http.StatusSeeOther)
}

// manageBilling sends the browser to Stripe's portal for the account's customer.
func (s *Service) manageBilling(w http.ResponseWriter, r *http.Request, account string) {
	acc, err := s.accounts.get(r.Context(), account)
	if err != nil || acc == nil || acc.StripeCustomer == "" {
		http.Redirect(w, r, "/account", http.StatusSeeOther)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	to, err := s.stripe.Portal(ctx, acc.StripeCustomer, "https://"+s.cfg.Domain+"/account")
	if err != nil {
		s.log(acc.ID + ": billing portal: " + err.Error())
		s.accountPage(w, r, account, "Stripe could not be reached just now. Try Manage Billing again in a moment.")
		return
	}
	http.Redirect(w, r, to, http.StatusSeeOther)
}

// webhook is Stripe's event: signed with the endpoint's secret within five minutes, and
// acted on once (FR-033). An event for an account that is gone is ignored, and logged.
func (s *Service) webhook(w http.ResponseWriter, r *http.Request) {
	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		plain(w, http.StatusBadRequest, "The event could not be read.\n")
		return
	}
	if err := billing.Verify(payload, r.Header.Get("Stripe-Signature"), s.cfg.StripeWebhookSecret, s.cfg.Now()); err != nil {
		s.log("stripe: refused an event: " + err.Error())
		plain(w, http.StatusBadRequest, "The signature is wrong or too old.\n")
		return
	}
	event, err := billing.Parse(payload)
	if err != nil || !validEventID(event.ID) {
		plain(w, http.StatusBadRequest, "That is not an event.\n")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	// Seen first, written only if absent, so two deliveries at once act once; taken back
	// when acting fails, so Stripe's retry acts.
	seen, _ := json.Marshal(map[string]any{"type": event.Type, "at": s.cfg.Now().UTC()})
	if _, err := s.cfg.Store.Put(ctx, stripeEventKey(event.ID), seen, store.Absent); err != nil {
		if store.IsConflict(err) {
			plain(w, http.StatusOK, "Already done.\n")
			return
		}
		s.log("stripe " + event.ID + ": " + err.Error())
		plain(w, http.StatusServiceUnavailable, "Try again.\n")
		return
	}
	if err := s.actOn(ctx, event); err != nil {
		_ = s.cfg.Store.Delete(ctx, stripeEventKey(event.ID))
		s.log("stripe " + event.ID + ": " + err.Error())
		plain(w, http.StatusServiceUnavailable, "Try again.\n")
		return
	}
	plain(w, http.StatusOK, "Done.\n")
}

// actOn changes the account's plan for an event: Pro when a Checkout is done, Pro or Free
// as a subscription's status says, Free when it ends. Nothing is deleted (FR-023).
func (s *Service) actOn(ctx context.Context, e billing.Event) error {
	o := e.Data.Object
	var account string
	var change func(*Account)
	switch e.Type {
	case billing.CheckoutCompleted:
		account = o.ClientReferenceID
		change = func(acc *Account) {
			acc.Plan, acc.StripeCustomer = PlanPro, o.Customer
			if o.Subscription != "" {
				acc.StripeSubscription = o.Subscription
			}
		}
	case billing.SubscriptionUpdated, billing.SubscriptionDeleted:
		account = o.Metadata["account"]
		if account == "" {
			found, err := s.byCustomer(ctx, o.Customer)
			if err != nil {
				return err
			}
			account = found
		}
		paid := e.Type == billing.SubscriptionUpdated && billing.Paid(o.Status)
		change = func(acc *Account) {
			// An old subscription's end does not end a newer one.
			if !paid && acc.StripeSubscription != "" && acc.StripeSubscription != o.ID {
				return
			}
			acc.Plan = PlanFree
			if paid {
				acc.Plan, acc.StripeSubscription = PlanPro, o.ID
			}
			if o.Customer != "" {
				acc.StripeCustomer = o.Customer
			}
		}
	default:
		return nil
	}
	if !validID(account) {
		s.log("stripe " + e.ID + ": " + e.Type + " names no account; ignored")
		return nil
	}
	acc, err := s.accounts.update(ctx, account, change)
	if err != nil {
		return err
	}
	if acc == nil {
		s.log("stripe " + e.ID + ": " + e.Type + " for " + account + ", which is gone; ignored")
		return nil
	}
	s.log(acc.ID + ": " + e.Type + ": on " + PlanOf(acc).Name)
	s.planChanged(acc)
	return nil
}

// byCustomer is the account with a Stripe customer, or "".
func (s *Service) byCustomer(ctx context.Context, customer string) (string, error) {
	if customer == "" {
		return "", nil
	}
	list, err := s.accounts.all(ctx)
	if err != nil {
		return "", err
	}
	for _, acc := range list {
		if acc.StripeCustomer == customer {
			return acc.ID, nil
		}
	}
	return "", nil
}

// planChanged gives a running copy its new plan now, not at the next sweep.
func (s *Service) planChanged(acc *Account) {
	s.mu.Lock()
	c := s.copies[acc.ID]
	s.mu.Unlock()
	if c != nil && c.limits != nil {
		c.limits.setPlan(PlanOf(acc))
	}
}

// sweepStripeEvents deletes the events acted on more than stripeEventLife ago, once a day.
func (s *Service) sweepStripeEvents(ctx context.Context) {
	if !s.billingOn() {
		return
	}
	now := s.cfg.Now()
	s.mu.Lock()
	due := now.Sub(s.stripeSwept) >= 24*time.Hour
	if due {
		s.stripeSwept = now
	}
	s.mu.Unlock()
	if !due {
		return
	}
	keys, err := s.cfg.Store.List(ctx, hostedPrefix+"v1/stripe/")
	if err != nil {
		s.log("stripe events sweep: " + err.Error())
		return
	}
	for _, k := range keys {
		o, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil || o == nil {
			continue
		}
		var seen struct {
			At time.Time `json:"at"`
		}
		if json.Unmarshal(o.Data, &seen) == nil && now.Sub(seen.At) > stripeEventLife {
			_ = s.cfg.Store.Delete(ctx, k.Key)
		}
	}
}

// validEventID is a Stripe event id as a store key may hold it: evt_ and letters, digits.
func validEventID(id string) bool {
	if !strings.HasPrefix(id, "evt_") || len(id) > 255 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}
