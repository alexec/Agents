package agentsd

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Org routes on the machine (#999, spec 999 slice 2, T013–T019): kept sealed, listed as
// accounts, reached through the model relay with a stand-in, never in the runtime's hands;
// the policy's reach; Antigravity's terms; replace, remove and offline.

const orgTestHost = "host-1"

// orgMachine is a daemon on a root that joined a control plane as orgTestHost, with its
// own key, trusting k for the policy; and that key's public half, to seal to.
func orgMachine(t *testing.T, root string, k controlKeys) (*Daemon, *conn, []byte) {
	t.Helper()
	_, public := machineKeys(t, root)
	d, c := joined(t, root, k)
	return d, c, public
}

// machineKeys writes a joined machine's membership and key into root.
func machineKeys(t *testing.T, root string) ([]byte, []byte) {
	t.Helper()
	keyFile := filepath.Join(root, "control-host-key")
	private, err := os.ReadFile(keyFile)
	if err != nil {
		private = controllink.NewPrivateKey()
		os.WriteFile(keyFile, private, 0o600)
	}
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	if err := (&controllink.Membership{Host: orgTestHost, Name: "Scratch"}).Save(root); err != nil {
		t.Fatal(err)
	}
	return private, public
}

// sealTo is the control plane's seal of one value for a machine (FR-005).
func sealTo(t *testing.T, public []byte, route, host string, version int64, value string) wire.SealedEnvelope {
	t.Helper()
	key, err := ecdh.P256().NewPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	recipient, err := hpke.NewDHKEMPublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	enc, sender, err := hpke.NewSender(recipient, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(orgRoutePurpose))
	if err != nil {
		t.Fatal(err)
	}
	ct, err := sender.Seal(orgRouteAD(route, host, version), []byte(value))
	if err != nil {
		t.Fatal(err)
	}
	return wire.SealedEnvelope{Encapsulated: enc, Ciphertext: ct}
}

// testRoute is a delivered route of a kind, for runtimes, its secrets sealed to public.
func testRoute(t *testing.T, public []byte, id string, version int64, kind wire.OrgRouteKind, vendor wire.OrgRouteVendor,
	address string, secrets map[string]string, runtimes ...string) wire.DeliveredRoute {
	t.Helper()
	r := wire.DeliveredRoute{ID: id, Name: "Acme " + id, Kind: kind, Runtimes: runtimes, DefaultFor: []string{}, Version: version,
		Sealed: map[string]wire.SealedEnvelope{}, Settings: &wire.OrgRouteSettings{}}
	if vendor != "" {
		r.Vendor = &vendor
	}
	if address != "" {
		r.Settings.Address = &address
	}
	switch kind {
	case wire.OrgRouteKindBedrock:
		r.Settings.Region = new("us-east-1")
	case wire.OrgRouteKindVertex:
		r.Settings.Project, r.Settings.Location = new("acme-proj"), new("us-east5")
	}
	for field, v := range secrets {
		r.SecretFields = append(r.SecretFields, field)
		r.Sealed[field] = sealTo(t, public, id, orgTestHost, version, v)
	}
	return r
}

func deliver(t *testing.T, d *Daemon, routes ...wire.DeliveredRoute) {
	t.Helper()
	if routes == nil {
		routes = []wire.DeliveredRoute{}
	}
	b, _ := json.Marshal(wire.OrgRouteDelivery{Routes: routes, At: now()})
	d.Told(wire.NotifyMachineOrgRoutes.Name, b)
}

// fakeProvider is a model provider on loopback: it keeps each request's headers, path and
// body, and answers with answer.
type fakeProvider struct {
	*httptest.Server
	mu       sync.Mutex
	requests []*http.Request
	bodies   [][]byte
	answer   func(w http.ResponseWriter, r *http.Request)
}

func newFakeProvider(t *testing.T) *fakeProvider {
	t.Helper()
	p := &fakeProvider{}
	p.answer = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"type":"message","role":"assistant","content":[{"type":"text","text":"Hi."}],"usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}`)
	}
	p.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		p.mu.Lock()
		p.requests = append(p.requests, r.Clone(r.Context()))
		p.bodies = append(p.bodies, b)
		answer := p.answer
		p.mu.Unlock()
		answer(w, r)
	}))
	t.Cleanup(p.Close)
	return p
}

func (p *fakeProvider) last(t *testing.T) (*http.Request, []byte) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.requests) == 0 {
		t.Fatal("the provider got nothing")
	}
	return p.requests[len(p.requests)-1], p.bodies[len(p.bodies)-1]
}

func (p *fakeProvider) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.requests)
}

// relayClient trusts the relay's CA, as a runtime is told to.
func relayClient(t *testing.T, d *Daemon) *http.Client {
	t.Helper()
	r, err := d.relay()
	if err != nil {
		t.Fatal(err)
	}
	ca, err := os.ReadFile(r.caFile)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Transport: &http.Transport{TLSClientConfig: tlsTrusting(t, ca)}, Timeout: 20 * time.Second}
}

// envOf is a launch environment as a map.
func envOf(env []string) map[string]string {
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	return m
}

// leaks is where a key is found, in its bytes, base64 or hex (SC-003).
func leaks(key string, where string, b []byte) []string {
	var found []string
	for _, form := range []string{key, base64.StdEncoding.EncodeToString([]byte(key)), base64.RawURLEncoding.EncodeToString([]byte(key)),
		hex.EncodeToString([]byte(key))} {
		if bytes.Contains(b, []byte(form)) {
			found = append(found, where)
		}
	}
	return found
}

// leaksUnder searches every file under a folder.
func leaksUnder(t *testing.T, key, dir string) []string {
	t.Helper()
	var found []string
	filepath.WalkDir(dir, func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() || e.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if b, err := os.ReadFile(path); err == nil {
			found = append(found, leaks(key, path, b)...)
		}
		return nil
	})
	return found
}

