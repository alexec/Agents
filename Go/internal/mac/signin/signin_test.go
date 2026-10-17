package signin

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fakeSource struct {
	token   atomic.Value
	renewed atomic.Int32
}

func (f *fakeSource) Current() (Token, error) { return f.token.Load().(Token), nil }
func (f *fakeSource) Renew(_ context.Context, stale Token) (Token, error) {
	f.renewed.Add(1)
	t := Token{Access: "renewed", Headers: map[string]string{"ChatGPT-Account-Id": "acct"}}
	f.token.Store(t)
	return t, nil
}
func (f *fakeSource) StandIn() (string, error) { return "sk-ant-oat01-agents-relay-test", nil }

// A relay in front of a stand-in for the runtime's service: requests carry the stand-in
// bearer in, this Mac's token out, and a 401 is renewed once.
func TestTheRelayPutsTheMacsTokenOnEachRequest(t *testing.T) {
	var seen atomic.Value
	service := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen.Store(r.Header.Clone())
		if r.Header.Get("Authorization") == "Bearer stale" {
			w.WriteHeader(401)
			return
		}
		b, _ := io.ReadAll(r.Body)
		w.Header().Set("X-Path", r.URL.RequestURI())
		fmt.Fprintf(w, "echo %s", b)
	}))
	defer service.Close()
	source := &fakeSource{}
	source.token.Store(Token{Access: "real"})
	var lines []string
	relay := &Relay{Upstream: "api.example.test", Source: source, Certs: Certificates{Folder: t.TempDir()},
		Log: func(l string) { lines = append(lines, l) },
		Client: &http.Client{Transport: &http.Transport{
			DialTLSContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return tls.Dial("tcp", service.Listener.Addr().String(), &tls.Config{InsecureSkipVerify: true})
			}}}}
	port, err := relay.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Stop()
	relay.ExpectClientBearer("standin")
	pem, _ := relay.Certs.CAPEM()
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(pem))
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	ask := func(target, bearer string, header ...string) (*http.Response, string) {
		req, _ := http.NewRequest("POST", fmt.Sprintf("https://127.0.0.1:%d%s", port, target), strings.NewReader("hi"))
		req.Header.Set("Authorization", "Bearer "+bearer)
		req.Header.Set("X-Api-Key", "theirs")
		for i := 0; i+1 < len(header); i += 2 {
			req.Header.Set(header[i], header[i+1])
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}

	resp, body := ask("/v1/messages?beta=true", "standin", "Anthropic-Version", "2023-06-01")
	h := seen.Load().(http.Header)
	if resp.StatusCode != 200 || body != "echo hi" || resp.Header.Get("X-Path") != "/v1/messages?beta=true" ||
		h.Get("Authorization") != "Bearer real" || h.Get("X-Api-Key") != "" || h.Get("Anthropic-Version") != "2023-06-01" {
		t.Fatalf("%d %q %v", resp.StatusCode, body, h)
	}
	if resp, _ := ask("/v1/messages", "sk-ant-oat01-agents-relay-standin"); resp.StatusCode != 403 {
		t.Fatalf("the fixed stand-in drew the token: %d", resp.StatusCode)
	}
	if resp, _ := ask("/v1/messages", "standin", "Upgrade", "websocket", "Connection", "Upgrade"); resp.StatusCode != 404 {
		t.Fatalf("a WebSocket: %d", resp.StatusCode)
	}
	source.token.Store(Token{Access: "stale"})
	resp, body = ask("/v1/messages", "standin")
	h = seen.Load().(http.Header)
	if resp.StatusCode != 200 || source.renewed.Load() != 1 || h.Get("Authorization") != "Bearer renewed" ||
		h.Get("Chatgpt-Account-Id") != "acct" {
		t.Fatalf("after a 401: %d %q %v", resp.StatusCode, body, h)
	}
	for _, l := range lines {
		if strings.Contains(l, "real") || strings.Contains(l, "standin") || strings.Contains(l, "beta") {
			t.Fatalf("the log said too much: %q", l)
		}
	}
}

func TestAnUpstreamURLIsAPathOnly(t *testing.T) {
	for target, want := range map[string]string{
		"/v1/messages":            "https://api.anthropic.com/v1/messages",
		"/v1/m?beta=true&x=%2F":   "https://api.anthropic.com/v1/m?beta=true&x=%2F",
		"//evil.example/":         "",
		"@evil.example/":          "",
		"http://evil.example/":    "",
		"/a b":                    "",
		"/a%zz":                   "",
		"/a#frag":                 "",
		"/backend-api/codex/x%20": "https://api.anthropic.com/backend-api/codex/x%20",
	} {
		u := UpstreamURL("api.anthropic.com", target)
		got := ""
		if u != nil {
			got = u.String()
		}
		if got != want {
			t.Fatalf("%q: %q, want %q", target, got, want)
		}
	}
}

