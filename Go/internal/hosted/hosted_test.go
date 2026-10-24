package hosted

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

const domain = "hosted.test"

// fakeGitHub signs in user 42, ana, made in 2015, for the code "good"; user <id>, <login>,
// made <days> days ago, for the code "u.<id>.<login>.<days>"; and nobody for any other.
func fakeGitHub(t *testing.T) *httptest.Server {
	g := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/oauth/access_token":
			r.ParseForm()
			code := r.PostForm.Get("code")
			if r.PostForm.Get("client_secret") != "secret" || code != "good" && !strings.HasPrefix(code, "u.") {
				json.NewEncoder(w).Encode(map[string]string{"error": "bad_verification_code", "error_description": "The code is wrong."})
				return
			}
			json.NewEncoder(w).Encode(map[string]string{"access_token": "gho_" + code})
		case "/user":
			token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer gho_")
			if token == "good" {
				json.NewEncoder(w).Encode(map[string]any{"id": 42, "login": "ana", "created_at": "2015-01-01T00:00:00Z"})
				return
			}
			parts := strings.Split(token, ".")
			if len(parts) != 4 || parts[0] != "u" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			id, _ := strconv.Atoi(parts[1])
			days, _ := strconv.Atoi(parts[3])
			json.NewEncoder(w).Encode(map[string]any{"id": id, "login": parts[2],
				"created_at": time.Now().Add(-time.Duration(days) * 24 * time.Hour).UTC().Format(time.RFC3339)})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(g.Close)
	return g
}

type browser struct {
	t      *testing.T
	client *http.Client
	// The body of the last answer.
	last string
}

// start serves the hosted service over TLS, and a browser that reaches it at every name.
func start(t *testing.T, st store.Store) (*Service, *browser) {
	t.Helper()
	return startBehind(t, st, nil)
}

// startBehind is start with trusted as the proxies in front. Sign-up is open, so these
// tests sign up with no invite; signup_test.go tests the rest.
func startBehind(t *testing.T, st store.Store, trusted []netip.Prefix) (*Service, *browser) {
	t.Helper()
	s, newBrowser := startWith(t, Config{Store: st, TrustedProxies: trusted, SignUp: SignUpOpen})
	return s, newBrowser()
}

// startWith serves the hosted service of cfg, with the fake GitHub and a test keeper, and
// makes browsers that reach it at every name, each with cookies of its own.
func startWith(t *testing.T, cfg Config) (*Service, func() *browser) {
	t.Helper()
	g := fakeGitHub(t)
	cfg.Keeper = "base64key://" + base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	cfg.Domain, cfg.GitHubClientID, cfg.GitHubSecret, cfg.GitHubWeb, cfg.GitHubAPI = domain, "Iv1.test", "secret", g.URL, g.URL
	cfg.Log = func(line string) { t.Log(line) }
	s, err := New(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	server := httptest.NewTLSServer(s)
	t.Cleanup(server.Close)
	address := server.Listener.Addr().String()
	return s, func() *browser {
		jar, _ := cookiejar.New(nil)
		transport := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, address)
			}}
		client := &http.Client{Jar: jar, Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		return &browser{t: t, client: client}
	}
}

