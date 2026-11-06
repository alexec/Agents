package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Okta as an org provider and a SCIM client, on a real Okta org (#3415):
// scripts/okta-walk.sh starts a Cloudflare quick tunnel to this test and runs it beside
// it. The person who walks it drives a browser and Okta's admin console; the test and
// that person talk through files in AGENTS_LIVE_OKTA_DIR. With no AGENTS_LIVE_OKTA_ORG it
// skips, so `go test ./...` and CI never need Okta.
//
//	AGENTS_LIVE_OKTA_ORG            https://integrator-….okta.com, the org authorization server
//	AGENTS_LIVE_OKTA_URL            the tunnel's public https URL: the plane's address
//	AGENTS_LIVE_OKTA_CLIENT_ID      the Okta app's client, and its secret
//	AGENTS_LIVE_OKTA_CLIENT_SECRET
//	AGENTS_LIVE_OKTA_DIR            the files below
//
// In the folder, the test writes scim-url and scim-token (0600) for Okta's Provisioning
// tab, start-<n> for each sign-in to open in the browser, and scim.jsonl: every SCIM
// request Okta sent, with the plane's answer and no Authorization header. The walker
// writes ticket-<n> (the ticket in the URL the browser came back to) and, at the end,
// done: the userName Okta deactivated.
type liveOkta struct {
	org, url, clientID, secret, dir string
}

func liveOktaFromEnv(t *testing.T) *liveOkta {
	org := os.Getenv("AGENTS_LIVE_OKTA_ORG")
	if org == "" {
		t.Skip("no Okta org: scripts/okta-walk.sh runs this test")
	}
	return &liveOkta{org: org, url: os.Getenv("AGENTS_LIVE_OKTA_URL"), clientID: os.Getenv("AGENTS_LIVE_OKTA_CLIENT_ID"),
		secret: os.Getenv("AGENTS_LIVE_OKTA_CLIENT_SECRET"), dir: os.Getenv("AGENTS_LIVE_OKTA_DIR")}
}

func (l *liveOkta) write(t *testing.T, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(l.dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

// wait waits for the walker's file and returns what it holds.
func (l *liveOkta) wait(t *testing.T, name string, limit time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(filepath.Join(l.dir, name)); err == nil && len(bytes.TrimSpace(data)) > 0 {
			return strings.TrimSpace(string(data))
		}
		time.Sleep(time.Second)
	}
	t.Fatalf("no %s in %s", name, limit)
	return ""
}

// recorder is the tunnel's way in: it passes each request to the plane and writes each
// SCIM one, with the answer, to scim.jsonl.
type recorder struct {
	mu    sync.Mutex
	out   *os.File
	proxy *httputil.ReverseProxy
	t     *testing.T
}

type recorded struct {
	At     string          `json:"at"`
	Method string          `json:"method"`
	Path   string          `json:"path"`
	Agent  string          `json:"userAgent,omitempty"`
	Body   json.RawMessage `json:"body,omitempty"`
	Status int             `json:"status"`
	Answer json.RawMessage `json:"answer,omitempty"`
}

type capture struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (c *capture) WriteHeader(status int) { c.status = status; c.ResponseWriter.WriteHeader(status) }
func (c *capture) Write(b []byte) (int, error) {
	c.body.Write(b)
	return c.ResponseWriter.Write(b)
}

func (r *recorder) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if !strings.HasPrefix(req.URL.Path, "/scim/") {
		r.proxy.ServeHTTP(w, req)
		return
	}
	body, _ := io.ReadAll(req.Body)
	req.Body = io.NopCloser(bytes.NewReader(body))
	c := &capture{ResponseWriter: w, status: http.StatusOK}
	r.proxy.ServeHTTP(c, req)
	line := recorded{At: time.Now().UTC().Format(time.RFC3339), Method: req.Method, Path: strings.TrimPrefix(req.URL.RequestURI(), "/scim/v2"),
		Agent: req.UserAgent(), Status: c.status}
	if json.Valid(body) {
		line.Body = body
	}
	if json.Valid(c.body.Bytes()) {
		line.Answer = c.body.Bytes()
	}
	data, _ := json.Marshal(line)
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.out.Write(append(data, '\n')); err != nil {
		r.t.Errorf("scim.jsonl: %v", err)
	}
	r.t.Logf("scim: %s %s → %d", req.Method, line.Path, c.status)
}

// T-okta (#3415): an admin adds the Okta org as the okta preset, checks it, and a person
// signs in there twice and is one person; Okta's SCIM client then provisions and
// deactivates people through the tunnel, and the deactivated one is suspended.
func TestOktaLive(t *testing.T) {
	l := liveOktaFromEnv(t)
	st := store.NewMemory()
	const planePort = 8791
	p := startPlaneWith(t, st, controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.Port, c.URL = planePort, l.url
		c.SignIn = &signin.Config{HTTP: &http.Client{Timeout: 10 * time.Second}}
	})
	// Clients dial the public URL, which their sign-in proof names; the tunnel comes in here.
	p.url = l.url
	target, _ := url.Parse("http://127.0.0.1:" + itoa(planePort))
	out, err := os.OpenFile(filepath.Join(l.dir, "scim.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	// Every interface: the tunnel is another container on the walk's network.
	listener, err := net.Listen("tcp", "0.0.0.0:8790")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: &recorder{out: out, proxy: httputil.NewSingleHostReverseProxy(target), t: t}, ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)
	defer server.Close()

	_, owner := p.client("Alex's Mac")
	join := wire.OrgProviderJoinAnyone
	var kept wire.OrgProviderKept
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: wire.OrgProvider{Name: "Okta",
		Preset: wire.OrgProviderPresetOkta, Issuer: l.org, ClientID: l.clientID, Join: &join}, Secret: &l.secret}), &kept)
	id := kept.Provider.ID
	var check wire.OrgProviderCheck
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/check", wire.OrgProviderRequest{ID: id}), &check)
	if !check.Ok || check.JwksKeys == 0 || check.RedirectURI != l.url+"/v1/oidc/callback" {
		t.Fatalf("check: %+v", check)
	}
	t.Logf("provider %s checked: %d keys, redirect %s", id, check.JwksKeys, check.RedirectURI)

	match := wire.SCIMMatchExternalId
	call(t, owner, "", "scim/set", wire.SCIMSet{Provider: id, On: true, Match: &match})
	var made wire.SCIMTokenMade
	json.Unmarshal(call(t, owner, "", "scim/tokens/make", wire.SCIMTokenMake{Provider: id, Name: "Okta"}), &made)
	l.write(t, "scim-url", made.URL)
	l.write(t, "scim-token", made.Value)
	t.Logf("SCIM at %s (token in scim-token)", made.URL)

	// Two sign-ins through the web page's way back: the same person both times.
	ctx := context.Background()
	var account string
	for n := range 2 {
		s := openSignIn(t, p)
		raw, err := s.Call(ctx, "signIn/orgStart", wire.SignInOrgStart{Provider: id, Purpose: wire.SignInOrgPurposePair, ReturnTo: wire.SignInOrgReturnWeb})
		if err != nil {
			t.Fatal(err)
		}
		var started wire.SignInOrgStarted
		json.Unmarshal(raw, &started)
		name := "start-" + itoa(n+1)
		l.write(t, name, started.URL)
		t.Logf("sign-in %d: open %s", n+1, name)
		if err := ticketOn(s, l.wait(t, "ticket-"+itoa(n+1), 10*time.Minute), wire.ClientKindBrowser); err != nil {
			t.Fatalf("sign-in %d: %v", n+1, err)
		}
		var them []records.Person
		for _, q := range p.s.records.People() {
			if len(q.SignIns) > 0 && q.SignIns[0].Provider == id {
				them = append(them, q)
			}
		}
		if len(them) != 1 || (account != "" && them[0].SignIns[0].Account != account) || len(them[0].SignIns) != 1 {
			t.Fatalf("sign-in %d: %d people", n+1, len(them))
		}
		account = them[0].SignIns[0].Account
		t.Logf("sign-in %d: %s %q, account %s, %s", n+1, them[0].ID, them[0].Name, account, them[0].SignIns[0].Email)
	}

	// Okta's SCIM client, driven from the admin console, until the walker writes done.
	gone := l.wait(t, "done", 60*time.Minute)
	for _, q := range p.s.records.People() {
		state := "active"
		if q.IsSuspended() {
			state = "suspended"
		}
		userName := ""
		if q.SCIM != nil {
			userName = q.SCIM.UserName
		}
		t.Logf("person %s %q scim=%q provisioned=%v %s", q.ID, q.Name, userName, q.Provisioned, state)
		if userName == gone && !q.IsSuspended() {
			t.Fatalf("%s is not suspended after Okta deactivated them", gone)
		}
	}
	noSecretKept(t, p, l.secret)
}
