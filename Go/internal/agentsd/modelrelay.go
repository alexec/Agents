package agentsd

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The model relay (#999, spec D4, FR-011, FR-012): one TLS server on loopback, with a CA
// of its own that each runtime on an org account is told to trust. The runtime is given
// https://127.0.0.1:<port>/<route id> as its base URL and a stand-in in place of the key.
// The relay checks the stand-in, takes it out, puts in the route's real credential (opened
// in memory for that request only), sends the request on, and streams the answer back as
// it is. On the way it reads only the usage fields of each answer (research R5) and adds
// them to the session's turn: the provider's own count. It writes no body anywhere.
//
// The stand-in comes in the header the runtime sends a key in, or, for a runtime told to
// skip its own auth (Claude on Bedrock, Vertex or Foundry), as the path segment after the
// route: /<route id>/~<stand-in>/….

const (
	relayMostBody = 32 << 20
	// relayMostCounted is the most of a whole (not streamed) answer read for its usage.
	relayMostCounted = 8 << 20
	// relayMostLine bounds one line of a stream, or one event of Bedrock's.
	relayMostLine = 4 << 20
	// relayMostStandIns bounds the stand-ins kept: one per session, the oldest goes first.
	relayMostStandIns = 1024
	// relayOutWithoutATime is how long an account is out after a rate limit with no time.
	relayOutWithoutATime = 5 * time.Minute
	relayCAFile          = "model-relay-ca.pem"
	orgExpiredWords      = "Your organisation's %s access ended while this machine is offline. Connect to the network."
)

// relayUpstreamClient sends what the relay sends on. A test points it at a fake provider.
var relayUpstreamClient = &http.Client{Transport: &http.Transport{Proxy: http.ProxyFromEnvironment,
	ForceAttemptHTTP2: true, MaxIdleConnsPerHost: 16, IdleConnTimeout: 90 * time.Second}}

// relayNow is the relay's clock; a test moves it.
var relayNow = time.Now

type modelRelay struct {
	port   int
	caFile string
	ln     net.Listener
	srv    *http.Server

	mu       sync.Mutex
	standIns map[string]standIn
	byAgent  map[wire.UUID]string
	order    []string
	// turns is each session's tokens since its runtime last reported a turn's usage.
	turns map[wire.UUID]*wire.RelayTokens
}

// standIn is what a stand-in is for: one session (or a handshake) on one org account.
type standIn struct {
	route, runtime, account string
	agent                   wire.UUID
}

// relay is the model relay, started the first time it is needed.
func (d *Daemon) relay() (*modelRelay, error) {
	d.relayMu.Lock()
	defer d.relayMu.Unlock()
	if d.modelRelay != nil {
		return d.modelRelay, nil
	}
	cert, caPEM, err := relayCertificate()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(d.Store.Loc.Root, "runtimes")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	caFile := filepath.Join(dir, relayCAFile)
	if err := os.WriteFile(caFile, caPEM, 0o600); err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	r := &modelRelay{port: ln.Addr().(*net.TCPAddr).Port, caFile: caFile, ln: ln, standIns: map[string]standIn{},
		byAgent: map[wire.UUID]string{}, turns: map[wire.UUID]*wire.RelayTokens{}}
	r.srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) { d.relayServe(r, w, req) }),
		ReadHeaderTimeout: 30 * time.Second, ErrorLog: log.New(io.Discard, "", 0),
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, NextProtos: []string{"http/1.1"}, MinVersion: tls.VersionTLS12}}
	tlsLn := tls.NewListener(ln, r.srv.TLSConfig)
	safe.Go("model relay", func() { r.srv.Serve(tlsLn) })
	d.modelRelay = r
	log.Printf("model relay: on 127.0.0.1:%d", r.port)
	return r, nil
}

func (d *Daemon) stopModelRelay() {
	d.relayMu.Lock()
	r := d.modelRelay
	d.modelRelay = nil
	d.relayMu.Unlock()
	if r != nil {
		r.srv.Close()
	}
}

// relayCertificate is a CA of the relay's own, made at each start and kept in memory, and
// a certificate for loopback it signs. The runtime is told to trust the CA's certificate.
func relayCertificate() (tls.Certificate, []byte, error) {
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	serial := func() *big.Int { n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120)); return n }
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "Agents model relay CA"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(5 * 365 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign, MaxPathLenZero: true}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	caCert, _ := x509.ParseCertificate(caDER)
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	leaf := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "127.0.0.1"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(5 * 365 * 24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{"localhost"},
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: leafKey},
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), nil
}

