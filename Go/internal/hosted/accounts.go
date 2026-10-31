package hosted

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Where things are in the service's store:
//
//	hosted/v1/accounts/<id>.json   an account: who signed up, and when
//	hosted/v1/github/<id>.json     a GitHub user's account, written once (one account each)
//	hosted/v1/keys/control.sealed  this service's own key, for its session key
//	hosted/v1/allow/<login>.json   a GitHub login that may sign up (#2152, signup.go)
//	hosted/v1/invites/<code>.json  an invite link, and who used it
//	hosted/v1/waiting/<id>.json    a GitHub user on the waitlist: its place's key below
//	hosted/v1/waitlist/<place>.json  the waitlist, in order of its keys
//	hosted/v1/blocked/<id>.json    a GitHub user who may not sign up
//	hosted/v1/stripe/<event>.json  a Stripe event acted on, so once (#2225, billing.go)
//	accounts/<id>/v1/…             the account's control plane's store, its sealed key too
const (
	hostedPrefix   = "hosted/"
	accountsPrefix = "accounts/"
)

// Account is one sign-up: the GitHub user it is for, and its control plane's id.
type Account struct {
	ID      string    `json:"id"`
	GitHub  GitHubID  `json:"github"`
	Created time.Time `json:"created"`
	// The plan whose limits hold (spec 1003 FR-020): "" is free.
	Plan string `json:"plan,omitempty"`
	// Set by the operator: the control plane is stopped and refuses every request.
	Suspended *Suspension `json:"suspended,omitempty"`
	// When its name's certificate was first allowed (FR-008), so it counts once.
	Certificate *time.Time `json:"certificate,omitempty"`
	// Its Stripe customer and subscription (#2225, FR-035): no card data.
	StripeCustomer     string `json:"stripe_customer,omitempty"`
	StripeSubscription string `json:"stripe_subscription,omitempty"`
}

// Suspension is why and when the operator suspended an account.
type Suspension struct {
	Reason string    `json:"reason"`
	At     time.Time `json:"at"`
}

// GitHubID is who signed in: GitHub's numeric id, which never changes, and the login
// when they signed up, for the page. Created is when the GitHub account was made, for
// the minimum age (#2152); it is not kept.
type GitHubID struct {
	ID      int64     `json:"id"`
	Login   string    `json:"login"`
	Created time.Time `json:"-"`
}

type accounts struct {
	store store.Store
	now   func() time.Time
}

func accountKey(id string) string { return hostedPrefix + "v1/accounts/" + id + ".json" }
func gitHubKey(id int64) string {
	return hostedPrefix + "v1/github/" + strconv.FormatInt(id, 10) + ".json"
}
func accountStore(st store.Store, id string) *store.Prefixed {
	return store.NewPrefixed(st, accountsPrefix+id+"/")
}

// byGitHub is the account a GitHub user signed up with, or nil.
func (a *accounts) byGitHub(ctx context.Context, user int64) (*Account, error) {
	o, err := a.store.Get(ctx, gitHubKey(user))
	if err != nil || o == nil {
		return nil, err
	}
	var link struct {
		Account string `json:"account"`
	}
	if err := json.Unmarshal(o.Data, &link); err != nil {
		return nil, err
	}
	return a.get(ctx, link.Account)
}

func (a *accounts) get(ctx context.Context, id string) (*Account, error) {
	if !validID(id) {
		return nil, nil
	}
	o, err := a.store.Get(ctx, accountKey(id))
	if err != nil || o == nil {
		return nil, err
	}
	var acc Account
	if err := json.Unmarshal(o.Data, &acc); err != nil {
		return nil, err
	}
	return &acc, nil
}

// make is a sign-up: the GitHub user's link first, written only if absent, so a user gets
// one account however many times they sign up at once. It says whether it was made.
func (a *accounts) make(ctx context.Context, user GitHubID) (*Account, bool, error) {
	acc := Account{ID: newID(), GitHub: user, Created: a.now().UTC()}
	link, _ := json.Marshal(map[string]string{"account": acc.ID})
	if _, err := a.store.Put(ctx, gitHubKey(user.ID), link, store.Absent); err != nil {
		if store.IsConflict(err) {
			existing, err := a.byGitHub(ctx, user.ID)
			return existing, false, err
		}
		return nil, false, err
	}
	data, _ := json.MarshalIndent(acc, "", "  ")
	if _, err := a.store.Put(ctx, accountKey(acc.ID), data, store.Absent); err != nil {
		return nil, false, err
	}
	return &acc, true, nil
}

// update changes an account's record by f, again on a conflict, and gives it back as
// written; nil when there is no account.
func (a *accounts) update(ctx context.Context, id string, f func(*Account)) (*Account, error) {
	for range 5 {
		o, err := a.store.Get(ctx, accountKey(id))
		if err != nil || o == nil {
			return nil, err
		}
		var acc Account
		if err := json.Unmarshal(o.Data, &acc); err != nil {
			return nil, err
		}
		f(&acc)
		data, _ := json.MarshalIndent(acc, "", "  ")
		if _, err := a.store.Put(ctx, accountKey(id), data, store.Matching(o.ETag)); err != nil {
			if store.IsConflict(err) {
				continue
			}
			return nil, err
		}
		return &acc, nil
	}
	return nil, fmt.Errorf("account %s kept changing", id)
}

// all is every account, in order of id.
func (a *accounts) all(ctx context.Context) ([]Account, error) {
	keys, err := a.store.List(ctx, hostedPrefix+"v1/accounts/")
	if err != nil {
		return nil, err
	}
	var list []Account
	for _, k := range keys {
		id := strings.TrimSuffix(strings.TrimPrefix(k.Key, hostedPrefix+"v1/accounts/"), ".json")
		if acc, err := a.get(ctx, id); err != nil {
			return nil, err
		} else if acc != nil {
			list = append(list, *acc)
		}
	}
	return list, nil
}

// count is how many accounts there are.
func (a *accounts) count(ctx context.Context) (int, error) {
	keys, err := a.store.List(ctx, hostedPrefix+"v1/accounts/")
	return len(keys), err
}

// remove deletes the account: its control plane's whole store, then the account, then the
// GitHub user's link, so a stop part way is finished by deleting again.
func (a *accounts) remove(ctx context.Context, acc *Account) error {
	if _, err := store.DeleteAll(ctx, accountStore(a.store, acc.ID)); err != nil {
		return fmt.Errorf("its store: %w", err)
	}
	if err := a.store.Delete(ctx, usageKey(acc.ID)); err != nil {
		return err
	}
	if err := a.store.Delete(ctx, accountKey(acc.ID)); err != nil {
		return err
	}
	return a.store.Delete(ctx, gitHubKey(acc.GitHub.ID))
}

// An account's id is its control plane's host name: ten lower-case letters and digits,
// random, so it says nothing of who signed up.
const idLetters = "abcdefghijklmnopqrstuvwxyz0123456789"

func newID() string {
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = idLetters[int(b[i])%len(idLetters)]
	}
	// A name starts with a letter.
	b[0] = idLetters[int(b[0])%26]
	return string(b)
}

func validID(id string) bool {
	if len(id) != 10 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}
