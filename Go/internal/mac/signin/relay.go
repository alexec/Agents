package signin

import (
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Relay is MacSignInRelay: TLS on 127.0.0.1, ended with the Mac's own certificate, every
// request sent on to Upstream with the Mac's current token in place of the stand-in's. A
// 401 asks the source to renew, once, and the request is asked again.
//
// The loopback port is every local account's to dial, so a request draws this Mac's token
// only when it carries the stand-in bearer handed to the server with the grant (S4).
type Relay struct {
	Upstream string
	Source   Source
	Certs    Certificates
	Log      func(string)
	// Client sends requests on; its transport's TLS is the system's.
	Client *http.Client

	mu       sync.Mutex
	listener net.Listener
	server   *http.Server
	bearer   string
}

// maxBody bounds a request the relay holds to ask again after a 401.
const maxBody = 64 << 20

// Start listens on 127.0.0.1, on a free port, and says which.
func (r *Relay) Start() (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.listener != nil {
		return r.listener.Addr().(*net.TCPAddr).Port, nil
	}
	identity, err := r.Certs.Identity()
	if err != nil {
		return 0, err
	}
	l, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{identity}, MinVersion: tls.VersionTLS12})
	if err != nil {
		return 0, err
	}
	if r.Client == nil {
		r.Client = &http.Client{Timeout: time.Hour}
	}
	r.listener = l
	r.server = &http.Server{Handler: r, ReadHeaderTimeout: 30 * time.Second}
	go r.server.Serve(l)
	return l.Addr().(*net.TCPAddr).Port, nil
}

// Port is where it listens, or 0 before Start.
func (r *Relay) Port() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.listener == nil {
		return 0
	}
	return r.listener.Addr().(*net.TCPAddr).Port
}

// ExpectClientBearer remembers the stand-in bearer given to a server with this grant.
func (r *Relay) ExpectClientBearer(b string) {
	r.mu.Lock()
	r.bearer = b
	r.mu.Unlock()
}

// Stop closes the listener.
func (r *Relay) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.server != nil {
		r.server.Close()
	}
	r.listener, r.server = nil, nil
}

func (r *Relay) log(format string, a ...any) {
	if r.Log != nil {
		r.Log(fmt.Sprintf(format, a...))
	}
}

// dropped are hop-by-hop headers, and the ones the relay sets itself.
var dropped = map[string]bool{"host": true, "authorization": true, "x-api-key": true, "chatgpt-account-id": true,
	"connection": true, "keep-alive": true, "proxy-connection": true, "transfer-encoding": true,
	"content-length": true, "upgrade": true, "te": true, "trailer": true, "accept-encoding": true}

// UpstreamURL is the URL for a request target, or nil unless it is origin-form: a path
// starting with one `/`, then an optional query, in characters a URL may carry as they
// are, every % two hex digits. Built by parts, so nothing in the target can become a user,
// a port or another host; and checked once built.
func UpstreamURL(host, target string) *url.URL {
	if !strings.HasPrefix(target, "/") || strings.HasPrefix(target, "//") {
		return nil
	}
	for i := 0; i < len(target); i++ {
		ch := target[i]
		switch {
		case ch == '%':
			if i+2 >= len(target) || !isHex(target[i+1]) || !isHex(target[i+2]) {
				return nil
			}
		case ch <= ' ' || ch >= 0x7f || strings.IndexByte(`"<>\^`+"`"+`{|}#`, ch) >= 0:
			return nil
		}
	}
	path, query, _ := strings.Cut(target, "?")
	u := &url.URL{Scheme: "https", Host: host, RawQuery: query}
	p, err := url.PathUnescape(path)
	if err != nil {
		return nil
	}
	u.Path, u.RawPath = p, path
	if u.Scheme != "https" || u.Host != host || u.User != nil || u.Port() != "" {
		return nil
	}
	return u
}

func isHex(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}

func bearerOf(h http.Header) string {
	v := h.Get("Authorization")
	if b, ok := strings.CutPrefix(v, "Bearer "); ok {
		return b
	}
	return v
}

func (r *Relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	path := req.URL.Path
	// A WebSocket upgrade is refused plainly: the runtime falls back to HTTPS at once.
	if req.Header.Get("Upgrade") != "" {
		r.log("relay: %s %s -> 404 (no WebSockets)", req.Method, path)
		http.Error(w, "", http.StatusNotFound)
		return
	}
	// The token goes only to the runtime's own service: a target that is not a plain
	// path is refused before the sign-in is read, and not logged.
	u := UpstreamURL(r.Upstream, req.RequestURI)
	if u == nil {
		r.log("relay: %s -> 400 (the request target is not a path)", req.Method)
		http.Error(w, "", http.StatusBadRequest)
		return
	}
	r.mu.Lock()
	expected := r.bearer
	r.mu.Unlock()
	if expected == "" || bearerOf(req.Header) != expected {
		r.log("relay: %s %s -> 403 (not the stand-in)", req.Method, path)
		http.Error(w, "", http.StatusForbidden)
		return
	}
	token, err := r.Source.Current()
	if err != nil {
		r.log("relay: %s %s -> 502 (no sign-in on this Mac)", req.Method, path)
		http.Error(w, "", http.StatusBadGateway)
		return
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		r.log("relay: %s %s -> 413", req.Method, path)
		http.Error(w, "", http.StatusRequestEntityTooLarge)
		return
	}
	resp, err := r.send(req, u, body, token)
	if err == nil && resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		r.log("relay: %s %s -> 401; renewing this Mac's sign-in", req.Method, path)
		if renewed, rerr := r.Source.Renew(req.Context(), token); rerr == nil {
			resp, err = r.send(req, u, body, renewed)
		} else {
			r.log("relay: renewing failed; this Mac's sign-in needs signing in again")
			resp, err = r.send(req, u, body, token)
		}
	}
	if err != nil {
		r.log("relay: %s %s -> 502", req.Method, path)
		http.Error(w, "", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	r.log("relay: %s %s -> %d", req.Method, path, resp.StatusCode)
	for name, values := range resp.Header {
		switch strings.ToLower(name) {
		case "transfer-encoding", "connection", "content-length", "content-encoding", "keep-alive":
			continue
		}
		for _, v := range values {
			w.Header().Add(name, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32<<10)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if rerr != nil {
			return
		}
	}
}

// send is the request as it goes on: everything the runtime sent but its own sign-in and
// hop-by-hop headers, with this Mac's token and the sign-in's headers in their place.
func (r *Relay) send(req *http.Request, u *url.URL, body []byte, token Token) (*http.Response, error) {
	up, err := http.NewRequestWithContext(req.Context(), req.Method, u.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for name, values := range req.Header {
		if dropped[strings.ToLower(name)] {
			continue
		}
		for _, v := range values {
			up.Header.Add(name, v)
		}
	}
	up.Header.Set("Authorization", "Bearer "+token.Access)
	for k, v := range token.Headers {
		up.Header.Set(k, v)
	}
	if len(body) == 0 {
		up.Body, up.ContentLength = http.NoBody, 0
	}
	return r.Client.Do(up)
}
