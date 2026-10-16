package controllink

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeControl is the control plane's end of the exchange, as ControlService.swift does it,
// enough to enrol a host, take its uplink, and open a channel to it.
type fakeControl struct {
	t       *testing.T
	private []byte
	secret  []byte // the host code's
	host    string
	srv     *httptest.Server
	hellos  chan HostHello
	channel chan string // what the host wrote on channel 1
	refuse  bool

	mu         sync.Mutex
	hostPublic []byte // from hosts/announce
}

func newFakeControl(t *testing.T) *fakeControl {
	f := &fakeControl{t: t, private: NewPrivateKey(), secret: make([]byte, 32), host: "k3rs7zgm",
		hellos: make(chan HostHello, 4), channel: make(chan string, 16)}
	rand.Read(f.secret)
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeControl) code() *Code {
	pub, _ := PublicKey(f.private)
	return &Code{Host: true, ControlKey: pub, Secret: f.secret, URL: f.srv.URL, Name: "scratch"}
}

func (f *fakeControl) serve(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/connect" {
		http.NotFound(w, r)
		return
	}
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ctx := r.Context()
	l := &Lines{ws: ws}
	nonce := make([]byte, 32)
	rand.Read(nonce)
	pub, _ := PublicKey(f.private)
	hello, _ := json.Marshal(map[string]Hello{"hello": {V: authVersion, Name: "scratch", Control: ToB64URL(pub), Nonce: ToB64URL(nonce), Copy: "a"}})
	l.Write(ctx, string(hello))
	line, err := l.Read(ctx)
	if err != nil {
		return
	}
	var m map[string]Auth
	json.Unmarshal([]byte(line), &m)
	a := m["auth"]
	var key []byte
	switch {
	case strings.HasPrefix(a.ID, "e:"):
		key = CodeKey(f.secret)
	case a.ID == "h:"+f.host:
		// The control plane's side of HostKey: ECDH of its private key and the host's public one.
		key = f.hostKey()
	}
	peer, _ := B64URL(a.Nonce)
	origin, _ := Origin(f.srv.URL)
	tr := transcript(nonce, peer, a.ID, origin)
	got, _ := B64URL(a.MAC)
	if key == nil || f.refuse || string(got) != string(hmac256(key, []byte("c"), tr)) {
		l.Write(ctx, `{"refused":{"reason":"unknown"}}`)
		return
	}
	ok, _ := json.Marshal(map[string]OK{"ok": {MAC: ToB64URL(hmac256(key, []byte("s"), tr))}})
	l.Write(ctx, string(ok))
	if strings.HasPrefix(a.ID, "e:") {
		req, _ := l.Read(ctx)
		var call struct {
			Method string `json:"method"`
			Params struct {
				PublicKey []byte `json:"publicKey"`
			} `json:"params"`
		}
		json.Unmarshal([]byte(req), &call)
		if call.Method != "hosts/announce" {
			f.t.Errorf("enrol said %s", call.Method)
		}
		f.mu.Lock()
		f.hostPublic = call.Params.PublicKey
		f.mu.Unlock()
		l.Write(ctx, `{"jsonrpc":"2.0","id":1,"result":{"host":"`+f.host+`"}}`)
		return
	}
	// The uplink: host/hello on channel 0, then a channel opened and a message on it.
	first, _ := l.Read(ctx)
	var frame struct {
		C int `json:"c"`
		M struct {
			Method string    `json:"method"`
			Params HostHello `json:"params"`
		} `json:"m"`
	}
	json.Unmarshal([]byte(first), &frame)
	if frame.C != 0 || frame.M.Method != "host/hello" {
		f.t.Errorf("first uplink line %s", first)
	}
	f.hellos <- frame.M.Params
	l.Write(ctx, `{"c":1,"open":{"client":"C","device":"D1"}}`)
	l.Write(ctx, `{"c":1,"m":{"jsonrpc":"2.0","id":7,"method":"daemon/ping"}}`)
	for {
		line, err := l.Read(ctx)
		if err != nil {
			return
		}
		f.channel <- line
	}
}

