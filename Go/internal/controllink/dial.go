package controllink

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"net/url"
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

// Dial opens wss://…/v1/connect. With a pin, only a certificate whose SPKI hashes to it is
// taken and no trust store is read (R6); without one, the system roots decide.
func Dial(ctx context.Context, base, pin string) (*Lines, error) {
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
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if pin != "" {
		tlsConfig.InsecureSkipVerify = true
		tlsConfig.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
			if len(raw) == 0 {
				return errors.New("no certificate")
			}
			leaf, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
			if B64URL(sum[:]) != pin {
				return fmt.Errorf("the certificate is not the pinned one")
			}
			return nil
		}
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}}
	dctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(dctx, u.String(), &websocket.DialOptions{HTTPClient: client})
	if err != nil {
		return nil, err
	}
	ws.SetReadLimit(64 << 20)
	return &Lines{ws: ws}, nil
}

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
	m, ok := ParseMessage(hello)
	if !ok || m.Hello == nil {
		l.Close()
		return nil, nil, fmt.Errorf("expected hello, got %s", hello)
	}
	id, ok := ParseIdentity(cr.Identity)
	if !ok {
		l.Close()
		return nil, nil, fmt.Errorf("%s is not an identity", cr.Identity)
	}
	auth, expect, err := Answer(m.Hello, id, cr.Key, origin, cr.Kind, cr.ControlKey, "", cr.Epoch)
	if err != nil {
		l.Close()
		return nil, nil, err
	}
	if err := l.Write(ctx, Message{Auth: auth}.Line()); err != nil {
		l.Close()
		return nil, nil, err
	}
	reply, err := l.Read(rctx)
	if err != nil {
		l.Close()
		return nil, nil, fmt.Errorf("no ok: %w", err)
	}
	m, ok = ParseMessage(reply)
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
	return l, m.OK, nil
}

// Credentials are who a peer proves it is, and the key it proves it with.
type Credentials struct {
	Identity   string // c:<UUID>, h:<host>, p:<code id>, e:<code id>
	Key        []byte
	Kind       string
	ControlKey []byte
	Epoch      *int
}
