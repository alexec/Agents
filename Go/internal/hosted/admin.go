package hosted

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/kms"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/signin"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
)

// Admin is the operator's tool (#2152 FR-010, `agents-hosted admin`): it works on the
// service's store, from the service's machine. A running service sees what it writes: a
// suspension within a minute (sweepAccounts), the rest at the next sign-in.
type Admin struct {
	Store store.Store
	// Where the pages are, for an invite link.
	Domain string
	// The service's keeper (AGENTS_CONTROL_KMS), for an email's mark: only a block or an
	// unblock by email needs it.
	Keeper string
	Now    func() time.Time
}

// markOf is an email's mark, as the service makes it.
func (a Admin) markOf(ctx context.Context, email string) (string, error) {
	if a.Keeper == "" {
		return "", errors.New("an email's mark needs the service's keeper: AGENTS_CONTROL_KMS, as serve has")
	}
	own, err := kms.Kept{Store: store.NewPrefixed(a.Store, hostedPrefix), Keeper: a.Keeper}.ControlKey(ctx)
	if err != nil {
		return "", fmt.Errorf("the hosted service's own key: %w", err)
	}
	return emailMark(emailMarkKey(own), email), nil
}

// isEmail says the operator typed an email, not a sign-in.
func isEmail(who string) bool { return strings.Contains(who, "@") }

func (a Admin) now() time.Time {
	if a.Now == nil {
		return time.Now().UTC()
	}
	return a.Now().UTC()
}

func (a Admin) accounts() *accounts { return &accounts{store: a.Store, now: a.now} }

// Invite makes an invite link, usable once within life (InviteLife when 0).
func (a Admin) Invite(ctx context.Context, life time.Duration) (string, error) {
	if life <= 0 {
		life = InviteLife
	}
	code := newInviteCode()
	data, _ := json.Marshal(Invite{Expires: a.now().Add(life)})
	if _, err := a.Store.Put(ctx, inviteKey(code), data, store.Absent); err != nil {
		return "", err
	}
	return "https://" + a.Domain + "/?invite=" + code, nil
}

// Allow lets a GitHub login sign up, whatever its age; Admit is the same for one on the
// waitlist.
func (a Admin) Allow(ctx context.Context, login string) error {
	if !validLogin(login) {
		return fmt.Errorf("%q is not a GitHub login", login)
	}
	data, _ := json.Marshal(map[string]any{"login": login, "at": a.now()})
	_, err := a.Store.Put(ctx, allowKey(login), data, store.Always)
	return err
}

// Disallow takes a login off the allowlist. An account made already stays.
func (a Admin) Disallow(ctx context.Context, login string) error {
	if !validLogin(login) {
		return fmt.Errorf("%q is not a GitHub login", login)
	}
	return a.Store.Delete(ctx, allowKey(login))
}

// Waitlist is everyone on it, in order.
func (a Admin) Waitlist(ctx context.Context) ([]Waiting, error) {
	keys, err := a.Store.List(ctx, waitlistFolder)
	if err != nil {
		return nil, err
	}
	var list []Waiting
	for _, k := range keys {
		o, err := a.Store.Get(ctx, k.Key)
		if err != nil || o == nil {
			continue
		}
		var link waitlistLink
		if json.Unmarshal(o.Data, &link) != nil || !link.signIn().valid() {
			continue
		}
		w, err := a.Store.Get(ctx, waitingKey(link.signIn()))
		if err != nil || w == nil {
			continue
		}
		var entry Waiting
		if json.Unmarshal(w.Data, &entry) == nil {
			entry.SignIn = signInOf(entry.SignIn, entry.GitHub)
			list = append(list, entry)
		}
	}
	return list, nil
}

// Suspend stops an account's control plane and refuses its requests, keeping its records.
func (a Admin) Suspend(ctx context.Context, id, reason string) error {
	if strings.TrimSpace(reason) == "" {
		return errors.New("say why: the person reads it on their account page")
	}
	acc, err := a.accounts().update(ctx, id, func(acc *Account) {
		acc.Suspended = &Suspension{Reason: reason, At: a.now()}
	})
	if err == nil && acc == nil {
		err = fmt.Errorf("there is no account %q", id)
	}
	return err
}

// Unsuspend lets an account's control plane start again at its next request.
func (a Admin) Unsuspend(ctx context.Context, id string) error {
	acc, err := a.accounts().update(ctx, id, func(acc *Account) { acc.Suspended = nil })
	if err == nil && acc == nil {
		err = fmt.Errorf("there is no account %q", id)
	}
	return err
}

