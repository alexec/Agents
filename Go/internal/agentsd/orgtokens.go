package agentsd

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"log"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/orgtoken"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Tokens and checks on the machine (#3397). An admin's client seals a route's cloud
// credential (an AWS access key, a Google service account, an Entra app's secret) to this
// machine as it seals a key; the control plane cannot open it, so this machine makes its
// own token from it, at most an hour long, and a new one when the last has less than 10
// minutes to go. The token is kept in memory only. orgRoutes/check comes here too
// (machine/orgRouteCheck): this machine has the key, the control plane does not.

// orgCheckTimeout bounds machine/orgRouteCheck.
const orgCheckTimeout = 25 * time.Second

// orgToken is a token made for a route's seal, and after a renewal that failed, how many
// failed and when the next is tried.
type orgToken struct {
	sealVersion int64
	field       string
	value       string
	expires     time.Time
	failures    int
	retryAt     time.Time
	err         error
}

func (d *Daemon) tokenEndpoints() *orgtoken.Endpoints {
	if d.orgEndpoints != nil {
		return d.orgEndpoints
	}
	return &orgtoken.Default
}

// routeValues opens every one of a route's secrets, in memory, for one request.
func (d *Daemon) routeValues(r wire.DeliveredRoute) map[string]string {
	values := map[string]string{}
	for field := range r.Sealed {
		if v, ok := d.orgSecret(r, field); ok {
			values[field] = string(v)
			clear(v)
		}
	}
	return values
}

func tokenRoute(r wire.DeliveredRoute) orgtoken.Route {
	return orgtoken.Route{ID: r.ID, Kind: r.Kind, Vendor: r.Vendor, Settings: r.Settings}
}

// routeToken is a route's token for its cloud credential, made here when there is none
// that lasts more than orgtoken.RenewBefore; "" and the error when none could be made.
// field is awsSession, googleToken or entraToken.
func (d *Daemon) routeToken(ctx context.Context, r wire.DeliveredRoute, values map[string]string) (string, error) {
	field := orgtoken.Field(r.Kind, values)
	if field == "" {
		return "", errors.New("this route needs no token")
	}
	e := d.tokenEndpoints()
	now := e.Now()
	d.orgTokenMu.Lock()
	defer d.orgTokenMu.Unlock()
	t := d.orgTokens[r.ID]
	if t.sealVersion != r.SealVersion || t.field != field {
		t = orgToken{sealVersion: r.SealVersion, field: field}
	}
	if t.expires.Sub(now) <= orgtoken.RenewBefore && !now.Before(t.retryAt) {
		value, expires, err := orgtoken.Make(ctx, e, tokenRoute(r), values)
		if err == nil {
			t = orgToken{sealVersion: r.SealVersion, field: field, value: value, expires: expires}
			log.Printf("org route %s: a token made here, until %s", r.ID, expires.UTC().Format(time.TimeOnly))
		} else {
			t.err = err
			t.failures++
			t.retryAt = now.Add(orgtoken.Retry(t.failures))
			log.Printf("org route %s: no token made (%v); tried again at %s", r.ID, err, t.retryAt.UTC().Format(time.TimeOnly))
		}
	}
	if d.orgTokens == nil {
		d.orgTokens = map[string]orgToken{}
	}
	d.orgTokens[r.ID] = t
	// The last token goes on until it ends, through a renewal that failed.
	if t.value == "" || !t.expires.After(now) {
		return "", cmp.Or(t.err, errors.New("no token was made"))
	}
	return t.value, nil
}

// checkOrgRoute is machine/orgRouteCheck: orgRoutes/check with this machine's copy.
func (d *Daemon) checkOrgRoute(params json.RawMessage) wire.OrgRouteCheck {
	var request wire.OrgRouteRequest
	if json.Unmarshal(params, &request) != nil {
		return wire.OrgRouteCheck{Words: "That is not a route."}
	}
	r, ok := d.heldOrgRoute(request.ID)
	if !ok {
		return wire.OrgRouteCheck{Words: "This machine does not hold the route."}
	}
	values := d.routeValues(r)
	if len(values) != len(r.SecretFields) {
		return wire.OrgRouteCheck{Words: "The route's key does not open on this machine."}
	}
	ctx, cancel := context.WithTimeout(context.Background(), orgCheckTimeout)
	defer cancel()
	return orgtoken.Check(ctx, d.tokenEndpoints(), tokenRoute(r), values)
}
