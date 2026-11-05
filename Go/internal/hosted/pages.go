package hosted

import (
	"context"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/signin"
)

// The pages at the service's own domain (#1807):
//
//	/                  Sign up (or Sign in) with Apple, Google or GitHub (#3386); an account
//	                   signed in goes to /account; ?invite=<code> carries an invite link to
//	                   the sign-in (#2152)
//	/signin?with=<provider>  to Apple, Google or GitHub (none is GitHub, as links before)
//	/signin/callback   back from the provider: a new account gets its control plane, whose
//	                   first person signs in with the same provider, and this browser is
//	                   sent to it to pair, with nothing to type
//	/account           the control plane's address, Open in This Browser, Sign Out, Delete
//	/account/open      a new code for this browser, then to the control plane
//	/account/delete    the account and its store, once its name is typed
//	/signout           the session ends
//	/account/upgrade, /account/billing, /billing/webhook   with billing on (billing.go)

func (s *Service) pages(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	// A form's redirect counts for form-action: Upgrade and Manage Billing go on to Stripe.
	formAction := "'self'"
	if s.billingOn() {
		formAction += " https://checkout.stripe.com https://billing.stripe.com"
	}
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action "+formAction+"; frame-ancestors 'none'; base-uri 'none'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cache-Control", "no-store")
	account := s.sessions.account(r)
	switch {
	case r.URL.Path == "/" && r.Method == http.MethodGet:
		if account != "" {
			http.Redirect(w, r, "/account", http.StatusSeeOther)
			return
		}
		invite := r.URL.Query().Get("invite")
		if !validInvite(invite) {
			invite = ""
		}
		s.page(w, http.StatusOK, page{Title: "Agents", Welcome: true, Invite: invite, Providers: s.offered()})
	case r.URL.Path == "/signin" && r.Method == http.MethodGet:
		provider := r.URL.Query().Get("with")
		if provider == "" {
			provider = signin.GitHub
		}
		if !s.offers(provider) {
			s.page(w, http.StatusServiceUnavailable, page{Title: "Agents", Problem: "Sign-up is not open yet."})
			return
		}
		if invite := r.URL.Query().Get("invite"); validInvite(invite) {
			setCookie(w, inviteCookie, s.sessions.sign(invite), stateLife)
		}
		state := s.sessions.newState(w, provider)
		to := s.github.authorize(state)
		if o := s.oidc[provider]; o != nil {
			to = o.authorize(state, s.sessions.derived("nonce", state), s.sessions.derived("pkce", state))
		}
		http.Redirect(w, r, to, http.StatusSeeOther)
	case r.URL.Path == "/signin/callback" && r.Method == http.MethodGet:
		s.callback(w, r)
	case r.URL.Path == "/account" && r.Method == http.MethodGet:
		s.accountPage(w, r, account, "")
	case r.URL.Path == "/account/open" && r.Method == http.MethodPost:
		if account == "" || !s.sessions.formOK(r, account) {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		s.openIn(w, r, account)
	case r.URL.Path == "/account/delete" && r.Method == http.MethodPost:
		s.deleteAccount(w, r, account)
	case r.URL.Path == "/account/upgrade" && r.Method == http.MethodPost && s.billingOn(),
		r.URL.Path == "/account/billing" && r.Method == http.MethodPost && s.billingOn():
		if account == "" || !s.sessions.formOK(r, account) {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		if r.URL.Path == "/account/upgrade" {
			s.upgrade(w, r, account)
		} else {
			s.manageBilling(w, r, account)
		}
	case r.URL.Path == "/billing/webhook" && r.Method == http.MethodPost && s.billingOn():
		s.webhook(w, r)
	case r.URL.Path == "/signout" && r.Method == http.MethodPost:
		endCookie(w, sessionCookie)
		http.Redirect(w, r, "/", http.StatusSeeOther)
	default:
		plain(w, http.StatusNotFound, "Not found.\n")
	}
}

// offers says a provider's web sign-in is set up.
func (s *Service) offers(provider string) bool {
	if provider == signin.GitHub {
		return s.github.clientID != "" && s.github.secret != ""
	}
	return s.oidc[provider] != nil
}

// offered is the sign-up page's buttons: each provider set up, in the order the control
// plane lists them (Apple, Google, GitHub).
func (s *Service) offered() []offer {
	var out []offer
	for _, p := range signin.Providers {
		if s.offers(p) {
			out = append(out, offer{With: p, Title: signin.Title(p)})
		}
	}
	return out
}

// callback is the provider's answer: the account the person has, or a new one.
func (s *Service) callback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	state := q.Get("state")
	if !s.sessions.stateOK(r, state) || !s.offers(providerOf(state)) {
		s.page(w, http.StatusBadRequest, page{Title: "Agents", Welcome: true, Providers: s.offered(),
			Problem: "That sign-in was not started here, or took too long. Sign in again."})
		return
	}
	endCookie(w, stateCookie)
	provider := providerOf(state)
	title := signin.Title(provider)
	if q.Get("error") != "" || q.Get("code") == "" {
		s.page(w, http.StatusOK, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: title + " did not sign you in. Try again."})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	var user SignIn
	var err error
	if o := s.oidc[provider]; o != nil {
		user, err = o.user(ctx, q.Get("code"), s.sessions.derived("nonce", state), s.sessions.derived("pkce", state))
	} else {
		user, err = s.github.user(ctx, q.Get("code"))
	}
	if err != nil {
		s.log("sign-in with " + title + ": " + err.Error())
		s.page(w, http.StatusBadGateway, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: title + " could not be asked who you are. Try again."})
		return
	}
	acc, err := s.accounts.bySignIn(ctx, user)
	if err != nil {
		s.log("accounts: " + errText(err))
		s.page(w, http.StatusServiceUnavailable, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: "Your account could not be read or made. Try again in a moment."})
		return
	}
	made := false
	if acc == nil {
		// A new person: who may sign up (#2152).
		invite := ""
		if c, err := r.Cookie(inviteCookie); err == nil {
			invite, _ = s.sessions.open(c.Value)
		}
		endCookie(w, inviteCookie)
		got := s.gate(ctx, s.clientOf(r), user, invite)
		switch {
		case got.refused != "":
			s.metrics.refused(got.kind)
			s.log(fmt.Sprintf("sign-up refused: %s: %s", user, got.refused))
			s.page(w, got.status, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: got.refused})
			return
		case got.account == nil:
			s.page(w, http.StatusOK, page{Title: "The waitlist", Place: got.place, Why: whyText(got.why, s.cfg.MinGitHubAge)})
			return
		}
		acc, made = got.account, got.made
	}
	s.sessions.start(w, acc.ID)
	if !made {
		http.Redirect(w, r, "/account", http.StatusSeeOther)
		return
	}
	s.metrics.signedUp("account")
	s.log("signed up: " + acc.ID + " with " + title)
	// Its first person signs in with the same provider, from any client (#3386). A
	// failure here leaves the code below, which pairs this browser all the same.
	if err := s.ownerSignsIn(ctx, acc); err != nil {
		s.log(acc.ID + ": the first person's sign-in: " + err.Error())
	}
	// The browser that signed up is the first client: to its control plane, to pair.
	s.openIn(w, r, acc.ID)
}

