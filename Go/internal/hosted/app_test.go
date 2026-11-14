package hosted

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
)

// appCodeIn is the client code in the app's answer, or fails.
func appCodeIn(t *testing.T, res *http.Response) *controllink.Code {
	t.Helper()
	to, err := url.Parse(res.Header.Get("Location"))
	if err != nil || res.StatusCode != http.StatusSeeOther || to.Scheme != "agents" || to.Host != "hosted" {
		t.Fatalf("%d %s", res.StatusCode, res.Header.Get("Location"))
	}
	text, ok := strings.CutPrefix(to.Fragment, "code=")
	if !ok {
		t.Fatal(to)
	}
	code, err := controllink.ParseCode(text)
	if err != nil || code.Host {
		t.Fatalf("%+v %v", code, err)
	}
	return code
}

// #4228: the Mac app's Connect to Another… signs in here and gets a client code for the
// account's control plane on agents://hosted: a new person after signing up, and a person
// already signed in at once. The code is an app's, not only a browser's.
func TestTheAppGetsACodeForItsControlPlane(t *testing.T) {
	s, b := start(t, store.NewMemory())

	// Not signed in: to the welcome page, and the sign-in comes back to the app.
	res, _ := b.get("https://" + domain + "/app/connect")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/" {
		t.Fatalf("%d %s", res.StatusCode, res.Header.Get("Location"))
	}
	code := appCodeIn(t, b.signIn("good"))
	id, ok := strings.CutSuffix(strings.TrimPrefix(code.URL, "https://"), "."+domain)
	if !ok || !validID(id) {
		t.Fatal(code.URL)
	}
	copy, err := s.copyFor(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := copy.service.Codes().Stored(t.Context(), code.ID(), false)
	s.done(copy)
	if err != nil || stored.Browser != nil {
		t.Fatalf("%+v %v: the app's code is a browser's", stored, err)
	}

	// Signed in already: straight back to the app with a new code.
	again := appCodeIn(t, func() *http.Response { r, _ := b.get("https://" + domain + "/app/connect"); return r }())
	if again.URL != code.URL || string(again.Secret) == string(code.Secret) {
		t.Fatal("not a new code for the same control plane")
	}

	// The app's cookie went with its sign-in: a later sign-in in this browser is a browser's.
	if res := b.signIn("good"); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"))
	}
}
