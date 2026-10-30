package web

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// The cases are LoopbackListenerTests.swift's: every row of the contract's tables, then the
// listener on a real copy.

const testPort = 8899

var testGate = &gate{port: testPort, files: Files{
	"/index.html":   {Data: []byte("<!doctype html>"), ContentType: "text/html; charset=utf-8"},
	"/app.js":       {Data: []byte("export{}"), ContentType: "text/javascript; charset=utf-8"},
	"/sandbox.html": {Data: []byte("<!doctype html>"), ContentType: "text/html; charset=utf-8"},
	"/sandbox.js":   {Data: []byte("void 0"), ContentType: "text/javascript; charset=utf-8"},
}}

// req is one request head for the gate.
type req struct {
	method, host, uri, origin string
	upgrade                   bool
}

func get(uri string) req { return req{method: "GET", host: "localhost:8899", uri: uri} }

func (r req) at(host string) req     { r.host = host; return r }
func (r req) from(origin string) req { r.origin = origin; return r }
func (r req) upgrading() req         { r.upgrade = true; return r }
func (r req) with(method string) req { r.method = method; return r }
func (r req) header() http.Header {
	h := http.Header{}
	if r.origin != "" {
		h.Set("Origin", r.origin)
	}
	if r.upgrade {
		h.Set("Upgrade", "websocket")
		h.Set("Connection", "Upgrade")
	}
	return h
}
func (r req) judge() verdict { return testGate.judge(r.method, r.host, r.uri, r.header()) }
func (r req) reply() plainReply {
	return testGate.reply(r.method, r.host, r.uri, r.header())
}
func (r req) status() int {
	v := r.judge()
	if v.upgrade {
		return 0
	}
	return v.status
}

func headerValue(headers [][2]string, name string) (string, bool) {
	for _, kv := range headers {
		if kv[0] == name {
			return kv[1], true
		}
	}
	return "", false
}

// 1. Host

func TestAHostThatIsNotThisListenerIsMisdirected(t *testing.T) {
	for _, r := range []req{get("/").at("evil.test:8899"), get("/").at("localhost:1"), get("/").at("localhost"),
		get("/").at(""), get("/v1/connect").at("evil.test:8899").from("http://localhost:8899").upgrading()} {
		if s := r.status(); s != 421 {
			t.Errorf("%+v: %d, want 421", r, s)
		}
	}
	if s := get("/").at("LOCALHOST:8899").status(); s != 200 {
		t.Errorf("upper case host: %d", s)
	}
}

// The views' sandbox proxy (#187)

func TestTheSandboxProxyIsServedOnlyAtItsOwnOrigin(t *testing.T) {
	if v := get("/sandbox.html?csp=e30").at("127.0.0.1:8899").judge(); v != (verdict{status: 200, path: "/sandbox.html"}) {
		t.Errorf("sandbox.html: %+v", v)
	}
	if v := get("/sandbox.js").at("127.0.0.1:8899").judge(); v != (verdict{status: 200, path: "/sandbox.js"}) {
		t.Errorf("sandbox.js: %+v", v)
	}
	for _, r := range []req{get("/sandbox.html"), get("/sandbox.js"), get("/sandbox.html").at("[::1]:8899"),
		get("/sandbox.html").at("127.0.0.1:8899").upgrading()} {
		if s := r.status(); s != 404 {
			t.Errorf("%+v: %d, want 404", r, s)
		}
	}
	// Everything else at the address still goes to the name.
	if v := get("/").at("127.0.0.1:8899").judge(); v != (verdict{status: 308, location: "http://localhost:8899/"}) {
		t.Errorf("/ at the address: %+v", v)
	}
}