// standInFor is a session's stand-in on an org account: the same one each time the session
// starts its runtime, so a runtime that holds an old one still reaches the relay.
func (r *modelRelay) standInFor(s standIn) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if s.agent != "" {
		if token, ok := r.byAgent[s.agent]; ok && r.standIns[token] == s {
			return token
		}
	}
	b := make([]byte, 24)
	rand.Read(b)
	token := "agents-relay-" + base64.RawURLEncoding.EncodeToString(b)
	r.standIns[token] = s
	r.order = append(r.order, token)
	if s.agent != "" {
		r.byAgent[s.agent] = token
	}
	for len(r.order) > relayMostStandIns {
		old := r.order[0]
		r.order = r.order[1:]
		if a := r.standIns[old].agent; a != "" && r.byAgent[a] == old {
			delete(r.byAgent, a)
		}
		delete(r.standIns, old)
	}
	return token
}

// dropStandIn takes away a session's stand-in: its runtime has ended, so nothing it left
// running reaches the model with it. The session's next runtime is given a new one.
func (d *Daemon) dropStandIn(agent wire.UUID) {
	d.relayMu.Lock()
	r := d.modelRelay
	d.relayMu.Unlock()
	if r == nil {
		return
	}
	r.mu.Lock()
	if token, ok := r.byAgent[agent]; ok {
		r.forgetLocked(token)
	}
	r.mu.Unlock()
}

// forgetLocked takes a stand-in away, from the order too, so a dropped one never pushes a
// stand-in still in use out of it. r.mu is held.
func (r *modelRelay) forgetLocked(token string) {
	if a := r.standIns[token].agent; a != "" && r.byAgent[a] == token {
		delete(r.byAgent, a)
	}
	delete(r.standIns, token)
	if i := slices.Index(r.order, token); i >= 0 {
		r.order = slices.Delete(r.order, i, i+1)
	}
}

// dropStandInsOfGoneRoutes takes away the stand-ins of routes no longer here.
func (d *Daemon) dropStandInsOfGoneRoutes() {
	d.relayMu.Lock()
	r := d.modelRelay
	d.relayMu.Unlock()
	if r == nil {
		return
	}
	r.mu.Lock()
	tokens := make([]string, 0, len(r.standIns))
	for token := range r.standIns {
		tokens = append(tokens, token)
	}
	r.mu.Unlock()
	for _, token := range tokens {
		r.mu.Lock()
		s := r.standIns[token]
		r.mu.Unlock()
		if _, ok := d.heldOrgRoute(s.route); ok {
			continue
		}
		r.mu.Lock()
		r.forgetLocked(token)
		r.mu.Unlock()
	}
}

