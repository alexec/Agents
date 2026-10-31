package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Leavers without SCIM (#1002, Q1 answer A, FR-024): an org sign-in's refresh token is
// kept sealed with the keeper, bound to its store key, and used at each key renewal of the
// person's clients and once a day. invalid_grant suspends the person (D13). While the
// provider cannot be reached, keys renew for 7 days after the last good check, then stop
// until a check succeeds. No refresh token leaves the control plane, or is written in the
// clear.

const (
	refreshPrefix = "v1/signin/refresh/"
	// refreshGrace is how long keys renew while the provider cannot be reached.
	refreshGrace = 7 * 24 * time.Hour
	// refreshEvery is how often each person is checked with no renewal.
	refreshEvery = 24 * time.Hour
	// refreshQuiet is how long a good check stands before a renewal asks again.
	refreshQuiet = time.Hour
)

func refreshKey(person, provider string) string {
	return refreshPrefix + person + "/" + provider + ".json"
}

// refreshRecord is signin/refresh/<person>/<provider>.json.
type refreshRecord struct {
	ID           string         `json:"id"`
	Sealed       *kms.Sealed    `json:"sealed"`
	LastGood     records.Stamp  `json:"lastGood"`
	FailingSince *records.Stamp `json:"failingSince,omitempty"`
}

// sealTicketRefresh seals a callback's refresh token into its ticket, bound to the
// ticket's key, so the ticket in the store holds nothing to use.
func (si *signIns) sealTicketRefresh(ctx context.Context, ticketKey, refresh string) *kms.Sealed {
	if refresh == "" {
		return nil
	}
	sealed, err := si.s.users.SealFor(ctx, []byte(refresh), []byte(ticketKey+"#refresh"))
	if err != nil {
		si.s.log("an org sign-in's refresh token could not be sealed; its person is checked at sign-in only")
		return nil
	}
	return sealed
}

// keepRefresh moves a spent ticket's refresh token to its person, as their last good
// check.
func (si *signIns) keepRefresh(ctx context.Context, t *orgTicket, person string) {
	if t.Refresh == nil || person == "" {
		return
	}
	plain, err := si.s.users.OpenFor(ctx, t.Refresh, []byte(t.key+"#refresh"))
	if err != nil {
		si.s.log("an org sign-in's refresh token could not be opened")
		return
	}
	if err := si.writeRefresh(ctx, person, t.Provider, string(plain), records.At(si.clock()), nil, store.Always); err != nil {
		si.s.log("an org sign-in's refresh token could not be kept: " + err.Error())
	}
}

func (si *signIns) writeRefresh(ctx context.Context, person, provider, token string, good records.Stamp, failing *records.Stamp, when store.Condition) error {
	key := refreshKey(person, provider)
	sealed, err := si.s.users.SealFor(ctx, []byte(token), []byte(key))
	if err != nil {
		return err
	}
	data, err := records.Encode(refreshRecord{ID: key, Sealed: sealed, LastGood: good, FailingSince: failing})
	if err != nil {
		return err
	}
	_, err = si.s.cfg.Store.Put(ctx, key, data, when)
	return err
}

// refreshVerdict is what a check found.
type refreshVerdict int

const (
	refreshNone refreshVerdict = iota // no refresh token kept: nothing to say
	refreshGood
	refreshDown    // the provider could not be reached, within the grace
	refreshTooLong // the provider could not be reached for more than the grace
	refreshRefused // invalid_grant: the person is suspended
)

// checkRefresh uses one person's refresh token of one provider.
func (si *signIns) checkRefresh(ctx context.Context, person, provider string) refreshVerdict {
	key := refreshKey(person, provider)
	object, err := si.s.cfg.Store.Get(ctx, key)
	if err != nil {
		return refreshDown
	}
	if object == nil {
		return refreshNone
	}
	var r refreshRecord
	if json.Unmarshal(object.Data, &r) != nil || r.Sealed == nil {
		return refreshNone
	}
	p := si.s.records.Person(person)
	if p == nil || p.IsRemoved() || !hasSignInOf(p, provider) {
		_ = si.s.cfg.Store.Delete(ctx, key)
		return refreshNone
	}
	now := si.clock()
	// Checked within the hour: a renewal on each connection asks the provider no more.
	if r.FailingSince == nil && now.Sub(r.LastGood.Time) < refreshQuiet {
		return refreshGood
	}
	down := func() refreshVerdict {
		if r.FailingSince == nil {
			at := records.At(now)
			r.FailingSince = &at
			if data, err := records.Encode(r); err == nil {
				_, _ = si.s.cfg.Store.Put(ctx, key, data, store.Matching(object.ETag))
			}
		}
		if now.Sub(r.LastGood.Time) > refreshGrace {
			return refreshTooLong
		}
		return refreshDown
	}
	token, err := si.s.users.OpenFor(ctx, r.Sealed, []byte(key))
	if err != nil {
		return down()
	}
	o, err := si.scimProvider(ctx, provider)
	if err != nil {
		_ = si.s.cfg.Store.Delete(ctx, key)
		return refreshNone
	}
	d, err := si.discovery(ctx, *o, false)
	if err != nil {
		return down()
	}
	secret, err := si.openSecret(ctx, provider)
	if err != nil {
		return down()
	}
	client := si.cfg.HTTP
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	next, err := signin.Refresh(ctx, client, d, o.ClientID, secret, string(token), o.Name)
	switch {
	case errors.Is(err, signin.ErrInvalidGrant):
		_ = si.s.cfg.Store.Delete(ctx, key)
		actor := wire.AuditActor{User: person, Refresh: &wire.AuditRefresh{Provider: provider}}
		if name := si.s.personName(person); name != "" {
			actor.UserName = &name
		}
		si.s.suspend(ctx, person, records.Suspension{By: "refresh", Provider: provider, At: records.At(now),
			Why: o.Name + " refused the sign-in's refresh"}, actor)
		return refreshRefused
	case err != nil:
		return down()
	}
	if err := si.writeRefresh(ctx, person, provider, next, records.At(now), nil, store.Matching(object.ETag)); err != nil {
		si.s.log("a refresh token could not be kept again: " + err.Error())
	}
	return refreshGood
}

func hasSignInOf(p *records.Person, provider string) bool {
	for _, s := range p.SignIns {
		if s.Provider == provider {
			return true
		}
	}
	return false
}

// refreshAllows checks each org sign-in of a person that keeps a refresh token, as their
// key is about to renew, and says whether it may: not when the provider refused, or has
// not answered for more than the grace.
func (si *signIns) refreshAllows(ctx context.Context, person string) bool {
	p := si.s.records.Person(person)
	if p == nil {
		return true
	}
	for _, sign := range p.SignIns {
		if !isOrgProvider(sign.Provider) {
			continue
		}
		switch si.checkRefresh(ctx, person, sign.Provider) {
		case refreshRefused, refreshTooLong:
			return false
		}
	}
	return true
}

// checkRefreshes is the daily check: each refresh token not used for a day.
func (si *signIns) checkRefreshes(ctx context.Context) {
	keys, err := si.s.cfg.Store.List(ctx, refreshPrefix)
	if err != nil {
		return
	}
	now := si.clock()
	for _, k := range keys {
		person, provider, ok := strings.Cut(strings.TrimSuffix(strings.TrimPrefix(k.Key, refreshPrefix), ".json"), "/")
		if !ok {
			continue
		}
		object, err := si.s.cfg.Store.Get(ctx, k.Key)
		if err != nil || object == nil {
			continue
		}
		var r refreshRecord
		if json.Unmarshal(object.Data, &r) != nil {
			continue
		}
		if now.Sub(r.LastGood.Time) < refreshEvery && r.FailingSince == nil {
			continue
		}
		si.checkRefresh(ctx, person, provider)
	}
}

// dropRefreshes deletes a removed person's refresh tokens.
func (si *signIns) dropRefreshes(ctx context.Context, person string) {
	keys, err := si.s.cfg.Store.List(ctx, refreshPrefix+person+"/")
	if err != nil {
		return
	}
	for _, k := range keys {
		_ = si.s.cfg.Store.Delete(ctx, k.Key)
	}
}
