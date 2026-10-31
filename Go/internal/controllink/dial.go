package controllink

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Lines is a WebSocket carrying one line per text frame, as WebSocketLineTransport does.
type Lines struct {
	ws *websocket.Conn
	mu sync.Mutex
}

func (l *Lines) Write(ctx context.Context, line string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return l.ws.Write(ctx, websocket.MessageText, []byte(line))
}

func (l *Lines) Read(ctx context.Context) (string, error) {
	_, b, err := l.ws.Read(ctx)
	return string(b), err
}

func (l *Lines) Close() { l.ws.Close(websocket.StatusNormalClosure, "") }

// Socket is the WebSocket under the lines, for a caller that keeps its own queue on it:
// the control plane's link to another copy.
func (l *Lines) Socket() *websocket.Conn { return l.ws }

// MaxMessage is the largest message a socket dialled here reads. A longer one fails the
// read and closes the link, so the control plane keeps what it sends under it (#2730).
const MaxMessage = 64 << 20

// Dial opens wss://…/v1/connect. With a pin, only a certificate whose SPKI hashes to it is
// taken and no trust store is read (R6); without one, TrustRoots decide. It goes through
// the network's proxy, if there is one (network.go).
func Dial(ctx context.Context, base, pin string) (*Lines, error) { return dial(ctx, base, pin, "") }

// DialOrigin opens the web remote's socket as the page does: plain ws on loopback, with
// the page's own Origin, which the loopback listener checks (071).
func DialOrigin(ctx context.Context, base, origin string) (*Lines, error) {
	return dial(ctx, base, "", origin)
}

func dial(ctx context.Context, base, pin, origin string) (*Lines, error) {
	u, err := url.Parse(base)
	if err != nil {
		return nil, err
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	}
	u.Path = "/v1/connect"
	// Through the network's proxy, trusting its CA too (#2177).
	client := &http.Client{Transport: transport(pin)}
	dctx, cancel := context.WithTimeout(ctx, dialWait)
	defer cancel()
	options := &websocket.DialOptions{HTTPClient: client}
	if origin != "" {
		options.HTTPHeader = http.Header{"Origin": []string{origin}}
	}
	ws, _, err := websocket.Dial(dctx, u.String(), options)
	if err != nil {
		if ctx.Err() == nil && errors.Is(dctx.Err(), context.DeadlineExceeded) {
			// Such as a tunnel's dead remote forward, which takes the connection and never
			// answers (#1770).
			return nil, fmt.Errorf("%s took the connection but did not answer within %s", u.Host, dialWait)
		}
		return nil, err
	}
	ws.SetReadLimit(MaxMessage)
	return &Lines{ws: ws}, nil
}

// dialWait is how long a dial has to get the control plane's answer, TLS and the upgrade.
var dialWait = 10 * time.Second

// Join dials and proves credentials: hello, auth, ok.
func Join(ctx context.Context, base, pin string, cr Credentials) (*Lines, *OK, error) {
	origin, err := Origin(base)
	if err != nil {
		return nil, nil, err
	}
	l, err := Dial(ctx, base, pin)
	if err != nil {
		return nil, nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	hello, err := l.Read(rctx)
	if err != nil {
		l.Close()
		return nil, nil, fmt.Errorf("no hello: %w", err)
	}
	h, ok := ParseMessage(hello)
	if !ok || h.Hello == nil {
		l.Close()
		return nil, nil, fmt.Errorf("expected hello, got %s", hello)
	}
	id, ok := ParseIdentity(cr.Identity)
	if !ok {
		l.Close()
		return nil, nil, fmt.Errorf("%q is not an identity", cr.Identity)
	}
	auth, expect, err := Answer(h.Hello, id, cr.Key, origin, cr.Kind, cr.ControlKey, "", cr.Epoch)
	if err != nil {
		l.Close()
		return nil, nil, err
	}
	auth.Capabilities = cr.Capabilities
	if err := l.Write(ctx, Message{Auth: auth}.Line()); err != nil {
		l.Close()
		return nil, nil, err
	}
	reply, err := l.Read(rctx)
	if err != nil {
		l.Close()
		return nil, nil, fmt.Errorf("no ok: %w", err)
	}
	m, ok := ParseMessage(reply)
	switch {
	case !ok:
		l.Close()
		return nil, nil, fmt.Errorf("expected ok, got %s", reply)
	case m.OK == nil:
		l.Close()
		return nil, nil, Refuse(m.Refused)
	}
	if err := Check(m.OK, expect); err != nil {
		l.Close()
		return nil, nil, err
	}
	// Rotated (#997): the new key, only once its proof is checked; Adopt then keeps it.
	if _, err := NewKey(m.OK, cr.Key); err != nil {
		l.Close()
		return nil, nil, err
	}
	return l, m.OK, nil
}

// Credentials are who a peer proves it is, and the key it proves it with.
type Credentials struct {
	Identity   string // e:<id>, h:<host>, c:<client>, p:<id>
	Key        []byte
	Kind       string
	ControlKey []byte // the control plane's key the peer already trusts, or nil
	Epoch      *int
	// What a client says it has (#1748); nil from a host, which says its own in host/hello.
	Capabilities []string
}

// TestTrustRoots is TestTrustRoot.swift: a walk's stand-in for a publicly trusted root
// (#61, Pebble), one more CA that counts for a control plane with no pin, so a certificate
// from a test CA counts as public without touching this Mac's trust settings.
// AGENTS_TEST_TRUST_ROOT holds the root as PEM, or as its DER in base64; Agents Host passes
// it on only in a Debug build. Nil, the system roots alone, when it is not set.
func TestTrustRoots() *x509.CertPool {
	text := strings.TrimSpace(os.Getenv("AGENTS_TEST_TRUST_ROOT"))
	if text == "" {
		return nil
	}
	pool, err := x509.SystemCertPool()
	if err != nil {
		pool = x509.NewCertPool()
	}
	if strings.Contains(text, "-----BEGIN") {
		pool.AppendCertsFromPEM([]byte(text))
	} else if der, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(text), "")); err == nil {
		if cert, err := x509.ParseCertificate(der); err == nil {
			pool.AddCert(cert)
		}
	}
	return pool
}