// takeRelayTokens is a session's tokens since its last turn's report, and its route.
func (d *Daemon) takeRelayTokens(agent wire.UUID) (*wire.RelayTokens, string) {
	d.relayMu.Lock()
	r := d.modelRelay
	d.relayMu.Unlock()
	if r == nil {
		return nil, ""
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	t := r.turns[agent]
	delete(r.turns, agent)
	route := ""
	if token, ok := r.byAgent[agent]; ok {
		route = r.standIns[token].route
	}
	return t, route
}

// relayError answers the runtime in the shape its SDK reads as an error, and sends nothing on.
func relayError(w http.ResponseWriter, status int, kind, words string) {
	b, _ := json.Marshal(map[string]any{"type": "error", "error": map[string]any{"type": kind, "message": words, "code": status}})
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(b)
}

// authHeaders are the headers a runtime sends a key in: each is taken out before the
// request goes on.
var authHeaders = []string{"X-Api-Key", "Authorization", "Api-Key", "X-Goog-Api-Key"}

// hopHeaders are not passed on in either direction.
var hopHeaders = []string{"Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "Proxy-Connection", "Te",
	"Trailer", "Transfer-Encoding", "Upgrade"}

// standInIn is the stand-in a request carries, and the path after the route without it.
func standInIn(req *http.Request, rest string) (string, string) {
	if after, ok := strings.CutPrefix(rest, "/~"); ok {
		token, path, _ := strings.Cut(after, "/")
		return token, "/" + path
	}
	for _, h := range authHeaders {
		if v := req.Header.Get(h); v != "" {
			if bearer, ok := strings.CutPrefix(v, "Bearer "); ok {
				v = bearer
			}
			return strings.TrimSpace(v), rest
		}
	}
	return req.URL.Query().Get("key"), rest
}

func (d *Daemon) relayServe(r *modelRelay, w http.ResponseWriter, req *http.Request) {
	routeID, rest, _ := strings.Cut(strings.TrimPrefix(req.URL.Path, "/"), "/")
	rest = "/" + rest
	token, rest := standInIn(req, rest)
	r.mu.Lock()
	s, ok := r.standIns[token]
	r.mu.Unlock()
	if token == "" || !ok || s.route != routeID {
		relayError(w, http.StatusUnauthorized, "authentication_error", "This is not a key for this machine's model relay.")
		return
	}
	route, held := d.heldOrgRoute(routeID)
	if !held {
		relayError(w, http.StatusUnauthorized, "authentication_error", "Your organisation removed this way to the model.")
		return
	}
	if !relayAllows(route, req.Method, rest) {
		relayError(w, http.StatusNotFound, "not_found_error", "The model relay sends on only requests for a model's answers.")
		return
	}
	a, gone := d.relayAgent(r, s, token)
	if gone {
		relayError(w, http.StatusUnauthorized, "authentication_error", "This session has ended.")
		return
	}
	p := d.orgPolicy()
	if err := d.relayRefusal(p, s, a); err != nil {
		relayError(w, http.StatusForbidden, "permission_error", policyWords(err))
		return
	}
	key := accountKey(s.runtime, &s.account)
	if route.Expires != nil && !relayNow().Before(route.Expires.Time()) {
		words := fmt.Sprintf(orgExpiredWords, kindName(route.Kind))
		d.markOut(key, wire.AllowanceStateOutReasonRuntimeFailed, nil, wire.AllowanceStateSourceExpiry, nil)
		d.tellAllowances()
		relayError(w, http.StatusUnauthorized, "authentication_error", words)
		return
	}
	if req.ContentLength > relayMostBody {
		relayError(w, http.StatusRequestEntityTooLarge, "request_too_large", "The request is over 32 MiB.")
		return
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, relayMostBody+1))
	if err != nil {
		relayError(w, http.StatusBadRequest, "invalid_request_error", "The request could not be read.")
		return
	}
	if len(body) > relayMostBody {
		relayError(w, http.StatusRequestEntityTooLarge, "request_too_large", "The request is over 32 MiB.")
		return
	}
	if err := d.relayModelRefusal(p, s.runtime, a, rest, body); err != nil {
		relayError(w, http.StatusForbidden, "permission_error", policyWords(err))
		return
	}
	target, err := upstreamURL(route, rest, req.URL.Query())
	if err != nil {
		relayError(w, http.StatusBadGateway, "api_error", err.Error())
		return
	}
	body, target.Path = rewriteModels(route, body, target.Path)
	body = askForUsage(target.Path, body)
	out, err := http.NewRequestWithContext(req.Context(), req.Method, target.String(), bytes.NewReader(body))
	if err != nil {
		relayError(w, http.StatusBadGateway, "api_error", err.Error())
		return
	}
	for name, values := range req.Header {
		if isHeaderIn(name, authHeaders) || isHeaderIn(name, hopHeaders) || strings.EqualFold(name, "Accept-Encoding") ||
			strings.EqualFold(name, "Content-Length") || strings.EqualFold(name, "Host") {
			continue
		}
		out.Header[name] = values
	}
	out.ContentLength = int64(len(body))
	if err := d.addCredential(out, route, body); err != nil {
		relayError(w, http.StatusBadGateway, "api_error", err.Error())
		return
	}
	resp, err := relayUpstreamClient.Do(out)
	if err != nil {
		if req.Context().Err() == nil {
			relayError(w, http.StatusBadGateway, "api_error", "The organisation's way to the model could not be reached.")
		}
		return
	}
	defer resp.Body.Close()
	for name, values := range resp.Header {
		if isHeaderIn(name, hopHeaders) || strings.EqualFold(name, "Content-Length") {
			continue
		}
		w.Header()[name] = values
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		d.relayRateLimited(key, resp.Header)
	}
	w.WriteHeader(resp.StatusCode)
	m := newUsageMeter(resp.Header.Get("Content-Type"))
	flush := http.NewResponseController(w)
	buf := make([]byte, 32<<10)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			flush.Flush()
			m.write(buf[:n])
		}
		if err != nil {
			break
		}
	}
	if resp.StatusCode < 300 {
		if t := m.done(); t != nil {
			d.relayCounted(r, s, *t)
		}
	}
}

// relayPostPaths and relayGetPaths are the requests the relay sends on: a model's answers
// and token counts, and the list of models. Anything else the route's credential could
// reach (files, batches, fine-tuning, a cloud's control plane) is refused.
var (
	relayPostPaths = regexp.MustCompile(`^(?:/v1)?/(?:messages|messages/count_tokens|chat/completions|completions|responses|responses/compact|embeddings)$|` +
		`^/deployments/[^/]+/(?:chat/completions|completions|responses|embeddings)$|` +
		`^/v1(?:beta1)?/projects/[^/]+/locations/[^/]+/endpoints/openapi/chat/completions$|` +
		`^(?:/v1(?:beta|beta1|alpha)?)?/(?:projects/[^/]+/locations/[^/]+/)?(?:publishers/[^/]+/)?models/[^/]+:` +
		`(?:generateContent|streamGenerateContent|countTokens|embedContent|batchEmbedContents|rawPredict|streamRawPredict|predict|serverStreamingPredict)$|` +
		`^/model/.+/(?:invoke|invoke-with-response-stream|converse|converse-stream|count-tokens)$`)
	relayGetPaths = regexp.MustCompile(`^(?:/v1(?:beta|beta1)?)?/models(?:/[^/]+)?$|^/(?:inference-profiles|foundation-models)(?:/[^/]+)?$`)
)