func TestTheProxysPolicyIsTheViewsOwn(t *testing.T) {
	csp := func(query string) string {
		reply := get("/sandbox.html" + query).at("127.0.0.1:8899").reply()
		if _, ok := headerValue(reply.headers, "X-Frame-Options"); ok {
			t.Errorf("%q: the proxy has X-Frame-Options", query)
		}
		v, _ := headerValue(reply.headers, "Content-Security-Policy")
		return v
	}
	strict := csp("")
	want := "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
		"img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; " +
		"frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors http://localhost:8899"
	if strict != want {
		t.Errorf("strict:\n%s\nwant\n%s", strict, want)
	}
	declared := base64.RawURLEncoding.EncodeToString(
		[]byte(`{"connectDomains":["https://api.example.com","*"],"frameDomains":["https://a.b"]}`))
	wide := csp("?csp=" + declared)
	for _, part := range []string{"connect-src https://api.example.com;", "frame-src https://a.b;"} {
		if !strings.Contains(wide, part) {
			t.Errorf("wide lacks %q: %s", part, wide)
		}
	}
	if strings.Contains(wide, " *") {
		t.Errorf("wide allows *: %s", wide)
	}
	if got := csp("?csp=%%%not-base64"); got != strict {
		t.Errorf("bad csp: %s", got)
	}
	// The page may frame the proxy and nothing else.
	page, _ := headerValue(testGate.headers(), "Content-Security-Policy")
	if !strings.Contains(page, "frame-src http://127.0.0.1:8899;") {
		t.Errorf("page CSP: %s", page)
	}
}

func TestOriginsAreKeptOnlyWhenPlain(t *testing.T) {
	for text, want := range map[string]string{
		"https://API.example.com/": "https://api.example.com", " wss://*.a.b:443 ": "wss://*.a.b:443",
		"*": "", "https:": "", "ftp://a.b": "", "https://a.b:0": "", "https://a.b:x": "", "https://-a.b": "",
		"https://a.b; script-src *": "", "https://a.b/path": "",
	} {
		got, _ := originOf(text)
		if got != want {
			t.Errorf("originOf(%q) = %q, want %q", text, got, want)
		}
	}
}

// 2. Method

func TestOnlyGETIsAnswered(t *testing.T) {
	for _, method := range []string{"POST", "PUT", "DELETE", "HEAD", "OPTIONS"} {
		if s := get("/").with(method).status(); s != 405 {
			t.Errorf("%s: %d", method, s)
		}
	}
}

// 3. Redirect

func TestTheAddressesRedirectToTheName(t *testing.T) {
	if v := get("/app.js?x=1").at("127.0.0.1:8899").judge(); v != (verdict{status: 308, location: "http://localhost:8899/app.js"}) {
		t.Errorf("v4: %+v", v)
	}
	if v := get("/").at("[::1]:8899").judge(); v != (verdict{status: 308, location: "http://localhost:8899/"}) {
		t.Errorf("v6: %+v", v)
	}
	// Never for an upgrade: the page that dials is on the name already.
	if s := get("/v1/connect").at("127.0.0.1:8899").from("http://localhost:8899").upgrading().status(); s != 421 {
		t.Errorf("upgrade at the address: %d", s)
	}
}

// 4–5. The upgrade

func TestTheUpgradeNeedsThisPagesOrigin(t *testing.T) {
	for _, uri := range []string{"/v1/connect", "/v1/connect?x"} {
		if v := get(uri).from("http://localhost:8899").upgrading().judge(); !v.upgrade {
			t.Errorf("%s: %+v", uri, v)
		}
	}
	for _, origin := range []string{"", "http://evil.test", "http://127.0.0.1:8899", "https://localhost:8899", "null"} {
		if s := get("/v1/connect").from(origin).upgrading().status(); s != 403 {
			t.Errorf("origin %q: %d", origin, s)
		}
	}
}

func TestConnectWithoutAnUpgradeOrAnUpgradeElsewhereIsBad(t *testing.T) {
	if s := get("/v1/connect").status(); s != 400 {
		t.Errorf("no upgrade: %d", s)
	}
	if s := get("/app.js").from("http://localhost:8899").upgrading().status(); s != 400 {
		t.Errorf("upgrade elsewhere: %d", s)
	}
}

// 6–7. Files