// ownerSignsIn gives an account's control plane's first person the sign-in it was made
// with, and turns that provider on there.
func (s *Service) ownerSignsIn(ctx context.Context, acc *Account) error {
	c, err := s.copyFor(ctx, acc.ID)
	if err != nil {
		return err
	}
	defer s.done(c)
	return c.service.AddOwnerSignIn(ctx, acc.SignIn.Provider, acc.SignIn.Subject, acc.SignIn.Login)
}

// openIn sends this browser to its control plane with a code it pairs itself with.
func (s *Service) openIn(w http.ResponseWriter, r *http.Request, account string) {
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	if acc, err := s.accounts.get(ctx, account); err == nil && acc != nil && acc.Suspended != nil {
		s.accountPage(w, r, account, "")
		return
	}
	link, err := s.firstCode(ctx, account)
	if errors.Is(err, errFull) {
		s.metrics.refused("full")
		s.accountPage(w, r, account, "The service is full just now. Try Open in This Browser again in a few minutes.")
		return
	}
	if err != nil {
		s.log(account + ": no code: " + err.Error())
		s.accountPage(w, r, account, "Your control plane could not start just now. Try Open in This Browser again in a moment.")
		return
	}
	http.Redirect(w, r, link, http.StatusSeeOther)
}

func (s *Service) accountPage(w http.ResponseWriter, r *http.Request, account, problem string) {
	if account == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	acc, err := s.accounts.get(r.Context(), account)
	if err != nil || acc == nil {
		endCookie(w, sessionCookie)
		s.page(w, http.StatusOK, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: "That account is gone. Sign up again."})
		return
	}
	if problem == "" && acc.Certificate == nil && !s.certificateRoom() {
		problem = "Your control plane’s address is not ready yet. Try again in an hour."
	}
	use, err := s.useOf(r.Context(), acc)
	if err != nil {
		s.log(acc.ID + ": use: " + err.Error())
	}
	billingOn := s.billingOn()
	s.page(w, http.StatusOK, page{Title: "Your account", Account: acc, Address: s.accountURL(acc.ID),
		Token: s.sessions.form(acc.ID), Problem: problem, Use: &use, StorageUsed: bytesText(use.Storage),
		StorageAllowed: bytesText(use.Plan.Storage), EventsDays: int(use.Plan.EventsKept / day),
		Upgrade: billingOn && use.Plan.ID == PlanFree, ManageBilling: billingOn && acc.StripeCustomer != "",
		Confirming: billingOn && use.Plan.ID == PlanFree && r.URL.Query().Get("upgraded") == "1"})
}

