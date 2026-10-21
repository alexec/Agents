package connections

import (
	"context"
	"errors"
	"sync"
	"time"
)

// RefreshMargin is how long before its end an access token is renewed. The host looks once
// a minute, so a token of 8 hours is renewed with about 10 minutes left, and a server that
// reads it again each minute never holds an ended one.
const RefreshMargin = 10 * time.Minute

// RefreshResult is what one look at a connection did.
type RefreshResult int

const (
	// Unchanged: no connection, nothing to renew yet, or already "Sign in again".
	Unchanged RefreshResult = iota
	// Renewed: a new pair is kept.
	Renewed
	// Refused: the provider refused the refresh, so the connection says "Sign in again".
	Refused
)

// Refresher spends a refresh token for a new pair: GitHub's DeviceFlow and Linear's CodeFlow.
type Refresher interface {
	Refresh(ctx context.Context, refresh string) (Token, error)
}

// RefreshIfDue renews provider's connection in s when its access token ends within
// RefreshMargin of now. A refresh token is single use: only the host calls this, one call
// at a time per store. A network failure leaves the connection as it is, to try again.
func RefreshIfDue(ctx context.Context, s Store, f Refresher, provider string, now time.Time) (RefreshResult, error) {
	c, ok, err := s.Get(provider)
	if err != nil || !ok || c.SignInAgain || c.AccessExpiresAt.IsZero() || now.Add(RefreshMargin).Before(c.AccessExpiresAt) {
		return Unchanged, err
	}
	if c.Refresh == "" {
		// An access token with no renewal (a GitLab personal access token) has ended: its end
		// is kept, so the row says the token ended, not that a renewal was refused (#1865).
		again := signInAgain(c)
		again.AccessExpiresAt = c.AccessExpiresAt
		return Refused, s.Put(again)
	}
	if !c.RefreshExpiresAt.IsZero() && !now.Before(c.RefreshExpiresAt) {
		return Refused, s.Put(signInAgain(c))
	}
	t, err := f.Refresh(ctx, c.Refresh)
	if errors.Is(err, ErrRefused) {
		return Refused, s.Put(signInAgain(c))
	}
	if err != nil {
		return Unchanged, err
	}
	next := t.Connection(c.Provider, c.Login, c.ConnectedAt)
	next.Workspace, next.URL = c.Workspace, c.URL
	if next.Refresh == "" {
		next.Refresh, next.RefreshExpiresAt = c.Refresh, c.RefreshExpiresAt
	}
	return Renewed, s.Put(next)
}

// signInAgain is c with its tokens gone: the row stays and says "Sign in again".
func signInAgain(c Connection) Connection {
	return Connection{Provider: c.Provider, Login: c.Login, Workspace: c.Workspace, URL: c.URL, ConnectedAt: c.ConnectedAt, SignInAgain: true}
}

// TokenReader is a provider's access token as the host keeps it, read again after a
// minute, at once when the one held has ended, and after a failed read: a server sees a
// renewal or a new sign-in without a restart. It never refreshes (the host does).
func TokenReader(l Locator, provider string) func() string {
	read := Reader(l, provider)
	return func() string {
		c, ok := read()
		if !ok {
			return ""
		}
		return c.Access
	}
}

// Reader is TokenReader's whole connection, for a server that must also know where the token
// goes (a self-managed GitLab's URL). ok is false with no usable connection.
func Reader(l Locator, provider string) func() (Connection, bool) {
	var mu sync.Mutex
	var held Connection
	var at time.Time
	return func() (Connection, bool) {
		mu.Lock()
		defer mu.Unlock()
		now := time.Now()
		if held.Usable(now) && now.Sub(at) < time.Minute {
			return held, true
		}
		held = Connection{}
		s, err := Open(l)
		if err != nil {
			return Connection{}, false
		}
		c, ok, err := s.Get(provider)
		if err != nil || !ok || !c.Usable(now) {
			return Connection{}, false
		}
		held, at = c, now
		return c, true
	}
}
