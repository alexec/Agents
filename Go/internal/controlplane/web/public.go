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
// It has no second origin for the sandbox proxy (#187), so MCP Apps views are not drawn on
// it: /sandbox.html and /sandbox.js are not served, and the policy frames nothing.
type Public struct {
	origin string
	host   string
	files  Files
}

// NewPublic loads the files from folder's manifest for the page at address, the control
// plane's https address. An error is a *FilesError when the build does not match its
// manifest, or says the address is not one a browser can open the page at.
func NewPublic(folder, address string) (*Public, error) {
	origin, host, err := PageOrigin(address)
	if err != nil {
		return nil, err
	}
	files, err := LoadFiles(folder)
	if err != nil {
		return nil, err
	}
	return &Public{origin: origin, host: host, files: files}, nil
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

// FromPage is true when an upgrade came from the page itself: a browser always sends its
// page's Origin. A window, a phone or a host sends none, and stays the TLS listener's.
func (p *Public) FromPage(h http.Header) bool { return h.Get("Origin") == p.origin }

// headers is the loopback gate's headers for this origin: the same policy, with the
// page's own socket, nothing framed, and HTTPS kept.
func (p *Public) headers() [][2]string {
	return [][2]string{
		{"Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; " +
			fmt.Sprintf("font-src 'self'; connect-src wss://%s; base-uri 'none'; form-action 'none'; ", p.host) +
			"frame-ancestors 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; manifest-src 'self'; " +
			"require-trusted-types-for 'script'; trusted-types 'none'"},
		{"X-Content-Type-Options", "nosniff"},
		{"Referrer-Policy", "no-referrer"},
		{"Cross-Origin-Opener-Policy", "same-origin"},
		{"Cross-Origin-Resource-Policy", "same-origin"},
		{"X-Frame-Options", "DENY"},
		{"Strict-Transport-Security", "max-age=31536000"},
		{"Cache-Control", "no-cache"},
	}
}

// Serve answers a request that is not the socket, when it is the page's: a GET of a file
// the manifest lists, at the page's own name. False leaves the request to the caller (the
// probes, the install script and its files).
func (p *Public) Serve(w http.ResponseWriter, r *http.Request) bool {
	path := pathOf(r.RequestURI, "/")
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
