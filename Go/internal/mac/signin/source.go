package signin

import (
	"context"
	"errors"
	"fmt"
)

// Token is what the relay puts on a request: the access token as `Authorization: Bearer`,
// and any other headers the service wants from the sign-in (Codex's account id).
type Token struct {
	Access  string
	Headers map[string]string
}

// String is never the token itself, so a log line or an error cannot carry it.
func (t Token) String() string { return fmt.Sprintf("Token(%d headers)", len(t.Headers)) }

// Source is MacSignInSource: where a relay gets this Mac's own sign-in for a runtime.
type Source interface {
	Current() (Token, error)
	// Renew answers a token other than stale, which was refused, or ErrRenewalRefused.
	Renew(ctx context.Context, stale Token) (Token, error)
	// StandIn is what the server's runtime starts with: no secret of this Mac's.
	StandIn() (string, error)
}

// MacSignInFailure's cases.
var (
	ErrNotSignedIn    = errors.New("this Mac is not signed in the way a server can use")
	ErrUnreadable     = errors.New("this Mac's sign-in could not be read")
	ErrRenewalRefused = errors.New("this Mac's sign-in was not renewed")
)