// Block refuses a sign-in, by provider:subject, a GitHub user's numeric id, or a GitHub
// login (looked up in the accounts and the waitlist), and suspends their account; its
// email, when the account has one, is blocked too (#3388). Given an email, it blocks
// that email, from every provider, and suspends the email's account. It says the sign-in
// it blocked (none for an email).
func (a Admin) Block(ctx context.Context, who, reason string) (SignIn, error) {
	data, _ := json.Marshal(Block{Reason: reason, At: a.now()})
	if reason == "" {
		reason = "Blocked by the operator."
	}
	if isEmail(who) {
		mark, err := a.markOf(ctx, who)
		if err != nil {
			return SignIn{}, err
		}
		if _, err := a.Store.Put(ctx, blockedEmailKey(mark), data, store.Always); err != nil {
			return SignIn{}, err
		}
		acc, err := a.accounts().byEmail(ctx, mark)
		if err != nil || acc == nil {
			return SignIn{}, err
		}
		return SignIn{}, a.Suspend(ctx, acc.ID, reason)
	}
	user, err := a.resolve(ctx, who)
	if err != nil {
		return SignIn{}, err
	}
	data, _ = json.Marshal(Block{Login: user.Login, Reason: reason, At: a.now()})
	if _, err := a.Store.Put(ctx, blockedKey(user), data, store.Always); err != nil {
		return SignIn{}, err
	}
	leaveWaitlist(ctx, a.Store, user)
	if acc, err := a.accounts().bySignIn(ctx, user); err != nil {
		return user, err
	} else if acc != nil {
		if acc.EmailMark != "" {
			if _, err := a.Store.Put(ctx, blockedEmailKey(acc.EmailMark), data, store.Always); err != nil {
				return user, err
			}
		}
		return user, a.Suspend(ctx, acc.ID, reason)
	}
	return user, nil
}

// Unblock lets a sign-in, provider:subject or a GitHub id, and its account's email, or an
// email alone, sign up again. Its account, if any, stays suspended until Unsuspend.
func (a Admin) Unblock(ctx context.Context, who string) error {
	if isEmail(who) {
		mark, err := a.markOf(ctx, who)
		if err != nil {
			return err
		}
		return a.Store.Delete(ctx, blockedEmailKey(mark))
	}
	user, ok := parseSignIn(who)
	if !ok {
		return fmt.Errorf("%q: %w", who, ErrNotSignIn)
	}
	if acc, err := a.accounts().bySignIn(ctx, user); err != nil {
		return err
	} else if acc != nil && acc.EmailMark != "" {
		if err := a.Store.Delete(ctx, blockedEmailKey(acc.EmailMark)); err != nil {
			return err
		}
	}
	return a.Store.Delete(ctx, blockedKey(user))
}

// ErrNotSignIn is a sign-in the operator typed that is neither provider:subject nor a
// GitHub id.
var ErrNotSignIn = errors.New("not provider:subject or a GitHub id")

// parseSignIn is a sign-in as the operator types it: provider:subject, or a GitHub id.
func parseSignIn(who string) (SignIn, bool) {
	if n, err := strconv.ParseInt(who, 10, 64); err == nil && n > 0 {
		return gitHubSignIn(n, ""), true
	}
	provider, subject, ok := strings.Cut(who, ":")
	user := SignIn{Provider: strings.ToLower(provider), Subject: subject}
	return user, ok && user.valid()
}

// SetPlan puts an account on a plan by hand (#2224): a running copy has its limits within
// a minute. Billing sets it too (#2225).
func (a Admin) SetPlan(ctx context.Context, id, plan string) error {
	if !ValidPlan(plan) {
		return fmt.Errorf("%q is not a plan: free or pro", plan)
	}
	acc, err := a.accounts().update(ctx, id, func(acc *Account) { acc.Plan = plan })
	if err == nil && acc == nil {
		err = fmt.Errorf("there is no account %q", id)
	}
	return err
}

// Accounts is every account.
func (a Admin) Accounts(ctx context.Context) ([]Account, error) { return a.accounts().all(ctx) }

// resolve is a sign-in from provider:subject, a GitHub id, or a GitHub login an account or
// the waitlist has.
func (a Admin) resolve(ctx context.Context, who string) (SignIn, error) {
	if user, ok := parseSignIn(who); ok {
		return user, nil
	}
	list, err := a.Accounts(ctx)
	if err != nil {
		return SignIn{}, err
	}
	for _, acc := range list {
		if acc.SignIn.Provider == signin.GitHub && strings.EqualFold(acc.SignIn.Login, who) {
			return acc.SignIn, nil
		}
	}
	waiting, err := a.Waitlist(ctx)
	if err != nil {
		return SignIn{}, err
	}
	for _, w := range waiting {
		if w.SignIn.Provider == signin.GitHub && strings.EqualFold(w.SignIn.Login, who) {
			return w.SignIn, nil
		}
	}
	return SignIn{}, fmt.Errorf("no account or waitlist entry has the GitHub login %q: give provider:subject or the GitHub id", who)
}
