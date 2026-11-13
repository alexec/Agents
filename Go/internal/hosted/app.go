package hosted

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
)

// The Mac app's way in (#4228): Settings ▸ Control plane ▸ Connect to Another… opens
// /app/connect in an authentication session. A person signed in here already goes straight
// back to the app; anyone else signs in first, as on the welcome page, and comes back here.
// The app gets a client code for the account's control plane on agents://hosted, in the
// fragment, as the control plane's own sign-in answers on agents://oidc. The code is for an
// app, not a browser, so the app pairs the window with it and then makes this Mac's machine
// code with that pairing.

const (
	// appCookie says the sign-in under way was started by the app, so its callback goes
	// back to the app and not to the control plane's page.
	appCookie = "agents_app"
	// appReturn is where the app's authentication session waits.
	appReturn = "agents://hosted"
)

// appConnect is /app/connect.
func (s *Service) appConnect(w http.ResponseWriter, r *http.Request, account string) {
	if account == "" {
		// Signed in by the welcome page's buttons; the callback comes back here.
		setFlowCookie(w, appCookie, s.sessions.sign("mac"))
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	s.toApp(w, r, account)
}

// fromApp says the sign-in under way was started by /app/connect, and ends that cookie.
func (s *Service) fromApp(w http.ResponseWriter, r *http.Request) bool {
	c, err := r.Cookie(appCookie)
	if err != nil {
		return false
	}
	endCookie(w, appCookie)
	_, ok := s.sessions.open(c.Value)
	return ok
}

// toApp sends the app a new client code for the account's control plane, or why not.
func (s *Service) toApp(w http.ResponseWriter, r *http.Request, account string) {
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	if acc, err := s.accounts.get(ctx, account); err == nil && acc != nil && acc.Suspended != nil {
		appAnswer(w, r, "message", "This hosted account is suspended. See https://"+s.cfg.Domain+"/account.")
		return
	}
	text, err := s.appCode(ctx, account)
	switch {
	case errors.Is(err, errFull):
		s.metrics.refused("full")
		appAnswer(w, r, "message", "The service is full just now. Try again in a few minutes.")
	case err != nil:
		s.log(account + ": no code for the app: " + err.Error())
		appAnswer(w, r, "message", "Your control plane could not start just now. Try again in a moment.")
	default:
		appAnswer(w, r, "code", text)
	}
}

// appCode is a client code for an app (not only a browser) on the account's control plane.
func (s *Service) appCode(ctx context.Context, id string) (string, error) {
	c, err := s.copyFor(ctx, id)
	if err != nil {
		return "", err
	}
	defer s.done(c)
	shown, err := c.service.Codes().Issue(ctx, false, false, controllink.CodeLifetime)
	if err != nil {
		return "", err
	}
	return shown.Text, nil
}

// appAnswer is the redirect the app's authentication session ends on.
func appAnswer(w http.ResponseWriter, r *http.Request, key, value string) {
	// Every byte but the unreserved ones escaped, so a space is not a "+" to the app.
	http.Redirect(w, r, appReturn+"#"+key+"="+escapeCode(value), http.StatusSeeOther)
}