func TestTheManifestsFilesAndNothingElse(t *testing.T) {
	if v := get("/").judge(); v != (verdict{status: 200, path: "/index.html"}) {
		t.Errorf("/: %+v", v)
	}
	if v := get("/app.js?v=2").judge(); v != (verdict{status: 200, path: "/app.js"}) {
		t.Errorf("/app.js: %+v", v)
	}
	for _, p := range []string{"/nope", "/MANIFEST", "/../MANIFEST", "/%2e%2e/MANIFEST", "/app.js%00", `/app.js\..\x`,
		"//app.js", "/healthz", "/readyz", "/v1/install.sh", "/v1/servers/agentsd"} {
		if s := get(p).status(); s != 404 {
			t.Errorf("%s: %d", p, s)
		}
	}
}

// Chrome DevTools asks for this by itself (#114). It is a 404 with the headers, and
// connect-src still allows only the page's one WebSocket.
func TestChromeDevToolsProbeIsNotFoundAndWidensNothing(t *testing.T) {
	probe := get("/.well-known/appspecific/com.chrome.devtools.json")
	if s := probe.status(); s != 404 {
		t.Errorf("probe: %d", s)
	}
	reply := probe.reply()
	if len(reply.body) != 0 {
		t.Errorf("probe body: %q", reply.body)
	}
	if _, ok := headerValue(reply.headers, "Content-Security-Policy"); !ok {
		t.Error("probe has no CSP")
	}
	csp, _ := headerValue(testGate.headers(), "Content-Security-Policy")
	var connect []string
	for _, clause := range strings.Split(csp, ";") {
		if c := strings.TrimSpace(clause); strings.HasPrefix(c, "connect-src") {
			connect = append(connect, c)
		}
	}
	if len(connect) != 1 || connect[0] != "connect-src ws://localhost:8899" {
		t.Errorf("connect-src: %v", connect)
	}
}

func TestEveryAnswerCarriesTheHeaders(t *testing.T) {
	for _, r := range []req{get("/"), get("/nope"), get("/").with("POST"), get("/").at("evil:1"),
		get("/").at("127.0.0.1:8899"), get("/v1/connect").upgrading(), get("/v1/connect")} {
		reply := r.reply()
		for _, wanted := range []string{"Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy",
			"Cross-Origin-Opener-Policy", "Cross-Origin-Resource-Policy", "X-Frame-Options", "Cache-Control"} {
			if _, ok := headerValue(reply.headers, wanted); !ok {
				t.Errorf("%s on %d", wanted, reply.status)
			}
		}
	}
	csp, _ := headerValue(testGate.headers(), "Content-Security-Policy")
	want := "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; font-src 'self'; " +
		"connect-src ws://localhost:8899; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; " +
		"frame-src http://127.0.0.1:8899; object-src 'none'; worker-src 'self'; manifest-src 'self'; " +
		"require-trusted-types-for 'script'; trusted-types agents-sw"
	if csp != want {
		t.Errorf("CSP:\n%s\nwant\n%s", csp, want)
	}
	for name, want := range map[string]string{"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
		"Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Resource-Policy": "same-origin",
		"X-Frame-Options": "DENY", "Cache-Control": "no-cache"} {
		if v, _ := headerValue(testGate.headers(), name); v != want {
			t.Errorf("%s: %q", name, v)
		}
	}
}

// FR-032: nothing ambient. No answer sets a cookie or asks for HTTP authentication, and a
// request with either is answered as one without.
func TestNoCookieAndNoHTTPAuthenticationEitherWay(t *testing.T) {
	for _, r := range []req{get("/"), get("/app.js"), get("/nope"), get("/v1/connect"),
		get("/v1/connect").from("http://localhost:8899").upgrading()} {
		h := r.header()
		h.Set("Cookie", "session=stolen")
		h.Set("Authorization", "Basic c3RvbGVu")
		plain := r.reply()
		with := testGate.reply(r.method, r.host, r.uri, h)
		if plain.status != with.status || string(plain.body) != string(with.body) {
			t.Errorf("%s: differs with a cookie", r.uri)
		}
		for _, reply := range []plainReply{plain, with} {
			for _, kv := range reply.headers {
				if n := strings.ToLower(kv[0]); n == "set-cookie" || n == "www-authenticate" {
					t.Errorf("%s: %s", r.uri, kv[0])
				}
			}
		}
	}
}

