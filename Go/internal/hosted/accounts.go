package hosted

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Where things are in the service's store:
//
//	hosted/v1/accounts/<id>.json   an account: who signed up, and when
//	hosted/v1/<provider>/<subject>.json  a sign-in's account, written once (one account
//	                               each): github/<id>, apple/<sub> or google/<sub> (#3386)
//	hosted/v1/keys/control.sealed  this service's own key, for its session key
//	hosted/v1/allow/<login>.json   a GitHub login that may sign up (#2152, signup.go)
//	hosted/v1/invites/<code>.json  an invite link, and who used it
//	hosted/v1/waiting/<who>.json   a sign-in on the waitlist: its place's key below
//	hosted/v1/waitlist/<place>.json  the waitlist, in order of its keys
//	hosted/v1/blocked/<who>.json   a sign-in that may not sign up
//
// <who> is a GitHub user's id, as before #3386, or apple/<sub> or google/<sub>.
//	hosted/v1/stripe/<event>.json  a Stripe event acted on, so once (#2225, billing.go)
//	accounts/<id>/v1/…             the account's control plane's store, its sealed key too
const (
	hostedPrefix   = "hosted/"
	accountsPrefix = "accounts/"
)

// Account is one sign-up: the sign-in it is for, and its control plane's id.
type Account struct {
	ID string `json:"id"`
	// Who signed up: their control plane's first person signs in with it too (#3386).
	SignIn SignIn `json:"signIn"`
	// The GitHub user of an account made before #3386, read as its SignIn.
	GitHub  *GitHubID `json:"github,omitempty"`
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

// SignIn is who signed in (#3386): a provider (apple, google or github) and its subject,
// which never changes, as the control plane keys a person's sign-in. GitHub's subject is
// its numeric id, and Login its login when they signed in, for the page and the allowlist;
// Apple and Google give no login, and none is asked for. Created is when a GitHub account
// was made, for the minimum age (#2152); it is not kept.
type SignIn struct {
	Provider string    `json:"provider"`
	Subject  string    `json:"subject"`
	Login    string    `json:"login,omitempty"`
	Created  time.Time `json:"-"`
}

// gitHubSignIn is a GitHub user's sign-in.
func gitHubSignIn(id int64, login string) SignIn {
	return SignIn{Provider: signin.GitHub, Subject: strconv.FormatInt(id, 10), Login: login}
}

// who is the sign-in in a key: a GitHub user's id alone, as before #3386, so their
// records are where they were; <provider>/<subject> for the others.
func (si SignIn) who() string {
	if si.Provider == signin.GitHub {
		return si.Subject
	}
	return si.Provider + "/" + si.Subject
}

// String is the sign-in as the operator's tool says it: provider:subject.
func (si SignIn) String() string { return si.Provider + ":" + si.Subject }

// Shown is the sign-in as the account page says it: "GitHub as ana", or "Apple".
func (si SignIn) Shown() string {
	if si.Login != "" {
		return signin.Title(si.Provider) + " as " + si.Login
	}
	return signin.Title(si.Provider)
}

// valid says a sign-in can be a key: a provider this service knows, and a subject of
// letters, digits, dots, hyphens and underscores (Apple's is 000123.abc….0123; GitHub's
// is digits).
func (si SignIn) valid() bool {
	if si.Provider != signin.Apple && si.Provider != signin.Google && si.Provider != signin.GitHub {
		return false
	}
	if si.Subject == "" || len(si.Subject) > 255 || si.Subject[0] == '.' {
		return false
	}
	for i := 0; i < len(si.Subject); i++ {
		c := si.Subject[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') {
			return false
		}
		if si.Provider == signin.GitHub && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// GitHubID is a GitHub user as records before #3386 say them: its numeric id, and its
// login then.
type GitHubID struct {
	ID    int64  `json:"id"`
	Login string `json:"login"`
}

// signInOf is a record's sign-in: the one it says, or its GitHub user's, from before #3386.
func signInOf(si SignIn, legacy *GitHubID) SignIn {
	if si.Provider == "" && legacy != nil && legacy.ID > 0 {
		return gitHubSignIn(legacy.ID, legacy.Login)
	}
	return si
}

type accounts struct {
	store store.Store
	now   func() time.Time
}

func accountKey(id string) string { return hostedPrefix + "v1/accounts/" + id + ".json" }
// signInKey is a sign-in's link to its account: hosted/v1/github/<id>.json for a GitHub
// user, as before #3386.
func signInKey(si SignIn) string {
	return hostedPrefix + "v1/" + si.Provider + "/" + si.Subject + ".json"
}
func accountStore(st store.Store, id string) *store.Prefixed {
	return store.NewPrefixed(st, accountsPrefix+id+"/")
}

// bySignIn is the account a sign-in signed up with, or nil.
func (a *accounts) bySignIn(ctx context.Context, user SignIn) (*Account, error) {
	if !user.valid() {
		return nil, nil
	}
	o, err := a.store.Get(ctx, signInKey(user))
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
	acc.SignIn = signInOf(acc.SignIn, acc.GitHub)
	return &acc, nil
}

// make is a sign-up: the sign-in's link first, written only if absent, so a person gets
// one account however many times they sign up at once. It says whether it was made.
func (a *accounts) make(ctx context.Context, user SignIn) (*Account, bool, error) {
	if !user.valid() {
		return nil, false, fmt.Errorf("%s is not a sign-in", user)
	}
	acc := Account{ID: newID(), SignIn: user, Created: a.now().UTC()}
	link, _ := json.Marshal(map[string]string{"account": acc.ID})
	if _, err := a.store.Put(ctx, signInKey(user), link, store.Absent); err != nil {
		if store.IsConflict(err) {
			existing, err := a.bySignIn(ctx, user)
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
		acc.SignIn = signInOf(acc.SignIn, acc.GitHub)
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
// sign-in's link, so a stop part way is finished by deleting again.
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
	return a.store.Delete(ctx, signInKey(acc.SignIn))
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
