package service

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

// A client and a host as the #1125 spike's Go agentsd and a window dial: the exchange,
// then lines. Enough to drive the service end to end in one process.

type peer struct {
	ws *websocket.Conn
}

func (p *peer) send(t *testing.T, line string) {
	t.Helper()
	if err := p.ws.Write(context.Background(), websocket.MessageText, []byte(line)); err != nil {
		t.Fatal(err)
	}
}

func (p *peer) read(t *testing.T) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := p.ws.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(b)
}

// readUntil reads lines until one contains want.
func (p *peer) readUntil(t *testing.T, want string) string {
	t.Helper()
	for range 50 {
		if l := p.read(t); strings.Contains(l, want) {
			return l
		}
	}
	t.Fatalf("no line with %s", want)
	return ""
}

func dial(t *testing.T, url, pin, identity string, key, controlKey []byte, kind string) (*peer, error) {
	tlsConfig := &tls.Config{InsecureSkipVerify: true, VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
		leaf, _ := x509.ParseCertificate(raw[0])
		sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
		if auth.ToB64URL(sum[:]) != pin {
			return errors.New("not the pinned certificate")
		}
		return nil
	}}
	ws, _, err := websocket.Dial(context.Background(), strings.Replace(url, "https", "wss", 1)+"/v1/connect",
		&websocket.DialOptions{HTTPClient: &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}}})
	if err != nil {
		return nil, err
	}
	p := &peer{ws: ws}
	var hello struct{ Hello auth.Hello }
	json.Unmarshal([]byte(p.read(t)), &hello)
	if c, _ := auth.B64URL(hello.Hello.Control); string(c) != string(controlKey) {
		return nil, errors.New("wrong control plane")
	}
	sn, _ := auth.B64URL(hello.Hello.Nonce)
	pn := auth.Nonce()
	origin, _ := auth.Origin(url)
	p.send(t, auth.Line("auth", auth.Auth{ID: identity, Nonce: auth.ToB64URL(pn), MAC: auth.ToB64URL(auth.PeerMAC(key, sn, pn, identity, origin)), Kind: kind}))
	line := p.read(t)
	var ok struct {
		OK      *auth.OK `json:"ok"`
		Refused *struct{ Reason string }
	}
	json.Unmarshal([]byte(line), &ok)
	if ok.OK == nil {
		return nil, fmt.Errorf("refused: %s", line)
	}
	if m, _ := auth.B64URL(ok.OK.MAC); string(m) != string(auth.ServerMAC(key, sn, pn, identity, origin)) {
		return nil, errors.New("the ok's MAC does not match")
	}
	return p, nil
}

type world struct {
	s    *Service
	url  string
	pin  string
	ckey []byte
}

func start(t *testing.T) *world {
	tlsConfig, pin, err := SelfSigned(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	// The port is chosen first, so the URL the codes carry is the one listened on.
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: priv, URL: "https://127.0.0.1:1", TLS: tlsConfig, Pin: pin,
		Bind: "127.0.0.1", Port: 0, Name: "test", MachineID: "this-mac", Log: func(l string) { t.Log(l) }})
	if err != nil {
		t.Fatal(err)
	}
	port, err := s.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	url := fmt.Sprintf("https://127.0.0.1:%d", port)
	s.origin, _ = auth.Origin(url)
	s.codes.URL = url
	t.Cleanup(s.Stop)
	return &world{s: s, url: url, pin: pin, ckey: pub}
}