func (s *Service) deleteAccount(w http.ResponseWriter, r *http.Request, account string) {
	if account == "" || !s.sessions.formOK(r, account) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if r.PostFormValue("confirm") != account {
		s.accountPage(w, r, account, "Type the account’s name, "+account+", to delete it.")
		return
	}
	acc, err := s.accounts.get(r.Context(), account)
	if err != nil || acc == nil {
		s.accountPage(w, r, account, "The account could not be read. Try again in a moment.")
		return
	}
	s.stopCopy(account)
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	if err := s.accounts.remove(ctx, acc); err != nil {
		s.log(account + ": delete: " + err.Error())
		s.accountPage(w, r, account, "Not everything could be deleted. Delete the account again.")
		return
	}
	s.log("deleted: " + account)
	endCookie(w, sessionCookie)
	s.page(w, http.StatusOK, page{Title: "Agents", Welcome: true, Providers: s.offered(), Problem: "Your account and its control plane are deleted."})
}

func errText(err error) string {
	if err == nil {
		return "none made"
	}
	return err.Error()
}

type page struct {
	Title   string
	Welcome bool
	Problem string
	Account *Account
	Address string
	Token   string
	// An invite link's code, carried to the sign-in.
	Invite string
	// The providers to sign up with, one button each.
	Providers []offer
	// A place on the waitlist, and why, when not 0.
	Place int
	Why   string
	// The account's plan and use (#2224).
	Use                         *Use
	StorageUsed, StorageAllowed string
	EventsDays                  int
	// Billing (#2225): Upgrade and Manage Billing, each only with billing on; Confirming
	// is back from Checkout before Stripe's event came.
	Upgrade, ManageBilling, Confirming bool
}

// offer is a provider on the sign-up page: its name in /signin?with=, and as people read it.
type offer struct{ With, Title string }

func (s *Service) page(w http.ResponseWriter, status int, p page) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := pageTemplate.Execute(w, p); err != nil {
		s.log("page: " + err.Error())
	}
}

