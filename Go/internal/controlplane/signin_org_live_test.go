package controlplane

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/signin"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A generic OIDC org provider on a real issuer (#3415): scripts/oidc-walk.sh starts Dex
// in a container and runs this test beside it. With no AGENTS_LIVE_OIDC_ISSUER it skips,
// so `go test ./...` and CI never need a container.
//
//	AGENTS_LIVE_OIDC_ISSUER         https://dex:5556/dex
//	AGENTS_LIVE_OIDC_TRUST_ROOT     the issuer's certificate, PEM
//	AGENTS_LIVE_OIDC_CLIENT_ID      the client the issuer has for this plane
//	AGENTS_LIVE_OIDC_CLIENT_SECRET  its secret
//	AGENTS_LIVE_OIDC_LOGIN          a person's login at the issuer, and their password
//	AGENTS_LIVE_OIDC_PASSWORD
//	AGENTS_LIVE_OIDC_PORT           the plane's port, in the client's redirect URI
type liveIssuer struct {
	issuer, clientID, secret, login, password string
	port                                      int
	http                                      *http.Client
}

func liveIssuerFromEnv(t *testing.T) *liveIssuer {
	issuer := os.Getenv("AGENTS_LIVE_OIDC_ISSUER")
	if issuer == "" {
		t.Skip("no live issuer: scripts/oidc-walk.sh runs this test")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(os.Getenv("AGENTS_LIVE_OIDC_TRUST_ROOT"))) {
		t.Fatal("AGENTS_LIVE_OIDC_TRUST_ROOT holds no certificate")
	}
	port, err := strconv.Atoi(os.Getenv("AGENTS_LIVE_OIDC_PORT"))
	if err != nil {
		t.Fatal("AGENTS_LIVE_OIDC_PORT is not a port")
	}
	return &liveIssuer{issuer: issuer, clientID: os.Getenv("AGENTS_LIVE_OIDC_CLIENT_ID"), secret: os.Getenv("AGENTS_LIVE_OIDC_CLIENT_SECRET"),
		login: os.Getenv("AGENTS_LIVE_OIDC_LOGIN"), password: os.Getenv("AGENTS_LIVE_OIDC_PASSWORD"), port: port,
		http: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}}
}

// waitUp waits for the issuer's discovery document: the container may still be starting.
func (l *liveIssuer) waitUp(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for {
		resp, err := l.http.Get(l.issuer + "/.well-known/openid-configuration")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("the issuer did not come up: %v", err)
		}
		time.Sleep(time.Second)
	}
}

// loginForm is the issuer's password form: the action it posts to.
var loginForm = regexp.MustCompile(`(?is)<form[^>]*method="post"[^>]*action="([^"]*)"|<form[^>]*action="([^"]*)"[^>]*method="post"`)