// relayAllows is whether a request is one the relay sends on: a model's path, with no
// "." or ".." in it, and on Vertex in the route's own Google Cloud project.
func relayAllows(r wire.DeliveredRoute, method, p string) bool {
	if path.Clean(p) != p {
		return false
	}
	if r.Kind == wire.OrgRouteKindVertex && r.Settings != nil && r.Settings.Project != nil {
		if _, after, ok := strings.Cut(p, "/projects/"); ok {
			if project, _, _ := strings.Cut(after, "/"); project != *r.Settings.Project {
				return false
			}
		}
	}
	switch method {
	case http.MethodPost:
		return relayPostPaths.MatchString(p)
	case http.MethodGet:
		return relayGetPaths.MatchString(p)
	}
	return false
}

// relayAgent is a stand-in's session, and whether it is gone: deleted or archived, when
// its stand-in is dropped too. A handshake's stand-in has no session.
func (d *Daemon) relayAgent(r *modelRelay, s standIn, token string) (*wire.Agent, bool) {
	if s.agent == "" {
		return nil, false
	}
	a := d.Store.Agent(s.agent)
	if a != nil && a.State != wire.AgentStateArchived {
		return a, false
	}
	r.mu.Lock()
	r.forgetLocked(token)
	r.mu.Unlock()
	return nil, true
}

// relayRefusal is why the relay sends no request on now, as a turn would not start: the
// kill switch, a suspension or no policy (workRefusal), the runtime or the session's reach
// no longer allowed, or a budget used. Nil otherwise.
func (d *Daemon) relayRefusal(p *wire.OrgPolicy, s standIn, a *wire.Agent) error {
	if err := d.workRefusal(); err != nil {
		return err
	}
	if p == nil {
		return nil
	}
	if err := d.runtimeRefusal(p, s.runtime); err != nil {
		return err
	}
	if a != nil {
		if err := d.sessionReachRefusal(a); err != nil {
			return err
		}
		if err := d.agentBudgetRefusal(a); err != nil {
			return err
		}
	}
	return d.dayBudgetRefusal()
}

// relayModelRefusal is why the policy does not allow the model a request names, in its
// path or its body, or nil.
func (d *Daemon) relayModelRefusal(p *wire.OrgPolicy, runtimeID string, a *wire.Agent, reqPath string, body []byte) error {
	if !hasModelRule(p, runtimeID) {
		return nil
	}
	var options []wire.ConfigOption
	if a != nil {
		options = a.AdvertisedOptions
	}
	choices := runtimeModelChoices(runtimeID, options)
	for _, model := range requestModels(reqPath, body) {
		err := d.modelRefusalIn(p, runtimeID, model, choices)
		if err == nil {
			continue
		}
		if plain := plainModel(model); plain != model && d.modelRefusalIn(p, runtimeID, plain, choices) == nil {
			continue
		}
		return err
	}
	return nil
}

// requestModels is the models a request names: in a Bedrock, Gemini or Vertex path, and
// in the body's "model".
func requestModels(p string, body []byte) []string {
	var models []string
	for _, re := range []*regexp.Regexp{bedrockModel, pathModel} {
		if m := re.FindStringSubmatch(p); m != nil {
			if model, err := url.PathUnescape(m[1]); err == nil {
				models = append(models, model)
			}
		}
	}
	if bytes.Contains(body, []byte(`"model"`)) {
		var obj struct {
			Model string `json:"model"`
		}
		if json.Unmarshal(body, &obj) == nil && obj.Model != "" {
			models = append(models, obj.Model)
		}
	}
	return models
}

// bedrockVersion is the version at the end of a Bedrock model id, such as -v1:0.
var bedrockVersion = regexp.MustCompile(`-v\d+(?::\d+)?$`)

// plainModel is a cloud's model id as its vendor names it: claude-sonnet-4-5-20250929 for
// Bedrock's us.anthropic.claude-sonnet-4-5-20250929-v1:0 and Vertex's
// claude-sonnet-4-5@20250929.
func plainModel(model string) string {
	model, _, _ = strings.Cut(model, "@")
	if _, after, ok := strings.Cut(model, "anthropic."); ok {
		model = bedrockVersion.ReplaceAllString(after, "")
	}
	return model
}

func isHeaderIn(name string, list []string) bool {
	for _, h := range list {
		if strings.EqualFold(name, h) {
			return true
		}
	}
	return false
}

func kindName(k wire.OrgRouteKind) string {
	switch k {
	case wire.OrgRouteKindBedrock:
		return "Bedrock"
	case wire.OrgRouteKindVertex:
		return "Vertex AI"
	case wire.OrgRouteKindAzure:
		return "Azure"
	}
	return "model"
}

