package controlplane

import (
	"context"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Key lifetimes (#997, spec 736 FR-042). A client's or machine's key expires 90 days
// after it was paired or last renewed, and the control plane renews it while it is in
// use: on each connection, and every hour for a connection that stays open, once it is
// in the last 30 days of its life. Every connection proves the key already (R6), so a
// renewal needs no call of its own. A key that expired is refused as expired; the client
// asks for a new code, as a forgotten one does.

// DefaultKeyLifetime is how long a key lives with no setting.
const DefaultKeyLifetime = 90 * 24 * time.Hour

// renewWithin is how near its end a key is renewed: the last 30 days, or the last third
// of a shorter lifetime.
func renewWithin(life time.Duration) time.Duration {
	return min(30*24*time.Hour, life/3)
}

func (s *Service) keyLifetime() time.Duration {
	if s.cfg.KeyLifetime > 0 {
		return s.cfg.KeyLifetime
	}
	return DefaultKeyLifetime
}

// keyExpired is whether a key's expiry has passed. None is not expired: a key paired
// before #997 gets one when it is next used, or from the sweep.
func keyExpired(expires *records.Stamp, now time.Time) bool {
	return expires != nil && !now.Before(expires.Time)
}

// renewing is the new expiry for a key, or nil when it has long enough to live. A key
// with none, paired before #997, counts from when it was last used.
func renewing(expires *records.Stamp, lastUsed time.Time, now time.Time, life time.Duration) *records.Stamp {
	if expires == nil {
		at := records.At(lastUsed.Add(life))
		if !at.After(now) {
			at = records.At(now.Add(life))
		}
		return &at
	}
	if expires.Sub(now) > renewWithin(life) {
		return nil
	}
	at := records.At(now.Add(life))
	return &at
}

// newExpiry is the expiry a key paired now gets.
func (s *Service) newExpiry() *records.Stamp {
	at := records.At(time.Now().Add(s.keyLifetime()))
	return &at
}

// renewClient renews a client's key when it is due. A conflict is let go: the next
// connection, or the next hour, tries again.
func (s *Service) renewClient(ctx context.Context, id string) {
	life, now := s.keyLifetime(), time.Now()
	person := s.PersonOf(id)
	if c := s.records.Client(id); c != nil && c.Expires != nil && c.Expires.Sub(now) > renewWithin(life) {
		return
	}
	// A built-in sign-in at a domain that requires its org provider renews nothing (#1002,
	// D9); nor does a suspended person, or one whose org provider refused their refresh, or
	// has not answered for 7 days (D13, Q1 A).
	refused := s.signIns.refusesRenewal(ctx, person) || s.suspended(person) || !s.signIns.refreshAllows(ctx, person)
	err := s.records.ChangeClient(ctx, id, func(c *records.ClientRecord) bool {
		used := c.Paired.Time
		if c.LastSeen != nil {
			used = c.LastSeen.Time
		}
		next := renewing(c.Expires, used, now, life)
		if next == nil || refused && c.Expires != nil {
			return false
		}
		c.Expires = next
		return true
	})
	if err != nil {
		s.log("could not renew a client's key: " + err.Error())
	}
}

// renewHost renews a machine's key when it is due. A host record says no time it was
// paired or seen, so one with no expiry counts from now.
func (s *Service) renewHost(ctx context.Context, id string) {
	h := s.records.Host(id)
	if h == nil {
		return
	}
	now := time.Now()
	next := renewing(h.Expires, now, now, s.keyLifetime())
	// A suspended person's machine renews nothing (D13).
	if next == nil || h.Expires != nil && s.suspended(s.ownerOf(id)) {
		return
	}
	h.Expires = next
	if err := s.records.SaveHost(ctx, *h); err != nil {
		s.log("could not renew " + id + "'s key: " + err.Error())
	}
}

// renewConnected renews the keys of every client and machine connected to this copy,
// and gives the others paired before #997 an expiry, once an hour.
func (s *Service) renewConnected(ctx context.Context) {
	connected := map[string]bool{}
	for _, id := range s.router.ConnectedMembers() {
		connected[id] = true
	}
	life, now := s.keyLifetime(), time.Now()
	for _, c := range s.records.Clients() {
		if connected[c.ID] || c.Expires == nil {
			s.renewClient(ctx, c.ID)
		}
	}
	for _, h := range s.records.Hosts() {
		if connected[h.ID] {
			s.renewHost(ctx, h.ID)
		} else if h.Expires == nil {
			// Not seen since #997: its life starts now, as if it had just connected.
			at := records.At(now.Add(life))
			h.Expires = &at
			if err := s.records.SaveHost(ctx, h); err != nil {
				s.log("could not give " + h.ID + "'s key an expiry: " + err.Error())
			}
		}
	}
}