func (f *fakeControl) hostKey() []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	k, err := HostKey(f.private, f.hostPublic, f.host)
	if err != nil {
		f.t.Fatal(err)
	}
	return k
}

func TestParseCode(t *testing.T) {
	f := newFakeControl(t)
	c := f.code()
	text := "agents-control:2:h:-:" + ToB64URL(c.ControlKey) + ":" + ToB64URL(c.Secret) + ":https%3A%2F%2F10.0.0.2%3A8787:abc_-:my%20plane"
	got, err := ParseCode(text)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Host || got.URL != "https://10.0.0.2:8787" || got.Pin != "abc_-" || got.Name != "my plane" || got.ID() != c.ID() {
		t.Fatalf("parsed %+v", got)
	}
	if _, err := ParseCode("agents-control:1:h:x"); err == nil {
		t.Fatal("a version 1 code parsed")
	}
}

func TestOrigin(t *testing.T) {
	for in, want := range map[string]string{
		"wss://Plane.example":        "https://plane.example:443",
		"http://10.0.0.2:8787/v1/x": "http://10.0.0.2:8787",
		"ws://h":                     "http://h:80",
	} {
		if got, _ := Origin(in); got != want {
			t.Errorf("Origin(%q) = %q, want %q", in, got, want)
		}
	}
}

// A host enrols with its code, keeps control-host.json, dials as h:<host>, says host/hello
// on channel 0 and serves a channel the control plane opens.
func TestEnrolThenUplink(t *testing.T) {
	f := newFakeControl(t)
	root := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	private, err := HostPrivateKey(root)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := HostPrivateKey(root)
	if string(again) != string(private) {
		t.Fatal("the host key changed between reads")
	}
	hello := HostHello{Version: "1.2.3", Platform: "Linux arm64", MachineID: "m1", Name: "devbox", Implementation: "go"}
	m, err := Enroll(ctx, root, f.code(), private, hello)
	if err != nil {
		t.Fatal(err)
	}
	if m.Host != f.host {
		t.Fatalf("host %q", m.Host)
	}
	if _, err := os.Stat(filepath.Join(root, "control-host.json")); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadMembership(root)
	if err != nil || loaded.Host != f.host || loaded.URL != f.srv.URL {
		t.Fatalf("loaded %+v %v", loaded, err)
	}
	served := make(chan string, 4)
	u := &Uplink{Root: root, Member: loaded, Private: private, Hello: hello, Accept: func(c Conn) {
		if c.Device() != "D1" {
			t.Errorf("device %q", c.Device())
		}
		for line := range c.In() {
			served <- line
			c.Write(`{"jsonrpc":"2.0","id":7,"result":{}}`)
		}
	}}
	go u.Run(ctx)
	select {
	case h := <-f.hellos:
		if h.Host != f.host || h.Implementation != "go" || h.Version != "1.2.3" {
			t.Fatalf("hello %+v", h)
		}
	case <-ctx.Done():
		t.Fatal("no host/hello")
	}
	if line := <-served; !strings.Contains(line, "daemon/ping") {
		t.Fatalf("served %s", line)
	}
	if line := <-f.channel; line != `{"c":1,"m":{"jsonrpc":"2.0","id":7,"result":{}}}` {
		t.Fatalf("reply frame %s", line)
	}
}

func TestEnrolRefused(t *testing.T) {
	f := newFakeControl(t)
	f.refuse = true
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := Enroll(ctx, t.TempDir(), f.code(), NewPrivateKey(), HostHello{})
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("err %v", err)
	}
}

// The membership file keeps the Swift ControlMembership's shape: Data as base64.
func TestMembershipShape(t *testing.T) {
	root := t.TempDir()
	m := &Membership{Host: "h1", ControlKey: []byte{4, 1, 2}, Addresses: []string{}, Name: "n", URL: "https://x"}
	if err := m.Save(root); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(root, "control-host.json"))
	if !strings.Contains(string(b), `"controlKey":"BAEC"`) {
		t.Fatalf("file %s", b)
	}
}