// relayRateLimited is the provider's rate-limit or quota answer: that account is out
// until the time the answer gives, or 5 minutes (FR-020), and nothing else.
func (d *Daemon) relayRateLimited(key string, h http.Header) {
	until := relayNow().Add(relayOutWithoutATime)
	if v := h.Get("Retry-After"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
			until = relayNow().Add(time.Duration(secs) * time.Second)
		} else if t, err := http.ParseTime(v); err == nil {
			until = t
		}
	}
	d.rateLimited(key, wire.DateOf(until))
}

// relayCounted adds an answer's tokens to its session's turn.
func (d *Daemon) relayCounted(r *modelRelay, s standIn, t wire.RelayTokens) {
	if s.agent == "" {
		return
	}
	r.mu.Lock()
	sum := r.turns[s.agent]
	if sum == nil {
		sum = &wire.RelayTokens{}
		r.turns[s.agent] = sum
	}
	sum.Input += t.Input
	sum.Output += t.Output
	sum.CacheRead += t.CacheRead
	sum.CacheWrite += t.CacheWrite
	r.mu.Unlock()
}

// MARK: where the request goes

var vendorAddress = map[wire.OrgRouteVendor]string{
	wire.OrgRouteVendorAnthropic: "https://api.anthropic.com",
	wire.OrgRouteVendorOpenai:    "https://api.openai.com",
	wire.OrgRouteVendorGemini:    "https://generativelanguage.googleapis.com",
	wire.OrgRouteVendorXai:       "https://api.x.ai",
}

// vertexPublishers is a Vertex path without its folder and location, as Gemini's express
// mode sends it: the relay puts the route's in.
var vertexPublishers = regexp.MustCompile(`^/(v1|v1beta1)/publishers/`)

// upstreamURL is where a request goes: the route's address, or its provider's for the
// route's settings, then the path after the route.
func upstreamURL(r wire.DeliveredRoute, path string, query url.Values) (*url.URL, error) {
	st := wire.OrgRouteSettings{}
	if r.Settings != nil {
		st = *r.Settings
	}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	base := str(st.Address)
	switch r.Kind {
	case wire.OrgRouteKindKey:
		if base == "" && r.Vendor != nil {
			base = vendorAddress[*r.Vendor]
		}
	case wire.OrgRouteKindBedrock:
		if base == "" && str(st.Region) != "" {
			host := "bedrock-runtime"
			if strings.HasPrefix(path, "/inference-profiles") || strings.HasPrefix(path, "/foundation-models") {
				host = "bedrock"
			}
			base = "https://" + host + "." + str(st.Region) + ".amazonaws.com"
		}
	case wire.OrgRouteKindVertex:
		location := str(st.Location)
		if strings.HasPrefix(path, "/projects/") {
			path = "/v1" + path
		}
		if vertexPublishers.MatchString(path) && str(st.Project) != "" && location != "" {
			version, after, _ := strings.Cut(strings.TrimPrefix(path, "/"), "/")
			path = "/" + version + "/projects/" + str(st.Project) + "/locations/" + location + "/" + after
		}
		if base == "" && location != "" {
			base = "https://" + location + "-aiplatform.googleapis.com"
			if location == "global" {
				base = "https://aiplatform.googleapis.com"
			}
		}
	case wire.OrgRouteKindAzure:
		if base == "" && str(st.Resource) != "" {
			base = "https://" + str(st.Resource) + ".openai.azure.com/openai"
			if r.Vendor != nil && *r.Vendor == wire.OrgRouteVendorAnthropic {
				base = "https://" + str(st.Resource) + ".services.ai.azure.com/anthropic"
			}
		}
		if v := str(st.ApiVersion); v != "" && query.Get("api-version") == "" {
			query = cloneQuery(query)
			query.Set("api-version", v)
		}
	}
	if base == "" {
		return nil, errors.New("The organisation's route says no address for this request.")
	}
	u, err := url.Parse(strings.TrimSuffix(base, "/") + path)
	if err != nil || u.Host == "" {
		return nil, errors.New("The organisation's route has an address that is not one.")
	}
	q := cloneQuery(query)
	q.Del("key")
	u.RawQuery = q.Encode()
	return u, nil
}

func cloneQuery(q url.Values) url.Values {
	out := url.Values{}
	for k, v := range q {
		out[k] = append([]string(nil), v...)
	}
	return out
}

// bedrockModel is the model in a Bedrock path; geminiModel is the model in a Gemini or
// Vertex path.
var (
	bedrockModel = regexp.MustCompile(`/model/([^/]+)/`)
	pathModel    = regexp.MustCompile(`/models/([^/:]+):`)
)