func (b *browser) get(u string) (*http.Response, string) {
	b.t.Helper()
	res, err := b.client.Get(u)
	if err != nil {
		b.t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	b.last = string(body)
	return res, string(body)
}

func (b *browser) post(u string, form url.Values) (*http.Response, string) {
	b.t.Helper()
	res, err := b.client.PostForm(u, form)
	if err != nil {
		b.t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	b.last = string(body)
	return res, string(body)
}

// signIn goes to GitHub and back with code, and says where the service sent the browser.
func (b *browser) signIn(code string) *http.Response {
	b.t.Helper()
	return b.signInWith(code, "")
}

// signInWith is signIn from an invite link's code, when not "".
func (b *browser) signInWith(code, invite string) *http.Response {
	b.t.Helper()
	from := "https://" + domain + "/signin"
	if invite != "" {
		from += "?invite=" + invite
	}
	res, _ := b.get(from)
	to, err := url.Parse(res.Header.Get("Location"))
	if err != nil || res.StatusCode != http.StatusSeeOther || to.Path != "/login/oauth/authorize" {
		b.t.Fatalf("%d %s", res.StatusCode, res.Header.Get("Location"))
	}
	if to.Query().Get("redirect_uri") != "https://"+domain+"/signin/callback" || to.Query().Get("client_id") != "Iv1.test" {
		b.t.Fatal(to)
	}
	back, _ := b.get("https://" + domain + "/signin/callback?" + url.Values{"code": {code}, "state": {to.Query().Get("state")}}.Encode())
	return back
}

// #1807: sign up with GitHub, get a control plane of your own, and this browser is sent to
// it with a code it pairs itself with. Signing in again finds the same account; deleting
// it deletes its control plane's store.
func TestSignUpGivesAControlPlaneOfYourOwn(t *testing.T) {
	st := store.NewMemory()
	s, b := start(t, st)
	_, page := b.get("https://" + domain + "/")
	if !strings.Contains(page, "Sign Up with GitHub") {
		t.Fatal(page)
	}

	res := b.signIn("good")
	to, err := url.Parse(res.Header.Get("Location"))
	if err != nil || res.StatusCode != http.StatusSeeOther {
		t.Fatalf("%d %v", res.StatusCode, err)
	}
	id, ok := strings.CutSuffix(to.Host, "."+domain)
	if !ok || !validID(id) || to.Scheme != "https" || to.Path != "/" {
		t.Fatal(to)
	}
	text, ok := strings.CutPrefix(to.Fragment, "code=")
	if !ok {
		t.Fatal(to)
	}
	code, err := controllink.ParseCode(text)
	if err != nil || code.URL != "https://"+id+"."+domain || code.Host {
		t.Fatalf("%+v %v", code, err)
	}
	// The code is that account's control plane's, under its own prefix and key.
	o, _ := st.Get(context.Background(), "accounts/"+id+"/v1/control.json")
	var settings records.Settings
	if o == nil || json.Unmarshal(o.Data, &settings) != nil || !bytes.Equal(settings.ControlKey, code.ControlKey) {
		t.Fatal("the code is not the account's control plane's")
	}
	if o, _ := st.Get(context.Background(), "accounts/"+id+"/v1/keys/control.sealed"); o == nil {
		t.Fatal("the account's key is not sealed in its prefix")
	}
	// Its control plane answers at its own name, through this service.
	if res, body := b.get("https://" + id + "." + domain + "/readyz"); res.StatusCode != http.StatusOK {
		t.Fatalf("%d %s", res.StatusCode, body)
	}
	if res, _ := b.get("https://abcdefghij." + domain + "/readyz"); res.StatusCode != http.StatusNotFound {
		t.Fatal("a name with no account was answered")
	}
	// A WebSocket reaches it too: the upgrade passes through.
	req, _ := http.NewRequest(http.MethodGet, "https://"+id+"."+domain+"/v1/connect", nil)
	for k, v := range map[string]string{"Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
		"Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="} {
		req.Header.Set(k, v)
	}
	if res, err := b.client.Do(req); err != nil || res.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("%v %v", res, err)
	} else {
		res.Body.Close()
	}
	// A certificate is asked for only for the pages and an account that exists.
	for name, want := range map[string]int{domain: 200, id + "." + domain: 200, "abcdefghij." + domain: 404, "other.test": 404} {
		if res, _ := b.get("https://" + domain + "/v1/tls-allowed?domain=" + name); res.StatusCode != want {
			t.Fatalf("%s: %d", name, res.StatusCode)
		}
	}

	// Signing in again is the same account, and this browser can be sent to it again.
	res = b.signIn("good")
	if res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"))
	}
	_, page = b.get("https://" + domain + "/account")
	if !strings.Contains(page, "https://"+id+"."+domain) || !strings.Contains(page, "as ana") {
		t.Fatal(page)
	}
	token := s.sessions.form(id)
	res, _ = b.post("https://"+domain+"/account/open", url.Values{"token": {token}})
	if !strings.HasPrefix(res.Header.Get("Location"), "https://"+id+"."+domain+"/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
	// A form from anywhere else does nothing.
	if res, _ := b.post("https://"+domain+"/account/open", url.Values{"token": {"forged"}}); res.Header.Get("Location") != "/" {
		t.Fatal(res.Header.Get("Location"))
	}

	// Deleting asks for the name first, then takes the control plane's whole store.
	if _, page := b.post("https://"+domain+"/account/delete", url.Values{"token": {token}, "confirm": {"nope"}}); !strings.Contains(page, "Type the account") {
		t.Fatal(page)
	}
	if _, page := b.post("https://"+domain+"/account/delete", url.Values{"token": {token}, "confirm": {id}}); !strings.Contains(page, "are deleted") {
		t.Fatal(page)
	}
	if left, _ := st.List(context.Background(), "accounts/"+id+"/"); len(left) != 0 {
		t.Fatalf("%d objects left", len(left))
	}
	if res, _ := b.get("https://" + id + "." + domain + "/readyz"); res.StatusCode != http.StatusNotFound {
		t.Fatal("a deleted account's control plane answered")
	}
	// The same GitHub user can sign up again, with a new control plane.
	res = b.signIn("good")
	if again, _ := url.Parse(res.Header.Get("Location")); again == nil || strings.HasPrefix(again.Host, id) {
		t.Fatal(res.Header.Get("Location"))
	}
}

// Behind a trusted proxy, the copy counts each client by its own address, not the
// proxy's: one client's sockets do not count against another.
func TestTheCopyCountsEachClientNotTheProxy(t *testing.T) {
	_, b := startBehind(t, store.NewMemory(), []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
	to, _ := url.Parse(b.signIn("good").Header.Get("Location"))
	connect := func(from string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, "https://"+to.Host+"/v1/connect", nil)
		for k, v := range map[string]string{"Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
			"Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", "X-Forwarded-For": from} {
			req.Header.Set(k, v)
		}
		res, err := b.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		return res
	}
	for i := 0; i < 50; i++ {
		if res := connect("203.0.113.7"); res.StatusCode != http.StatusSwitchingProtocols {
			t.Fatalf("socket %d: %d", i, res.StatusCode)
		}
	}
	if res := connect("203.0.113.7"); res.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("the first client's 51st socket: %d", res.StatusCode)
	}
	if res := connect("198.51.100.9"); res.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("the second client was counted with the first: %d", res.StatusCode)
	}
}

