package hosted

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Admin is the operator's tool (#2152 FR-010, `agents-hosted admin`): it works on the
// service's store, from the service's machine. A running service sees what it writes: a
// suspension within a minute (sweepSuspended), the rest at the next sign-in.
type Admin struct {
	Store store.Store
	// Where the pages are, for an invite link.
	Domain string
	Now    func() time.Time
}

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
		var link struct {
			GitHub int64 `json:"github"`
		}
		if json.Unmarshal(o.Data, &link) != nil {
			continue
		}
		w, err := a.Store.Get(ctx, waitingKey(link.GitHub))
		if err != nil || w == nil {
			continue
		}
		var entry Waiting
		if json.Unmarshal(w.Data, &entry) == nil {
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

// Block refuses a GitHub user, by numeric id or by login (looked up in the accounts and
// the waitlist), and suspends their account. It says the id it blocked.
func (a Admin) Block(ctx context.Context, who, reason string) (int64, error) {
	user, login, err := a.resolve(ctx, who)
	if err != nil {
		return 0, err
	}
	data, _ := json.Marshal(Block{Login: login, Reason: reason, At: a.now()})
	if _, err := a.Store.Put(ctx, blockedKey(user), data, store.Always); err != nil {
		return 0, err
	}
	leaveWaitlist(ctx, a.Store, user)
	if acc, err := a.accounts().byGitHub(ctx, user); err != nil {
		return user, err
	} else if acc != nil {
		if reason == "" {
			reason = "Blocked by the operator."
		}
		return user, a.Suspend(ctx, acc.ID, reason)
	}
	return user, nil
}

// Unblock lets a GitHub id sign up again. Its account, if any, stays suspended until
// Unsuspend.
func (a Admin) Unblock(ctx context.Context, user int64) error {
	return a.Store.Delete(ctx, blockedKey(user))
}

// Accounts is every account.
func (a Admin) Accounts(ctx context.Context) ([]Account, error) { return a.accounts().all(ctx) }

// resolve is a GitHub id from a number, or from a login an account or the waitlist has.
func (a Admin) resolve(ctx context.Context, who string) (int64, string, error) {
	if n, err := strconv.ParseInt(who, 10, 64); err == nil && n > 0 {
		return n, "", nil
	}
	list, err := a.Accounts(ctx)
	if err != nil {
		return 0, "", err
	}
	for _, acc := range list {
		if strings.EqualFold(acc.GitHub.Login, who) {
			return acc.GitHub.ID, acc.GitHub.Login, nil
		}
	}
	waiting, err := a.Waitlist(ctx)
	if err != nil {
		return 0, "", err
	}
	for _, w := range waiting {
		if strings.EqualFold(w.GitHub.Login, who) {
			return w.GitHub.ID, w.GitHub.Login, nil
		}
	}
	return 0, "", fmt.Errorf("no account or waitlist entry has the login %q: give the GitHub id", who)
}