// rewriteModels puts the gateway's model ids for the runtime's (the route's model map):
// in a Bedrock or Vertex path, and in the body's "model".
func rewriteModels(r wire.DeliveredRoute, body []byte, path string) ([]byte, string) {
	if len(r.Models) == 0 {
		return body, path
	}
	for _, re := range []*regexp.Regexp{bedrockModel, pathModel} {
		if m := re.FindStringSubmatchIndex(path); m != nil {
			from, _ := url.PathUnescape(path[m[2]:m[3]])
			if to, ok := r.Models[from]; ok {
				path = path[:m[2]] + to + path[m[3]:]
			}
		}
	}
	if !bytes.Contains(body, []byte(`"model"`)) {
		return body, path
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(body, &obj) != nil {
		return body, path
	}
	var model string
	if json.Unmarshal(obj["model"], &model) != nil {
		return body, path
	}
	to, ok := r.Models[model]
	if !ok {
		return body, path
	}
	obj["model"], _ = json.Marshal(to)
	if b, err := json.Marshal(obj); err == nil {
		body = b
	}
	return body, path
}

// askForUsage asks a streamed Chat Completions answer for its usage on the last chunk,
// where the runtime did not (research R5).
func askForUsage(path string, body []byte) []byte {
	if !strings.HasSuffix(path, "/chat/completions") {
		return body
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(body, &obj) != nil || string(obj["stream"]) != "true" {
		return body
	}
	var opts map[string]json.RawMessage
	json.Unmarshal(obj["stream_options"], &opts)
	if opts == nil {
		opts = map[string]json.RawMessage{}
	}
	if string(opts["include_usage"]) == "true" {
		return body
	}
	opts["include_usage"] = json.RawMessage("true")
	obj["stream_options"], _ = json.Marshal(opts)
	if b, err := json.Marshal(obj); err == nil {
		return b
	}
	return body
}

// MARK: the credential

// addCredential puts in the route's credential for its kind (research R3), opened for this
// request only.
func (d *Daemon) addCredential(req *http.Request, r wire.DeliveredRoute, body []byte) error {
	secret := func(field string) string {
		v, ok := d.orgSecret(r, field)
		if !ok {
			return ""
		}
		s := string(v)
		clear(v)
		return s
	}
	vendor := wire.OrgRouteVendor("")
	if r.Vendor != nil {
		vendor = *r.Vendor
	}
	missing := errors.New("The organisation's route has no key on this machine yet.")
	switch r.Kind {
	case wire.OrgRouteKindKey:
		key := secret("apiKey")
		if key == "" {
			return missing
		}
		setVendorKey(req, vendor, key)
	case wire.OrgRouteKindBaseURL:
		key := secret("apiKey")
		if key == "" {
			return nil
		}
		if r.Settings != nil && r.Settings.Header != nil {
			if strings.EqualFold(*r.Settings.Header, "Authorization") {
				req.Header.Set("Authorization", "Bearer "+key)
			} else {
				req.Header.Set(*r.Settings.Header, key)
			}
			return nil
		}
		setVendorKey(req, vendor, key)
	case wire.OrgRouteKindBedrock:
		if key := secret("apiKey"); key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
			return nil
		}
		var session struct {
			AccessKeyID     string `json:"accessKeyId"`
			SecretAccessKey string `json:"secretAccessKey"`
			SessionToken    string `json:"sessionToken"`
		}
		if json.Unmarshal([]byte(secret("awsSession")), &session) != nil || session.AccessKeyID == "" {
			return missing
		}
		region := ""
		if r.Settings != nil && r.Settings.Region != nil {
			region = *r.Settings.Region
		}
		signAWS(req, body, session.AccessKeyID, session.SecretAccessKey, session.SessionToken, region, "bedrock", relayNow())
	case wire.OrgRouteKindVertex:
		token := secret("googleToken")
		if token == "" {
			return missing
		}
		req.Header.Set("Authorization", "Bearer "+token)
	case wire.OrgRouteKindAzure:
		if token := secret("entraToken"); token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
			return nil
		}
		key := secret("apiKey")
		if key == "" {
			return missing
		}
		if vendor == wire.OrgRouteVendorAnthropic {
			req.Header.Set("X-Api-Key", key)
		} else {
			req.Header.Set("Api-Key", key)
		}
	}
	return nil
}

func setVendorKey(req *http.Request, vendor wire.OrgRouteVendor, key string) {
	switch vendor {
	case wire.OrgRouteVendorAnthropic:
		req.Header.Set("X-Api-Key", key)
	case wire.OrgRouteVendorGemini:
		req.Header.Set("X-Goog-Api-Key", key)
	default:
		req.Header.Set("Authorization", "Bearer "+key)
	}
}

