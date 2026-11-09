package agentsd

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// An HTTP MCP server whose url or a header names a secret with Ask before use (#4120, the
// spike #4013): the runtime is given a route of agentsd's own, on the app's endpoint with the
// session's token (as a hosted server is, hostedmcp.go), and agentsd sends each request on to
// the server with the value in its place. The value is never in the runtime's config or
// process: every session runs as the same user, so a value in one session's process is every
// session's.
//
// The route's first request asks a person, through askSecretUse with the use mcp and the
// server's name as the place, and is never held: a start never waits on a person. Until
// they allow it, each request is refused with words that say which request to wait on; once
// they do, the session's runtime starts again at its next turn (warmKey), so it connects.
// An allowance holds for the route, the runtime's one connection: "once" is that connection.
// A person's deny holds for the route too, so a runtime that tries again does not ask again.
//
// A stdio server, or an sse one, with a flagged ${NAME} is left out, as a server missing a
// secret is: its process, or the stream's own endpoint, would have the value.

const secretProxyPathPrefix = "/mcp/secret/"

type secretProxyState struct {
	secretProxyMu sync.Mutex
	// secretProxies is each route by its id.
	secretProxies map[string]*secretProxy
	// secretProxyStarts counts, by sessionKey, the routes a person allowed after they were
	// refused: warmKey has it, so the runtime starts again and connects.
	secretProxyStarts map[wire.UUID]int
}

// secretProxy is one server a session reaches through agentsd.
type secretProxy struct {
	token string // the session's app token
	agent wire.UUID
	// server is the server's url and headers, every ${NAME} filled but the flagged ones.
	server  sdk.McpServerHttpInline
	flagged []string

	mu      sync.Mutex
	allowed bool
	refused bool
	denied  error
}

// flaggedNames is every ${NAME} of text that flagged says has Ask before use.
func flaggedNames(text string, flagged func(string) bool, into *[]string) {
	for _, m := range secretRef.FindAllStringSubmatch(text, -1) {
		if flagged(m[1]) && !slices.Contains(*into, m[1]) {
			*into = append(*into, m[1])
		}
	}
}

// secretProxySwapped is a session's servers, each with a flagged ${NAME} swapped for its
// route on this endpoint.
func (d *Daemon) secretProxySwapped(entries []sessionEntry, port int, token string, agent wire.UUID) []sessionEntry {
	out := make([]sessionEntry, 0, len(entries))
	for _, e := range entries {
		if len(e.flagged) == 0 || e.server.Http == nil {
			out = append(out, e)
			continue
		}
		route := string(store.NewUUID())
		d.secretProxyMu.Lock()
		if d.secretProxies == nil {
			d.secretProxies = map[string]*secretProxy{}
		}
		d.secretProxies[route] = &secretProxy{token: token, agent: agent, server: *e.server.Http, flagged: e.flagged}
		d.secretProxyMu.Unlock()
		e.server = sdk.McpServer{Http: &sdk.McpServerHttpInline{Name: e.name, Type: "http",
			Url:     "http://127.0.0.1:" + strconv.Itoa(port) + secretProxyPathPrefix + route,
			Headers: []sdk.HttpHeader{{Name: "Authorization", Value: "Bearer " + token}}}}
		out = append(out, e)
	}
	return out
}

// dropSecretProxies takes away the routes of tokens a runtime no longer holds; none at all
// is every route.
func (d *Daemon) dropSecretProxies(tokens []string, all bool) {
	d.secretProxyMu.Lock()
	defer d.secretProxyMu.Unlock()
	for route, p := range d.secretProxies {
		if all || slices.Contains(tokens, p.token) {
			delete(d.secretProxies, route)
		}
	}
}

// secretProxyAnswered is a person's answer to a server's use of a secret. A deny holds for
// the session's routes of it that asked. An allowance starts again the runtime of each route
// of it that was refused, the session's own or, for always, every session's.
func (d *Daemon) secretProxyAnswered(agent wire.UUID, ask wire.RequestSecretUse, action string, always bool) {
	d.secretProxyMu.Lock()
	defer d.secretProxyMu.Unlock()
	for _, p := range d.secretProxies {
		if !strings.EqualFold(p.server.Name, ask.Place) || !always && sessionKey(p.agent) != sessionKey(agent) {
			continue
		}
		p.mu.Lock()
		refused := p.refused && p.denied == nil
		if refused && action == secretUseDeny && slices.Contains(p.flagged, ask.Name) {
			p.denied = errSecretUseDenied{ask.Name, ask.Place}
		}
		p.mu.Unlock()
		if refused && action != secretUseDeny {
			if d.secretProxyStarts == nil {
				d.secretProxyStarts = map[wire.UUID]int{}
			}
			d.secretProxyStarts[sessionKey(p.agent)]++
		}
	}
}