var pageTemplate = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Title}}</title>
<style>
  body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1.25rem; color: #1d1d1f; background: #fbfbf8; }
  h1 { font-size: 1.6rem; margin-bottom: .25rem; }
  .quiet { color: #6e6e73; }
  .problem { color: #b3261e; }
  a.signup { min-width: 14rem; text-align: center; }
  a.button, button { display: inline-block; font: inherit; padding: .5rem 1rem; border-radius: .5rem; border: 1px solid #c7c7cc; background: #fff; color: inherit; text-decoration: none; cursor: pointer; }
  a.prominent, button.prominent { background: #2c5fd6; border-color: #2c5fd6; color: #fff; }
  button.destructive { color: #b3261e; }
  code { font-size: .95rem; background: #f0f0ec; padding: .1rem .3rem; border-radius: .25rem; }
  section { margin-top: 2rem; }
  form { display: inline; }
  td { padding: .15rem 1.5rem .15rem 0; }
  input { font: inherit; padding: .4rem .5rem; border: 1px solid #c7c7cc; border-radius: .4rem; }
  @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #f2f2f7; } a.button, button, input { background: #2c2c2e; color: #f2f2f7; border-color: #48484a; } a.prominent, button.prominent { background: #2c5fd6; border-color: #2c5fd6; color: #fff; } code { background: #2c2c2e; } }
</style>
</head>
<body>
{{if .Place}}
<h1>You are on the waitlist</h1>
<p>You are number {{.Place}} on the waitlist. {{.Why}}</p>
<p class="quiet">Agents keeps no email address and sends you nothing. Sign in again later to see if your account is ready.</p>
<p><a class="button" href="/">Back</a></p>
{{else if .Welcome}}
<h1>Agents</h1>
<p>Run many coding agents at once, and watch and answer them from a browser, a Mac or a phone.</p>
<p>Sign up and you get a control plane of your own. You type no command and hold no key.</p>
{{if .Problem}}<p class="problem" role="alert">{{.Problem}}</p>{{end}}
{{if .Invite}}<p>You have an invite.</p>{{end}}
{{range .Providers}}<p><a class="button prominent signup" href="/signin?with={{.With}}{{if $.Invite}}&amp;invite={{$.Invite}}{{end}}">Sign Up with {{.Title}}</a></p>
{{else}}<p>Sign-up is not open yet.</p>
{{end}}
{{if not .Invite}}<p class="quiet">Sign-up is by invitation while Agents is in beta. Without an invite, you join the waitlist.</p>{{end}}
<p class="quiet">Signed up before? The same button signs you in.</p>
{{else if .Account.Suspended}}
<h1>Your account</h1>
<p class="quiet">Signed in with {{.Account.SignIn.Shown}}.</p>
<p class="problem" role="alert">This account is suspended: {{.Account.Suspended.Reason}}</p>
<p>Your control plane is stopped, and its records are kept.</p>
<form method="post" action="/signout"><button>Sign Out</button></form>
<section>
<h2>Delete Account</h2>
<p>This deletes your control plane and everything it keeps. Type <code>{{.Account.ID}}</code> to delete it.</p>
<form method="post" action="/account/delete"><input type="hidden" name="token" value="{{.Token}}"><input name="confirm" aria-label="Account name" autocomplete="off"> <button class="destructive">Delete Account</button></form>
</section>
{{else}}
<h1>Your account</h1>
<p class="quiet">Signed in with {{.Account.SignIn.Shown}}.</p>
{{if .Problem}}<p class="problem" role="alert">{{.Problem}}</p>{{end}}
<section>
<p>Your control plane is at <a href="{{.Address}}">{{.Address}}</a>. Each browser, Mac and phone you use pairs with it once.</p>
<form method="post" action="/account/open"><input type="hidden" name="token" value="{{.Token}}"><button class="prominent">Open in This Browser</button></form>
<form method="post" action="/signout"><button>Sign Out</button></form>
</section>
{{with .Use}}<section>
<h2>{{.Plan.Name}} Plan</h2>
<table>
<tr><td>Machines</td><td>{{.Machines}} of {{.Plan.Machines}}</td></tr>
<tr><td>Clients</td><td>{{.Clients}} of {{.Plan.Clients}}</td></tr>
<tr><td>Storage</td><td>{{$.StorageUsed}} of {{$.StorageAllowed}}</td></tr>
<tr><td>Connections at once</td><td>up to {{.Plan.Connections}}</td></tr>
<tr><td>Events kept</td><td>{{$.EventsDays}} days</td></tr>
<tr><td>Agents running at once</td><td>up to {{.Plan.AgentsRunning}}</td></tr>
</table>
<p class="quiet">At a limit, nothing is deleted: the next machine, client or write is refused, with words that say which limit.</p>
{{if $.Confirming}}<p role="status">Stripe is confirming your payment. Your account is on Pro in a minute; reload this page.</p>{{end}}
{{if $.Upgrade}}<form method="post" action="/account/upgrade"><input type="hidden" name="token" value="{{$.Token}}"><button class="prominent">Upgrade</button></form>{{end}}
{{if $.ManageBilling}}<form method="post" action="/account/billing"><input type="hidden" name="token" value="{{$.Token}}"><button>Manage Billing</button></form>{{end}}
</section>{{end}}
<section>
<h2>Delete Account</h2>
<p>This deletes your control plane and everything it keeps: your people, clients, machines and settings. Your machines and their agents are not deleted. Type <code>{{.Account.ID}}</code> to delete it.</p>
<form method="post" action="/account/delete"><input type="hidden" name="token" value="{{.Token}}"><input name="confirm" aria-label="Account name" autocomplete="off"> <button class="destructive">Delete Account</button></form>
</section>
{{end}}
</body>
</html>
`))