// signAWS signs a request with AWS Signature Version 4, with a session token.
func signAWS(req *http.Request, body []byte, accessKey, secretKey, sessionToken, region, service string, now time.Time) {
	now = now.UTC()
	amzDate, day := now.Format("20060102T150405Z"), now.Format("20060102")
	payload := sha256.Sum256(body)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", hex.EncodeToString(payload[:]))
	if sessionToken != "" {
		req.Header.Set("X-Amz-Security-Token", sessionToken)
	}
	headers := map[string]string{"host": req.URL.Host, "x-amz-date": amzDate, "x-amz-content-sha256": hex.EncodeToString(payload[:])}
	if ct := req.Header.Get("Content-Type"); ct != "" {
		headers["content-type"] = ct
	}
	if sessionToken != "" {
		headers["x-amz-security-token"] = sessionToken
	}
	names := make([]string, 0, len(headers))
	for k := range headers {
		names = append(names, k)
	}
	sort.Strings(names)
	var canonHeaders strings.Builder
	for _, k := range names {
		canonHeaders.WriteString(k + ":" + strings.TrimSpace(headers[k]) + "\n")
	}
	signed := strings.Join(names, ";")
	// The path goes as AWS encodes it, and is signed encoded twice, as for every service
	// but S3.
	segments := strings.Split(req.URL.Path, "/")
	once, twice := make([]string, len(segments)), make([]string, len(segments))
	for i, seg := range segments {
		once[i] = awsEscape(seg)
		twice[i] = awsEscape(once[i])
	}
	req.URL.RawPath = strings.Join(once, "/")
	canonPath := strings.Join(twice, "/")
	if canonPath == "" {
		canonPath = "/"
	}
	query := req.URL.Query()
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var pairs []string
	for _, k := range keys {
		values := append([]string(nil), query[k]...)
		sort.Strings(values)
		for _, v := range values {
			pairs = append(pairs, awsEscape(k)+"="+awsEscape(v))
		}
	}
	canonQuery := strings.Join(pairs, "&")
	canonical := strings.Join([]string{req.Method, canonPath, canonQuery, canonHeaders.String(), signed, hex.EncodeToString(payload[:])}, "\n")
	scope := day + "/" + region + "/" + service + "/aws4_request"
	hashed := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(hashed[:])
	mac := func(key []byte, s string) []byte {
		h := hmac.New(sha256.New, key)
		h.Write([]byte(s))
		return h.Sum(nil)
	}
	k := mac(mac(mac(mac([]byte("AWS4"+secretKey), day), region), service), "aws4_request")
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+accessKey+"/"+scope+", SignedHeaders="+signed+
		", Signature="+hex.EncodeToString(mac(k, toSign)))
}

// MARK: counting the provider's tokens (research R5)

// usageMeter reads an answer's usage as it goes by: a stream's events (server-sent events,
// or Bedrock's event stream), or a whole JSON answer. It keeps no more of the body than
// one line or event, or a whole answer up to relayMostCounted.
type usageMeter struct {
	kind  string
	buf   []byte
	over  bool
	usage struct {
		seen                                      bool
		input, output, cacheRead, cacheWrite      int64
		openAICached, geminiCached, geminiThought int64
	}
}

func newUsageMeter(contentType string) *usageMeter {
	kind := "json"
	switch {
	case strings.HasPrefix(contentType, "text/event-stream"):
		kind = "sse"
	case strings.HasPrefix(contentType, "application/vnd.amazon.eventstream"):
		kind = "eventstream"
	}
	return &usageMeter{kind: kind}
}

func (m *usageMeter) write(b []byte) {
	if m.over {
		return
	}
	m.buf = append(m.buf, b...)
	switch m.kind {
	case "sse":
		for {
			i := bytes.IndexByte(m.buf, '\n')
			if i < 0 {
				break
			}
			m.line(m.buf[:i])
			m.buf = m.buf[i+1:]
		}
		if len(m.buf) > relayMostLine {
			m.over = true
		}
	case "eventstream":
		for len(m.buf) >= 12 {
			total := int(binary.BigEndian.Uint32(m.buf[0:4]))
			if total < 16 || total > relayMostLine {
				m.over = true
				return
			}
			if len(m.buf) < total {
				break
			}
			m.bedrockEvent(m.buf[:total])
			m.buf = m.buf[total:]
		}
	default:
		if len(m.buf) > relayMostCounted {
			m.over = true
		}
	}
	if m.over {
		m.buf = nil
	}
}

func (m *usageMeter) line(l []byte) {
	l = bytes.TrimRight(l, "\r")
	data, ok := bytes.CutPrefix(l, []byte("data:"))
	if !ok {
		return
	}
	m.object(bytes.TrimSpace(data))
}

// bedrockEvent is one event of Bedrock's stream: its payload is {"bytes": base64 of an
// Anthropic event}.
func (m *usageMeter) bedrockEvent(frame []byte) {
	headers := int(binary.BigEndian.Uint32(frame[4:8]))
	start, end := 12+headers, len(frame)-4
	if start > end {
		return
	}
	var payload struct {
		Bytes string `json:"bytes"`
	}
	if json.Unmarshal(frame[start:end], &payload) != nil || payload.Bytes == "" {
		return
	}
	if b, err := base64.StdEncoding.DecodeString(payload.Bytes); err == nil {
		m.object(b)
	}
}

