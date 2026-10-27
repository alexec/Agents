package controlplane

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// A GitHub sign-in on a new client waits for Approve on another client of the person (R3,
// FR-010), and so does a browser that asks by an account (#2097), with the code it shows typed: a GitHub token carries no nonce, so a control plane that was given one could
// pass it on, and only the person's own client can say this new one is theirs. The new
// client and the card show the same short code. Requests are kept in the store
// (v1/signins/<request>.json), so the person may approve at any copy; the approving copy
// pairs the client, and the copy holding the waiting connection tells it.

const (
	signInRequestsPrefix = "v1/signins/"
	// At most this many requests wait for one person, and for everyone.
	signInRequestsPerPerson = 5
	signInRequestsOpen      = 50
	// browserProvider is a browser's request (#2097): approved only with the code it shows.
	browserProvider = "browser"
)

type signInRequest struct {
	ID        string        `json:"id"`
	Code      string        `json:"code"`
	Client    string        `json:"client"`
	PublicKey []byte        `json:"publicKey"`
	Name      string        `json:"name"`
	Kind      string        `json:"kind"`
	Person    string        `json:"person"`
	Provider  string        `json:"provider"`
	Login     string        `json:"login,omitempty"`
	Created   records.Stamp `json:"created"`
	Expires   records.Stamp `json:"expires"`
	Result    string        `json:"result,omitempty"`
	By        string        `json:"by,omitempty"`
}

func signInRequestKey(id string) string { return signInRequestsPrefix + id + ".json" }

// signInAsk is what a waiting sign-in asks for.
type signInAsk struct {
	client, name, kind, person, login, provider string
	public                                      []byte
}

type signInApprovals struct {
	s   *Service
	now func() time.Time
	mu  sync.Mutex
}

func newSignInApprovals(s *Service) *signInApprovals { return &signInApprovals{s: s, now: time.Now} }

func (a *signInApprovals) open(r signInRequest) bool {
	return r.Result == "" && a.now().Before(r.Expires.Time)
}

func (a *signInApprovals) read(ctx context.Context, id string) (*signInRequest, string, error) {
	if !isJoinID(id) {
		return nil, "", nil
	}
	object, err := a.s.cfg.Store.Get(ctx, signInRequestKey(id))
	if err != nil || object == nil {
		return nil, "", err
	}
	var r signInRequest
	if json.Unmarshal(object.Data, &r) != nil || r.ID != id {
		return nil, "", nil
	}
	return &r, object.ETag, nil
}

// all is every request kept; ended ones older than joinKept are deleted on the way.
func (a *signInApprovals) all(ctx context.Context) ([]signInRequest, error) {
	listed, err := a.s.cfg.Store.List(ctx, signInRequestsPrefix)
	if err != nil {
		return nil, err
	}
	out := []signInRequest{}
	for _, entry := range listed {
		r, _, err := a.read(ctx, strings.TrimSuffix(strings.TrimPrefix(entry.Key, signInRequestsPrefix), ".json"))
		if err != nil || r == nil {
			continue
		}
		if a.now().Sub(r.Expires.Time) > joinKept {
			a.s.cfg.Store.Delete(ctx, entry.Key)
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created.Before(out[j].Created.Time) })
	return out, nil
}

func (a *signInApprovals) write(ctx context.Context, r signInRequest, condition store.Condition) error {
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	if _, err := a.s.cfg.Store.Put(ctx, signInRequestKey(r.ID), data, condition); err != nil {
		if store.IsConflict(err) {
			return fail(notPermitted, "That sign-in was decided already.")
		}
		return err
	}
	return nil
}

func (a *signInApprovals) row(r signInRequest) wire.SignInRequest {
	code := r.Code
	if r.Provider == browserProvider {
		// The person types the code the browser shows: the card never carries it (FR-014a).
		code = ""
	}
	return wire.SignInRequest{Request: r.ID, Name: r.Name, Kind: wire.ClientKind(r.Kind), Provider: r.Provider, Login: optional(r.Login),
		Code: code, Expires: dateOf(r.Expires.Time)}
}

// code is the code a sign-in shows (controllink.ApprovalCode): bound to the new client's key
// and this control plane's, so a control plane that passes a sign-in on cannot show the
// person the code their card shows.
func (a *signInApprovals) code(public []byte) string {
	return controllink.ApprovalCode(public, a.s.currentKeys().public)
}

// sameCode says a typed code is the request's: case, spaces and dashes aside.
func sameCode(typed, code string) bool {
	clean := strings.Map(func(r rune) rune {
		if r == ' ' || r == '-' {
			return -1
		}
		return r
	}, typed)
	return code != "" && strings.EqualFold(clean, code)
}

// unanswered is a browser's wait that no person can approve (FR-014b): an account nobody
// has, or one with every place taken. It looks the same as one that waits for a person.
func (a *signInApprovals) unanswered(conn *Conn, ask signInAsk) (*wire.Admitted, error) {
	expires := a.now().Add(joinLifetime)
	conn.SendNow(notification("control/signInWaiting", wire.SignInWaiting{Code: a.code(ask.public), Expires: dateOf(expires)}))
	timer := time.NewTimer(time.Until(expires))
	defer timer.Stop()
	select {
	case <-conn.Done():
		return nil, fail(notPermitted, "The sign-in connection closed.")
	case <-timer.C:
		return nil, fail(notPermitted, "Nobody approved the sign-in within 10 minutes. Sign in again.")
	}
}