// US1, SC-001: no route, no change: no org account, no relay, the same launch.
func TestNoOrgRouteChangesNothing(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c, _ := orgMachine(t, root, newControlKeys(t))
	before := map[string][]string{}
	for i := range catalog {
		l, err := d.launchAs(&catalog[i], root, nil)
		if err != nil {
			t.Fatal(err)
		}
		before[catalog[i].ID] = l.Env
	}
	var told []string
	var mu sync.Mutex
	d.SetControl(func(method string, params any) { mu.Lock(); told = append(told, method); mu.Unlock() })
	deliver(t, d)
	var list []wire.AccountProfile
	json.Unmarshal(c.call(t, 1, "runtimes/accountProfiles", map[string]any{}), &list)
	if len(list) != 0 {
		t.Fatalf("%+v", list)
	}
	for i := range catalog {
		l, _ := d.launchAs(&catalog[i], root, nil)
		a, b := slices.Sorted(slices.Values(before[catalog[i].ID])), slices.Sorted(slices.Values(l.Env))
		if !slices.Equal(a, b) {
			t.Fatalf("%s's launch changed", catalog[i].ID)
		}
	}
	if d.modelRelay != nil {
		t.Fatal("a relay with no route")
	}
	if _, err := os.Stat(filepath.Join(root, orgRoutesFolder)); err == nil {
		t.Fatal("a routes folder with no route")
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.Contains(told, wire.CallMachineOrgRoutesApplied.Name) {
		t.Fatalf("%v", told)
	}
	if !slices.Contains(d.Capabilities(), wire.CapHostOrgRoutes1) {
		t.Fatal("the machine does not say host.org-routes/1")
	}
}

// T013, SC-003: for each runtime and kind it builds, the runtime's environment and every
// file under the root hold no part of the key; a session that prints its environment
// puts no key in the transcript, the events, the log or a message to a client; and the
// provider sees the key.
func TestTheOrgKeyLeaksNowhere(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	var logged bytes.Buffer
	var logMu sync.Mutex
	restoreLog := captureLog(&logged, &logMu)
	defer restoreLog()
	d, c, public := orgMachine(t, root, newControlKeys(t))
	p := newFakeProvider(t)
	const key = "sk-org-Zq8vLm3Np0RtUw5Xy7"
	var routes []wire.DeliveredRoute
	type row struct {
		runtime string
		kind    wire.OrgRouteKind
		vendor  wire.OrgRouteVendor
	}
	var rows []row
	for runtime, kinds := range orgRouteRows {
		for _, kind := range kinds {
			vendor := orgRouteVendors[runtime][0]
			id := strings.ToLower(runtime + "-" + string(kind))
			secrets := map[string]string{"apiKey": key}
			switch kind {
			case wire.OrgRouteKindVertex:
				secrets = map[string]string{"googleToken": key}
			}
			routes = append(routes, testRoute(t, public, id, 1, kind, vendor, p.URL, secrets, runtime))
			rows = append(rows, row{runtime, kind, vendor})
		}
	}
	deliver(t, d, routes...)
	for _, r := range rows {
		id := orgAccountPrefix + strings.ToLower(r.runtime+"-"+string(r.kind))
		account := d.accountProfile(r.runtime, id)
		if account == nil {
			t.Fatalf("%s has no account %s", r.runtime, id)
		}
		l, err := d.launchOn(runtimeByID(r.runtime), root, account, "")
		if err != nil {
			t.Fatalf("%s %s: %v", r.runtime, r.kind, err)
		}
		if found := leaks(key, r.runtime+" "+string(r.kind)+" environment", []byte(strings.Join(l.Env, "\n"))); len(found) > 0 {
			t.Fatalf("%v", found)
		}
	}
	if found := leaksUnder(t, key, root); len(found) > 0 {
		t.Fatalf("%v", found)
	}

	// A session on the Claude key route, whose runtime calls the model through the relay
	// and prints its whole environment into the chat.
	dir := t.TempDir()
	var heard bytes.Buffer
	var id wire.UUID
	json.Unmarshal(c.call(t, 2, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir, "prompt": "call the model",
		"startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}, "accountID": "org:claude-key"}), &id)
	c.until(t, "the turn's end", func(method string, params json.RawMessage) bool {
		heard.Write(params)
		return ended(id, wire.AgentStateFinished)(method, params)
	})
	got, _ := p.last(t)
	if got.Header.Get("X-Api-Key") != key || got.Header.Get("Authorization") != "" {
		t.Fatalf("the provider did not get the key: %v", got.Header)
	}
	transcript := transcriptText(t, d, id)
	if !strings.Contains(transcript, "ANTHROPIC_AUTH_TOKEN=agents-relay-") || !strings.Contains(transcript, "The model said 200") {
		t.Fatalf("the runtime did not reach the relay: %s", transcript)
	}
	logMu.Lock()
	found := leaks(key, "daemon.log", logged.Bytes())
	logMu.Unlock()
	found = append(found, leaks(key, "a message to a client", heard.Bytes())...)
	found = append(found, leaks(key, "the transcript", []byte(transcript))...)
	found = append(found, leaksUnder(t, key, root)...)
	found = append(found, leaksUnder(t, key, home)...)
	if len(found) > 0 {
		t.Fatalf("the key was found: %v", found)
	}
}

// T014: the relay puts in each kind's credential and takes the stand-in out; a wrong
// stand-in gets 401 and sends nothing; a body over 32 MiB is refused; an answer streams.
func TestTheModelRelay(t *testing.T) {
	root := t.TempDir()
	d, _, public := orgMachine(t, root, newControlKeys(t))
	p := newFakeProvider(t)
	cases := []struct {
		id      string
		kind    wire.OrgRouteKind
		vendor  wire.OrgRouteVendor
		secrets map[string]string
		header  string
		want    string
	}{
		{"anthropic-key", wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, map[string]string{"apiKey": "ak"}, "X-Api-Key", "ak"},
		{"openai-key", wire.OrgRouteKindKey, wire.OrgRouteVendorOpenai, map[string]string{"apiKey": "ok"}, "Authorization", "Bearer ok"},
		{"gemini-key", wire.OrgRouteKindKey, wire.OrgRouteVendorGemini, map[string]string{"apiKey": "gk"}, "X-Goog-Api-Key", "gk"},
		{"bedrock-key", wire.OrgRouteKindBedrock, "", map[string]string{"apiKey": "bk"}, "Authorization", "Bearer bk"},
		{"vertex", wire.OrgRouteKindVertex, "", map[string]string{"googleToken": "ya29.t"}, "Authorization", "Bearer ya29.t"},
		{"azure-openai", wire.OrgRouteKindAzure, wire.OrgRouteVendorOpenai, map[string]string{"apiKey": "zk"}, "Api-Key", "zk"},
		{"azure-entra", wire.OrgRouteKindAzure, wire.OrgRouteVendorOpenai, map[string]string{"entraToken": "et"}, "Authorization", "Bearer et"},
		{"gateway", wire.OrgRouteKindBaseURL, wire.OrgRouteVendorOpenai, map[string]string{"apiKey": "gw"}, "Authorization", "Bearer gw"},
	}
	var routes []wire.DeliveredRoute
	for _, k := range cases {
		routes = append(routes, testRoute(t, public, k.id, 1, k.kind, k.vendor, p.URL, k.secrets, "claude"))
	}
	custom := testRoute(t, public, "custom-header", 1, wire.OrgRouteKindBaseURL, wire.OrgRouteVendorAnthropic, p.URL+"/litellm",
		map[string]string{"apiKey": "ck"}, "claude")
	custom.Settings.Header = new("X-Litellm-Key")
	routes = append(routes, custom)
	session := testRoute(t, public, "bedrock-session", 1, wire.OrgRouteKindBedrock, "", p.URL,
		map[string]string{"awsSession": `{"accessKeyId":"ASIAEXAMPLE","secretAccessKey":"s3cr3t","sessionToken":"tok"}`}, "claude")
	routes = append(routes, session)
	deliver(t, d, routes...)
	r, err := d.relay()
	if err != nil {
		t.Fatal(err)
	}
	client := relayClient(t, d)
	base := "https://127.0.0.1:" + strconv.Itoa(r.port)
	send := func(route, standIn, path string, body []byte, header string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest("POST", base+"/"+route+path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if header != "" {
			req.Header.Set(header, standIn)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp
	}
	for _, k := range cases {
		token := r.standInFor(standIn{route: k.id, runtime: "claude", account: "org:" + k.id})
		if resp := send(k.id, token, "/v1/messages", []byte(`{"model":"m"}`), "Authorization"); resp.StatusCode != 200 {
			t.Fatalf("%s: %d", k.id, resp.StatusCode)
		}
		got, _ := p.last(t)
		if got.Header.Get(k.header) != k.want || strings.Contains(strings.Join(flatHeaders(got.Header), "\n"), token) {
			t.Fatalf("%s: %v", k.id, got.Header)
		}
	}
	// A base URL with the header it names, and the path after the route's address.
	token := r.standInFor(standIn{route: "custom-header", runtime: "claude", account: "org:custom-header"})
	send("custom-header", token, "/v1/messages", []byte(`{}`), "X-Api-Key")
	if got, _ := p.last(t); got.Header.Get("X-Litellm-Key") != "ck" || got.Header.Get("X-Api-Key") != "" || got.URL.Path != "/litellm/v1/messages" {
		t.Fatalf("%v %s", got.Header, got.URL.Path)
	}
	// Bedrock with an AWS session: signed, the stand-in in the path, the model's colon kept.
	token = r.standInFor(standIn{route: "bedrock-session", runtime: "claude", account: "org:bedrock-session"})
	send("bedrock-session", token, "/~"+token+"/model/us.anthropic.claude-v2:1/invoke", []byte(`{}`), "")
	got, _ := p.last(t)
	if auth := got.Header.Get("Authorization"); !strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential=ASIAEXAMPLE/") ||
		!strings.Contains(auth, "/us-east-1/bedrock/aws4_request") || got.Header.Get("X-Amz-Security-Token") != "tok" ||
		got.URL.EscapedPath() != "/model/us.anthropic.claude-v2%3A1/invoke" {
		t.Fatalf("%v %s", got.Header, got.URL.EscapedPath())
	}

	// A wrong stand-in, another route's, or none: 401, and nothing sent on.
	n := p.count()
	other := r.standInFor(standIn{route: "openai-key", runtime: "claude", account: "org:openai-key"})
	for _, s := range []struct{ route, token string }{{"anthropic-key", "agents-relay-wrong"}, {"anthropic-key", other}, {"anthropic-key", ""}} {
		if resp := send(s.route, s.token, "/v1/messages", []byte(`{}`), "X-Api-Key"); resp.StatusCode != 401 {
			t.Fatalf("%+v: %d", s, resp.StatusCode)
		}
	}
	if p.count() != n {
		t.Fatal("a refused request was sent on")
	}
	// Over 32 MiB: refused, nothing sent on.
	token = r.standInFor(standIn{route: "anthropic-key", runtime: "claude", account: "org:anthropic-key"})
	if resp := send("anthropic-key", token, "/v1/messages", bytes.Repeat([]byte("a"), relayMostBody+1), "X-Api-Key"); resp.StatusCode != 413 {
		t.Fatalf("%d", resp.StatusCode)
	}
	if p.count() != n {
		t.Fatal("a body over 32 MiB was sent on")
	}

	// An answer streams: the first event reaches the runtime before the provider ends.
	release := make(chan struct{})
	p.mu.Lock()
	p.answer = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n")
		w.(http.Flusher).Flush()
		<-release
		io.WriteString(w, "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n")
	}
	p.mu.Unlock()
	req, _ := http.NewRequest("POST", base+"/anthropic-key/v1/messages", strings.NewReader(`{"stream":true}`))
	req.Header.Set("X-Api-Key", token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	first := make([]byte, 64)
	if n, _ := resp.Body.Read(first); !strings.Contains(string(first[:n]), "message_start") {
		t.Fatalf("%q", first[:n])
	}
	close(release)
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}

// tlsTrusting is a TLS config that trusts one CA.
func tlsTrusting(t *testing.T, caPEM []byte) *tls.Config {
	t.Helper()
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("no CA")
	}
	return &tls.Config{RootCAs: pool}
}

func flatHeaders(h http.Header) []string {
	var out []string
	for k, v := range h {
		out = append(out, k+": "+strings.Join(v, ","))
	}
	return out
}

// lockedWriter is a log's output a test reads while the daemon writes it.
type lockedWriter struct {
	mu *sync.Mutex
	b  *bytes.Buffer
}

func (w lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

// captureLog sends the daemon's log to b too, as daemon.log has it.
func captureLog(b *bytes.Buffer, mu *sync.Mutex) func() {
	old := log.Writer()
	log.SetOutput(io.MultiWriter(old, lockedWriter{mu, b}))
	return func() { log.SetOutput(old) }
}

// transcriptText is a session's whole transcript as the clients read it.
func transcriptText(t *testing.T, d *Daemon, id wire.UUID) string {
	t.Helper()
	entries, _, err := d.Store.Transcript(id, 0)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(entries)
	return string(b)
}

// T015: each runtime's launch on an org account: its own variables from the login
// environment and the pass-through out first, then the relay, the stand-in and the
// gateway's switches; the 056 relay is not used for it, and still is for the own sign-in.
func TestEachRuntimesOrgLaunch(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	t.Setenv("ANTHROPIC_API_KEY", "sk-person")
	t.Setenv("ANTHROPIC_BASE_URL", "https://person.example")
	t.Setenv("OPENAI_API_KEY", "sk-person-openai")
	t.Setenv("GEMINI_API_KEY", "person-gemini")
	t.Setenv("AWS_PROFILE", "person")
	d, _, public := orgMachine(t, root, newControlKeys(t))
	d.mu.Lock()
	d.relays["claude"] = &relay{port: 9, standIn: "lent", caFile: "/lent-ca.pem"}
	d.mu.Unlock()
	routes := []wire.DeliveredRoute{
		testRoute(t, public, "ckey", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, "", map[string]string{"apiKey": "k"}, "claude"),
		testRoute(t, public, "cbed", 1, wire.OrgRouteKindBedrock, "", "", map[string]string{"apiKey": "k"}, "claude"),
		testRoute(t, public, "cvtx", 1, wire.OrgRouteKindVertex, "", "", map[string]string{"googleToken": "k"}, "claude", "gemini"),
		testRoute(t, public, "caz", 1, wire.OrgRouteKindAzure, wire.OrgRouteVendorAnthropic, "", map[string]string{"apiKey": "k"}, "claude"),
		testRoute(t, public, "xkey", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorOpenai, "", map[string]string{"apiKey": "k"}, "codex", "opencode"),
		testRoute(t, public, "gkey", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorGemini, "", map[string]string{"apiKey": "k"}, "gemini"),
		// Not built here: OpenCode on Bedrock, and a vendor Claude does not speak.
		testRoute(t, public, "obed", 1, wire.OrgRouteKindBedrock, "", "", map[string]string{"apiKey": "k"}, "opencode"),
		testRoute(t, public, "cwrong", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorOpenai, "", map[string]string{"apiKey": "k"}, "claude"),
	}
	deliver(t, d, routes...)
	rl, _ := d.relay()
	base := "https://127.0.0.1:" + strconv.Itoa(rl.port)
	launch := func(runtime, account string) map[string]string {
		t.Helper()
		p := d.accountProfile(runtime, account)
		if p == nil {
			t.Fatalf("%s has no %s", runtime, account)
		}
		l, err := d.launchAs(runtimeByID(runtime), root, p)
		if err != nil {
			t.Fatal(err)
		}
		return envOf(l.Env)
	}
	person := func(e map[string]string) {
		t.Helper()
		for _, v := range []string{"sk-person", "https://person.example", "sk-person-openai", "person-gemini"} {
			for k, got := range e {
				if got == v {
					t.Fatalf("%s=%s from the person reached an org launch", k, v)
				}
			}
		}
		if _, ok := e["AWS_PROFILE"]; ok {
			t.Fatal("AWS_PROFILE reached an org launch")
		}
		if e["NODE_EXTRA_CA_CERTS"] == "/lent-ca.pem" || strings.Contains(e["ANTHROPIC_BASE_URL"], ":9") {
			t.Fatal("the 056 relay was used for an org account")
		}
	}
	e := launch("claude", "org:ckey")
	person(e)
	if e["ANTHROPIC_BASE_URL"] != base+"/ckey" || !strings.HasPrefix(e["ANTHROPIC_AUTH_TOKEN"], "agents-relay-") ||
		e["NODE_EXTRA_CA_CERTS"] != rl.caFile || !strings.HasPrefix(e["CLAUDE_CONFIG_DIR"], filepath.Join(root, "runtimes", "org", "claude")) {
		t.Fatalf("%v", e)
	}
	e = launch("claude", "org:cbed")
	person(e)
	if e["CLAUDE_CODE_USE_BEDROCK"] != "1" || e["CLAUDE_CODE_SKIP_BEDROCK_AUTH"] != "1" || e["AWS_REGION"] != "us-east-1" ||
		!strings.HasPrefix(e["ANTHROPIC_BEDROCK_BASE_URL"], base+"/cbed/~agents-relay-") {
		t.Fatalf("%v", e)
	}
	e = launch("claude", "org:cvtx")
	if e["CLAUDE_CODE_USE_VERTEX"] != "1" || e["CLAUDE_CODE_SKIP_VERTEX_AUTH"] != "1" || e["ANTHROPIC_VERTEX_PROJECT_ID"] != "acme-proj" ||
		e["CLOUD_ML_REGION"] != "us-east5" || !strings.HasPrefix(e["ANTHROPIC_VERTEX_BASE_URL"], base+"/cvtx/~") {
		t.Fatalf("%v", e)
	}
	e = launch("claude", "org:caz")
	if e["CLAUDE_CODE_USE_FOUNDRY"] != "1" || e["CLAUDE_CODE_SKIP_FOUNDRY_AUTH"] != "1" || !strings.HasPrefix(e["ANTHROPIC_FOUNDRY_BASE_URL"], base+"/caz/~") {
		t.Fatalf("%v", e)
	}
	e = launch("codex", "org:xkey")
	person(e)
	config, _ := os.ReadFile(filepath.Join(e["CODEX_HOME"], "config.toml"))
	if !strings.Contains(string(config), `base_url = "`+base+`/xkey/v1"`) || !strings.Contains(string(config), `env_key = "AGENTS_ORG_STAND_IN"`) ||
		e["CODEX_CA_CERTIFICATE"] != rl.caFile || !strings.HasPrefix(e[orgStandInVariable], "agents-relay-") ||
		strings.Contains(string(config), e[orgStandInVariable]) {
		t.Fatalf("%v %s", e, config)
	}
	e = launch("gemini", "org:gkey")
	person(e)
	settings, _ := os.ReadFile(filepath.Join(e["GEMINI_CLI_HOME"], ".gemini", "settings.json"))
	if e["GOOGLE_GEMINI_BASE_URL"] != base+"/gkey" || !strings.HasPrefix(e["GEMINI_API_KEY"], "agents-relay-") ||
		!strings.Contains(string(settings), `"gemini-api-key"`) {
		t.Fatalf("%v %s", e, settings)
	}
	e = launch("gemini", "org:cvtx")
	settings, _ = os.ReadFile(filepath.Join(e["GEMINI_CLI_HOME"], ".gemini", "settings.json"))
	if e["GOOGLE_GENAI_USE_VERTEXAI"] != "true" || e["GOOGLE_VERTEX_BASE_URL"] != base+"/cvtx" || e["GOOGLE_CLOUD_PROJECT"] != "acme-proj" ||
		!strings.Contains(string(settings), `"vertex-ai"`) {
		t.Fatalf("%v %s", e, settings)
	}
	e = launch("opencode", "org:xkey")
	person(e)
	oc, _ := os.ReadFile(e["OPENCODE_CONFIG"])
	if !strings.Contains(string(oc), base+"/xkey/v1") || !strings.Contains(string(oc), "{env:AGENTS_ORG_STAND_IN}") {
		t.Fatalf("%v %s", e, oc)
	}
	if d.accountProfile("opencode", "org:obed") != nil || d.accountProfile("claude", "org:cwrong") != nil {
		t.Fatal("an org account the machine does not build")
	}
	// The own sign-in still goes through the lent sign-in, as before (FR-014).
	l, _ := d.launchAs(runtimeByID("claude"), root, nil)
	own := envOf(l.Env)
	if own["ANTHROPIC_BASE_URL"] != "https://127.0.0.1:9" || own["NODE_EXTRA_CA_CERTS"] != "/lent-ca.pem" {
		t.Fatalf("%v", own)
	}
}

// T016, SC-004: "the org path only" for Claude: no way to a sign-in account on any path,
// none of the person's own variables, the org default taken where none is named.
func TestTheOrgPathOnly(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c, public := orgMachine(t, root, k)
	os.MkdirAll(d.SettingsDir, 0o755)
	d.Told(wire.NotifyMachinePolicy.Name, k.signed(t, 1, map[string]any{
		"runtimes": map[string]any{"claude": map[string]any{"reach": []string{"orgKey", "gateway"}}}, "requires": []string{wire.CapHostPolicy1, wire.CapHostOrgRoutes1}}))
	dir := t.TempDir()
	// No route here yet: refused with orgRouteMissing.
	if e := c.callError(t, 1, "agents/start", startParams(dir, "claude", nil)); e == nil || e.Code != wire.FailureOrgRouteMissing {
		t.Fatalf("%+v", e)
	}
	r := testRoute(t, public, "acme-bedrock", 1, wire.OrgRouteKindBedrock, "", "", map[string]string{"apiKey": "k"}, "claude")
	deliver(t, d, r)
	var added wire.AccountProfile
	json.Unmarshal(c.call(t, 2, "runtimes/addAccount", map[string]any{"runtimeID": "claude", "name": "Work"}), &added)
	// The own sign-in, named, and an added account: refused, with the route to use.
	for i, account := range []string{"default", added.ID} {
		p := startParams(dir, "claude", nil)
		p["accountID"] = account
		e := c.callError(t, 10+i, "agents/start", p)
		refused(t, e, "policy", "runtimes.claude.reach")
		if !strings.Contains(e.Message, "Your organisation requires Claude to use Acme acme-bedrock.") {
			t.Fatalf("%s", e.Message)
		}
	}
	// None named: the org default, the route.
	var id wire.UUID
	json.Unmarshal(c.call(t, 20, "agents/start", startParams(dir, "claude", nil)), &id)
	if a := d.Store.Agent(id); a == nil || a.AccountID == nil || *a.AccountID != "org:acme-bedrock" {
		t.Fatalf("%+v", a)
	}
	c.until(t, "its end", ended(id, wire.AgentStateFinished))
	// A helper of a session on the own sign-in (started before the policy) takes the org
	// account, and says so; Continue in New and Branch of that session are refused.
	old := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeSessionID = new("fake-session") })
	helper, err := d.startFor(wire.StartRequest{RuntimeID: "claude", Cwd: store.FolderURL(dir), Prompt: "help",
		StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}}, Attachments: []wire.Attachment{},
		AdditionalDirectories: nil, McpServers: []wire.MCPServer{}, Labels: []string{}},
		startedBy{agent: &old.ID, owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		t.Fatal(err)
	}
	if a := d.Store.Agent(helper); *a.AccountID != "org:acme-bedrock" || !strings.Contains(transcriptText(t, d, helper), "It runs on Acme acme-bedrock") {
		t.Fatalf("%+v", a)
	}
	if err := d.promptRefusal(&old); err == nil || !strings.Contains(err.Error(), "Continue in New") {
		t.Fatalf("%v", err)
	}
	if e := c.callError(t, 21, "agents/branchFrom", map[string]any{"agentID": old.ID, "prompt": "x"}); e == nil || e.Code != wire.FailurePolicyRefused {
		t.Fatalf("%+v", e)
	}
	// Reaches the Model By: the own sign-in is refused, the route is taken.
	refused(t, c.callError(t, 22, "runtimes/setDefaultAccount", map[string]any{"runtimeID": "claude", "accountID": "default"}), "policy", "runtimes.claude.reach")
	c.call(t, 23, "runtimes/setDefaultAccount", map[string]any{"runtimeID": "claude", "accountID": "org:acme-bedrock"})
	var list []wire.AccountProfile
	json.Unmarshal(c.call(t, 24, "runtimes/accountProfiles", map[string]any{}), &list)
	for _, p := range list {
		switch p.ID {
		case "org:acme-bedrock":
			if p.SetBy != nil || p.IsDefault == nil || !*p.IsDefault || p.Source == nil || *p.Source != "organisation" || p.Reach.Gateway == nil {
				t.Fatalf("%+v", p)
			}
		case added.ID:
			if p.SetBy == nil || p.SetBy.Rule != "runtimes.claude.reach" {
				t.Fatalf("%+v", p)
			}
		}
	}
	// The person's own variables do not reach Claude, on the own sign-in's handshake either.
	t.Setenv("ANTHROPIC_BASE_URL", "https://elsewhere.example")
	t.Setenv("CLAUDE_CODE_USE_BEDROCK", "1")
	os.WriteFile(filepath.Join(d.SettingsDir, passThroughFile), []byte(`{"names":["ANTHROPIC_BASE_URL","CLAUDE_CODE_USE_BEDROCK"]}`), 0o644)
	l, _ := d.launchAs(runtimeByID("claude"), root, nil)
	if e := envOf(l.Env); e["ANTHROPIC_BASE_URL"] != "" || e["CLAUDE_CODE_USE_BEDROCK"] != "" {
		t.Fatalf("%v", e)
	}
	// A looser policy: the own sign-in comes back.
	d.Told(wire.NotifyMachinePolicy.Name, k.signed(t, 2, map[string]any{}))
	p := startParams(dir, "claude", nil)
	p["accountID"] = "default"
	c.call(t, 30, "agents/start", p)
}

// T017, US4: a replaced key is used from the next request, and none fails; a removed
// route stops its sessions with a line, its file goes and its account leaves the list.
func TestAnOrgKeyReplacedAndRemoved(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c, public := orgMachine(t, root, newControlKeys(t))
	p := newFakeProvider(t)
	deliver(t, d, testRoute(t, public, "acme", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, p.URL, map[string]string{"apiKey": "key-1"}, "claude"))
	r, _ := d.relay()
	client := relayClient(t, d)
	token := r.standInFor(standIn{route: "acme", runtime: "claude", account: "org:acme"})
	ask := func() int {
		req, _ := http.NewRequest("POST", "https://127.0.0.1:"+strconv.Itoa(r.port)+"/acme/v1/messages", strings.NewReader(`{}`))
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp.StatusCode
	}
	stop := make(chan struct{})
	failed := make(chan int, 100)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if s := ask(); s != 200 {
				failed <- s
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
	time.Sleep(50 * time.Millisecond)
	deliver(t, d, testRoute(t, public, "acme", 2, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, p.URL, map[string]string{"apiKey": "key-2"}, "claude"))
	time.Sleep(50 * time.Millisecond)
	close(stop)
	wg.Wait()
	if len(failed) > 0 {
		t.Fatalf("a request failed across the replacement: %d", <-failed)
	}
	if got, _ := p.last(t); got.Header.Get("X-Api-Key") != "key-2" {
		t.Fatalf("%v", got.Header)
	}
	file, _ := os.ReadFile(filepath.Join(root, orgRoutesFolder, "acme.json"))
	if !strings.Contains(string(file), `"version":2`) {
		t.Fatalf("%s", file)
	}

	// A session on it, waiting in its turn; then the route is removed.
	dir := t.TempDir()
	start := startParams(dir, "claude", nil)
	start["accountID"], start["prompt"] = "org:acme", "wait for me"
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", start), &id)
	c.until(t, "running", func(method string, params json.RawMessage) bool {
		var a wire.Agent
		json.Unmarshal(params, &a)
		return method == "agent/changed" && a.ID == id && a.State == wire.AgentStateRunning
	})
	deliver(t, d)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if !strings.Contains(transcriptText(t, d, id), "Your organisation removed Acme acme.") {
		t.Fatal("no line in the chat")
	}
	if _, err := os.Stat(filepath.Join(root, orgRoutesFolder, "acme.json")); err == nil {
		t.Fatal("the file is still there")
	}
	if d.accountProfile("claude", "org:acme") != nil || d.Store.Agent(id) == nil {
		t.Fatal("the account stayed, or the session went")
	}
	if s := ask(); s != 401 {
		t.Fatalf("%d", s)
	}
	// Its next prompt is refused, saying why; it does not go on another account.
	if e := c.callError(t, 2, "agents/prompt", map[string]any{"agentID": id, "prompt": "more", "attachments": []any{}}); e == nil ||
		e.Code != wire.FailureOrgRouteRemoved || !strings.Contains(e.Message, "Continue in New") {
		t.Fatalf("%+v", e)
	}
	// Continue in New moves it: a session in the same folder that reads this one, on the
	// runtime's account for new sessions, here its own sign-in.
	var moved wire.UUID
	json.Unmarshal(c.call(t, 3, "agents/continueInNew", map[string]any{"agentID": id}), &moved)
	c.until(t, "moved", func(method string, params json.RawMessage) bool {
		var a wire.Agent
		json.Unmarshal(params, &a)
		return method == "agent/changed" && a.ID == moved && a.State == wire.AgentStateRunning
	})
	m := d.Store.Agent(moved)
	if m.AccountID != nil || store.FolderPath(m.Cwd) != dir || m.RuntimeID != "claude" {
		t.Fatalf("%+v", m)
	}
	if said := userMessages(d, moved); len(said) != 1 || !strings.HasPrefix(said[0], "Continue the work of the session “wait for me” ("+string(id)+")") {
		t.Fatalf("%q", said)
	}
	// An account the organisation removed is not one to move to.
	if e := c.callError(t, 4, "agents/continueInNew", map[string]any{"agentID": id, "accountID": "org:acme"}); e == nil {
		t.Fatal("moved to a removed account")
	}
}

// T018, US7: the route holds across a restart with no control plane; a file that does not
// open is deleted and asked for again; an ended token says so and puts the account out.
func TestOrgRoutesOffline(t *testing.T) {
	root := t.TempDir()
	k := newControlKeys(t)
	d, _, public := orgMachine(t, root, k)
	deliver(t, d, testRoute(t, public, "acme", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, "", map[string]string{"apiKey": "k"}, "claude"),
		testRoute(t, public, "copied", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, "", map[string]string{"apiKey": "k"}, "claude"))
	d.Shutdown()
	// Copied from another machine: sealed to another key.
	other := controllink.NewPrivateKey()
	otherPublic, _ := controllink.PublicKey(other)
	b, _ := json.Marshal(testRoute(t, otherPublic, "copied", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, "", map[string]string{"apiKey": "k"}, "claude"))
	os.WriteFile(filepath.Join(root, orgRoutesFolder, "copied.json"), b, 0o600)

	d2, _ := joined(t, root, k)
	var asked []string
	var mu sync.Mutex
	d2.SetControl(func(method string, params any) { mu.Lock(); asked = append(asked, method); mu.Unlock() })
	if d2.accountProfile("claude", "org:acme") == nil {
		t.Fatal("the route did not hold across the restart")
	}
	if d2.accountProfile("claude", "org:copied") != nil {
		t.Fatal("a file that does not open was taken")
	}
	if _, err := os.Stat(filepath.Join(root, orgRoutesFolder, "copied.json")); err == nil {
		t.Fatal("not deleted")
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		ok := slices.Contains(asked, wire.CallMachineOrgRoutesAgain.Name)
		mu.Unlock()
		if ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("not asked for again")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// A Bedrock token that ended while offline.
	p := newFakeProvider(t)
	tok := testRoute(t, public, "acme-bedrock", 1, wire.OrgRouteKindBedrock, "", p.URL,
		map[string]string{"awsSession": `{"accessKeyId":"A","secretAccessKey":"S","sessionToken":"T"}`}, "claude")
	ends := wire.DateOf(time.Now().Add(-time.Minute))
	tok.Expires = &ends
	deliver(t, d2, tok)
	r, _ := d2.relay()
	token := r.standInFor(standIn{route: "acme-bedrock", runtime: "claude", account: "org:acme-bedrock"})
	req, _ := http.NewRequest("POST", "https://127.0.0.1:"+strconv.Itoa(r.port)+"/acme-bedrock/~"+token+"/model/m/invoke", strings.NewReader(`{}`))
	resp, err := relayClient(t, d2).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 401 || !strings.Contains(string(body), "Your organisation's Bedrock access ended while this machine is offline. Connect to the network.") || p.count() != 0 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	if s := d2.allowancesLocked()["claude:account:org:acme-bedrock"]; s.Status.Out == nil {
		t.Fatalf("%+v", s)
	}
}

// T019, US6: Antigravity's terms: shown as today, accepted, or refused on start and sign-in.
func TestAntigravityTermsByPolicy(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c, _ := orgMachine(t, root, k)
	dir := t.TempDir()
	for i, terms := range []string{"show", "accepted"} {
		d.Told(wire.NotifyMachinePolicy.Name, k.signed(t, int64(1+i), map[string]any{"notices": map[string]any{"antigravityTerms": terms},
			"requires": []string{wire.CapHostPolicy1, wire.CapHostOrgRoutes1}}))
		if err := d.runtimeRefusal(d.orgPolicy(), "antigravity"); err != nil {
			t.Fatalf("%s: %v", terms, err)
		}
	}
	d.Told(wire.NotifyMachinePolicy.Name, k.signed(t, 3, map[string]any{"notices": map[string]any{"antigravityTerms": "refuse"},
		"requires": []string{wire.CapHostPolicy1, wire.CapHostOrgRoutes1}}))
	e := c.callError(t, 1, "agents/start", startParams(dir, "antigravity", nil))
	refused(t, e, "policy", "notices.antigravityTerms")
	if !strings.Contains(e.Message, "because of Google's terms on third-party tools") {
		t.Fatal(e.Message)
	}
	refused(t, c.callError(t, 2, "runtimes/authenticate", map[string]any{"runtimeID": "antigravity", "methodID": "google"}), "policy", "notices.antigravityTerms")
	// Other runtimes are not touched.
	c.call(t, 3, "agents/start", startParams(dir, "claude", nil))
}

// T014, SC-006, US5: the relay's count equals the provider's usage for each answer shape;
// a session's turn keeps it beside the runtime's, its report row carries the route and
// counts it for a limit; a 429 puts that account out until its time, and only it.
func TestTheRelayCountsTheProvidersTokens(t *testing.T) {
	sse := func(events ...string) func(w http.ResponseWriter, r *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			for _, e := range events {
				io.WriteString(w, "data: "+e+"\n\n")
				w.(http.Flusher).Flush()
			}
		}
	}
	whole := func(body string) func(w http.ResponseWriter, r *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, body)
		}
	}
	bedrock := func(events ...string) func(w http.ResponseWriter, r *http.Request) {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/vnd.amazon.eventstream")
			for _, e := range events {
				w.Write(eventStreamFrame(`{"bytes":"` + base64.StdEncoding.EncodeToString([]byte(e)) + `"}`))
			}
		}
	}
	cases := []struct {
		name   string
		answer func(w http.ResponseWriter, r *http.Request)
		path   string
		want   wire.RelayTokens
	}{
		{"anthropic stream", sse(`{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":40,"cache_creation_input_tokens":10}}}`,
			`{"type":"content_block_delta"}`, `{"type":"message_delta","usage":{"output_tokens":55}}`), "/v1/messages",
			wire.RelayTokens{Input: 100, Output: 55, CacheRead: 40, CacheWrite: 10}},
		{"anthropic whole", whole(`{"type":"message","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}`),
			"/v1/messages", wire.RelayTokens{Input: 12, Output: 5, CacheRead: 3, CacheWrite: 2}},
		{"responses stream", sse(`{"type":"response.created"}`, `{"type":"response.completed","response":{"usage":{"input_tokens":300,"output_tokens":20,"input_tokens_details":{"cached_tokens":100}}}}`),
			"/v1/responses", wire.RelayTokens{Input: 200, Output: 20, CacheRead: 100}},
		{"chat completions stream", sse(`{"object":"chat.completion.chunk","choices":[]}`, `{"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":10}}}`, `[DONE]`),
			"/v1/chat/completions", wire.RelayTokens{Input: 40, Output: 7, CacheRead: 10}},
		{"gemini stream", sse(`{"candidates":[],"usageMetadata":{"promptTokenCount":80,"candidatesTokenCount":3}}`, `{"candidates":[],"usageMetadata":{"promptTokenCount":80,"candidatesTokenCount":9,"cachedContentTokenCount":30,"thoughtsTokenCount":4}}`),
			"/v1beta/models/gemini:streamGenerateContent", wire.RelayTokens{Input: 50, Output: 13, CacheRead: 30}},
		{"bedrock stream", bedrock(`{"type":"message_start","message":{"usage":{"input_tokens":70,"output_tokens":1}}}`, `{"type":"message_delta","usage":{"output_tokens":33}}`),
			"/model/m/invoke-with-response-stream", wire.RelayTokens{Input: 70, Output: 33}},
	}
	root := t.TempDir()
	d, _, public := orgMachine(t, root, newControlKeys(t))
	p := newFakeProvider(t)
	deliver(t, d, testRoute(t, public, "acme", 1, wire.OrgRouteKindBaseURL, wire.OrgRouteVendorAnthropic, p.URL, map[string]string{"apiKey": "k"}, "claude"))
	r, _ := d.relay()
	client := relayClient(t, d)
	for i, k := range cases {
		agent := wire.UUID(strconv.Itoa(i))
		token := r.standInFor(standIn{route: "acme", runtime: "claude", account: "org:acme", agent: agent})
		p.mu.Lock()
		p.answer = k.answer
		p.mu.Unlock()
		body := `{"stream":true}`
		req, _ := http.NewRequest("POST", "https://127.0.0.1:"+strconv.Itoa(r.port)+"/acme"+k.path, strings.NewReader(body))
		req.Header.Set("X-Api-Key", token)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		got, _ := d.takeRelayTokens(agent)
		if got == nil || *got != k.want {
			t.Fatalf("%s: %+v, want %+v", k.name, got, k.want)
		}
		if k.name == "chat completions stream" {
			if _, sent := p.last(t); !strings.Contains(string(sent), `"include_usage":true`) {
				t.Fatalf("%s", sent)
			}
		}
	}

	// A 429 with retry-after 60: that account is out about a minute, and the own is not.
	p.mu.Lock()
	p.answer = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(429)
		io.WriteString(w, `{"type":"error","error":{"type":"rate_limit_error"}}`)
	}
	p.mu.Unlock()
	token := r.standInFor(standIn{route: "acme", runtime: "claude", account: "org:acme"})
	req, _ := http.NewRequest("POST", "https://127.0.0.1:"+strconv.Itoa(r.port)+"/acme/v1/messages", strings.NewReader(`{}`))
	req.Header.Set("X-Api-Key", token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	states := d.allowancesLocked()
	out := states["claude:account:org:acme"]
	if resp.StatusCode != 429 || out.Status.RateLimited == nil || out.Status.RateLimited.Until.Time().Sub(time.Now()) < 50*time.Second ||
		out.Status.RateLimited.Until.Time().Sub(time.Now()) > 70*time.Second {
		t.Fatalf("%d %+v", resp.StatusCode, out)
	}
	if own, ok := states[ownKey("claude")]; ok && own.Status.Available == nil {
		t.Fatalf("%+v", own)
	}

	// A turn's usage keeps the relay's count and the route; its row counts it for a limit.
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.AccountID = new("org:acme") })
	u := wire.TurnUsage{TotalTokens: 2, InputTokens: 1, OutputTokens: 1, Route: new("acme"),
		RelayTokens: &wire.RelayTokens{Input: 100, Output: 55, CacheRead: 40, CacheWrite: 10}}
	d.bankTurnUsage(a.ID, u)
	d.reportMu.Lock()
	var row wire.UsageRollupRow
	for _, rows := range d.reportLocked().Hours {
		for k, v := range rows {
			if strings.HasSuffix(k, "\troute:acme") {
				row = v
			}
		}
	}
	d.reportMu.Unlock()
	if row.Route == nil || *row.Route != "acme" || row.LimitTokens == nil || *row.LimitTokens != 165 {
		t.Fatalf("%+v", row)
	}
	// Its allowance row says its tokens today, and the own sign-in's says none (FR-025).
	for _, r := range d.runtimeAllowances().Rows {
		switch r.CredentialKey {
		case "claude:account:org:acme":
			if r.TokensToday == nil || *r.TokensToday != 165 {
				t.Fatalf("%+v", r)
			}
		case ownKey("claude"):
			if r.TokensToday != nil {
				t.Fatalf("%+v", r)
			}
		}
	}
}

