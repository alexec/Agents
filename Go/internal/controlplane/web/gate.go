package web

import (
	"fmt"
	"net/http"
	"strings"
)

// gate is LoopbackGate: what the listener does with each request, in the contract's
// order. It does not touch the network, so each row of the contract is a test.
type gate struct {
	port  int
	files Files
}

// verdict is LoopbackGate.Verdict: an upgrade, or a reply with a status, the file to send
// (empty for none) and a Location (empty for none).
type verdict struct {
	upgrade  bool
	status   int
	path     string
	location string
}

// plainReply is PlainReply: an answer that is not a WebSocket.
type plainReply struct {
	status      int
	body        []byte
	contentType string
	headers     [][2]string
}

// proxyPaths is LoopbackGate.proxyPaths: the two files of the sandbox proxy (#187).
var proxyPaths = map[string]bool{"/sandbox.html": true, "/sandbox.js": true}

func (g *gate) origin() string { return OriginFor(g.port) }

// proxyOrigin is LoopbackGate.proxyOrigin: the same listener at the address, not the name.
// So it is another origin than the page's, as MCP Apps needs for a web page (#187).
func (g *gate) proxyOrigin() string { return fmt.Sprintf("http://127.0.0.1:%d", g.port) }

// headers is LoopbackGate.headers: sent on every answer, a refusal too.
func (g *gate) headers() [][2]string {
	return [][2]string{
		{"Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; " +
			fmt.Sprintf("font-src 'self'; connect-src ws://localhost:%d; base-uri 'none'; form-action 'none'; ", g.port) +
			fmt.Sprintf("frame-ancestors 'none'; frame-src %s; object-src 'none'; worker-src 'self'; manifest-src 'self'; ", g.proxyOrigin()) +
			"require-trusted-types-for 'script'; trusted-types agents-sw"},
		{"X-Content-Type-Options", "nosniff"},
		{"Referrer-Policy", "no-referrer"},
		{"Cross-Origin-Opener-Policy", "same-origin"},
		{"Cross-Origin-Resource-Policy", "same-origin"},
		{"X-Frame-Options", "DENY"},
		{"Cache-Control", "no-cache"},
	}
}

// proxyHeaders is LoopbackGate.proxyHeaders: the view's own policy, made again from the
// domains in the address (?csp=), and framed by the page only.
func (g *gate) proxyHeaders(uri string) [][2]string {
	return [][2]string{
		{"Content-Security-Policy", policyFor(domains(uri)).header() + "; frame-ancestors " + g.origin()},
		{"X-Content-Type-Options", "nosniff"},
		{"Referrer-Policy", "no-referrer"},
		{"Cross-Origin-Resource-Policy", "same-origin"},
		{"Cache-Control", "no-store"},
	}
}

// pathOf is the request target up to its "?", as the Swift splits head.uri.
func pathOf(uri, empty string) string {
	p, _, _ := strings.Cut(uri, "?")
	if p == "" {
		return empty
	}
	return p
}

// upgrading is true when an Upgrade header says websocket (as HTTPHeaders' canonical form
// reads it: each value split at commas).
func upgrading(h http.Header) bool {
	for _, value := range h.Values("Upgrade") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "websocket") {
				return true
			}
		}
	}
	return false
}

// judge is LoopbackGate.judge. host is the Host header (net/http keeps it apart from the
// other headers), and uri is the request target as sent.
func (g *gate) judge(method, host, uri string, h http.Header) verdict {
	host = strings.ToLower(host)
	canonical := fmt.Sprintf("localhost:%d", g.port)
	address := fmt.Sprintf("127.0.0.1:%d", g.port)
	// 1. DNS rebinding: a name that only resolves here is still refused.
	if host != canonical && host != address && host != fmt.Sprintf("[::1]:%d", g.port) {
		return verdict{status: http.StatusMisdirectedRequest}
	}
	// 2. Nothing here changes anything.
	if method != http.MethodGet {
		return verdict{status: http.StatusMethodNotAllowed}
	}
	p := pathOf(uri, "/")
	up := upgrading(h)
	// The sandbox proxy (#187): at its own origin only, never at the page's.
	if proxyPaths[p] {
		if _, ok := g.files[p]; host != address || up || !ok {
			return verdict{status: http.StatusNotFound}
		}
		return verdict{status: http.StatusOK, path: p}
	}
	// 3. One origin, so one key: the addresses go to the name.
	if host != canonical {
		if up {
			return verdict{status: http.StatusMisdirectedRequest}
		}
		return verdict{status: http.StatusPermanentRedirect, location: "http://" + canonical + p}
	}
	// 4–5. The socket, from this page only.
	if p == "/v1/connect" || up {
		if p != "/v1/connect" || !up {
			return verdict{status: http.StatusBadRequest}
		}
		if h.Get("Origin") != g.origin() {
			return verdict{status: http.StatusForbidden}
		}
		return verdict{upgrade: true}
	}
	// 6–7. The files the manifest lists, and nothing else.
	file := p
	if p == "/" {
		file = "/index.html"
	}
	if _, ok := g.files[file]; !ok {
		return verdict{status: http.StatusNotFound}
	}
	return verdict{status: http.StatusOK, path: file}
}

// reply is LoopbackGate.reply: the answer to a request that is not an upgrade.
func (g *gate) reply(method, host, uri string, h http.Header) plainReply {
	v := g.judge(method, host, uri, h)
	if v.upgrade {
		// Only when the upgrade itself failed after the gate let it through.
		return plainReply{status: http.StatusBadRequest, contentType: "text/plain", headers: g.headers()}
	}
	headers := g.headers()
	if proxyPaths[v.path] {
		headers = g.proxyHeaders(uri)
	} else if v.location != "" {
		headers = append(headers, [2]string{"Location", v.location})
	}
	if f, ok := g.files[v.path]; ok && v.path != "" {
		return plainReply{status: v.status, body: f.Data, contentType: f.ContentType, headers: headers}
	}
	return plainReply{status: v.status, contentType: "text/plain; charset=utf-8", headers: headers}
}