// wait asks the person's clients, tells the new client the code, and waits until the
// request is decided, runs out, or the connection goes.
func (a *signInApprovals) wait(ctx context.Context, conn *Conn, ask signInAsk) (*wire.Admitted, error) {
	a.mu.Lock()
	all, err := a.all(ctx)
	if err != nil {
		a.mu.Unlock()
		return nil, fail(storeUnavailable, "The sign-ins waiting could not be read.")
	}
	waiting, forPerson := 0, 0
	for _, r := range all {
		if a.open(r) {
			waiting++
			if r.Person == ask.person {
				forPerson++
			}
		}
	}
	if ask.provider == browserProvider && waiting < signInRequestsOpen && (ask.person == "" || forPerson >= signInRequestsPerPerson) {
		a.mu.Unlock()
		return a.unanswered(conn, ask)
	}
	if waiting >= signInRequestsOpen || forPerson >= signInRequestsPerPerson {
		a.mu.Unlock()
		return nil, fail(notPermitted, "Too many sign-ins are waiting for approval. Try again in a few minutes.")
	}
	now := records.At(a.now())
	r := signInRequest{ID: newJoinID(), Code: a.code(ask.public), Client: ask.client, PublicKey: ask.public, Name: ask.name, Kind: ask.kind,
		Person: ask.person, Provider: ask.provider, Login: ask.login, Created: now, Expires: records.At(now.Add(joinLifetime))}
	err = a.write(ctx, r, store.Absent)
	a.mu.Unlock()
	if err != nil {
		return nil, err
	}
	conn.SendNow(notification("control/signInWaiting", wire.SignInWaiting{Code: r.Code, Expires: dateOf(r.Expires.Time)}))
	a.s.router.TellPerson(r.Person, "control/signInRequested", a.row(r))
	if ask.provider == browserProvider {
		a.s.log(ask.name + " asked to sign in as a person and waits for approval (request " + r.ID[:8] + ")")
	} else {
		a.s.log(ask.name + " signed in with " + signin.Title(ask.provider) + " and waits for approval (request " + r.ID[:8] + ")")
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-conn.Done():
			a.end(r.ID, "")
			return nil, fail(notPermitted, "The sign-in connection closed.")
		case <-tick.C:
		}
		got, _, err := a.read(ctx, r.ID)
		if err != nil || got == nil {
			continue
		}
		switch {
		case got.Result == "approved":
			return &wire.Admitted{Client: new(wire.UUID(got.Client))}, nil
		case got.Result == "denied":
			return nil, fail(notPermitted, "The sign-in was denied on the person's other client.")
		case !a.open(*got):
			a.end(r.ID, "expired")
			return nil, fail(notPermitted, "Nobody approved the sign-in within 10 minutes. Sign in again.")
		}
	}
}

// end closes an open request that nobody decided: expired, or "" for a connection that went.
func (a *signInApprovals) end(id, result string) {
	ctx := context.Background()
	r, etag, err := a.read(ctx, id)
	if err != nil || r == nil || r.Result != "" {
		return
	}
	if result == "" {
		result = "expired"
	}
	r.Result = result
	if a.write(ctx, *r, store.Matching(etag)) == nil {
		a.s.router.TellPerson(r.Person, "control/signInDecided", wire.SignInDecided{Request: r.ID, Result: r.Result})
	}
}

// list is signIn/requests: the open requests for the caller.
func (a *signInApprovals) list(ctx context.Context, user string) ([]wire.SignInRequest, error) {
	all, err := a.all(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The sign-ins waiting could not be read: %v", err)
	}
	out := []wire.SignInRequest{}
	for _, r := range all {
		if a.open(r) && r.Person == user {
			out = append(out, a.row(r))
		}
	}
	return out, nil
}

// decide is signIn/approve and signIn/deny: only the person the sign-in names decides it,
// never an admin for them. Approved, the client pairs as that person.
func (a *signInApprovals) decide(ctx context.Context, id, user string, approve bool, code string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	r, etag, err := a.read(ctx, id)
	if err != nil {
		return fail(storeUnavailable, "The sign-in could not be read.")
	}
	if r == nil || r.Person != user {
		return fail(invalidParams, "There is no such sign-in waiting.")
	}
	if !a.open(*r) {
		return fail(notPermitted, "That sign-in has ended. The new client can sign in again.")
	}
	if p := a.s.records.Person(user); p != nil && p.IsRemoved() {
		return fail(notPermitted, "This person was removed.")
	}
	if approve && r.Provider == browserProvider && !sameCode(code, r.Code) {
		return fail(invalidParams, "That is not the code the browser shows.")
	}
	r.By = user
	if !approve {
		r.Result = "denied"
		if err := a.write(ctx, *r, store.Matching(etag)); err != nil {
			return err
		}
		a.s.router.TellPerson(r.Person, "control/signInDecided", wire.SignInDecided{Request: r.ID, Result: r.Result})
		a.s.log(r.Name + " was not let sign in")
		return nil
	}
	r.Result = "approved"
	// The request first: a second approval at another copy loses here, and pairs nothing.
	if err := a.write(ctx, *r, store.Matching(etag)); err != nil {
		return err
	}
	owner := r.Person
	record := records.ClientRecord{ID: r.Client, Name: r.Name, Kind: r.Kind, PublicKey: r.PublicKey, Paired: records.Now(),
		Owner: &owner, Expires: a.s.newExpiry()}
	if err := a.s.methods.Admit(ctx, record); err != nil {
		return err
	}
	a.s.announce("clientPaired", r.Client, "signin")
	a.s.router.TellPerson(r.Person, "control/signInDecided", wire.SignInDecided{Request: r.ID, Result: r.Result})
	a.s.log(r.Name + " paired (" + r.Kind + ") by signing in with " + signin.Title(r.Provider) + ", approved by person " + user)
	return nil
}