func TestCertificatesAreMadeOnceAndServe127(t *testing.T) {
	c := Certificates{Folder: filepath.Join(t.TempDir(), "relay")}
	pem1, err := c.CAPEM()
	if err != nil {
		t.Fatal(err)
	}
	pem2, _ := c.CAPEM()
	if pem1 != pem2 {
		t.Fatal("made twice")
	}
	id, err := c.Identity()
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(pem1))
	leaf, _ := x509.ParseCertificate(id.Certificate[0])
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"ca-key.pem", "relay-key.pem"} {
		if fi, _ := os.Stat(filepath.Join(c.Folder, f)); fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s is %v", f, fi.Mode())
		}
	}
	if fi, _ := os.Stat(c.Folder); fi.Mode().Perm() != 0o700 {
		t.Fatalf("the folder is %v", fi.Mode())
	}
}

func TestClaudesItemAsClaudeWritesIt(t *testing.T) {
	ms := time.Now().Add(time.Hour).UnixMilli()
	reads := 0
	item := fmt.Sprintf(`{"claudeAiOauth":{"accessToken":"tok","expiresAt":%d,"scopes":["user:inference"]}}`, ms)
	c := &Claude{read: func() ([]byte, error) { reads++; return []byte(item), nil }, now: time.Now, renew: func(context.Context) {}}
	if tok, err := c.Current(); err != nil || tok.Access != "tok" {
		t.Fatalf("%v %v", tok, err)
	}
	c.Current()
	if reads != 1 {
		t.Fatalf("read %d times: the token is kept until a minute before it expires", reads)
	}
	if _, _, err := parseClaude([]byte(`{"claudeAiOauth":{"accessToken":"tok","scopes":["user:profile"]}}`)); err != ErrNotSignedIn {
		t.Fatalf("no inference scope: %v", err)
	}
	if _, err := c.Renew(context.Background(), Token{Access: "tok"}); err != ErrRenewalRefused {
		t.Fatalf("a renewal that changed nothing: %v", err)
	}
	if s, _ := c.StandIn(); !strings.HasPrefix(s, ClaudeStandInPrefix) || len(s) != len(ClaudeStandInPrefix)+64 {
		t.Fatalf("stand-in %q", s)
	}
}

func TestCodexsFileIsLentAsAStandInAndRenewedInPlace(t *testing.T) {
	jwt := func(claims map[string]any) string { return unsigned(claims) }
	access := jwt(map[string]any{"client_id": "app_x"})
	id := jwt(map[string]any{"https://api.openai.com/auth": map[string]any{"chatgpt_plan_type": "pro", "secret": "no"}})
	file := filepath.Join(t.TempDir(), "auth.json")
	b, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]any{"access_token": access,
		"id_token": id, "refresh_token": "refresh", "account_id": "acct"}})
	os.WriteFile(file, b, 0o600)
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		if body["refresh_token"] != "refresh" || body["client_id"] != "app_x" {
			w.WriteHeader(400)
			return
		}
		fmt.Fprint(w, `{"access_token":"new","refresh_token":"refresh2"}`)
	}))
	defer endpoint.Close()
	c := NewCodex(file)
	c.TokenEndpoint = endpoint.URL
	tok, err := c.Current()
	if err != nil || tok.Access != access || tok.Headers["ChatGPT-Account-Id"] != "acct" {
		t.Fatalf("%v %v", tok, err)
	}
	standIn, err := c.StandIn()
	var lent struct {
		Tokens map[string]string `json:"tokens"`
	}
	json.Unmarshal([]byte(standIn), &lent)
	kept, _ := claims(lent.Tokens["id_token"])["https://api.openai.com/auth"].(map[string]any)
	if err != nil || lent.Tokens["refresh_token"] != "agents-relay-standin" || kept["chatgpt_plan_type"] != "pro" ||
		kept["secret"] != nil || ClientBearer(standIn) != lent.Tokens["access_token"] || strings.Contains(standIn, access) {
		t.Fatalf("%v %s", err, standIn)
	}
	renewed, err := c.Renew(context.Background(), tok)
	if err != nil || renewed.Access != "new" {
		t.Fatalf("%v %v", renewed, err)
	}
	again, _ := os.ReadFile(file)
	if !strings.Contains(string(again), `"refresh2"`) {
		t.Fatalf("not written in place: %s", again)
	}
	// Renewed already by the runtime on this Mac: nothing is spent.
	if r, err := c.Renew(context.Background(), tok); err != nil || r.Access != "new" {
		t.Fatalf("%v %v", r, err)
	}
}