// forgetSecretProxy drops an archived session's count.
func (d *Daemon) forgetSecretProxy(agent wire.UUID) {
	d.secretProxyMu.Lock()
	delete(d.secretProxyStarts, sessionKey(agent))
	d.secretProxyMu.Unlock()
}

// secretProxyStart is warmKey's count for agent.
func (d *Daemon) secretProxyStart(agent wire.UUID) int {
	d.secretProxyMu.Lock()
	defer d.secretProxyMu.Unlock()
	return d.secretProxyStarts[sessionKey(agent)]
}

// secretProxyValues is the flagged values for one request, or the words that say why not.
func (d *Daemon) secretProxyValues(p *secretProxy) (map[string]string, string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.denied != nil {
		return nil, p.denied.Error()
	}
	if !p.allowed {
		for _, n := range p.flagged {
			words, err := d.askSecretUse(p.agent, n, wire.SecretUseMCP, p.server.Name, 0)
			if err != nil {
				p.refused, p.denied = true, err
				return nil, err.Error()
			}
			if words != "" {
				p.refused = true
				return nil, words
			}
		}
		p.allowed = true
	}
	values := map[string]string{}
	for _, n := range p.flagged {
		v, ok, _ := d.localSecret(p.agent, n)
		if !ok || v == "" {
			return nil, "Nothing was sent to the MCP server " + p.server.Name + ": " + n + " is not set on this machine. Ask the person for it with ask_secret."
		}
		values[n] = v
	}
	return values, ""
}

// serveSecretProxy is one request to /mcp/secret/<route>. A token that is not the route's
// is 404: a server that is not there.
func (d *Daemon) serveSecretProxy(w http.ResponseWriter, r *http.Request) {
	route := strings.TrimPrefix(r.URL.Path, secretProxyPathPrefix)
	token := bearer(r.Header.Get("Authorization"))
	d.secretProxyMu.Lock()
	p := d.secretProxies[route]
	d.secretProxyMu.Unlock()
	if p == nil || token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(p.token)) != 1 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	values, words := d.secretProxyValues(p)
	if words != "" {
		refuseSecretProxy(w, r, words)
		return
	}
	var missing []string
	target, err := url.Parse(fill(p.server.Url, values, &missing))
	if err != nil || target.Host == "" || target.Scheme != "http" && target.Scheme != "https" {
		// The url may have the value in it: its words do not.
		refuseSecretProxy(w, r, "The MCP server "+p.server.Name+"'s url is not an http or https url once its secrets are in it.")
		return
	}
	headers := make([]sdk.HttpHeader, len(p.server.Headers))
	for i, h := range p.server.Headers {
		headers[i] = sdk.HttpHeader{Name: h.Name, Value: fill(h.Value, values, &missing)}
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL = target
			pr.Out.Host = target.Host
			// The session's token is agentsd's, never the server's.
			pr.Out.Header.Del("Authorization")
			for _, h := range headers {
				pr.Out.Header.Set(h.Name, h.Value)
			}
		},
		// A stream's events go to the runtime as they come.
		FlushInterval: -1,
		// The default logs the request's url, which may have the value in it.
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			log.Printf("secret proxy: %s did not answer", p.server.Name)
			w.WriteHeader(http.StatusBadGateway)
		},
	}
	proxy.ServeHTTP(w, r)
}

// refuseSecretProxy answers a request agentsd did not send on: a JSON-RPC request gets the
// words as its error, so the runtime shows them; anything else gets them as text.
func refuseSecretProxy(w http.ResponseWriter, r *http.Request, words string) {
	if r.Method == http.MethodPost {
		body, _ := io.ReadAll(io.LimitReader(r.Body, appBodyLimit))
		var m message
		if t := bytes.TrimSpace(body); len(t) > 0 && t[0] == '{' && json.Unmarshal(t, &m) == nil && len(m.ID) > 0 && string(m.ID) != "null" {
			writeJSON(w, mcpFailure(m.ID, CodeNotPermitted, words), "")
			return
		}
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	io.WriteString(w, words)
}