// object reads one JSON value's usage, in whichever provider's shape it has.
func (m *usageMeter) object(b []byte) {
	if len(b) == 0 || b[0] == '[' {
		var list []json.RawMessage
		if json.Unmarshal(b, &list) == nil {
			for _, item := range list {
				m.object(item)
			}
		}
		return
	}
	var o struct {
		Type    string       `json:"type"`
		Object  string       `json:"object"`
		Usage   *usageFields `json:"usage"`
		Message *struct {
			Usage *usageFields `json:"usage"`
		} `json:"message"`
		Response *struct {
			Usage *usageFields `json:"usage"`
		} `json:"response"`
		UsageMetadata *struct {
			Prompt   int64 `json:"promptTokenCount"`
			Output   int64 `json:"candidatesTokenCount"`
			Cached   int64 `json:"cachedContentTokenCount"`
			Thoughts int64 `json:"thoughtsTokenCount"`
		} `json:"usageMetadata"`
	}
	if json.Unmarshal(b, &o) != nil {
		return
	}
	u := &m.usage
	switch {
	case o.Type == "message_start" && o.Message != nil && o.Message.Usage != nil:
		f := o.Message.Usage
		u.seen = true
		u.input, u.output, u.cacheRead, u.cacheWrite = f.InputTokens, f.OutputTokens, f.CacheRead, f.CacheWrite
	case o.Type == "message_delta" && o.Usage != nil:
		// Anthropic's counts here are the answer's so far, not more.
		u.seen = true
		u.output = o.Usage.OutputTokens
		if o.Usage.InputTokens > 0 {
			u.input = o.Usage.InputTokens
		}
		if o.Usage.CacheRead > 0 {
			u.cacheRead = o.Usage.CacheRead
		}
		if o.Usage.CacheWrite > 0 {
			u.cacheWrite = o.Usage.CacheWrite
		}
	case o.Type == "message" && o.Usage != nil:
		u.seen = true
		u.input, u.output, u.cacheRead, u.cacheWrite = o.Usage.InputTokens, o.Usage.OutputTokens, o.Usage.CacheRead, o.Usage.CacheWrite
	case o.Type == "response.completed" && o.Response != nil && o.Response.Usage != nil:
		m.openAI(o.Response.Usage)
	case o.Object == "response" && o.Usage != nil:
		m.openAI(o.Usage)
	case strings.HasPrefix(o.Object, "chat.completion") && o.Usage != nil:
		m.openAI(o.Usage)
	case o.UsageMetadata != nil:
		// Gemini's counts are the answer's so far, on each chunk.
		g := o.UsageMetadata
		u.seen = true
		u.input, u.output, u.geminiCached, u.geminiThought = g.Prompt, g.Output, g.Cached, g.Thoughts
	}
}

// openAI is an OpenAI answer's usage: Responses or Chat Completions.
func (m *usageMeter) openAI(f *usageFields) {
	u := &m.usage
	u.seen = true
	u.input, u.output = f.InputTokens+f.PromptTokens, f.OutputTokens+f.CompletionTokens
	u.openAICached = 0
	if f.InputDetails != nil {
		u.openAICached += f.InputDetails.Cached
	}
	if f.PromptDetails != nil {
		u.openAICached += f.PromptDetails.Cached
	}
}

type usageFields struct {
	InputTokens      int64 `json:"input_tokens"`
	OutputTokens     int64 `json:"output_tokens"`
	CacheRead        int64 `json:"cache_read_input_tokens"`
	CacheWrite       int64 `json:"cache_creation_input_tokens"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	InputDetails     *struct {
		Cached int64 `json:"cached_tokens"`
	} `json:"input_tokens_details"`
	PromptDetails *struct {
		Cached int64 `json:"cached_tokens"`
	} `json:"prompt_tokens_details"`
}

// done is the answer's tokens: fresh input, output (thoughts in it), cache reads and
// writes; nil when the answer said none.
func (m *usageMeter) done() *wire.RelayTokens {
	if m.kind == "json" && !m.over {
		m.object(bytes.TrimSpace(m.buf))
	} else if m.kind == "sse" && !m.over && len(m.buf) > 0 {
		m.line(m.buf)
	}
	m.buf = nil
	u := m.usage
	if !u.seen {
		return nil
	}
	t := wire.RelayTokens{Input: u.input, Output: u.output, CacheRead: u.cacheRead, CacheWrite: u.cacheWrite}
	// OpenAI's and Gemini's input counts the cached part; Anthropic's does not.
	if u.openAICached > 0 {
		t.CacheRead, t.Input = u.openAICached, max(0, u.input-u.openAICached)
	}
	if u.geminiCached > 0 {
		t.CacheRead, t.Input = u.geminiCached, max(0, u.input-u.geminiCached)
	}
	t.Output += u.geminiThought
	return &t
}

// awsEscape is AWS's URI encoding: every byte but the unreserved ones.
func awsEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if 'A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