// eventStreamFrame is one event of AWS's event stream, with no headers.
func eventStreamFrame(payload string) []byte {
	total := 12 + len(payload) + 4
	b := make([]byte, total)
	binary.BigEndian.PutUint32(b[0:4], uint32(total))
	binary.BigEndian.PutUint32(b[4:8], 0)
	copy(b[12:], payload)
	return b
}

// SC-005: the relay adds under 5 ms to the first byte at the 95th percentile.
func TestTheRelayIsQuick(t *testing.T) {
	root := t.TempDir()
	d, _, public := orgMachine(t, root, newControlKeys(t))
	p := newFakeProvider(t)
	deliver(t, d, testRoute(t, public, "acme", 1, wire.OrgRouteKindKey, wire.OrgRouteVendorAnthropic, p.URL, map[string]string{"apiKey": "k"}, "claude"))
	r, _ := d.relay()
	client := relayClient(t, d)
	direct := &http.Client{}
	token := r.standInFor(standIn{route: "acme", runtime: "claude", account: "org:acme"})
	p95 := func(c *http.Client, url, header string) time.Duration {
		var took []time.Duration
		for range 100 {
			req, _ := http.NewRequest("POST", url, strings.NewReader(`{}`))
			req.Header.Set("X-Api-Key", header)
			at := time.Now()
			resp, err := c.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Read(make([]byte, 1))
			took = append(took, time.Since(at))
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		slices.Sort(took)
		return took[94]
	}
	// The least of three rounds, so a loaded machine does not fail it by chance.
	best := time.Hour
	for range 3 {
		over := p95(client, "https://127.0.0.1:"+strconv.Itoa(r.port)+"/acme/v1/messages", token) - p95(direct, p.URL+"/v1/messages", "k")
		best = min(best, over)
	}
	if best >= 5*time.Millisecond {
		t.Fatalf("the relay adds %v at p95", best)
	}
}