// browse is a browser for controllink.SignInOrg: it follows the start address to the
// issuer, fills its password form, and stops where the plane sends it back to the client.
func (l *liveIssuer) browse(t *testing.T, password string) func(string) (string, error) {
	return func(start string) (string, error) {
		jar, _ := cookiejar.New(nil)
		var back *url.URL
		client := &http.Client{Timeout: 15 * time.Second, Jar: jar, Transport: l.http.Transport,
			CheckRedirect: func(req *http.Request, _ []*http.Request) error {
				if req.URL.Scheme == "agents" || req.URL.Fragment != "" {
					back = req.URL
					return http.ErrUseLastResponse
				}
				return nil
			}}
		resp, err := client.Get(start)
		for range 3 {
			if err != nil || back != nil {
				break
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			m := loginForm.FindStringSubmatch(string(body))
			if m == nil {
				return "", errors.New("no password form at " + resp.Request.URL.String() + ": " + strconv.Itoa(resp.StatusCode))
			}
			action, _ := url.Parse(strings.ReplaceAll(m[1]+m[2], "&amp;", "&"))
			resp, err = client.PostForm(resp.Request.URL.ResolveReference(action).String(), url.Values{"login": {l.login}, "password": {password}})
		}
		if err != nil {
			return "", err
		}
		if back == nil {
			resp.Body.Close()
			return "", errors.New("the issuer did not send the browser back")
		}
		values, _ := url.ParseQuery(back.Fragment)
		ticket := values.Get("ticket") + values.Get("oidc-ticket")
		if ticket == "" {
			return "", errors.New(values.Get("error") + values.Get("oidc-error") + ": " + values.Get("message") + values.Get("oidc-message"))
		}
		return ticket, nil
	}
}

// T-live (#3415): an admin adds the issuer as a generic OIDC provider, checks it, and a
// person pairs a phone by signing in there, then again as the same person; the web page's
// way back pairs a browser; a wrong password pairs nothing; no secret or token is kept.
func TestOrgSignInLiveIssuer(t *testing.T) {
	l := liveIssuerFromEnv(t)
	l.waitUp(t)
	st := store.NewMemory()
	p := startPlaneWith(t, st, controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.Port, c.URL = l.port, "http://127.0.0.1:"+strconv.Itoa(l.port)
		c.SignIn = &signin.Config{HTTP: l.http}
	})
	p.url = "http://127.0.0.1:" + strconv.Itoa(l.port) // the helper chose a port before this one
	_, owner := p.client("Alex's Mac")
	join := wire.OrgProviderJoinAnyone
	var kept wire.OrgProviderKept
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: wire.OrgProvider{Name: "Acme",
		Preset: wire.OrgProviderPresetOidc, Issuer: l.issuer, ClientID: l.clientID, Join: &join}, Secret: &l.secret}), &kept)
	if kept.Provider.ID != "acme" {
		t.Fatalf("%+v", kept)
	}
	var check wire.OrgProviderCheck
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/check", wire.OrgProviderRequest{ID: "acme"}), &check)
	if !check.Ok || check.JwksKeys == 0 || check.RedirectURI != p.url+"/v1/oidc/callback" {
		t.Fatalf("check: %+v", check)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	phone, err := controllink.SignInOrg(ctx, p.url, "", nil, "Sam's iPhone", records.KindIPhone, "acme", l.browse(t, l.password))
	if err != nil {
		t.Fatal(err)
	}
	sam := personOf(t, p, phone)
	got := p.s.records.Person(sam)
	if got == nil || got.Role != records.RoleMember || len(got.SignIns) != 1 || got.SignIns[0].Provider != "acme" || got.SignIns[0].Email != l.login {
		t.Fatalf("%+v", got)
	}
	t.Logf("joined: %s %q, account %s", got.ID, got.Name, got.SignIns[0].Account)
	again, err := controllink.SignInOrg(ctx, p.url, "", nil, "Sam's Mac", records.KindMac, "acme", l.browse(t, l.password))
	if err != nil || personOf(t, p, again) != sam {
		t.Fatalf("again: %v", err)
	}

	// The web page's way back: a fragment on the plane's own page, then signIn/ticket.
	s := openSignIn(t, p)
	raw, err := s.Call(ctx, "signIn/orgStart", wire.SignInOrgStart{Provider: "acme", Purpose: wire.SignInOrgPurposePair, ReturnTo: wire.SignInOrgReturnWeb})
	if err != nil {
		t.Fatal(err)
	}
	var started wire.SignInOrgStarted
	json.Unmarshal(raw, &started)
	ticket, err := l.browse(t, l.password)(started.URL)
	if err != nil {
		t.Fatal(err)
	}
	if err := ticketOn(s, ticket, wire.ClientKindBrowser); err != nil {
		t.Fatalf("web: %v", err)
	}

	// A wrong password stays at the issuer's form: no ticket, nothing paired.
	if _, err := controllink.SignInOrg(ctx, p.url, "", nil, "Eve's iPhone", records.KindIPhone, "acme", l.browse(t, l.password+"x")); err == nil || !strings.Contains(err.Error(), "did not send the browser back") {
		t.Fatalf("a wrong password: %v", err)
	}
	noSecretKept(t, p, l.secret)
}
