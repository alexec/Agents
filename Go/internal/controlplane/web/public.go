package web

import (
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// Public is the page on the control plane's own domain (#1459): the same built web app as
// the loopback listener's, served by the control plane's own listener behind its proxy
// (Caddy, compose.public.yaml), at the origin of AGENTS_CONTROL_URL. A browser anywhere
// pairs there by a code, as one on the Mac pairs at localhost. Its key exchange is bound to
// that origin as the browser writes it, so a proof made for the page on the Mac fails here,
// and the other way round.
//
// MCP Apps views (#187) need the sandbox proxy at another origin than the page's (#1484): a
// second name in front of the same control plane (views.<domain>), at which /sandbox.html
// and /sandbox.js are served, and nothing else. The page's policy frames that origin only.
// With no second name, views are not drawn on the page, and the policy frames nothing.
type Public struct {
	origin string
	host   string
	files  Files
	// The sandbox proxy's origin and Host, or "" for none.
	viewsOrigin string
	viewsHost   string
}

// NewPublic loads the files from folder's manifest for the page at address, the control
// plane's https address, with the sandbox proxy at views, another https address ("" for
// none). An error is a *FilesError when the build does not match its manifest, or says an
// address is not one a browser can open the page at.
func NewPublic(folder, address, views string) (*Public, error) {
	origin, host, err := PageOrigin(address)
	if err != nil {
		return nil, err
	}
	p := &Public{origin: origin, host: host}
	if views != "" {
		if p.viewsOrigin, p.viewsHost, err = PageOrigin(views); err != nil {
			return nil, err
		}
		if p.viewsOrigin == origin {
			return nil, fmt.Errorf("%q is the page's own origin: the views need another name", views)
		}
	}
	if p.files, err = LoadFiles(folder); err != nil {
		return nil, err
	}
	return p, nil
}

// PageOrigin is address's origin as a browser writes it (location.origin): no port when it
// is the scheme's own. host is what the browser sends as Host. Only https: a browser keeps
// its key only for a page it reached safely.
func PageOrigin(address string) (origin, host string, err error) {
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" {
		return "", "", fmt.Errorf("%q is not an address a browser can open", address)
	}
	if !strings.EqualFold(u.Scheme, "https") && !strings.EqualFold(u.Scheme, "wss") {
		return "", "", fmt.Errorf("%q is not an https address, which the page needs", address)
	}
	host = strings.ToLower(u.Hostname())
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port := u.Port(); port != "" && port != "443" {
		if _, err := strconv.Atoi(port); err != nil {
			return "", "", fmt.Errorf("%q has no port a browser can open", address)
		}
		host += ":" + port
	}
	return "https://" + host, host, nil
}

// Origin is the page's origin, which its proofs are bound to.
func (p *Public) Origin() string { return p.origin }

// Address is where a person opens the page.
func (p *Public) Address() string { return p.origin + "/" }

// ViewsOrigin is the sandbox proxy's origin, or "" when views are not drawn on the page.
func (p *Public) ViewsOrigin() string { return p.viewsOrigin }

// FromPage is true when an upgrade came from the page itself: a browser always sends its
// page's Origin. A window, a phone or a host sends none, and stays the TLS listener's.
func (p *Public) FromPage(h http.Header) bool { return h.Get("Origin") == p.origin }

// headers is the loopback gate's headers for this origin: the same policy, with the
// page's own socket, only the sandbox proxy framed, and HTTPS kept.
func (p *Public) headers() [][2]string {
	frames := "'none'"
	if p.viewsOrigin != "" {
		frames = p.viewsOrigin
	}
	return [][2]string{
		{"Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; " +
			fmt.Sprintf("font-src 'self'; connect-src wss://%s; base-uri 'none'; form-action 'none'; ", p.host) +
			fmt.Sprintf("frame-ancestors 'none'; frame-src %s; object-src 'none'; worker-src 'self'; manifest-src 'self'; ", frames) +
			"require-trusted-types-for 'script'; trusted-types agents-sw"},
		{"X-Content-Type-Options", "nosniff"},
		{"Referrer-Policy", "no-referrer"},
		{"Cross-Origin-Opener-Policy", "same-origin"},
		{"Cross-Origin-Resource-Policy", "same-origin"},
		{"X-Frame-Options", "DENY"},
		{"Strict-Transport-Security", "max-age=31536000"},
		{"Cache-Control", "no-cache"},
	}
}

// proxyHeaders is the loopback gate's proxyHeaders for the views name: the view's own
// policy, framed by the page only, and HTTPS kept.
func (p *Public) proxyHeaders(uri string) [][2]string {
	return [][2]string{
		{"Content-Security-Policy", policyFor(domains(uri)).header() + "; frame-ancestors " + p.origin},
		{"X-Content-Type-Options", "nosniff"},
		{"Referrer-Policy", "no-referrer"},
		{"Cross-Origin-Resource-Policy", "same-origin"},
		{"Strict-Transport-Security", "max-age=31536000"},
		{"Cache-Control", "no-store"},
	}
}

// Serve answers a request that is not the socket, when it is the page's: a GET of a file
// the manifest lists, at the page's own name, or of the sandbox proxy's two at the views
// name. False leaves the request to the caller (the probes, the install script and its
// files), which refuses the proxy's files at the page's name.
func (p *Public) Serve(w http.ResponseWriter, r *http.Request) bool {
	path := pathOf(r.RequestURI, "/")
	if p.viewsHost != "" && strings.ToLower(r.Host) == p.viewsHost {
		return p.serveProxy(w, r, path)
	}
	file := path
	if path == "/" {
		file = "/index.html"
	}
	f, ok := p.files[file]
	if !ok || proxyPaths[file] {
		return false
	}
	h := w.Header()
	for _, kv := range p.headers() {
		h.Set(kv[0], kv[1])
	}
	switch {
	case strings.ToLower(r.Host) != p.host:
		// Only at its own name, so a name that only resolves here gets nothing (DNS rebinding).
		w.WriteHeader(http.StatusMisdirectedRequest)
	case r.Method != http.MethodGet && r.Method != http.MethodHead:
		w.WriteHeader(http.StatusMethodNotAllowed)
	default:
		h.Set("Content-Type", f.ContentType)
		h.Set("Content-Length", strconv.Itoa(len(f.Data)))
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodGet {
			w.Write(f.Data)
		}
	}
	return true
}

// serveProxy answers at the views name: the sandbox proxy's two files, and nothing else.
func (p *Public) serveProxy(w http.ResponseWriter, r *http.Request, path string) bool {
	f, ok := p.files[path]
	if !ok || !proxyPaths[path] || upgrading(r.Header) {
		return false
	}
	h := w.Header()
	for _, kv := range p.proxyHeaders(r.RequestURI) {
		h.Set(kv[0], kv[1])
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return true
	}
	h.Set("Content-Type", f.ContentType)
	h.Set("Content-Length", strconv.Itoa(len(f.Data)))
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		w.Write(f.Data)
	}
	return true
}
