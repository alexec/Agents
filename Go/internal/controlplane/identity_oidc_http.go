package controlplane

import (
	"context"
	"encoding/json"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// /v1/oidc/start and /v1/oidc/callback (#1002, FR-005, contracts/identity-api.md): the
// browser's half of an org provider's sign-in. Start sends it to the provider with the
// state, the nonce and a PKCE challenge; the callback exchanges the code with the client
// secret, checks the ID token, and sends the browser back to the client with a ticket for
// one use. The state and the ticket are records in the store, so the callback may come to
// another copy than the one that started it.

// providerErrorCode is what a provider's error may say when it is passed on.
var providerErrorCode = regexp.MustCompile(`^[a-z_]{1,40}$`)

// serveOIDC answers /v1/oidc/*. A control plane with no org provider has neither route
// (US1 AS2).
func (si *signIns) serveOIDC(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if r.Method != http.MethodGet {
		plain(w, http.StatusMethodNotAllowed, "only GET\n")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if keys, err := si.s.cfg.Store.List(ctx, orgProvidersPrefix); err != nil || len(keys) == 0 {
		plain(w, http.StatusNotFound, "not here\n")
		return
	}
	switch r.URL.Path {
	case "/v1/oidc/start":
		si.serveStart(ctx, w, r)
	case "/v1/oidc/callback":
		si.serveCallback(ctx, w, r)
	default:
		plain(w, http.StatusNotFound, "not here\n")
	}
}

// page is the little page a browser shows when it cannot be sent back to the client.
func page(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'")
	w.WriteHeader(status)
	w.Write([]byte("<!doctype html><meta charset=utf-8><title>Agents</title><p>" + html.EscapeString(text) + "</p>\n"))
}

// readState is a started flow by its id, and where it is kept.
func (si *signIns) readState(ctx context.Context, id string) (*orgState, string) {
	if len(id) < 16 || len(id) > 64 {
		return nil, ""
	}
	key := storeKeyHash(oidcStatePrefix, id)
	object, err := si.s.cfg.Store.Get(ctx, key+".json")
	if err != nil || object == nil {
		return nil, ""
	}
	var s orgState
	if json.Unmarshal(object.Data, &s) != nil || s.Sealed == nil {
		return nil, ""
	}
	return &s, key
}

func (si *signIns) openState(ctx context.Context, s *orgState, key string) (*stateSecrets, error) {
	plain, err := si.s.users.OpenFor(ctx, s.Sealed, []byte(key))
	if err != nil {
		return nil, err
	}
	var out stateSecrets
	if err := json.Unmarshal(plain, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (si *signIns) serveStart(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	s, key := si.readState(ctx, r.URL.Query().Get("s"))
	if s == nil || !si.clock().Before(s.Ends.Time) {
		page(w, http.StatusBadRequest, "This sign-in has ended. Start it again from Agents.")
		return
	}
	p, err := si.orgProviderOn(ctx, s.Provider)
	if err != nil {
		page(w, http.StatusBadRequest, asRPC(err).Message)
		return
	}
	d, err := si.discovery(ctx, *p, false)
	if err != nil {
		page(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	secrets, err := si.openState(ctx, s, key)
	if err != nil {
		page(w, http.StatusServiceUnavailable, "This control plane cannot open its secrets.")
		return
	}
	q := url.Values{"response_type": {"code"}, "client_id": {p.ClientID}, "redirect_uri": {si.redirectURI()},
		"scope": {strings.Join(p.Scopes, " ")}, "state": {r.URL.Query().Get("s")}, "nonce": {secrets.Nonce},
		"code_challenge": {pkceChallenge(secrets.Verifier)}, "code_challenge_method": {"S256"}}
	if s.LoginHint != "" {
		q.Set("login_hint", s.LoginHint)
	}
	// A refresh token, to find a leaver without SCIM (Q1 A, FR-024): offline_access where
	// the issuer offers it; Google's own way for Google Workspace.
	if slices.Contains(d.Scopes, "offline_access") && !slices.Contains(p.Scopes, "offline_access") {
		q.Set("scope", q.Get("scope")+" offline_access")
	}
	if p.Preset == wire.OrgProviderPresetGoogleWorkspace {
		q.Set("access_type", "offline")
	}
	if p.Preset == wire.OrgProviderPresetGoogleWorkspace {
		// Google sends people of other domains back with an error at once with hd set.
		if domains := si.provedDomains(ctx, p.ID); len(domains) == 1 {
			q.Set("hd", domains[0])
		}
	}
	target, err := url.Parse(d.AuthorizationEndpoint)
	if err != nil {
		page(w, http.StatusServiceUnavailable, p.Name+"'s sign-in page is not a web address.")
		return
	}
	for k, v := range target.Query() {
		if !q.Has(k) {
			q[k] = v
		}
	}
	target.RawQuery = q.Encode()
	http.Redirect(w, r, target.String(), http.StatusFound)
}

// back sends the browser to the client: agents://oidc for the Mac and the Remote, or the
// page's own address, with the ticket or the error in the fragment, which no server sees.
func (si *signIns) back(w http.ResponseWriter, r *http.Request, returnTo string, values url.Values) {
	fragment := values.Encode()
	if returnTo == string(wire.SignInOrgReturnWeb) {
		base, _ := si.httpsBase()
		// The page reads oidc-ticket or oidc-error and takes it out of the address bar.
		web := url.Values{}
		for k, v := range values {
			web["oidc-"+k] = v
		}
		http.Redirect(w, r, base+"/#"+web.Encode(), http.StatusFound)
		return
	}
	http.Redirect(w, r, "agents://oidc#"+fragment, http.StatusFound)
}

func (si *signIns) serveCallback(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	s, key := si.readState(ctx, q.Get("state"))
	if s == nil {
		page(w, http.StatusBadRequest, "This sign-in is not known here, or has ended. Start it again from Agents.")
		return
	}
	// One use (FR-005): of two callbacks for one state, at any copies, one goes on.
	if err := si.spend(ctx, key); err != nil {
		page(w, http.StatusBadRequest, "This sign-in was finished already. Start it again from Agents.")
		return
	}
	refuse := func(code, message string) {
		si.s.log("an org sign-in with " + s.Provider + " was refused: " + message)
		si.back(w, r, s.ReturnTo, url.Values{"error": {code}, "message": {message}})
	}
	if !si.clock().Before(s.Ends.Time) {
		refuse("expired", "The sign-in took more than 10 minutes. Start it again.")
		return
	}
	if e := q.Get("error"); e != "" {
		if !providerErrorCode.MatchString(e) {
			e = "provider_error"
		}
		refuse(e, "The provider did not sign you in ("+e+").")
		return
	}
	p, err := si.orgProviderOn(ctx, s.Provider)
	if err != nil {
		refuse("refused", asRPC(err).Message)
		return
	}
	c, err := si.finishCallback(ctx, s, key, p, q.Get("code"))
	if err != nil {
		code := "refused"
		if signin.IsUnavailable(err) {
			code = "unavailable"
		}
		refuse(code, err.Error())
		return
	}
	ticket := randomToken(16)
	now := si.clock()
	ticketKey := storeKeyHash(oidcTicketPrefix, ticket)
	t := orgTicket{Provider: p.ID, Account: c.account, Email: c.email, Name: c.name, Purpose: s.Purpose, ReturnTo: s.ReturnTo,
		Bind: s.Bind, Person: s.Person, Made: records.At(now), Ends: records.At(now.Add(ticketLife)),
		Refresh: si.sealTicketRefresh(ctx, ticketKey, c.refresh)}
	data, err := records.Encode(t)
	if err == nil {
		_, err = si.s.cfg.Store.Put(ctx, ticketKey+".json", data, store.Absent)
	}
	if err != nil {
		refuse("unavailable", "The sign-in could not be kept. Try again.")
		return
	}
	si.back(w, r, s.ReturnTo, url.Values{"ticket": {ticket}})
}

// orgChecked is who an org provider's callback names.
type orgChecked struct{ account, email, name, refresh string }

// finishCallback exchanges the code and checks the ID token (FR-005): its signature by the
// JWKS, iss, aud, exp and the nonce, then the account claim, Entra's tid, and Google
// Workspace's hd. The tokens are forgotten here.
func (si *signIns) finishCallback(ctx context.Context, s *orgState, key string, p *wire.OrgProvider, code string) (*orgChecked, error) {
	if code == "" || len(code) > 4096 {
		return nil, &signin.Refused{Reason: "The provider sent no code. Sign in again."}
	}
	secrets, err := si.openState(ctx, s, key)
	if err != nil {
		return nil, &signin.Unavailable{Reason: "This control plane cannot open its secrets."}
	}
	secret, err := si.openSecret(ctx, p.ID)
	if err != nil {
		return nil, &signin.Unavailable{Reason: "This control plane cannot open its secrets."}
	}
	d, err := si.discovery(ctx, *p, false)
	if err != nil {
		return nil, err
	}
	client := si.cfg.HTTP
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	tokens, err := signin.Exchange(ctx, client, d, p.ClientID, secret, code, si.redirectURI(), secrets.Verifier, p.Name)
	if err != nil {
		return nil, err
	}
	claims, err := si.checker(*p, d).Check(ctx, tokens.IDToken, secrets.Nonce)
	if err != nil {
		return nil, err
	}
	account := claims.Claim(deref(p.AccountClaim))
	if account == "" {
		return nil, &signin.Refused{Reason: "The ID token has no " + deref(p.AccountClaim) + " claim, which names the person."}
	}
	if tenant := deref(p.Tenant); tenant != "" && claims.Tenant != tenant {
		return nil, &signin.Refused{Reason: "That account is in another Entra tenant."}
	}
	if p.Preset == wire.OrgProviderPresetGoogleWorkspace {
		if hd := strings.ToLower(claims.Domain); hd == "" || !slices.Contains(si.provedDomains(ctx, p.ID), hd) {
			return nil, &signin.Refused{Reason: "That Google account is not in one of this provider's domains."}
		}
	}
	name := claims.Name
	if len([]rune(name)) > 80 {
		name = string([]rune(name)[:80])
	}
	email := claims.Email
	if len(email) > 254 {
		email = ""
	}
	return &orgChecked{account: account, email: email, name: name, refresh: tokens.RefreshToken}, nil
}