// With no trusted proxy in front, what a client says in X-Forwarded-For is not believed.
func TestTheCopyBelievesNoClientsForwardedFor(t *testing.T) {
	s, _ := start(t, store.NewMemory())
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "192.0.2.4:5000"
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	if got := s.clientOf(r); got != "192.0.2.4" {
		t.Fatal(got)
	}
	s.cfg.TrustedProxies = []netip.Prefix{netip.MustParsePrefix("192.0.2.0/24")}
	r.Header.Add("X-Forwarded-For", "10.0.0.1, 198.51.100.9")
	if got := s.clientOf(r); got != "198.51.100.9" {
		t.Fatal(got)
	}
}

// A callback that this browser did not start, or that GitHub refused, signs nobody in.
func TestASignInMustBeThisBrowsers(t *testing.T) {
	_, b := start(t, store.NewMemory())
	if res, _ := b.get("https://" + domain + "/signin/callback?code=good&state=made-up"); res.StatusCode != http.StatusBadRequest {
		t.Fatal(res.StatusCode)
	}
	res := b.signIn("bad")
	if res.StatusCode != http.StatusBadGateway {
		t.Fatal(res.StatusCode)
	}
	if res, _ := b.get("https://" + domain + "/account"); res.Header.Get("Location") != "/" {
		t.Fatal("signed in with a refused code")
	}
	if res, _ := b.get("https://elsewhere.test/"); res.StatusCode != http.StatusMisdirectedRequest {
		t.Fatal(res.StatusCode)
	}
}

// A code in the link decodes back whole in the page (decodeURIComponent).
func TestTheLinkKeepsTheCodeWhole(t *testing.T) {
	code := "agents-control:2:c:-:AbC_-:s3cr3t:https%3A%2F%2Fx.test:-:Your%20control%20plane"
	back, err := url.PathUnescape(escapeCode(code))
	if err != nil || back != code || strings.ContainsAny(escapeCode(code), ":/% ") && !strings.Contains(escapeCode(code), "%3A") {
		t.Fatal(escapeCode(code), back, err)
	}
}