// The files from the manifest

func hashOf(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func writeManifest(t *testing.T, folder string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(folder, "MANIFEST"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestFilesLoadOnlyWhenTheyMatchTheirManifest(t *testing.T) {
	folder := t.TempDir()
	index := []byte("<!doctype html>")
	os.WriteFile(filepath.Join(folder, "index.html"), index, 0o644)
	writeManifest(t, folder, "agents-web 1", "src abc Web/src/main.tsx", "out "+hashOf(index)+" Web/dist/index.html")
	files, err := LoadFiles(folder)
	if err != nil || len(files) != 1 || files["/index.html"].ContentType != "text/html; charset=utf-8" {
		t.Fatalf("load: %v %v", files, err)
	}

	writeManifest(t, folder, "out "+strings.Repeat("0", 64)+" Web/dist/index.html")
	var failure *FilesError
	if _, err := LoadFiles(folder); !errors.As(err, &failure) || err.Error() != "index.html does not match its manifest" {
		t.Errorf("wrong hash: %v", err)
	}

	os.WriteFile(filepath.Join(folder, "run.sh"), []byte("x"), 0o644)
	writeManifest(t, folder, "out "+hashOf(index)+" Web/dist/index.html", "out "+hashOf([]byte("x"))+" Web/dist/run.sh")
	if _, err := LoadFiles(folder); !errors.As(err, &failure) || err.Error() != "run.sh has a type the web remote never serves" {
		t.Errorf("run.sh: %v", err)
	}

	writeManifest(t, folder, "out "+hashOf(index)+" elsewhere/index.html")
	if _, err := LoadFiles(folder); err == nil || err.Error() != "elsewhere/index.html is not under Web/dist" {
		t.Errorf("outside: %v", err)
	}
	writeManifest(t, folder, "agents-web 1")
	if _, err := LoadFiles(folder); err == nil || err.Error() != "the manifest lists no index.html" {
		t.Errorf("no index: %v", err)
	}
	if _, err := LoadFiles(t.TempDir()); err == nil || !strings.HasSuffix(err.Error(), "MANIFEST is missing") {
		t.Errorf("no manifest: %v", err)
	}
}

// The listener on a real copy

// dist is a built page of its own, laid out as Web/build.mjs lays one out.
func dist(t *testing.T) string {
	t.Helper()
	folder := t.TempDir()
	files := map[string]string{
		"index.html": "<!doctype html><html><head><script type=\"module\" src=\"/app.js\"></script></head><body></body></html>\n",
		"app.js":     "console.log(\"agents\");\n",
	}
	names := []string{"app.js", "index.html"}
	lines := []string{"agents-web 1"}
	for _, name := range names {
		os.WriteFile(filepath.Join(folder, name), []byte(files[name]), 0o644)
		lines = append(lines, "out "+hashOf([]byte(files[name]))+" Web/dist/"+name)
	}
	writeManifest(t, folder, lines...)
	return folder
}

type lines struct {
	mu  sync.Mutex
	all []string
}

func (l *lines) add(s string) { l.mu.Lock(); l.all = append(l.all, s); l.mu.Unlock() }
func (l *lines) has(part string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, s := range l.all {
		if strings.Contains(s, part) {
			return true
		}
	}
	return false
}

func start(t *testing.T, cfg Config) *Listener {
	t.Helper()
	l, err := Start(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(l.Stop)
	return l
}

// noRedirects stops at a redirect rather than following it.
var noRedirects = &http.Client{
	Timeout:       5 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// fetch is a GET to address with the Host header given.
func fetch(t *testing.T, method, address, host, path string) (*http.Response, string) {
	t.Helper()
	r, _ := http.NewRequest(method, "http://"+address+path, nil)
	r.Host = host
	resp, err := noRedirects.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp, string(body)
}

func hasIPv6Loopback() bool {
	ln, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

func TestACopyServesTheBuiltPage(t *testing.T) {
	log := &lines{}
	l := start(t, Config{Folder: dist(t), Log: log.add})
	port := l.Port()
	if l.Origin() != fmt.Sprintf("http://localhost:%d", port) {
		t.Errorf("origin: %s", l.Origin())
	}
	if !log.has("web: serving the web remote at http://localhost:" + fmt.Sprint(port)) {
		t.Errorf("log: %v", log.all)
	}
	v4 := fmt.Sprintf("127.0.0.1:%d", port)
	name := fmt.Sprintf("localhost:%d", port)

	resp, body := fetch(t, "GET", v4, name, "/")
	if resp.StatusCode != 200 || !strings.Contains(body, `<script type="module" src="/app.js">`) {
		t.Errorf("/: %d %q", resp.StatusCode, body)
	}
	for header, want := range map[string]string{"Content-Type": "text/html; charset=utf-8",
		"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cross-Origin-Opener-Policy": "same-origin",
		"Cross-Origin-Resource-Policy": "same-origin", "X-Frame-Options": "DENY", "Cache-Control": "no-cache",
		"Content-Length": fmt.Sprint(len(body))} {
		if got := resp.Header.Get(header); got != want {
			t.Errorf("%s: %q, want %q", header, got, want)
		}
	}
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, fmt.Sprintf("connect-src ws://localhost:%d;", port)) {
		t.Errorf("CSP: %s", csp)
	}
	if !resp.Close {
		t.Error("the connection stays open")
	}
	resp, body = fetch(t, "GET", v4, name, "/app.js")
	if resp.StatusCode != 200 || body != "console.log(\"agents\");\n" || resp.Header.Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Errorf("/app.js: %d %q %s", resp.StatusCode, body, resp.Header.Get("Content-Type"))
	}

	// The address goes to the name.
	resp, _ = fetch(t, "GET", v4, v4, "/app.js")
	if resp.StatusCode != 308 || resp.Header.Get("Location") != fmt.Sprintf("http://localhost:%d/app.js", port) {
		t.Errorf("redirect: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	if resp.Header.Get("Content-Security-Policy") == "" {
		t.Error("the redirect has no CSP")
	}
	// Another Host.
	resp, body = fetch(t, "GET", v4, "evil.test", "/")
	if resp.StatusCode != 421 || body != "" || resp.Header.Get("X-Frame-Options") != "DENY" {
		t.Errorf("evil host: %d %q", resp.StatusCode, body)
	}
	// Anything but GET, and it is logged.
	for _, method := range []string{"POST", "HEAD", "PUT"} {
		if resp, _ := fetch(t, method, v4, name, "/?q=1"); resp.StatusCode != 405 {
			t.Errorf("%s: %d", method, resp.StatusCode)
		}
	}
	if !log.has("web POST / 405") || !log.has("web HEAD / 405") {
		t.Errorf("log: %v", log.all)
	}
	resp, _ = fetch(t, "GET", v4, name, "/MANIFEST")
	if resp.StatusCode != 404 {
		t.Errorf("/MANIFEST: %d", resp.StatusCode)
	}
}

func TestIPv6LoopbackIsServedWhenThereIsOne(t *testing.T) {
	if !hasIPv6Loopback() {
		t.Skip("no ::1 here")
	}
	l := start(t, Config{Folder: dist(t)})
	v6 := fmt.Sprintf("[::1]:%d", l.Port())
	resp, _ := fetch(t, "GET", v6, v6, "/")
	if resp.StatusCode != 308 || resp.Header.Get("Location") != fmt.Sprintf("http://localhost:%d/", l.Port()) {
		t.Errorf("::1: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	resp, _ = fetch(t, "GET", v6, fmt.Sprintf("localhost:%d", l.Port()), "/")
	if resp.StatusCode != 200 {
		t.Errorf("::1 by name: %d", resp.StatusCode)
	}
}

func TestItIsNotReachableOnAnotherAddress(t *testing.T) {
	l := start(t, Config{Folder: dist(t)})
	interfaces, _ := net.InterfaceAddrs()
	tried := 0
	for _, a := range interfaces {
		ip, ok := a.(*net.IPNet)
		if !ok || ip.IP.IsLoopback() || ip.IP.To4() == nil {
			continue
		}
		tried++
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(ip.IP.String(), fmt.Sprint(l.Port())), 2*time.Second)
		if err == nil {
			conn.Close()
			t.Errorf("reached on %s", ip.IP)
		}
	}
	if tried == 0 {
		t.Skip("no other IPv4 address to try")
	}
}

func TestTheSocketIsAcceptedFromThePageOnly(t *testing.T) {
	type arrival struct{ remote, origin string }
	arrived := make(chan arrival, 1)
	l := start(t, Config{Folder: dist(t), Accept: func(ws *websocket.Conn, remote, origin string) {
		defer ws.CloseNow()
		arrived <- arrival{remote, origin}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, data, err := ws.Read(ctx)
		if err == nil {
			ws.Write(ctx, websocket.MessageText, append([]byte("echo "), data...))
		}
	}})
	port := l.Port()
	url := fmt.Sprintf("ws://127.0.0.1:%d/v1/connect", port)
	dial := func(origin string) (*websocket.Conn, *http.Response, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		h := http.Header{}
		if origin != "" {
			h.Set("Origin", origin)
		}
		return websocket.Dial(ctx, url, &websocket.DialOptions{Host: fmt.Sprintf("localhost:%d", port), HTTPHeader: h})
	}

	ws, _, err := dial(l.Origin())
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	select {
	case a := <-arrived:
		if a.origin != fmt.Sprintf("http://localhost:%d", port) || !strings.HasPrefix(a.remote, "127.0.0.1:") {
			t.Errorf("arrival: %+v", a)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Accept was not called")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws.Write(ctx, websocket.MessageText, []byte("hello"))
	if _, data, err := ws.Read(ctx); err != nil || string(data) != "echo hello" {
		t.Errorf("echo: %q %v", data, err)
	}

	for _, origin := range []string{"", "http://evil.test", fmt.Sprintf("http://127.0.0.1:%d", port)} {
		_, resp, err := dial(origin)
		if err == nil || resp == nil || resp.StatusCode != 403 {
			t.Errorf("origin %q: %v %v", origin, resp, err)
		} else if resp.Header.Get("Content-Security-Policy") == "" {
			t.Errorf("origin %q: the 403 has no CSP", origin)
		}
	}
}

// An upgrade the gate lets through but that is not a WebSocket handshake gets a 400.
func TestABrokenHandshakeIsBad(t *testing.T) {
	l := start(t, Config{Folder: dist(t), Accept: func(ws *websocket.Conn, _, _ string) { ws.CloseNow() }})
	r, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/v1/connect", l.Port()), nil)
	r.Host = fmt.Sprintf("localhost:%d", l.Port())
	r.Header.Set("Origin", l.Origin())
	r.Header.Set("Upgrade", "websocket")
	r.Header.Set("Connection", "Upgrade")
	resp, err := noRedirects.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 || resp.Header.Get("Content-Type") != "text/plain" {
		t.Errorf("%d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
}

// Saying whether it serves (071 R3)

func TestABuildThatDoesNotMatchItsManifestLeavesTheListenerOff(t *testing.T) {
	folder := dist(t)
	os.WriteFile(filepath.Join(folder, "app.js"), []byte("/* edited */"), 0o644)
	log := &lines{}
	l, err := Start(Config{Folder: folder, Port: 0, Log: log.add})
	if l != nil || err == nil {
		t.Fatal("served an edited build")
	}
	status := StatusOf(DefaultPort, l, err)
	if !same(status, Status{Port: DefaultPort, Reason: new(ReasonBuild), Detail: new("app.js does not match its manifest")}) {
		t.Errorf("status: %+v", status)
	}
	if !log.has("web: not serving, app.js does not match its manifest") {
		t.Errorf("log: %v", log.all)
	}
	if Summary(status) != "Not serving: this copy of Agents Host’s web app is damaged or missing." {
		t.Errorf("summary: %s", Summary(status))
	}
}

func TestATakenPortIsReportedAsNotServedAndServesOnceItIsFree(t *testing.T) {
	taken, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := taken.Addr().(*net.TCPAddr).Port
	log := &lines{}
	l, err := Start(Config{Folder: dist(t), Port: port, Log: log.add})
	if l != nil {
		t.Fatal("served on a taken port")
	}
	off := StatusOf(port, l, err)
	if off.Port != int64(port) || off.Served || off.Reason == nil || *off.Reason != ReasonPortInUse || off.Detail == nil || *off.Detail == "" {
		t.Errorf("off: %+v", off)
	}
	if Summary(off) != fmt.Sprintf("Not serving: port %d is in use by another app.", port) {
		t.Errorf("summary: %s", Summary(off))
	}
	if !log.has(fmt.Sprintf("web: port %d not bound", port)) {
		t.Errorf("log: %v", log.all)
	}

	taken.Close()
	l = start(t, Config{Folder: dist(t), Port: port})
	on := StatusOf(port, l, nil)
	if !same(on, Status{Port: int64(port), Served: true}) || !same(on, l.Status()) {
		t.Errorf("on: %+v", on)
	}
	if Summary(on) != fmt.Sprintf("At http://localhost:%d, for a browser on this Mac only.", port) {
		t.Errorf("summary: %s", Summary(on))
	}
	if resp, _ := fetch(t, "GET", fmt.Sprintf("127.0.0.1:%d", port), fmt.Sprintf("localhost:%d", port), "/"); resp.StatusCode != 200 {
		t.Errorf("after: %d", resp.StatusCode)
	}
}

// Taken on ::1 alone, by anyone, the listener stays off: a browser may go to ::1 for
// localhost, and would find whatever holds it at this page's origin.
func TestAPortTakenOnIPv6AloneLeavesTheListenerOff(t *testing.T) {
	if !hasIPv6Loopback() {
		t.Skip("no ::1 here")
	}
	taken, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	port := taken.Addr().(*net.TCPAddr).Port
	l, err := Start(Config{Folder: dist(t), Port: port})
	if l != nil {
		l.Stop()
		t.Fatal("served with ::1 taken")
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Skipf("127.0.0.1:%d was taken by someone else: %v", port, err)
	}
	if s := StatusOf(port, l, err); s.Reason == nil || *s.Reason != ReasonPortInUse {
		t.Errorf("status: %+v", s)
	}
	// And 127.0.0.1 on that port was let go.
	again, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("127.0.0.1 is still held: %v", err)
	}
	again.Close()
}

func TestStatusJSONIsTheSwifts(t *testing.T) {
	for _, c := range []struct {
		status Status
		want   string
	}{
		{Status{Port: 8792, Served: true}, `{"port":8792,"served":true}`},
		{Status{Port: 8792, Reason: new(ReasonPortInUse)}, `{"port":8792,"served":false,"reason":"portInUse"}`},
		{Status{Port: 8792, Reason: new(ReasonFailed), Detail: new("no such file")}, `{"port":8792,"served":false,"reason":"failed","detail":"no such file"}`},
	} {
		data, _ := json.Marshal(c.status)
		if string(data) != c.want {
			t.Errorf("%s, want %s", data, c.want)
		}
		var back Status
		if json.Unmarshal(data, &back) != nil || !same(back, c.status) {
			t.Errorf("round trip: %+v", back)
		}
	}
	failed := Status{Port: 1, Reason: new(ReasonFailed), Detail: new("x")}
	if Summary(failed) != "Not serving: port 1 couldn’t be opened (x)." {
		t.Errorf("summary: %s", Summary(failed))
	}
	if Summary(Status{Port: 1, Reason: new(ReasonFailed)}) != "Not serving: port 1 couldn’t be opened." {
		t.Error("summary without detail")
	}
}

// same is whether two statuses say the same on the wire.
func same(a, b Status) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// The page's origin as a browser writes it (#1459): no port when it is https's own, and
// only https.
func TestPageOrigin(t *testing.T) {
	for address, want := range map[string]string{
		"https://Agents.Example.com":      "https://agents.example.com",
		"https://agents.example.com:443/": "https://agents.example.com",
		"https://agents.test:8444":        "https://agents.test:8444",
		"wss://agents.example.com/v1/x":   "https://agents.example.com",
	} {
		if got, _, err := PageOrigin(address); err != nil || got != want {
			t.Errorf("%s: %q %v", address, got, err)
		}
	}
	for _, address := range []string{"http://agents.example.com", "https://", "nonsense"} {
		if _, _, err := PageOrigin(address); err == nil {
			t.Errorf("%s was taken", address)
		}
	}
}

// The page on the control plane's own domain draws views through the sandbox proxy at a
// second name (#1484): the proxy's two files there only, under the view's own policy and
// framed by the page only; the page frames that origin and nothing else.
func TestThePublicPagesViewsAreAtTheViewsNameOnly(t *testing.T) {
	p := &Public{origin: "https://agents.test:8444", host: "agents.test:8444",
		viewsOrigin: "https://views.test:8444", viewsHost: "views.test:8444", files: testGate.files}
	serve := func(method, host, uri string, upgrade bool) (*httptest.ResponseRecorder, bool) {
		r := httptest.NewRequest(method, uri, nil)
		r.Host = host
		if upgrade {
			r.Header.Set("Upgrade", "websocket")
		}
		w := httptest.NewRecorder()
		return w, p.Serve(w, r)
	}
	w, ok := serve("GET", "Views.Test:8444", "/sandbox.html?csp=e30", false)
	csp := w.Header().Get("Content-Security-Policy")
	if !ok || w.Code != 200 || w.Body.String() != "<!doctype html>" ||
		!strings.HasSuffix(csp, "; frame-ancestors https://agents.test:8444") || !strings.Contains(csp, "connect-src 'none'") ||
		w.Header().Get("X-Frame-Options") != "" || w.Header().Get("Strict-Transport-Security") == "" {
		t.Fatalf("sandbox.html: %v %d %v", ok, w.Code, w.Header())
	}
	if w, ok := serve("GET", "views.test:8444", "/sandbox.js", false); !ok || w.Code != 200 {
		t.Fatalf("sandbox.js: %v %d", ok, w.Code)
	}
	if w, ok := serve("POST", "views.test:8444", "/sandbox.js", false); !ok || w.Code != 405 {
		t.Fatalf("POST: %v %d", ok, w.Code)
	}
	// Nothing else at the views name, and no socket there.
	for _, uri := range []string{"/", "/index.html", "/app.js", "/sandbox.html"} {
		if _, ok := serve("GET", "views.test:8444", uri, uri == "/sandbox.html"); ok {
			t.Errorf("%s answered at the views name", uri)
		}
	}
	// The proxy's files are refused at the page's own name.
	for _, uri := range []string{"/sandbox.html", "/sandbox.js"} {
		if _, ok := serve("GET", "agents.test:8444", uri, false); ok {
			t.Errorf("%s answered at the page's name", uri)
		}
	}
	w, ok = serve("GET", "agents.test:8444", "/", false)
	if page := w.Header().Get("Content-Security-Policy"); !ok || !strings.Contains(page, "frame-src https://views.test:8444;") {
		t.Errorf("page CSP: %s", page)
	}
	if p.ViewsOrigin() != "https://views.test:8444" {
		t.Error(p.ViewsOrigin())
	}
}

// A views address must be https, and not the page's own origin.
func TestTheViewsNameIsAnotherHTTPSOrigin(t *testing.T) {
	for _, views := range []string{"http://views.test", "https://agents.test:8444/", "nonsense"} {
		if _, err := NewPublic(t.TempDir(), "https://agents.test:8444", views); err == nil {
			t.Errorf("%s was taken", views)
		}
	}
}