func (w *world) code(t *testing.T, host bool) *auth.Code {
	shown, err := w.s.codes.Issue(context.Background(), host, false, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	c, err := auth.ParseCode(shown.Text)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// pairClient uses a client code (clients/announce), then dials as the client.
func (w *world) pairClient(t *testing.T, kind string) (*peer, string) {
	c := w.code(t, false)
	p, err := dial(t, c.URL, c.Pin, "p:"+c.ID(), auth.CodeKey(c.Secret), c.ControlKey, kind)
	if err != nil {
		t.Fatal(err)
	}
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	id := records.NewUUID()
	b, _ := json.Marshal(map[string]any{"id": id, "publicKey": pub, "name": "a " + kind, "kind": kind})
	p.send(t, `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(b)+`}`)
	if l := p.read(t); !strings.Contains(l, id) {
		t.Fatalf("announce: %s", l)
	}
	key, _ := auth.ClientKey(priv, w.ckey, id)
	cp, err := dial(t, w.url, w.pin, "c:"+id, key, w.ckey, kind)
	if err != nil {
		t.Fatal(err)
	}
	return cp, id
}

// enrolHost uses a host code (hosts/announce), dials as the host and says hello.
func (w *world) enrolHost(t *testing.T, machine string) (*peer, string) {
	c := w.code(t, true)
	p, err := dial(t, c.URL, c.Pin, "e:"+c.ID(), auth.CodeKey(c.Secret), c.ControlKey, "host")
	if err != nil {
		t.Fatal(err)
	}
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	b, _ := json.Marshal(map[string]any{"publicKey": pub, "name": "host on " + machine, "platform": "linux", "version": "test", "machineID": machine})
	p.send(t, `{"jsonrpc":"2.0","id":1,"method":"hosts/announce","params":`+string(b)+`}`)
	var r struct{ Result struct{ Host string } }
	json.Unmarshal([]byte(p.read(t)), &r)
	if r.Result.Host == "" {
		t.Fatal("no host id")
	}
	key, _ := auth.HostKey(priv, w.ckey, r.Result.Host)
	hp, err := dial(t, w.url, w.pin, "h:"+r.Result.Host, key, w.ckey, "host")
	if err != nil {
		t.Fatal(err)
	}
	hp.send(t, `{"c":0,"m":{"jsonrpc":"2.0","id":1,"method":"host/hello","params":{"version":"test","platform":"linux","machineID":"`+machine+`"}}}`)
	hp.readUntil(t, `"c":0`)
	return hp, r.Result.Host
}

func TestPairEnrolAndRoute(t *testing.T) {
	w := start(t)
	host, hostID := w.enrolHost(t, "this-mac")
	if hostID != "mac" {
		t.Fatalf("the host on the control plane's machine is %s, not mac", hostID)
	}
	client, clientID := w.pairClient(t, "mac")
	// The host is given a channel for the client.
	open := host.readUntil(t, `"open"`)
	if !strings.Contains(open, clientID) || strings.Contains(open, `"device"`) {
		t.Fatalf("open: %s", open)
	}
	var f struct{ C int }
	json.Unmarshal([]byte(open), &f)

	// The control plane's own method.
	client.send(t, `{"m":{"jsonrpc":"2.0","id":7,"method":"control/status"}}`)
	status := client.readUntil(t, `"id":7`)
	if !strings.Contains(status, `"homeHost":"mac"`) || !strings.Contains(status, clientID) {
		t.Fatalf("status: %s", status)
	}

	// A request for the host goes down the channel as its bytes, and the reply comes back.
	client.send(t, `{"h":"mac","m":{"jsonrpc":"2.0","id":8,"method":"agents/list","params":{}}}`)
	down := host.readUntil(t, "agents/list")
	if down != fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":8,"method":"agents/list","params":{}}}`, f.C) {
		t.Fatalf("down: %s", down)
	}
	host.send(t, fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":8,"result":[]}}`, f.C))
	if up := client.readUntil(t, `"id":8`); up != `{"h":"mac","m":{"jsonrpc":"2.0","id":8,"result":[]}}` {
		t.Fatalf("up: %s", up)
	}

	// A broadcast fanned out once comes to the client wrapped.
	host.send(t, fmt.Sprintf(`{"f":[%d],"m":{"jsonrpc":"2.0","method":"agents/changed","params":{}}}`, f.C))
	client.readUntil(t, "agents/changed")

	// A question left when the host goes is answered hostOffline (#77).
	client.send(t, `{"h":"mac","m":{"jsonrpc":"2.0","id":9,"method":"agents/list","params":{}}}`)
	host.readUntil(t, `"id":9`)
	host.ws.Close(websocket.StatusNormalClosure, "")
	if l := client.readUntil(t, `"id":9`); !strings.Contains(l, "-32090") {
		t.Fatalf("offline: %s", l)
	}
	client.readUntil(t, `"state":"offline"`)
	client.send(t, `{"h":"mac","m":{"jsonrpc":"2.0","id":10,"method":"agents/list"}}`)
	if l := client.readUntil(t, `"id":10`); !strings.Contains(l, "-32090") {
		t.Fatalf("offline: %s", l)
	}
	client.send(t, `{"h":"nope","m":{"jsonrpc":"2.0","id":11,"method":"agents/list"}}`)
	if l := client.readUntil(t, `"id":11`); !strings.Contains(l, "-32091") {
		t.Fatalf("no such host: %s", l)
	}
}

// Today's Remote speaks bare JSON-RPC to the home host.
func TestALegacyClientReachesTheHomeHost(t *testing.T) {
	w := start(t)
	host, _ := w.enrolHost(t, "this-mac")
	phone, _ := w.pairClient(t, "iPhone")
	open := host.readUntil(t, `"open"`)
	if !strings.Contains(open, `"device"`) {
		t.Fatalf("a phone's channel is bound to it: %s", open)
	}
	var f struct{ C int }
	json.Unmarshal([]byte(open), &f)
	phone.send(t, `{"jsonrpc":"2.0","id":1,"method":"daemon/ping"}`)
	host.readUntil(t, "daemon/ping")
	host.send(t, fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":1,"result":{}}}`, f.C))
	if l := phone.read(t); l != `{"jsonrpc":"2.0","id":1,"result":{}}` {
		t.Fatalf("bare reply: %s", l)
	}
	phone.send(t, `{"jsonrpc":"2.0","id":2,"method":"clients/list"}`)
	if l := phone.read(t); !strings.Contains(l, `"result":[`) || strings.HasPrefix(l, `{"m"`) {
		t.Fatalf("control's own, bare: %s", l)
	}
}

// Two hosts at once: each client gets a channel on each, and each reply comes back named.
func TestTwoHosts(t *testing.T) {
	w := start(t)
	a, _ := w.enrolHost(t, "this-mac")
	b, bID := w.enrolHost(t, "server")
	if bID == "mac" {
		t.Fatal("a second machine's host is not mac")
	}
	client, _ := w.pairClient(t, "mac")
	for _, h := range []struct {
		p  *peer
		id string
	}{{a, "mac"}, {b, bID}} {
		open := h.p.readUntil(t, `"open"`)
		var f struct{ C int }
		json.Unmarshal([]byte(open), &f)
		client.send(t, `{"h":"`+h.id+`","m":{"jsonrpc":"2.0","id":"x","method":"daemon/ping"}}`)
		h.p.readUntil(t, "daemon/ping")
		h.p.send(t, fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":"x","result":{"who":"%s"}}}`, f.C, h.id))
		if l := client.readUntil(t, `"who"`); !strings.HasPrefix(l, `{"h":"`+h.id+`"`) {
			t.Fatalf("reply: %s", l)
		}
	}
	client.send(t, `{"m":{"jsonrpc":"2.0","id":3,"method":"hosts/list"}}`)
	l := client.readUntil(t, `"id":3`)
	if strings.Count(l, `"state":"online"`) != 2 {
		t.Fatalf("hosts: %s", l)
	}
}

func TestACodeIsUsedOnce(t *testing.T) {
	w := start(t)
	c := w.code(t, false)
	announce := func(pub []byte) string {
		p, err := dial(t, c.URL, c.Pin, "p:"+c.ID(), auth.CodeKey(c.Secret), c.ControlKey, "mac")
		if err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(map[string]any{"id": records.NewUUID(), "publicKey": pub, "name": "w", "kind": "mac"})
		p.send(t, `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(b)+`}`)
		return p.read(t)
	}
	first := announce([]byte{4, 1})
	if !strings.Contains(first, "result") {
		t.Fatal(first)
	}
	if l := announce([]byte{4, 2}); !strings.Contains(l, "This code has been used") {
		t.Fatalf("second key: %s", l)
	}
}

func TestAForgottenClientIsClosedAndRefused(t *testing.T) {
	w := start(t)
	a, aID := w.pairClient(t, "mac")
	b, _ := w.pairClient(t, "mac")
	b.send(t, `{"m":{"jsonrpc":"2.0","id":1,"method":"clients/forget","params":{"client":"`+aID+`"}}}`)
	b.readUntil(t, `"id":1`)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err := a.ws.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != forgottenCloseCode {
				t.Fatalf("closed with %v", err)
			}
			break
		}
	}
}

// A sign-in lent between two hosts (T091): a channel on each, joined, bytes untouched.
func TestATunnelJoinsTwoHosts(t *testing.T) {
	w := start(t)
	lender, _ := w.enrolHost(t, "this-mac")
	borrower, bID := w.enrolHost(t, "server")
	client, _ := w.pairClient(t, "mac")
	lender.readUntil(t, `"open"`)
	borrower.readUntil(t, `"open"`)
	borrower.send(t, `{"c":0,"m":{"jsonrpc":"2.0","id":5,"method":"tunnel/open","params":{"runtime":"claude","ref":"r1"}}}`)
	if l := borrower.readUntil(t, `"id":5`); !strings.Contains(l, "-32045") {
		t.Fatalf("not lent yet: %s", l)
	}
	client.send(t, `{"m":{"jsonrpc":"2.0","id":1,"method":"hosts/lendSignIn","params":{"host":"`+bID+`","from":"mac","runtime":"claude","allowed":true}}}`)
	client.readUntil(t, `"id":1`)
	borrower.send(t, `{"c":0,"m":{"jsonrpc":"2.0","id":6,"method":"tunnel/open","params":{"runtime":"claude","ref":"r1"}}}`)
	near := borrower.readUntil(t, `"tunnelRef":"r1"`)
	far := lender.readUntil(t, `"tunnel":"claude"`)
	var n, f struct{ C int }
	json.Unmarshal([]byte(near), &n)
	json.Unmarshal([]byte(far), &f)
	borrower.send(t, fmt.Sprintf(`{"c":%d,"m":"aGVsbG8="}`, n.C))
	if l := lender.readUntil(t, "aGVsbG8="); l != fmt.Sprintf(`{"c":%d,"m":"aGVsbG8="}`, f.C) {
		t.Fatalf("far end: %s", l)
	}
	lender.send(t, fmt.Sprintf(`{"c":%d,"close":true}`, f.C))
	borrower.readUntil(t, fmt.Sprintf(`{"c":%d,"close":true}`, n.C))
}
